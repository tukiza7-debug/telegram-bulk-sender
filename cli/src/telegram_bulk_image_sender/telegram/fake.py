"""In-memory TelegramClient for tests and dry simulation.

Scriptable via a queue of outcomes: every queued item is either an
``ok`` marker (a SentMessage with an incrementing id is returned) or an
exception instance to raise. Unqueued calls use the default success
behaviour, so tests only script the interesting parts. All calls are
recorded for assertions on real behaviour (caption bytes, chat ids, order).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..model import ChatId, ParseMode
from .base import BotUser, SentMessage, TelegramClient

ScriptedOutcome = SentMessage | Exception


@dataclass(frozen=True)
class SendCall:
    chat_id: ChatId
    photo_path: str
    caption: str | None
    parse_mode: ParseMode
    filename: str | None


@dataclass
class FakeTelegramClient(TelegramClient):
    bot_user: BotUser = field(
        default_factory=lambda: BotUser(id=1, is_bot=True, username="test_bot")
    )
    outcomes: list[ScriptedOutcome] = field(default_factory=list)
    calls: list[SendCall] = field(default_factory=list)
    get_me_calls: int = 0
    fail_get_me: Exception | None = None
    _next_message_id: int = 1000

    def get_me(self) -> BotUser:
        self.get_me_calls += 1
        if self.fail_get_me is not None:
            raise self.fail_get_me
        return self.bot_user

    def send_photo(
        self,
        *,
        chat_id: ChatId,
        photo_path: str,
        caption: str | None,
        parse_mode: ParseMode,
        filename: str | None = None,
    ) -> SentMessage:
        self.calls.append(
            SendCall(
                chat_id=chat_id,
                photo_path=photo_path,
                caption=caption,
                parse_mode=parse_mode,
                filename=filename,
            )
        )
        if self.outcomes:
            outcome = self.outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome
        self._next_message_id += 1
        return SentMessage(message_id=self._next_message_id)

    def close(self) -> None:
        return None
