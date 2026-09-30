"""In-process fake Bot API server (loopback only).

Scriptable behaviours per request, popped in order; the default response is
a valid sendPhoto success. Records every parsed request (fields + file
bytes) so tests can assert on what the real multipart client actually sent.
"""

from __future__ import annotations

import email.header
import email.parser
import email.policy
import json
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


@dataclass(frozen=True)
class RecordedRequest:
    method: str
    path: str
    fields: dict[str, str]
    filename: str | None
    file_bytes: bytes


@dataclass(frozen=True)
class Ok:
    message_id: int | None = None  # None -> auto-increment


@dataclass(frozen=True)
class JsonError:
    status: int
    error_code: int
    description: str
    retry_after: int | None = None


@dataclass(frozen=True)
class RawResponse:
    status: int
    body: bytes
    content_type: str = "text/html"


@dataclass(frozen=True)
class DropConnection:
    """Simulate a network failure mid-request: headers sent, socket closed."""


@dataclass(frozen=True)
class StallThenOk:
    seconds: float


Outcome = Ok | JsonError | RawResponse | DropConnection | StallThenOk


@dataclass
class FakeBotAPIServer:
    address: tuple[str, int]
    outcomes: list[Outcome] = field(default_factory=list)
    requests: list[RecordedRequest] = field(default_factory=list)

    def __post_init__(self) -> None:
        self._http = ThreadingHTTPServer(self.address, self._handler())
        self._http.daemon_threads = True
        self.port = self._http.server_address[1]
        self._message_seq = 5000
        self._lock = threading.Lock()

    # -- lifecycle ---------------------------------------------------------

    def serve_forever_threaded(self) -> threading.Thread:
        thread = threading.Thread(target=self._http.serve_forever, daemon=True)
        thread.start()
        return thread

    def shutdown_server(self, thread: threading.Thread) -> None:
        self._http.shutdown()
        self._http.server_close()
        thread.join(timeout=5)

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    # -- scripting ---------------------------------------------------------

    def enqueue(self, *outcomes: Outcome) -> None:
        self.outcomes.extend(outcomes)

    def _next_response(self) -> Outcome:
        with self._lock:
            if self.outcomes:
                return self.outcomes.pop(0)
            self._message_seq += 1
            return Ok(message_id=self._message_seq)

    # -- handler -----------------------------------------------------------

    def _handler(self) -> type[BaseHTTPRequestHandler]:
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                pass  # quiet: the test runner owns output

            def do_GET(self) -> None:
                server._record_and_answer(self, file_part=None)

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                content_type = self.headers.get("Content-Type", "")
                if "multipart" in content_type:
                    fields, filename, file_bytes = parse_multipart(content_type, body)
                else:
                    fields = {"body": body.decode("utf-8", "replace")}
                    filename = None
                    file_bytes = body
                server._record_and_answer(self, file_part=(filename, file_bytes, fields))

        return Handler

    def _record_and_answer(
        self,
        handler: BaseHTTPRequestHandler,
        file_part: tuple[str | None, bytes | None, dict[str, str]] | None,
    ) -> None:
        path = handler.path
        fields: dict[str, str] = {}
        filename: str | None = None
        file_bytes = b""
        if file_part is not None:
            fields = file_part[2]
            filename = file_part[0]
            file_bytes = file_part[1] or b""
        with self._lock:
            self.requests.append(
                RecordedRequest(
                    method="POST" if file_part is not None else "GET",
                    path=path,
                    fields=fields,
                    filename=filename,
                    file_bytes=file_bytes,
                )
            )
        outcome = self._next_response()
        if isinstance(outcome, DropConnection):
            handler.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial")
            handler.close_connection = True
            handler.connection.close()
            return
        if isinstance(outcome, StallThenOk):
            threading.Event().wait(outcome.seconds)
            outcome = Ok()

        if path.endswith("/getMe") and isinstance(outcome, Ok):
            self._send_json(
                handler,
                200,
                {"ok": True, "result": {"id": 1, "is_bot": True, "username": "test_bot"}},
            )
        elif isinstance(outcome, Ok):
            self._message_seq += 1
            message_id = outcome.message_id if outcome.message_id is not None else self._message_seq
            self._send_json(handler, 200, {"ok": True, "result": {"message_id": message_id}})
        elif isinstance(outcome, JsonError):
            error_body: dict[str, object] = {
                "ok": False,
                "error_code": outcome.error_code,
                "description": outcome.description,
            }
            if outcome.retry_after is not None:
                error_body["parameters"] = {"retry_after": outcome.retry_after}
            self._send_json(handler, outcome.status, error_body)
        else:
            assert isinstance(outcome, RawResponse)
            handler.send_response(outcome.status)
            handler.send_header("Content-Type", outcome.content_type)
            handler.send_header("Content-Length", str(len(outcome.body)))
            handler.end_headers()
            handler.wfile.write(outcome.body)

    def _send_json(
        self, handler: BaseHTTPRequestHandler, status: int, body: dict[str, object]
    ) -> None:
        payload = json.dumps(body).encode("utf-8")
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        handler.wfile.write(payload)


def parse_multipart(content_type: str, body: bytes) -> tuple[dict[str, str], str | None, bytes]:
    """Parse multipart/form-data with the stdlib email parser (CRLF aware)."""
    parser = email.parser.BytesParser(policy=email.policy.HTTP.clone(max_line_length=0))
    raw = b"Content-Type: " + content_type.encode("utf-8") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
    message = parser.parsebytes(raw)
    fields: dict[str, str] = {}
    filename: str | None = None
    file_bytes = b""
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not isinstance(name, str):
            continue
        payload = part.get_payload(decode=True)
        data = payload if isinstance(payload, bytes) else b""
        part_filename = part.get_filename()
        if part_filename is None:
            fields[name] = data.decode("utf-8", "replace")
        else:
            filename = part_filename
            file_bytes = data
    return fields, filename, file_bytes
