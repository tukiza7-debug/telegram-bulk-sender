"""Failure injection: disk full, malformed image mid-folder, network drop,
token revoked mid-run — through the real pipeline and fake HTTP server."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from _fakeserver import FakeBotAPIServer, JsonError, Ok
from conftest import make_jpeg
from telegram_bulk_image_sender import Config, ExitCode, RunRequest, run
from telegram_bulk_image_sender.config import parse_config
from telegram_bulk_image_sender.errors import StateError, ValidationError
from telegram_bulk_image_sender.runner import ClientFactory
from telegram_bulk_image_sender.telegram.http_client import TelegramHttpClient

TOKEN = "123456789:TESTTOKEN_notarealtoken"


def _server_factory(server: FakeBotAPIServer) -> ClientFactory:
    def factory(config: Config, env: dict[str, str]) -> TelegramHttpClient:
        return TelegramHttpClient(
            parse_config({"telegram": {"api_base_url": server.base_url}}).telegram,
            env["TELEGRAM_BOT_TOKEN"],
        )

    return factory


def _folder_request(config: Config, src: str, **kwargs: object) -> RunRequest:
    return RunRequest(config=config, mode="folder", source_dir=src, recipients=("news",), **kwargs)  # type: ignore[arg-type]


def _config(tmp_path: Path, server: FakeBotAPIServer) -> Config:
    return parse_config(
        {
            "telegram": {"api_base_url": server.base_url},
            "recipients": [{"name": "news", "chat_id": 1}],
            "security": {"token_env": "TELEGRAM_BOT_TOKEN"},
            "storage": {
                "state_file": str(tmp_path / "state" / "cp.json"),
                "report_dir": str(tmp_path / "reports"),
            },
            "send": {"backoff_base_seconds": 0.0},
        }
    )


def test_disk_full_on_state_write_aborts_with_error(
    tmp_path: Path, server: FakeBotAPIServer, monkeypatch: pytest.MonkeyPatch
) -> None:
    imgs = [make_jpeg(tmp_path / "a.jpg", color=(1, 1, 1))]
    config = _config(tmp_path, server)
    calls = {"n": 0}
    real_replace = os.replace

    def flaky_replace(src: object, dst: object) -> None:
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError(28, "No space left on device")
        real_replace(src, dst)  # type: ignore[arg-type]

    monkeypatch.setattr(os, "replace", flaky_replace)
    with pytest.raises(StateError, match="No space left on device"):
        run(
            _folder_request(config, str(imgs[0].parent)),
            env={"TELEGRAM_BOT_TOKEN": TOKEN},
            client_factory=_server_factory(server),
            print_fn=lambda *_: None,
        )
    monkeypatch.undo()
    # the failure surfaced loudly: state and report files document it
    assert (tmp_path / "reports").exists()


def test_malformed_image_mid_folder_fails_whole_run_before_any_send(
    tmp_path: Path, server: FakeBotAPIServer
) -> None:
    src = tmp_path / "imgs"
    src.mkdir()
    make_jpeg(src / "good.jpg", color=(1, 1, 1))
    (src / "corrupt.jpg").write_bytes(b"\xff\xd8\xff" + b"garbage" * 20)
    config = _config(tmp_path, server)
    with pytest.raises(ValidationError, match=r"corrupt\.jpg"):
        run(
            _folder_request(config, str(src)),
            env={"TELEGRAM_BOT_TOKEN": TOKEN},
            client_factory=_server_factory(server),
            print_fn=lambda *_: None,
        )
    # nothing was sent and getMe was never called (validation precedes network)
    assert server.requests == []


def test_network_drop_mid_upload_retries_and_succeeds(
    tmp_path: Path, server: FakeBotAPIServer
) -> None:
    from _fakeserver import DropConnection

    src = tmp_path / "imgs"
    src.mkdir()
    make_jpeg(src / "a.jpg", color=(2, 2, 2))
    server.enqueue(Ok(), DropConnection())  # getMe ok; 1st upload drops
    config = _config(tmp_path, server)
    result = run(
        _folder_request(config, str(src)),
        env={"TELEGRAM_BOT_TOKEN": TOKEN},
        client_factory=_server_factory(server),
        print_fn=lambda *_: None,
    )
    assert result.exit_code.value == 0
    assert result.summary.sent == 1
    # the JSONL log shows the drop was retried, not hidden
    log_path = Path(result.report_location) / "log.jsonl"
    log_text = log_path.read_text(encoding="utf-8")
    assert '"result": "sent"' in log_text
    send_requests = [r for r in server.requests if r.path.endswith("sendPhoto")]
    assert len(send_requests) == 2  # one dropped attempt + one successful retry


def test_token_revoked_mid_run_is_fatal_and_records_state(
    tmp_path: Path, server: FakeBotAPIServer
) -> None:
    src = tmp_path / "imgs"
    src.mkdir()
    for i, color in enumerate([(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]):
        # Distinct sizes guarantee distinct bytes: 8x8 solid-colour JPEGs can
        # quantise to identical files for near colours.
        make_jpeg(src / f"img{i}.jpg", size=(8 + i, 8 + i), color=color)
    # getMe ok, first send ok, second send -> 401 (token revoked mid-run)
    server.enqueue(Ok(), Ok(), JsonError(status=401, error_code=401, description="Unauthorized"))
    config = _config(tmp_path, server)
    result = run(
        _folder_request(config, str(src)),
        env={"TELEGRAM_BOT_TOKEN": TOKEN},
        client_factory=_server_factory(server),
        print_fn=lambda *_: None,
    )
    assert result.exit_code is ExitCode.FATAL
    assert result.summary.sent == 1
    assert result.summary.failed_fatal == 1
    assert result.summary.not_sent_fatal == 2
    assert result.summary.aborted_reason is not None
    # delivered-before-revocation is checkpointed: a rerun skips it
    log_path = Path(result.report_location) / "log.jsonl"
    assert '"result": "sent"' in log_path.read_text(encoding="utf-8")
    assert '"result": "failed-fatal"' in log_path.read_text(encoding="utf-8")
