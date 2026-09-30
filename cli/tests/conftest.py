"""Shared fixtures: hermetic sockets, fake Bot API server, image factories.

No test in this suite may touch the real network: an autouse fixture blocks
every outbound socket connection that is not loopback. The fake Bot API
server binds 127.0.0.1 on an ephemeral port, so the whole suite runs with
networking disabled (CI gate: "no-network test run").
"""

from __future__ import annotations

import socket
from collections.abc import Iterator
from pathlib import Path

import pytest
from PIL import Image

from _fakeserver import FakeBotAPIServer
from telegram_bulk_image_sender import Config
from telegram_bulk_image_sender.telegram.fake import FakeTelegramClient

_LOOPBACK = {"127.0.0.1", "::1", "localhost"}


@pytest.fixture(autouse=True)
def no_external_network(monkeypatch: pytest.MonkeyPatch) -> None:
    """Refuse any TCP connection whose destination is not loopback."""
    real_create_connection = socket.create_connection

    def guarded(addresses: object, *args: object, **kwargs: object) -> socket.socket:
        host = addresses[0] if isinstance(addresses, tuple) else addresses
        if str(host) not in _LOOPBACK:
            raise AssertionError(f"test suite attempted an external connection to {host!r}")
        return real_create_connection(addresses, *args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(socket, "create_connection", guarded)


@pytest.fixture()
def fake_server() -> Iterator[FakeBotAPIServer]:
    server = FakeBotAPIServer(("127.0.0.1", 0))
    thread = server.serve_forever_threaded()
    yield server
    server.shutdown_server(thread)


@pytest.fixture()
def server(fake_server: FakeBotAPIServer) -> FakeBotAPIServer:
    """Short alias used by integration tests."""
    return fake_server


@pytest.fixture()
def fake_client() -> FakeTelegramClient:
    return FakeTelegramClient()


@pytest.fixture()
def env_token() -> dict[str, str]:
    return {"TELEGRAM_BOT_TOKEN": "123456789:TESTTOKEN_notarealtoken"}


@pytest.fixture()
def base_config() -> Config:
    return Config()


def make_jpeg(
    path: Path, size: tuple[int, int] = (8, 8), color: tuple[int, int, int] = (200, 30, 30)
) -> Path:
    Image.new("RGB", size, color).save(path, format="JPEG")
    return path


def make_png(
    path: Path, size: tuple[int, int] = (8, 8), color: tuple[int, int, int] = (10, 120, 240)
) -> Path:
    Image.new("RGB", size, color).save(path, format="PNG")
    return path
