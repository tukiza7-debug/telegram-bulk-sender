"""Real HTTP client against the loopback fake Bot API server.

This is the only place the real client runs; the fake server asserts what
actually went over the wire (multipart fields, file bytes).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from _fakeserver import FakeBotAPIServer, JsonError, RawResponse
from conftest import make_jpeg
from telegram_bulk_image_sender.config import TelegramConfig
from telegram_bulk_image_sender.errors import (
    AuthError,
    PermanentSendError,
    RateLimitedError,
    TransientSendError,
)
from telegram_bulk_image_sender.model import ParseMode
from telegram_bulk_image_sender.telegram.http_client import (
    MultipartBody,
    TelegramHttpClient,
)

TOKEN = "123456789:TESTTOKEN_notarealtoken"


def _client(server: FakeBotAPIServer, timeout: float = 10.0) -> TelegramHttpClient:
    return TelegramHttpClient(
        TelegramConfig(api_base_url=server.base_url, timeout_seconds=timeout), TOKEN
    )


def test_get_me_parses_bot_identity(fake_server: FakeBotAPIServer) -> None:
    bot = _client(fake_server).get_me()
    assert bot.username == "test_bot"
    assert bot.is_bot is True
    request = fake_server.requests[-1]
    assert request.path == f"/bot{TOKEN}/getMe"


def test_send_photo_uploads_expected_multipart(
    fake_server: FakeBotAPIServer, tmp_path: Path
) -> None:
    image = make_jpeg(tmp_path / "pic.jpg", color=(12, 34, 56))
    original_bytes = image.read_bytes()
    sent = _client(fake_server).send_photo(
        chat_id=-1001234567890,
        photo_path=str(image),
        caption="Hello <world>",
        parse_mode=ParseMode.HTML,
        filename="pic.jpg",
    )
    assert sent.message_id > 0
    request = fake_server.requests[-1]
    assert request.path == f"/bot{TOKEN}/sendPhoto"
    assert request.fields["chat_id"] == "-1001234567890"
    assert request.fields["caption"] == "Hello <world>"
    assert request.fields["parse_mode"] == "HTML"
    assert request.filename == "pic.jpg"
    assert request.file_bytes == original_bytes


def test_send_photo_without_caption_omits_parse_mode(
    fake_server: FakeBotAPIServer, tmp_path: Path
) -> None:
    image = make_jpeg(tmp_path / "pic.jpg")
    _client(fake_server).send_photo(
        chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.HTML
    )
    request = fake_server.requests[-1]
    assert "caption" not in request.fields
    assert "parse_mode" not in request.fields


def test_401_maps_to_auth_error(fake_server: FakeBotAPIServer, tmp_path: Path) -> None:
    fake_server.enqueue(JsonError(status=401, error_code=401, description="Unauthorized"))
    image = make_jpeg(tmp_path / "a.jpg")
    with pytest.raises(AuthError, match="Unauthorized") as excinfo:
        _client(fake_server).send_photo(
            chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.NONE
        )
    assert excinfo.value.http_status == 401


def test_429_with_retry_after(fake_server: FakeBotAPIServer, tmp_path: Path) -> None:
    fake_server.enqueue(
        JsonError(
            status=429,
            error_code=429,
            description="Too Many Requests: retry after 8",
            retry_after=8,
        )
    )
    image = make_jpeg(tmp_path / "a.jpg")
    with pytest.raises(RateLimitedError, match="retry after 8") as excinfo:
        _client(fake_server).send_photo(
            chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.NONE
        )
    assert excinfo.value.retry_after == 8.0


def test_429_without_retry_after_is_transient(
    fake_server: FakeBotAPIServer, tmp_path: Path
) -> None:
    fake_server.enqueue(JsonError(status=429, error_code=429, description="flooded"))
    image = make_jpeg(tmp_path / "a.jpg")
    with pytest.raises(TransientSendError):
        _client(fake_server).send_photo(
            chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.NONE
        )


def test_400_maps_to_permanent(fake_server: FakeBotAPIServer, tmp_path: Path) -> None:
    fake_server.enqueue(
        JsonError(status=400, error_code=400, description="Bad Request: image download failed")
    )
    image = make_jpeg(tmp_path / "a.jpg")
    with pytest.raises(PermanentSendError, match="Bad Request") as excinfo:
        _client(fake_server).send_photo(
            chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.NONE
        )
    assert excinfo.value.api_error_code == 400


def test_500_maps_to_transient(fake_server: FakeBotAPIServer, tmp_path: Path) -> None:
    fake_server.enqueue(JsonError(status=502, error_code=502, description="Bad Gateway"))
    image = make_jpeg(tmp_path / "a.jpg")
    with pytest.raises(TransientSendError, match="502"):
        _client(fake_server).send_photo(
            chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.NONE
        )


def test_non_json_response_is_transient_not_auth(
    fake_server: FakeBotAPIServer, tmp_path: Path
) -> None:
    # Captive portals and broken intermediaries answer with HTML; the client
    # must classify this as a network problem, never as a token problem.
    fake_server.enqueue(RawResponse(status=200, body=b"<html>login page</html>"))
    image = make_jpeg(tmp_path / "a.jpg")
    with pytest.raises(TransientSendError, match="non-JSON"):
        _client(fake_server).send_photo(
            chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.NONE
        )


def test_connection_drop_mid_upload_is_transient(
    fake_server: FakeBotAPIServer, tmp_path: Path
) -> None:
    from _fakeserver import DropConnection

    fake_server.enqueue(DropConnection())
    image = make_jpeg(tmp_path / "a.jpg")
    with pytest.raises(TransientSendError, match="network failure"):
        _client(fake_server).send_photo(
            chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.NONE
        )


def test_timeout_is_transient(fake_server: FakeBotAPIServer, tmp_path: Path) -> None:
    from _fakeserver import StallThenOk

    fake_server.enqueue(StallThenOk(seconds=2.0))
    image = make_jpeg(tmp_path / "a.jpg")
    with pytest.raises(TransientSendError, match="network failure"):
        _client(fake_server, timeout=0.3).send_photo(
            chat_id=1, photo_path=str(image), caption=None, parse_mode=ParseMode.NONE
        )


# -- multipart body streaming --------------------------------------------------


def test_multipart_body_streams_exactly(tmp_path: Path) -> None:
    image = make_jpeg(tmp_path / "stream.jpg", color=(1, 2, 3))
    payload = image.read_bytes()
    body = MultipartBody(
        fields={"chat_id": "7", "caption": "hi"},
        file_field="photo",
        file_path=str(image),
        file_content_type="image/jpeg",
        filename="stream.jpg",
    )
    collected = bytearray()
    while True:
        chunk = body.read(64)  # tiny reads force many chunks
        if not chunk:
            break
        collected += chunk
    assert len(collected) == body.length
    # the file payload survives byte-exact somewhere inside the body
    assert bytes(payload) in bytes(collected)
    assert b'name="chat_id"' in bytes(collected)
    body.close()


def test_multipart_body_single_read(tmp_path: Path) -> None:
    image = make_jpeg(tmp_path / "s2.jpg")
    body = MultipartBody(
        fields={"chat_id": "1"},
        file_field="photo",
        file_path=str(image),
        file_content_type="image/jpeg",
        filename="s2.jpg",
    )
    whole = body.read(-1)
    assert len(whole) == body.length
    body.close()
