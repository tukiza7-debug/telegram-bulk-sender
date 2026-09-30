"""Core data types shared by every pipeline stage.

Only plain, immutable-by-default dataclasses live here; no behaviour. This
module is the vocabulary of the pipeline described in docs/ARCHITECTURE.md.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum

ChatId = int | str
"""Telegram chat identifier: integer id or @channelname (as Bot API accepts)."""


class OrderKey(StrEnum):
    NAME = "name"
    MTIME = "mtime"
    MANIFEST_ROW = "manifest-row"


class CaptionMode(StrEnum):
    NONE = "none"
    PER_IMAGE = "per-image"
    PER_RUN = "per-run"
    MANIFEST_COLUMN = "manifest-column"


class ParseMode(StrEnum):
    NONE = "none"
    HTML = "html"
    MARKDOWN = "markdown"
    MARKDOWN_V2 = "markdownv2"


class ResultStatus(StrEnum):
    """Outcome of one planned send, as recorded in the report."""

    SENT = "sent"
    FAILED_TRANSIENT = "failed-transient"
    FAILED_PERMANENT = "failed-permanent"
    FAILED_FATAL = "failed-fatal"
    SKIPPED_DUPLICATE = "skipped-duplicate"
    SKIPPED_DAILY_CAP = "skipped-daily-cap"
    SKIPPED_QUIET_HOURS = "skipped-quiet-hours"
    NOT_SENT_FATAL = "not-sent-fatal"
    NOT_SENT_INTERRUPTED = "not-sent-interrupted"
    NOT_SENT_KILL_SWITCH = "not-sent-kill-switch"
    NOT_SENT_LIMIT = "not-sent-limit"


@dataclass(frozen=True)
class Recipient:
    """One explicitly allowlisted target chat."""

    name: str
    chat_id: ChatId


@dataclass(frozen=True)
class ImageCandidate:
    """A file discovered on disk, before validation."""

    path: str
    mtime_ns: int
    size: int


@dataclass(frozen=True)
class ValidatedImage:
    """A file that passed magic-byte, size and (optional) dimension checks."""

    candidate: ImageCandidate
    sha256: str
    format: str  # "jpeg" | "png" | "webp"
    width: int | None = None
    height: int | None = None
    exif_orientation: int | None = None
    # Set when a resized/normalised derivative will be uploaded instead of
    # this file; the original on disk is never modified.
    derivative_path: str | None = None
    derivative_note: str | None = None


@dataclass(frozen=True)
class PlannedSend:
    """One unit of work: one image (or derivative) to one recipient."""

    image: ValidatedImage
    recipient: Recipient
    caption: str | None
    parse_mode: ParseMode
    index_for_recipient: int  # 1-based position within this recipient's queue
    total_for_recipient: int
    manifest_row: int | None = None  # None for folder/single mode


@dataclass(frozen=True)
class SendOutcome:
    """Result of attempting one PlannedSend (or deciding not to attempt it)."""

    plan: PlannedSend
    status: ResultStatus
    attempts: int = 0
    telegram_message_id: int | None = None
    error_code: int | None = None
    error_description: str | None = None
    error_kind: str | None = None  # ErrorKind name when failed
    latency_ms: int | None = None
    note: str | None = None


@dataclass
class RunSummary:
    """Real counters only; no estimates, no percentages based on guesses."""

    run_id: str
    started_at: str
    finished_at: str | None = None
    planned: int = 0
    sent: int = 0
    failed_transient: int = 0
    failed_permanent: int = 0
    failed_fatal: int = 0
    skipped_duplicate: int = 0
    skipped_daily_cap: int = 0
    skipped_quiet_hours: int = 0
    not_sent_fatal: int = 0
    not_sent_interrupted: int = 0
    not_sent_kill_switch: int = 0
    not_sent_limit: int = 0
    derivatives_sent: int = 0
    aborted_reason: str | None = None
    dry_run: bool = False
    events: list[SendOutcome] = field(default_factory=list)

    def count(self, status: ResultStatus) -> int:
        return sum(1 for e in self.events if e.status is status)

    def recompute(self) -> None:
        """Rebuild all counters from events (single source of truth)."""
        self.sent = self.count(ResultStatus.SENT)
        self.failed_transient = self.count(ResultStatus.FAILED_TRANSIENT)
        self.failed_permanent = self.count(ResultStatus.FAILED_PERMANENT)
        self.failed_fatal = self.count(ResultStatus.FAILED_FATAL)
        self.skipped_duplicate = self.count(ResultStatus.SKIPPED_DUPLICATE)
        self.skipped_daily_cap = self.count(ResultStatus.SKIPPED_DAILY_CAP)
        self.skipped_quiet_hours = self.count(ResultStatus.SKIPPED_QUIET_HOURS)
        self.not_sent_fatal = self.count(ResultStatus.NOT_SENT_FATAL)
        self.not_sent_interrupted = self.count(ResultStatus.NOT_SENT_INTERRUPTED)
        self.not_sent_kill_switch = self.count(ResultStatus.NOT_SENT_KILL_SWITCH)
        self.not_sent_limit = self.count(ResultStatus.NOT_SENT_LIMIT)
        self.derivatives_sent = sum(
            1 for e in self.events if e.status is ResultStatus.SENT and e.plan.image.derivative_path
        )
