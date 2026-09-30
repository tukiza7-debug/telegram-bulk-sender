"""Perf sanity: 1,000-file dry run completes quickly with bounded memory.

Bounded memory is guaranteed by streaming SHA-256 (hashing.py): a recorder
wraps open() to prove the validator never reads more than CHUNK_SIZE at a
time.
"""

from __future__ import annotations

import io
import time
from pathlib import Path

import pytest

from conftest import make_jpeg
from telegram_bulk_image_sender import hashing
from telegram_bulk_image_sender.config import parse_config
from telegram_bulk_image_sender.runner import RunRequest, run


@pytest.mark.slow
def test_hashing_streams_in_chunks(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    blob = tmp_path / "blob.jpg"
    blob.write_bytes(b"\xff\xd8\xff" + b"\x00" * (64 * 1024 + 7))
    # Note: only the reading pattern matters here; sha256_of_file never parses.

    chunk_sizes: list[int] = []

    class Recorder(io.BufferedReader):
        def read(self, size: int = -1) -> bytes:  # type: ignore[override]
            chunk_sizes.append(size)
            return super().read(size)

    real_open = hashing._open

    def recording_open(file: str, mode: str = "r") -> io.BufferedReader:
        handle = real_open(file, mode)
        assert isinstance(handle, io.BufferedReader)
        return Recorder(handle)

    monkeypatch.setattr(hashing, "_open", recording_open)
    monkeypatch.setattr(hashing, "CHUNK_SIZE", 4096)
    hashing.sha256_of_file(str(blob))
    assert chunk_sizes, "file was never read"
    assert max(chunk_sizes) <= 4096, "hashing read more than one chunk at a time"


@pytest.mark.slow
def test_thousand_file_dry_run_is_fast(tmp_path: Path) -> None:
    src = tmp_path / "imgs"
    src.mkdir()
    colors = [(i % 251, (i * 7) % 251, (i * 13) % 251) for i in range(100)]
    for i in range(1000):
        # 100 distinct payloads repeated: exercises within-run dedupe too.
        make_jpeg(src / f"img{i:04d}.jpg", size=(4, 4), color=colors[i % 100])

    config = parse_config(
        {
            "recipients": [{"name": "news", "chat_id": 1}],
            "storage": {
                "state_file": str(tmp_path / "state.json"),
                "report_dir": str(tmp_path / "reports"),
            },
        }
    )

    def no_client(config: object, env: object) -> object:
        raise AssertionError("dry run must not build a client")

    started = time.monotonic()
    result = run(
        RunRequest(
            config=config, mode="folder", source_dir=str(src), recipients=("news",), dry_run=True
        ),
        env={},
        client_factory=no_client,  # type: ignore[arg-type]
        print_fn=lambda *_: None,
    )
    elapsed = time.monotonic() - started
    assert result.exit_code.value == 0
    assert result.summary.planned == 100  # 1000 files, 100 unique payloads
    assert elapsed < 30.0, f"dry run took {elapsed:.1f}s"
