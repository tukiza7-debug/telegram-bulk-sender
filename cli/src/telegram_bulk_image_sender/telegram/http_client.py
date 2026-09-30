"""Real Bot API client on stdlib urllib with streaming multipart uploads.

Deliberate engineering decisions:
- No third-party HTTP library: urllib + a hand-rolled multipart reader keeps
  the dependency list at zero for networking and lets us stream files from
  disk in chunks instead of loading a 10 MB photo into RAM.
- Direct connection only: ProxyHandler({}) deliberately ignores http_proxy/
  https_proxy environment variables. The tool must never route traffic
  anywhere the operator did not explicitly configure, and it certainly never
  rotates proxies (spec 2.4: no evasion mechanisms).
- Every request carries a timeout (spec 2.4: no call may hang forever).
- All responses are classified through errors.classify_http_status; the raw
  HTTP status and Telegram error description travel with the exception.
"""

from __future__ import annotations

import http.client
import json
import uuid
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener

from ..config import TelegramConfig
from ..errors import (
    AuthError,
    PermanentSendError,
    RateLimitedError,
    TransientSendError,
)
from ..formats import sniff_format
from ..model import ChatId, ParseMode
from .base import BotUser, SentMessage, TelegramClient

_UPLOAD_CHUNK = 256 * 1024

# Content types for the file part, by validated image format.
_FILE_CONTENT_TYPES = {"jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp"}


class MultipartBody:
    """A file-like streaming multipart/form-data body with known length.

    urlopen() accepts a file-like ``data`` object as long as Content-Length
    is provided; read() streams the photo from disk in chunks, so peak memory
    stays bounded regardless of image size.
    """

    def __init__(
        self,
        fields: dict[str, str],
        file_field: str,
        file_path: str,
        file_content_type: str,
        filename: str,
    ) -> None:
        self._boundary = f"tbis-{uuid.uuid4().hex}"
        self._file_path = file_path
        head = bytearray()
        for name, value in fields.items():
            head += _part_header(self._boundary, name, filename=None, content_type=None)
            head += value.encode("utf-8")
            head += b"\r\n"
        head += _part_header(
            self._boundary, file_field, filename=filename, content_type=file_content_type
        )
        self._head = bytes(head)
        self._tail = f"\r\n--{self._boundary}--\r\n".encode()
        self._file_size = Path(file_path).stat().st_size
        self.length = len(self._head) + self._file_size + len(self._tail)
        self._file_remaining = self._file_size
        # Opened for the lifetime of the upload body; closed in close().
        self._file_handle = open(file_path, "rb")  # noqa: SIM115

    @property
    def content_type(self) -> str:
        return f"multipart/form-data; boundary={self._boundary}"

    def read(self, size: int = -1) -> bytes:
        if size == -1:
            size = self.length  # http.client only ever asks in chunks
        chunks: list[bytes] = []
        wanted = size
        if self._head:
            take = min(wanted, len(self._head))
            chunks.append(self._head[:take])
            self._head = self._head[take:]
            wanted -= take
        if wanted > 0 and self._file_remaining > 0:
            take = min(wanted, self._file_remaining, _UPLOAD_CHUNK)
            data = self._file_handle.read(take)
            self._file_remaining -= len(data)
            chunks.append(data)
            wanted -= len(data)
        if wanted > 0 and self._tail:
            take = min(wanted, len(self._tail))
            chunks.append(self._tail[:take])
            self._tail = self._tail[take:]
        return b"".join(chunks)

    def close(self) -> None:
        self._file_handle.close()


def _part_header(
    boundary: str, name: str, *, filename: str | None, content_type: str | None
) -> bytes:
    lines = [f"--{boundary}\r\n"]
    disposition = f'Content-Disposition: form-data; name="{name}"'
    if filename is not None:
        disposition += f'; filename="{filename}"'
    lines.append(disposition + "\r\n")
    if content_type is not None:
        lines.append(f"Content-Type: {content_type}\r\n")
    lines.append("\r\n")
    return "".join(lines).encode("utf-8")


class TelegramHttpClient(TelegramClient):
    """Concrete Bot API client. Business logic never imports this class."""

    def __init__(self, config: TelegramConfig, token: str) -> None:
        self._config = config
        self._token = token
        self._base = config.api_base_url.rstrip("/")
        # Direct connections only; see module docstring.
        self._opener = build_opener(ProxyHandler({}))
        self.timeout = config.timeout_seconds

    # -- plumbing ----------------------------------------------------------

    def _request(self, method: str, body: MultipartBody | None) -> tuple[int, bytes]:
        url = f"{self._base}/bot{self._token}/{method}"
        headers = {"Accept": "application/json"}
        data: MultipartBody | bytes | None = None
        if body is not None:
            headers["Content-Type"] = body.content_type
            headers["Content-Length"] = str(body.length)
            data = body
        request = Request(url, data=data, headers=headers, method="POST" if body else "GET")
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                return response.status, response.read()
        except HTTPError as exc:
            payload = exc.read()
            exc.close()
            return exc.code, payload
        except (URLError, TimeoutError, ConnectionError, OSError, http.client.HTTPException) as exc:
            # Covers connect/read timeouts, dropped connections mid-upload and
            # truncated responses. All of these are TRANSIENT: the network
            # path failed, which is never evidence of a bad token.
            raise TransientSendError(
                f"network failure calling {method}: {type(exc).__name__}: {exc}"
            ) from exc

    # -- API surface ---------------------------------------------------------

    def get_me(self) -> BotUser:
        status, payload = self._request("getMe", None)
        document = _parse_json(method="getMe", status=status, payload=payload)
        result = _require_result(document, method="getMe")
        return BotUser(
            id=int(result["id"]),
            is_bot=bool(result.get("is_bot", True)),
            username=str(result.get("username", "")),
        )

    def send_photo(
        self,
        *,
        chat_id: ChatId,
        photo_path: str,
        caption: str | None,
        parse_mode: ParseMode,
        filename: str | None = None,
    ) -> SentMessage:
        source = Path(photo_path)
        send_name = filename or source.name
        fmt = sniff_format(photo_path) or ""
        content_type = _FILE_CONTENT_TYPES.get(fmt, "application/octet-stream")
        fields: dict[str, str] = {"chat_id": str(chat_id)}
        if caption:
            fields["caption"] = caption
        if parse_mode is not ParseMode.NONE and caption:
            fields["parse_mode"] = _PARSE_MODE_NAMES[parse_mode]
        body = MultipartBody(
            fields=fields,
            file_field="photo",
            file_path=photo_path,
            file_content_type=content_type,
            filename=send_name,
        )
        try:
            status, payload = self._request("sendPhoto", body)
        finally:
            body.close()
        document = _parse_json(method="sendPhoto", status=status, payload=payload)
        result = _require_result(document, method="sendPhoto")
        message_id = result.get("message_id")
        if not isinstance(message_id, int):
            # A success without a message id cannot be checkpointed; retrying
            # risks a duplicate send, so this is PERMANENT and surfaced.
            raise PermanentSendError(
                "sendPhoto succeeded but the response has no integer message_id; "
                f"response was: {payload[:200]!r}",
                http_status=status,
            )
        return SentMessage(message_id=message_id)

    def close(self) -> None:
        # urllib keeps a small connection cache per opener; nothing to close
        # deterministically. The method exists for interface parity.
        return None


_PARSE_MODE_NAMES = {
    ParseMode.HTML: "HTML",
    ParseMode.MARKDOWN: "Markdown",
    ParseMode.MARKDOWN_V2: "MarkdownV2",
}


def _parse_json(*, method: str, status: int, payload: bytes) -> dict[str, Any]:
    """Decode a Bot API response and raise the correctly classified error."""
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        # Non-JSON answer (captive portal, HTML error page, truncated body):
        # the network path is suspect -> TRANSIENT, never "bad token".
        raise TransientSendError(
            f"{method}: non-JSON response (HTTP {status}): {payload[:120]!r}"
        ) from None
    if not isinstance(document, dict):
        raise TransientSendError(f"{method}: unexpected non-object response: {payload[:120]!r}")

    if document.get("ok") is True:
        return document

    error_code = document.get("error_code")
    description = str(document.get("description", ""))
    api_code = error_code if isinstance(error_code, int) else status
    parameters = document.get("parameters")
    retry_after = None
    if isinstance(parameters, dict):
        raw_retry = parameters.get("retry_after")
        if isinstance(raw_retry, int):
            retry_after = raw_retry

    if status == 401 or api_code == 401:
        raise AuthError(
            f"the bot token was rejected by Telegram (HTTP 401): {description}",
            http_status=status,
            api_error_code=api_code,
            api_description=description,
        )
    if status == 429 or api_code == 429:
        if retry_after is not None:
            raise RateLimitedError(
                f"flood control: retry after {retry_after}s: {description}",
                retry_after=float(retry_after),
                http_status=status,
                api_error_code=api_code,
                api_description=description,
            )
        raise TransientSendError(
            f"flood control (HTTP 429) without retry_after: {description}",
            http_status=status,
            api_error_code=api_code,
            api_description=description,
        )
    if 500 <= status <= 599:
        raise TransientSendError(
            f"Telegram server error (HTTP {status}): {description}",
            http_status=status,
            api_error_code=api_code,
            api_description=description,
        )
    raise PermanentSendError(
        f"{method} rejected (HTTP {status}): {description}",
        http_status=status,
        api_error_code=api_code,
        api_description=description,
    )


def _require_result(document: dict[str, Any], *, method: str) -> dict[str, Any]:
    result = document.get("result")
    if not isinstance(result, dict):
        raise PermanentSendError(
            f"{method}: response 'ok' but 'result' is missing or not an object"
        )
    return result
