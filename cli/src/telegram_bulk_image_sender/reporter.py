"""Reporting: JSON Lines event log, machine report (JSON + CSV) and the
human-readable end-of-run summary. All numbers come from real counters.
"""

from __future__ import annotations

import csv
import json
from datetime import UTC, datetime
from pathlib import Path

from .config import Config
from .model import RunSummary, SendOutcome

_JSONL_FIELDS = [
    "run_id",
    "timestamp",
    "file",
    "recipient_name",
    "chat_id",
    "attempt",
    "result",
    "telegram_message_id",
    "error_code",
    "latency_ms",
    "note",
]

_CSV_FIELDS = _JSONL_FIELDS  # same schema for the CSV audit export


def utc_now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds")


class Reporter:
    """Writes report files for one run. Owns the JSONL log handle."""

    def __init__(self, *, run_id: str, config: Config, report_dir: str | None) -> None:
        self.run_id = run_id
        self._redacted_config = _redact(config)
        self._dir = Path(report_dir or config.storage.report_dir) / f"run-{run_id}"
        self._dir.mkdir(parents=True, exist_ok=True)
        self._jsonl_path = self._dir / "log.jsonl"
        # Long-lived handle owned by this instance; closed in close().
        self._jsonl = open(self._jsonl_path, "a", encoding="utf-8")  # noqa: SIM115

    @property
    def directory(self) -> str:
        return str(self._dir)

    def log_event(self, outcome: SendOutcome) -> None:
        record = {
            "run_id": self.run_id,
            "timestamp": utc_now_iso(),
            "file": outcome.plan.image.candidate.path,
            "recipient_name": outcome.plan.recipient.name,
            "chat_id": str(outcome.plan.recipient.chat_id),
            "attempt": outcome.attempts,
            "result": outcome.status.value,
            "telegram_message_id": outcome.telegram_message_id,
            "error_code": outcome.error_code,
            "latency_ms": outcome.latency_ms,
            "note": outcome.note,
        }
        self._jsonl.write(json.dumps(record, ensure_ascii=False) + "\n")
        self._jsonl.flush()

    def write_reports(self, summary: RunSummary) -> tuple[str, str, str]:
        """Write report.json and report.csv; return (dir, json_path, csv_path)."""
        report = {
            "run_id": summary.run_id,
            "started_at": summary.started_at,
            "finished_at": summary.finished_at or utc_now_iso(),
            "dry_run": summary.dry_run,
            "aborted_reason": summary.aborted_reason,
            "config": self._redacted_config,
            "summary": {
                "planned": summary.planned,
                "sent": summary.sent,
                "failed_transient": summary.failed_transient,
                "failed_permanent": summary.failed_permanent,
                "failed_fatal": summary.failed_fatal,
                "skipped_duplicate": summary.skipped_duplicate,
                "skipped_daily_cap": summary.skipped_daily_cap,
                "skipped_quiet_hours": summary.skipped_quiet_hours,
                "not_sent_fatal": summary.not_sent_fatal,
                "not_sent_interrupted": summary.not_sent_interrupted,
                "not_sent_kill_switch": summary.not_sent_kill_switch,
                "not_sent_limit": summary.not_sent_limit,
                "derivatives_sent": summary.derivatives_sent,
            },
            "events": [self._event_dict(e) for e in summary.events],
        }
        json_path = self._dir / "report.json"
        json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

        csv_path = self._dir / "report.csv"
        with open(csv_path, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=_CSV_FIELDS)
            writer.writeheader()
            for outcome in summary.events:
                writer.writerow(self._event_dict(outcome))
        return self.directory, str(json_path), str(csv_path)

    def close(self) -> None:
        self._jsonl.close()

    # -- helpers -----------------------------------------------------------

    def _event_dict(self, outcome: SendOutcome) -> dict[str, object]:
        return {
            "run_id": self.run_id,
            "timestamp": None,  # JSONL carries the timestamp; report keeps events ordered
            "file": outcome.plan.image.candidate.path,
            "recipient_name": outcome.plan.recipient.name,
            "chat_id": str(outcome.plan.recipient.chat_id),
            "attempt": outcome.attempts,
            "result": outcome.status.value,
            "telegram_message_id": outcome.telegram_message_id,
            "error_code": outcome.error_code,
            "latency_ms": outcome.latency_ms,
            "note": outcome.note,
        }


def _redact(config: Config) -> dict[str, object]:
    """Config echo for the report. The token can never appear: it is not
    part of Config and is read only from env/secrets-file (config.py)."""
    return {
        "telegram": {
            "api_base_url": config.telegram.api_base_url,
            "parse_mode": config.telegram.parse_mode.value,
            "timeout_seconds": config.telegram.timeout_seconds,
        },
        "limits": {
            "global_per_minute": config.limits.global_per_minute,
            "per_recipient_per_minute": config.limits.per_recipient_per_minute,
            "daily_cap_per_recipient": config.limits.daily_cap_per_recipient,
            "quiet_hours": {
                "enabled": config.limits.quiet_hours.enabled,
                "start": config.limits.quiet_hours.start,
                "end": config.limits.quiet_hours.end,
                "timezone": config.limits.quiet_hours.timezone,
            },
        },
        "kill_switch": {
            "failure_rate": config.kill_switch.failure_rate,
            "window_minutes": config.kill_switch.window_minutes,
            "min_sample": config.kill_switch.min_sample,
        },
        "send": {
            "concurrency": config.send.concurrency,
            "max_attempts": config.send.max_attempts,
            "backoff_base_seconds": config.send.backoff_base_seconds,
            "backoff_max_seconds": config.send.backoff_max_seconds,
        },
        "validation": {
            "max_file_mb": config.validation.max_file_mb,
            "verify_dimensions": config.validation.verify_dimensions,
            "max_total_dimension": config.validation.max_total_dimension,
            "normalize_exif": config.validation.normalize_exif,
            "resize_if_over_limit": config.validation.resize_if_over_limit,
        },
        "dedupe": {
            "within_run": config.dedupe.within_run,
            "across_runs": config.dedupe.across_runs,
        },
        "recipients": [{"name": r.name, "chat_id": str(r.chat_id)} for r in config.recipients],
        "storage": {
            "state_file": config.storage.state_file,
            "report_dir": config.storage.report_dir,
        },
    }


def format_summary(summary: RunSummary, report_location: str) -> str:
    """Human-readable end-of-run summary. Plain and factual."""
    lines = [
        f"Run {summary.run_id} "
        + ("(dry run)" if summary.dry_run else f"finished at {summary.finished_at}"),
        f"  planned:             {summary.planned}",
        f"  sent:                {summary.sent}",
        f"  failed-transient:    {summary.failed_transient}",
        f"  failed-permanent:    {summary.failed_permanent}",
        f"  failed-fatal:        {summary.failed_fatal}",
        f"  skipped-duplicate:   {summary.skipped_duplicate}",
        f"  skipped-daily-cap:   {summary.skipped_daily_cap}",
        f"  skipped-quiet-hours: {summary.skipped_quiet_hours}",
        f"  not-sent-fatal:      {summary.not_sent_fatal}",
        f"  not-sent-interrupted:{summary.not_sent_interrupted}",
        f"  not-sent-kill-switch:{summary.not_sent_kill_switch}",
        f"  not-sent-limit:      {summary.not_sent_limit}",
        f"  derivatives sent:    {summary.derivatives_sent}",
    ]
    if summary.aborted_reason:
        lines.append(f"  aborted: {summary.aborted_reason}")
    lines.append(f"  full report: {report_location}")
    return "\n".join(lines)
