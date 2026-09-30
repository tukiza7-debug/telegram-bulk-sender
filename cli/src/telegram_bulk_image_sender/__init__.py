"""telegram-bulk-image-sender: importable library + ``tbis`` CLI.

Public API (business logic must depend on these, never on concrete HTTP
internals):

- :class:`Config`, :func:`load_config`, :func:`parse_config`
- :class:`RunRequest`, :func:`run`, :class:`RunResult`
- :class:`TelegramClient` (interface), :class:`FakeTelegramClient`
- :class:`CheckpointStore`, :class:`RateLimitedExecutor`, :class:`Reporter`
- :class:`ExitCode`, the exception taxonomy and :class:`ResultStatus`
"""

from __future__ import annotations

from .config import Config, load_config, parse_config
from .errors import (
    AuthError,
    ConfigError,
    ErrorKind,
    ExitCode,
    PermanentSendError,
    RateLimitedError,
    SecretError,
    StateError,
    TbisError,
    TransientSendError,
    ValidationError,
)
from .model import (
    CaptionMode,
    ChatId,
    OrderKey,
    ParseMode,
    PlannedSend,
    Recipient,
    ResultStatus,
    RunSummary,
    SendOutcome,
    ValidatedImage,
)
from .runner import ClientFactory, RunRequest, RunResult, run
from .state import CheckpointStore
from .telegram.base import TelegramClient
from .telegram.fake import FakeTelegramClient

__version__ = "2.0.0"

__all__ = [
    "AuthError",
    "CaptionMode",
    "ChatId",
    "CheckpointStore",
    "ClientFactory",
    "Config",
    "ConfigError",
    "ErrorKind",
    "ExitCode",
    "FakeTelegramClient",
    "OrderKey",
    "ParseMode",
    "PermanentSendError",
    "PlannedSend",
    "RateLimitedError",
    "Recipient",
    "ResultStatus",
    "RunRequest",
    "RunResult",
    "RunSummary",
    "SecretError",
    "SendOutcome",
    "StateError",
    "TbisError",
    "TelegramClient",
    "TransientSendError",
    "ValidatedImage",
    "ValidationError",
    "__version__",
    "load_config",
    "parse_config",
    "run",
]
