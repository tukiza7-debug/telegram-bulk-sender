"""Planner: turns validated images + recipients into an ordered send plan.

All three modes funnel through here; the only difference is which source
produced the (image, recipient) pairs. The plan is what --dry-run prints
and what the executor consumes. Cross-run deduplication is applied here
(against the checkpoint); the executor re-checks as a safety net.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from .captions import build_and_escape, check_template
from .config import Config
from .errors import ValidationError
from .model import (
    CaptionMode,
    ParseMode,
    PlannedSend,
    Recipient,
    ResultStatus,
    SendOutcome,
    ValidatedImage,
)
from .sources import ManifestRow
from .state import CheckpointStore


@dataclass
class PlanBuild:
    plan: list[PlannedSend] = field(default_factory=list)
    skipped: list[SendOutcome] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def estimated_api_calls(self) -> int:
        # One sendPhoto per planned pair; +1 for the getMe preflight.
        return len(self.plan) + (1 if self.plan else 0)


class Planner:
    # Machine-comparable skip notes (runner keys off these; do not inline).
    NOTE_DUP_WITHIN = "duplicate within run"
    NOTE_DUP_ACROSS = "already delivered in a previous run"

    def __init__(self, config: Config, checkpoint: CheckpointStore) -> None:
        self._config = config
        self._checkpoint = checkpoint
        self._now = datetime.now(timezone.utc)

    def build(
        self,
        *,
        images: list[ValidatedImage],
        recipients: list[Recipient],
        rows: list[ManifestRow] | None,
        caption_mode: CaptionMode,
        caption_template: str,
        caption_column: str,
    ) -> PlanBuild:
        result = PlanBuild()
        if caption_mode is CaptionMode.MANIFEST_COLUMN and rows is None:
            raise ValidationError(
                ["caption-mode 'manifest-column' requires a manifest with a "
                 f"'{caption_column}' column"]
            )
        if caption_mode is CaptionMode.MANIFEST_COLUMN and rows is not None:
            missing = [r.row_number for r in rows if caption_column not in r.custom]
            if missing:
                result.warnings.append(
                    f"rows without a '{caption_column}' value get no caption: "
                    + ", ".join(str(n) for n in missing)
                )
        known_custom = self._custom_columns(rows)
        if caption_mode is CaptionMode.PER_IMAGE and caption_template:
            check_template(caption_template, known_custom, "caption template")

        seen_in_run: set[str] = set()
        total_rows = len(rows) if rows is not None else None

        if rows is not None:
            per_recipient_counter: dict[str, int] = {}
            for row in rows:
                image = self._image_for_row(images, row)
                recipient = self._recipient_for_row(recipients, row)
                if recipient is None or image is None:
                    continue  # already reported as a warning below
                if self._is_duplicate(image, recipient, seen_in_run, result):
                    continue
                index = per_recipient_counter.get(str(recipient.chat_id), 0) + 1
                per_recipient_counter[str(recipient.chat_id)] = index
                caption = self._caption_for_row(
                    row, caption_mode, caption_column, index=index, total=total_rows or 0
                )
                result.plan.append(
                    PlannedSend(
                        image=image,
                        recipient=recipient,
                        caption=caption,
                        parse_mode=self._config.telegram.parse_mode,
                        index_for_recipient=index,
                        total_for_recipient=total_rows or 1,
                        manifest_row=row.row_number,
                    )
                )
            self._warn_unmatched(images, recipients, rows, result)
            return result

        total = len(images)
        for recipient in recipients:
            counter = 0
            for image in images:
                if self._is_duplicate(image, recipient, seen_in_run, result):
                    continue
                counter += 1
                caption = None
                if caption_mode is CaptionMode.PER_IMAGE and caption_template:
                    caption = build_and_escape(
                        caption_template,
                        self._config.telegram.parse_mode,
                        filename=Path(image.candidate.path).name,
                        index=counter,
                        total=total,
                        now=self._now,
                    )
                elif caption_mode is CaptionMode.PER_RUN:
                    caption = build_and_escape(
                        caption_template,
                        self._config.telegram.parse_mode,
                        filename="",
                        index=0,
                        total=0,
                        now=self._now,
                    )
                result.plan.append(
                    PlannedSend(
                        image=image,
                        recipient=recipient,
                        caption=caption,
                        parse_mode=self._config.telegram.parse_mode,
                        index_for_recipient=counter,
                        total_for_recipient=total,
                    )
                )
        return result

    # -- helpers -----------------------------------------------------------

    def _is_duplicate(
        self,
        image: ValidatedImage,
        recipient: Recipient,
        seen_in_run: set[str],
        result: PlanBuild,
    ) -> bool:
        key = CheckpointStore.entry_key(image.sha256, recipient.chat_id)
        duplicate_in_run = key in seen_in_run
        duplicate_across_runs = self._config.dedupe.across_runs and self._checkpoint.is_delivered(
            image.sha256, recipient.chat_id
        )
        if not (duplicate_in_run or duplicate_across_runs):
            seen_in_run.add(key)
            return False
        result.skipped.append(
            SendOutcome(
                plan=PlannedSend(
                    image=image,
                    recipient=recipient,
                    caption=None,
                    parse_mode=self._config.telegram.parse_mode,
                    index_for_recipient=0,
                    total_for_recipient=0,
                ),
                status=ResultStatus.SKIPPED_DUPLICATE,
                note=Planner.NOTE_DUP_WITHIN if duplicate_in_run else Planner.NOTE_DUP_ACROSS,
            )
        )
        return True

    def _image_for_row(
        self, images: list[ValidatedImage], row: ManifestRow
    ) -> ValidatedImage | None:
        for image in images:
            if image.candidate.path == row.resolved_path:
                return image
        return None

    def _recipient_for_row(
        self, recipients: list[Recipient], row: ManifestRow
    ) -> Recipient | None:
        for recipient in recipients:
            if recipient.name == row.recipient_ref or str(recipient.chat_id) == row.recipient_ref:
                return recipient
        return None

    def _warn_unmatched(
        self,
        images: list[ValidatedImage],
        recipients: list[Recipient],
        rows: list[ManifestRow],
        result: PlanBuild,
    ) -> None:
        known_images = {i.candidate.path for i in images}
        known_recipients = {r.name for r in recipients} | {
            str(r.chat_id) for r in recipients
        }
        for row in rows:
            if row.resolved_path not in known_images:
                result.warnings.append(
                    f"manifest row {row.row_number}: no validated image for {row.file_value}"
                )
            elif self._recipient_for_row(recipients, row) is None:
                result.warnings.append(
                    f"manifest row {row.row_number}: recipient {row.recipient_ref!r} is not "
                    "in the allowlist; row ignored"
                )

    def _caption_for_row(
        self,
        row: ManifestRow,
        caption_mode: CaptionMode,
        caption_column: str,
        *,
        index: int,
        total: int,
    ) -> str | None:
        if caption_mode is CaptionMode.NONE:
            return None
        if caption_mode is CaptionMode.MANIFEST_COLUMN:
            raw = row.custom.get(caption_column, "")
            if not raw:
                return None
            return build_and_escape(
                raw,
                self._config.telegram.parse_mode,
                filename=Path(row.resolved_path).name,
                index=index,
                total=total,
                custom=row.custom,
                now=self._now,
            )
        if caption_mode is CaptionMode.PER_RUN:
            return build_and_escape(
                self._config.defaults.caption,
                self._config.telegram.parse_mode,
                filename=Path(row.resolved_path).name,
                index=index,
                total=total,
                custom=row.custom,
                now=self._now,
            )
        # PER_IMAGE in manifest mode: template may come from CLI/config; fall
        # back to the row's caption column when no template is configured.
        template = self._config.defaults.caption or row.custom.get(caption_column, "")
        if not template:
            return None
        return build_and_escape(
            template,
            self._config.telegram.parse_mode,
            filename=Path(row.resolved_path).name,
            index=index,
            total=total,
            custom=row.custom,
            now=self._now,
        )

    def _custom_columns(self, rows: list[ManifestRow] | None) -> set[str]:
        if not rows:
            return set()
        columns: set[str] = set()
        for row in rows:
            columns.update(row.custom.keys())
        return columns
