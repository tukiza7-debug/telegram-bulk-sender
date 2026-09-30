"""Error taxonomy, exit codes and every exception the CLI raises.

Every failure mode of the tool belongs to exactly one class here. The
executor and the CLI map these to exit codes; nothing else invents its own
error strings for classification purposes.
"""

from __future__ import annotations

from enum import IntEnum


class ExitCode(IntEnum):
    """Process exit codes, as documented in README.md (section "Exit codes")."""

    OK = 0
    PARTIAL_FAILURE = 2
    FATAL = 3
    VALIDATION_ERROR = 4


class ErrorKind(IntEnum):
    """Machine-readable classification of a single failed send attempt.

    TRANSIENT  -> worth retrying (network, 5xx, 429 after the requested wait).
    PERMANENT  -> the request itself is wrong; retrying will not help.
    FATAL      -> the run cannot continue at all (bad token, broken state).
    """

    TRANSIENT = 1
    PERMANENT = 2
    FATAL = 3


class TbisError(Exception):
    """Base class for every error raised deliberately by this package."""

    kind: ErrorKind = ErrorKind.PERMANENT

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class ConfigError(TbisError):
    """Configuration is missing, malformed or failed schema validation."""

    kind = ErrorKind.FATAL


class SecretError(ConfigError):
    """The bot token is absent, malformed, or was found where it must not be."""


class ValidationError(TbisError):
    """One or more input files/manifest rows failed validation."""

    kind = ErrorKind.FATAL

    def __init__(self, issues: list[str]) -> None:
        joined = "\n  - ".join(issues)
        super().__init__(f"{len(issues)} validation error(s):\n  - {joined}")
        self.issues = issues


class TelegramApiError(TbisError):
    """Base for errors reported by (or about) the Telegram Bot API."""

    def __init__(
        self,
        message: str,
        *,
        http_status: int | None = None,
        api_error_code: int | None = None,
        api_description: str | None = None,
    ) -> None:
        super().__init__(message)
        self.http_status = http_status
        self.api_error_code = api_error_code
        self.api_description = api_description


class TransientSendError(TelegramApiError):
    """Network failure, timeout, 5xx or non-JSON response. Retry is allowed."""

    kind = ErrorKind.TRANSIENT


class RateLimitedError(TelegramApiError):
    """HTTP 429 with a server-provided retry_after (seconds)."""

    kind = ErrorKind.TRANSIENT

    def __init__(
        self,
        message: str,
        *,
        retry_after: float,
        http_status: int | None = 429,
        api_error_code: int | None = None,
        api_description: str | None = None,
    ) -> None:
        super().__init__(
            message,
            http_status=http_status,
            api_error_code=api_error_code,
            api_description=api_description,
        )
        self.retry_after = retry_after


class PermanentSendError(TelegramApiError):
    """HTTP 400/403/404 and similar: the request is wrong, retry is futile."""

    kind = ErrorKind.PERMANENT


class AuthError(TelegramApiError):
    """HTTP 401: the bot token is invalid or was revoked. Run must abort."""

    kind = ErrorKind.FATAL


class StateError(TbisError):
    """The checkpoint store could not be read or written (e.g. disk full)."""

    kind = ErrorKind.FATAL


class KillSwitchTriggered(TbisError):
    """Failure rate over the configured window exceeded the threshold."""

    kind = ErrorKind.FATAL


class RunInterrupted(TbisError):
    """SIGINT/SIGTERM requested a graceful stop; in-flight send finished."""

    kind = ErrorKind.PERMANENT


def classify_http_status(status: int) -> ErrorKind:
    """Classify an HTTP status code per the error taxonomy in README.md.

    429 is handled separately by the caller (it carries retry_after), but is
    classified TRANSIENT here as well so no caller can mis-classify it.
    """
    if status in (400, 403, 404, 409, 413):
        return ErrorKind.PERMANENT
    if status == 401:
        return ErrorKind.FATAL
    if status == 429 or 500 <= status <= 599:
        return ErrorKind.TRANSIENT
    # Unknown 4xx (e.g. 422): the request was received and rejected; a retry
    # with the same bytes would fail identically. Treat as PERMANENT.
    if 400 <= status <= 499:
        return ErrorKind.PERMANENT
    return ErrorKind.TRANSIENT
