"""Checkpoint store: idempotent resume across runs.

State file maps (content sha256, chat_id) -> delivery record. Re-running
after an interruption never resends an already-delivered pair (spec 2.4).
Writes are atomic (temp file + fsync + os.replace + directory fsync); any
I/O failure raises StateError — failure is data, never hidden.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from .errors import StateError
from .model import ChatId

STATE_VERSION = 1


class CheckpointStore:
    def __init__(self, path: str, *, now: Callable[[], datetime] | None = None) -> None:
        self._path = Path(path)
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._entries: dict[str, dict[str, object]] = {}
        self._loaded = False

    # -- reading -----------------------------------------------------------

    def load(self) -> None:
        """Read the state file. A missing file starts empty; a corrupt one
        is a hard error (we refuse to risk resending over bad state)."""
        self._loaded = True
        if not self._path.exists():
            self._entries = {}
            return
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise StateError(
                f"checkpoint file {self._path} exists but cannot be read: {exc}"
            ) from exc
        if not isinstance(raw, dict) or raw.get("version") != STATE_VERSION:
            raise StateError(
                f"checkpoint file {self._path} has an unsupported format; "
                f"expected version {STATE_VERSION}"
            )
        entries = raw.get("entries")
        if not isinstance(entries, list):
            raise StateError(f"checkpoint file {self._path}: 'entries' must be a list")
        parsed: dict[str, dict[str, object]] = {}
        for i, item in enumerate(entries):
            if not isinstance(item, dict):
                raise StateError(f"checkpoint file {self._path}: malformed entry #{i}")
            key = item.get("key")
            if not isinstance(key, str):
                raise StateError(f"checkpoint file {self._path}: malformed entry #{i}")
            parsed[key] = item
        self._entries = parsed

    def _ensure_loaded(self) -> None:
        if not self._loaded:
            self.load()

    # -- queries -----------------------------------------------------------

    @staticmethod
    def entry_key(sha256: str, chat_id: ChatId) -> str:
        return f"{sha256}:{chat_id}"

    def is_delivered(self, sha256: str, chat_id: ChatId) -> bool:
        self._ensure_loaded()
        return self.entry_key(sha256, chat_id) in self._entries

    def count_today(self, chat_id: ChatId, *, now_utc: datetime | None = None) -> int:
        """Deliveries recorded for chat_id on today's UTC date.

        Daily-cap windows are UTC days: deterministic and independent of the
        operator's machine timezone (documented in config.example.yaml).
        """
        self._ensure_loaded()
        current = now_utc or self._now()
        today = current.astimezone(timezone.utc).date().isoformat()
        chat_key = str(chat_id)
        return sum(
            1
            for entry in self._entries.values()
            if entry.get("chat") == chat_key and entry.get("chat_day") == today
        )

    # -- writing -----------------------------------------------------------

    def record(self, sha256: str, chat_id: ChatId, message_id: int) -> None:
        """Record a delivery in memory; call flush() to persist."""
        self._ensure_loaded()
        stamp = self._now()
        key = self.entry_key(sha256, chat_id)
        self._entries[key] = {
            "key": key,
            "sha256": sha256,
            "chat": str(chat_id),
            "chat_day": stamp.astimezone(timezone.utc).date().isoformat(),
            "message_id": message_id,
            "timestamp": stamp.isoformat(),
        }

    def flush(self) -> None:
        """Atomically persist entries. Raises StateError on any I/O failure."""
        self._ensure_loaded()
        payload = {"version": STATE_VERSION, "entries": list(self._entries.values())}
        tmp_path = self._path.with_suffix(self._path.suffix + ".tmp")
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            with open(tmp_path, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, indent=1, sort_keys=True)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp_path, self._path)
            _fsync_directory(self._path.parent)
        except OSError as exc:
            raise StateError(f"failed to write checkpoint {self._path}: {exc}") from exc

    @property
    def path(self) -> str:
        return str(self._path)


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
