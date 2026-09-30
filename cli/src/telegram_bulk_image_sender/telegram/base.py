"""TelegramClient interface: the ONLY boundary between business logic and
the network. Exactly two implementations exist:

- :class:`telegram_bulk_image_sender.telegram.http_client.TelegramHttpClient`
  (real HTTP, stdlib urllib, direct connection, timeouts on every call)
- :class:`telegram_bulk_image_sender.telegram.fake.FakeTelegramClient`
  (in-memory, tests)

Business logic must import this module, never the concrete clients
(documented in docs/ARCHITECTURE.md and enforced in review).
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass

from ..model import ChatId, ParseMode


@dataclass(frozen=True)
class BotUser:
    id: int
    is_bot: bool
    username: str


@dataclass(frozen=True)
class SentMessage:
    message_id: int


class TelegramClient(ABC):
    """Minimal Bot API surface this tool needs: getMe + sendPhoto."""

    @abstractmethod
    def get_me(self) -> BotUser:
        """Validate the token and identify the bot (preflight)."""

    @abstractmethod
    def send_photo(
        self,
        *,
        chat_id: ChatId,
        photo_path: str,
        caption: str | None,
        parse_mode: ParseMode,
        filename: str | None = None,
    ) -> SentMessage:
        """Upload one photo. Raises the typed errors from errors.py."""

    @abstractmethod
    def close(self) -> None:
        """Release resources (no-op for the fake; urllib needs nothing)."""
