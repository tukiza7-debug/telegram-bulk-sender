"""Runner: wires the pipeline and owns the run lifecycle.

    ConfigLoader -> Source -> Validator -> Planner(dry-run)
        -> RateLimitedExecutor -> TelegramClient -> CheckpointStore
        -> Reporter

The runner is the only module that builds the real HTTP client, owns the
derivative temp dir, and maps outcomes to an exit code. Tests inject a
client_factory (usually the FakeTelegramClient) so no test touches network.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import threading
import uuid
from dataclasses import dataclass, replace as dataclass_replace
from pathlib import Path
from typing import Callable, Protocol

from .config import Config, ValidationConfig, resolve_token
from .discovery import order_candidates, scan_directory
from .errors import ExitCode, SecretError, ValidationError
from .executor import RateLimitedExecutor
from .model import (
    CaptionMode,
    ImageCandidate,
    OrderKey,
    PlannedSend,
    Recipient,
    RunSummary,
    ValidatedImage,
)
from .planner import PlanBuild, Planner
from .reporter import Reporter, format_summary, utc_now_iso
from .sources import ManifestRow, read_manifest
from .state import CheckpointStore
from .telegram.base import TelegramClient
from .telegram.http_client import TelegramHttpClient
from .validation import ImageRejected, build_derivative, validate_image

PrintFn = Callable[..., None]
MODES = ("folder", "manifest", "single")


class ClientFactory(Protocol):
    """Builds the TelegramClient for a run. The default uses real HTTP;
    tests inject the in-memory fake (interface isolation, spec 3)."""

    def __call__(self, config: Config, env: dict[str, str]) -> TelegramClient: ...


def _default_client_factory(config: Config, env: dict[str, str]) -> TelegramClient:
    token = resolve_token(config, env, required=True)
    if token is None:  # cannot happen: resolve_token(required=True) raises
        raise SecretError("bot token missing")
    return TelegramHttpClient(config.telegram, token)


@dataclass
class RunRequest:
    """Everything one execution needs, already merged from CLI/file/env."""

    config: Config
    mode: str
    source_dir: str | None = None
    manifest_path: str | None = None
    single_file: str | None = None
    recipients: tuple[str, ...] = ()
    caption_mode: CaptionMode | None = None
    caption_text: str | None = None
    order: OrderKey | None = None
    reverse: bool | None = None
    recursive: bool | None = None
    include: tuple[str, ...] = ()
    exclude: tuple[str, ...] = ()
    limit: int | None = None
    dry_run: bool = False
    state_file: str | None = None
    report_dir: str | None = None
    stop_event: threading.Event | None = None
    max_attempts: int | None = None
    concurrency: int | None = None
    timeout_seconds: float | None = None
    api_base_url: str | None = None
    resize_if_over_limit: bool | None = None
    normalize_exif: bool | None = None

    def effective_config(self) -> Config:
        """Config with CLI-level overrides applied (CLI wins, spec 4)."""
        config = self.config
        telegram = config.telegram
        if self.timeout_seconds is not None:
            telegram = dataclass_replace(telegram, timeout_seconds=self.timeout_seconds)
        if self.api_base_url is not None:
            telegram = dataclass_replace(telegram, api_base_url=self.api_base_url)
        send = config.send
        if self.max_attempts is not None:
            send = dataclass_replace(send, max_attempts=self.max_attempts)
        if self.concurrency is not None:
            send = dataclass_replace(send, concurrency=self.concurrency)
        validation = config.validation
        if self.resize_if_over_limit is not None:
            validation = dataclass_replace(
                validation, resize_if_over_limit=self.resize_if_over_limit
            )
        if self.normalize_exif is not None:
            validation = dataclass_replace(validation, normalize_exif=self.normalize_exif)
        return dataclass_replace(config, telegram=telegram, send=send, validation=validation)


@dataclass
class RunResult:
    summary: RunSummary
    exit_code: ExitCode
    report_location: str

    @property
    def human_summary(self) -> str:
        return format_summary(self.summary, self.report_location)


def run(
    request: RunRequest,
    *,
    env: dict[str, str] | None = None,
    client_factory: ClientFactory = _default_client_factory,
    print_fn: PrintFn = print,
) -> RunResult:
    """Execute one run end-to-end. Raises only TbisError subclasses."""
    if request.mode not in MODES:
        raise ValidationError([f"unknown mode {request.mode!r}; expected one of "
                               f"{', '.join(MODES)}"])
    environment = env if env is not None else dict(os.environ)
    config = request.effective_config()
    run_id = uuid.uuid4().hex[:12]
    summary = RunSummary(run_id=run_id, started_at=utc_now_iso(), dry_run=request.dry_run)

    # -- Source ------------------------------------------------------------
    rows: list[ManifestRow] | None = None
    if request.mode == "folder":
        if not request.source_dir:
            raise ValidationError(["folder mode requires --source-dir"])
        raw_candidates, rejections = scan_directory(
            request.source_dir,
            recursive=(request.recursive if request.recursive is not None
                       else config.defaults.recursive),
            include=request.include,
            exclude=request.exclude,
        )
        if rejections:
            raise ValidationError([f"{path}: {reason}" for path, reason in rejections])
        order = request.order if request.order is not None else config.defaults.order
        reverse = request.reverse if request.reverse is not None else config.defaults.reverse
        ordered_candidates = order_candidates(raw_candidates, order, reverse)
    elif request.mode == "manifest":
        if not request.manifest_path:
            raise ValidationError(["manifest mode requires --manifest"])
        order = request.order if request.order is not None else OrderKey.MANIFEST_ROW
        reverse = request.reverse if request.reverse is not None else False
        rows = read_manifest(request.manifest_path, order=order, reverse=reverse)
        ordered_candidates = _candidates_from_rows(rows)
    else:
        if not request.single_file:
            raise ValidationError(["single mode requires --file"])
        path = Path(request.single_file)
        if not path.is_file():
            raise ValidationError([f"file not found: {request.single_file}"])
        stat = path.stat()
        ordered_candidates = [
            ImageCandidate(path=str(path), mtime_ns=stat.st_mtime_ns, size=stat.st_size)
        ]

    # -- Validator ----------------------------------------------------------
    issues: list[str] = []
    validated: list[ValidatedImage] = []
    for candidate in ordered_candidates:
        try:
            validated.append(validate_image(candidate, config.validation))
        except ImageRejected as exc:
            issues.append(f"{exc.path}: {exc.reason}")
    if issues:
        raise ValidationError(issues)

    derivative_dir: str | None = None
    try:
        if config.validation.resize_if_over_limit or config.validation.normalize_exif:
            derivative_dir = tempfile.mkdtemp(prefix="tbis-derivatives-")
            validated = [
                _with_derivative(image, config.validation, derivative_dir)
                for image in validated
            ]

        # -- Recipients ------------------------------------------------------
        recipients = resolve_recipients(config, request)
        if not request.dry_run and not recipients:
            raise ValidationError(
                ["no recipients: pass --recipient or set defaults.recipients in the config"]
            )

        # -- Planner ---------------------------------------------------------
        checkpoint = CheckpointStore(request.state_file or config.storage.state_file)
        checkpoint.load()
        build = Planner(config, checkpoint).build(
            images=validated,
            recipients=recipients,
            rows=rows,
            caption_mode=request.caption_mode or config.defaults.caption_mode,
            caption_template=(request.caption_text if request.caption_text is not None
                              else config.defaults.caption),
            caption_column=config.defaults.caption_column,
        )

        if request.dry_run:
            return _finish_dry_run(request, summary, build, recipients, print_fn)

        # -- Queue + Executor + TelegramClient + CheckpointStore + Reporter --
        reporter = Reporter(run_id=run_id, config=config, report_dir=request.report_dir)
        try:
            executor_config = config
            if request.mode == "manifest" and executor_config.send.concurrency > 1:
                # One-by-one mode is strictly sequential (spec 1B).
                print_fn("manifest mode is strictly sequential; forcing concurrency=1")
                executor_config = dataclass_replace(
                    executor_config,
                    send=dataclass_replace(executor_config.send, concurrency=1),
                )
            executor = RateLimitedExecutor(
                client=client_factory(config, environment),
                config=executor_config,
                checkpoint=checkpoint,
                reporter=reporter,
                stop_event=request.stop_event,
            )
            summary.planned = len(build.plan)
            result = executor.run(build.plan, request.limit)
            summary.events = result.events
            if result.abort_reason is not None:
                summary.aborted_reason = result.abort_reason
        finally:
            reporter.close()

        summary.finished_at = utc_now_iso()
        summary.recompute()
        location = _write_report(reporter, summary)
        return _code_from_summary(summary, location)
    finally:
        if derivative_dir:
            shutil.rmtree(derivative_dir, ignore_errors=True)


# -- helpers -----------------------------------------------------------------


def _candidates_from_rows(rows: list[ManifestRow]) -> list[ImageCandidate]:
    candidates: list[ImageCandidate] = []
    for row in rows:
        stat = Path(row.resolved_path).stat()
        candidates.append(
            ImageCandidate(path=row.resolved_path, mtime_ns=stat.st_mtime_ns,
                           size=stat.st_size)
        )
    return candidates


def _with_derivative(
    image: ValidatedImage, validation: ValidationConfig, tmp_dir: str
) -> ValidatedImage:
    try:
        return build_derivative(image, validation)
    except ImageRejected as exc:
        raise ValidationError([f"{exc.path}: {exc.reason}"]) from exc


def _finish_dry_run(
    request: RunRequest,
    summary: RunSummary,
    build: PlanBuild,
    recipients: list[Recipient],
    print_fn: PrintFn,
) -> RunResult:
    summary.planned = len(build.plan)
    summary.finished_at = utc_now_iso()
    summary.recompute()
    print_fn(f"DRY RUN - no network calls are made in this mode (mode: {request.mode})")
    print_fn(
        f"recipients ({len(recipients)}): "
        + ", ".join(f"{r.name}={r.chat_id}" for r in recipients)
    )
    for warning in build.warnings:
        print_fn(f"warning: {warning}")
    in_run = sum(1 for s in build.skipped if s.note == Planner.NOTE_DUP_WITHIN)
    across = len(build.skipped) - in_run
    print_fn(f"skipped (duplicates within this run): {in_run}")
    print_fn(f"skipped (already delivered per checkpoint): {across}")
    print_fn(f"plan: {len(build.plan)} send(s), {build.estimated_api_calls} "
             "estimated API calls")
    for item in build.plan:
        derivative_note = (
            f" [derivative: {item.image.derivative_note}]"
            if item.image.derivative_path
            else ""
        )
        row_note = f" (manifest row {item.manifest_row})" if item.manifest_row else ""
        caption_text = item.caption if item.caption else "(none)"
        print_fn(
            f"  {item.index_for_recipient}/{item.total_for_recipient} "
            f"{item.image.candidate.path}{derivative_note} -> "
            f"{item.recipient.name} ({item.recipient.chat_id}){row_note} | "
            f"caption: {caption_text!r} ({item.parse_mode.value})"
        )
    if not build.plan:
        print_fn("  (nothing to send: every pair was already delivered or plan is empty)")
    return RunResult(summary, ExitCode.OK, "(dry run: no report files written)")


def _write_report(reporter: Reporter, summary: RunSummary) -> str:
    directory, _json_path, _csv_path = reporter.write_reports(summary)
    return directory


def _code_from_summary(summary: RunSummary, location: str) -> RunResult:
    if summary.failed_fatal > 0 or summary.not_sent_fatal > 0:
        return RunResult(summary, ExitCode.FATAL, location)
    if (
        summary.failed_transient > 0
        or summary.failed_permanent > 0
        or summary.not_sent_interrupted > 0
        or summary.not_sent_kill_switch > 0
        or summary.not_sent_limit > 0
    ):
        return RunResult(summary, ExitCode.PARTIAL_FAILURE, location)
    return RunResult(summary, ExitCode.OK, location)


def resolve_recipients(config: Config, request: RunRequest) -> list[Recipient]:
    """Resolve recipient references (name or chat_id) against the allowlist."""
    by_name = {entry.name: entry.chat_id for entry in config.recipients}
    by_id = {str(entry.chat_id): entry.chat_id for entry in config.recipients}
    name_by_id = {str(entry.chat_id): entry.name for entry in config.recipients}
    wanted = request.recipients or config.defaults.recipients
    found: list[Recipient] = []
    missing: list[str] = []
    for reference in wanted:
        chat_id = by_name.get(reference)
        if chat_id is None and reference in by_id:
            chat_id = by_id[reference]
        if chat_id is None:
            missing.append(reference)
            continue
        display = reference if reference in by_name else name_by_id.get(reference, reference)
        found.append(Recipient(name=display, chat_id=chat_id))
    if missing:
        raise ValidationError(
            [f"recipient(s) not in the allowlist: {', '.join(missing)}; allowlisted: "
             f"{', '.join(e.name for e in config.recipients) or '(empty)'}"]
        )
    unique: list[Recipient] = []
    seen: set[tuple[str, str]] = set()
    for recipient in found:
        key = (recipient.name, str(recipient.chat_id))
        if key not in seen:
            seen.add(key)
            unique.append(recipient)
    return unique
