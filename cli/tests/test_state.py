"""Checkpoint store: resume data, atomic writes, disk-full policy (100% module)."""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from pathlib import Path

import pytest

from telegram_bulk_image_sender.errors import StateError
from telegram_bulk_image_sender.state import CheckpointStore


def _store(tmp_path: Path) -> CheckpointStore:
    store = CheckpointStore(str(tmp_path / "state" / "checkpoint.json"))
    store.load()
    return store


def _fixed_now(day: str = "2026-09-30") -> datetime:
    return datetime.fromisoformat(f"{day}T12:00:00+00:00").astimezone(UTC)


def test_missing_file_starts_empty(tmp_path: Path) -> None:
    store = _store(tmp_path)
    assert store.is_delivered("abc", 1) is False
    assert store.count_today(1) == 0
    assert store.path.endswith("checkpoint.json")


def test_record_and_persist(tmp_path: Path) -> None:
    store = _store(tmp_path)
    store.record("abc", -1001234567890, 42)
    assert store.is_delivered("abc", -1001234567890) is True
    assert store.is_delivered("abc", 1) is False  # different chat: not delivered
    store.flush()
    raw = json.loads((tmp_path / "state" / "checkpoint.json").read_text(encoding="utf-8"))
    assert raw["version"] == 1
    assert raw["entries"][0]["message_id"] == 42
    assert raw["entries"][0]["chat"] == "-1001234567890"


def test_reload_preserves_entries(tmp_path: Path) -> None:
    store = _store(tmp_path)
    store.record("abc", 1, 10)
    store.flush()
    reloaded = CheckpointStore(str(tmp_path / "state" / "checkpoint.json"))
    reloaded.load()
    assert reloaded.is_delivered("abc", 1)


def test_corrupt_file_is_a_hard_error(tmp_path: Path) -> None:
    state_file = tmp_path / "checkpoint.json"
    state_file.write_text("{not json", encoding="utf-8")
    store = CheckpointStore(str(state_file))
    with pytest.raises(StateError, match="cannot be read"):
        store.load()


def test_unsupported_version_rejected(tmp_path: Path) -> None:
    state_file = tmp_path / "checkpoint.json"
    state_file.write_text('{"version": 99, "entries": []}', encoding="utf-8")
    store = CheckpointStore(str(state_file))
    with pytest.raises(StateError, match="unsupported format"):
        store.load()


def test_disk_full_on_flush(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    store = _store(tmp_path)
    store.record("abc", 1, 10)

    def enospc_replace(src: object, dst: object) -> None:
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(os, "replace", enospc_replace)
    with pytest.raises(StateError, match="No space left on device"):
        store.flush()
    monkeypatch.undo()
    store.flush()  # after the (injected) failure is resolved, flush succeeds


def test_count_today_filters_by_chat_and_utc_day(tmp_path: Path) -> None:
    store = _store(tmp_path)
    store._now = lambda: _fixed_now("2026-09-30")  # test seam: fixed clock
    store.record("a", 1, 1)
    store.record("b", 1, 2)
    store._now = lambda: _fixed_now("2026-10-01")  # test seam
    store.record("c", 1, 3)
    store.record("d", 2, 4)
    # The store's own clock says "today" is 2026-10-01.
    assert store.count_today(1) == 1
    assert store.count_today(2) == 1
    # Explicit evaluation dates reach the older entries.
    assert store.count_today(1, now_utc=_fixed_now("2026-09-30")) == 2
    assert store.count_today(2, now_utc=_fixed_now("2026-09-30")) == 0


def test_atomic_write_leaves_no_tmp_file(tmp_path: Path) -> None:
    store = _store(tmp_path)
    store.record("abc", 1, 7)
    store.flush()
    state_dir = tmp_path / "state"
    assert [p.name for p in state_dir.iterdir()] == ["checkpoint.json"]


def test_lazy_load_on_first_query(tmp_path: Path) -> None:
    other = _store(tmp_path)
    other.record("abc", 1, 1)
    other.flush()
    lazy = CheckpointStore(str(tmp_path / "state" / "checkpoint.json"))
    assert lazy._loaded is False
    assert lazy.is_delivered("abc", 1) is True  # implicit load()


def test_non_dict_and_bad_key_entries_rejected(tmp_path: Path) -> None:
    state_file = tmp_path / "checkpoint.json"
    state_file.write_text('{"version": 1, "entries": ["not-a-dict"]}', encoding="utf-8")
    store = CheckpointStore(str(state_file))
    with pytest.raises(StateError, match="malformed entry #0"):
        store.load()
    state_file.write_text('{"version": 1, "entries": [{"sha256": "x"}]}', encoding="utf-8")
    store = CheckpointStore(str(state_file))
    with pytest.raises(StateError, match="malformed entry #0"):
        store.load()


def test_entries_must_be_a_list(tmp_path: Path) -> None:
    state_file = tmp_path / "checkpoint.json"
    state_file.write_text('{"version": 1, "entries": {"key": "value"}}', encoding="utf-8")
    store = CheckpointStore(str(state_file))
    with pytest.raises(StateError, match="'entries' must be a list"):
        store.load()
