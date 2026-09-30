"""Token-bucket pacing: one global bucket plus one bucket per recipient.

Pure timing logic is separated from sleeping: reserve() returns the number
of seconds the caller must wait before sending (0 = go now). Tests inject a
fake clock and assert the returned delays without ever sleeping for real.

Conservative burst sizes: derived from the configured rate (2 seconds worth
of tokens, minimum 1), so a fresh run cannot burst wider than the configured
pacing.
"""

from __future__ import annotations

import threading
import time
from typing import Callable

from .config import LimitsConfig
from .model import ChatId


class TokenBucket:
    """Thread-safe token bucket with reservations that return wait times."""

    def __init__(
        self,
        *,
        capacity: float,
        refill_per_second: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if capacity < 1.0:
            raise ValueError("capacity must be >= 1")
        if refill_per_second <= 0:
            raise ValueError("refill_per_second must be > 0")
        self._capacity = float(capacity)
        self._rate = float(refill_per_second)
        self._clock = clock
        self._level = float(capacity)
        self._last = clock()
        self._lock = threading.Lock()

    def reserve(self) -> float:
        """Consume one token; return seconds to wait before acting (>= 0).

        Reservations may overdraw the bucket: a negative level schedules the
        next token, which keeps concurrent reservers correctly paced.
        """
        with self._lock:
            now = self._clock()
            self._level = min(self._capacity, self._level + (now - self._last) * self._rate)
            self._last = now
            self._level -= 1.0
            deficit = -self._level
            if deficit <= 0:
                return 0.0
            return deficit / self._rate


class RateLimiter:
    """Global + per-recipient pacing built on two TokenBuckets per lookup."""

    def __init__(self, limits: LimitsConfig, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._global_rate = limits.global_per_minute / 60.0
        self._chat_rate = limits.per_recipient_per_minute / 60.0
        self._global = TokenBucket(
            capacity=max(1.0, self._global_rate * 2.0),
            refill_per_second=self._global_rate,
            clock=clock,
        )
        self._per_chat: dict[str, TokenBucket] = {}
        self._chat_lock = threading.Lock()

    def reserve(self, chat_id: ChatId) -> float:
        """Reserve one send to chat_id; returns seconds to wait (>= 0).

        When both buckets need waiting, the caller waits the larger time.
        The other bucket's token is already consumed, which can only slow
        sending down, never speed it up (conservative direction).
        """
        global_wait = self._global.reserve()
        chat_wait = self._bucket_for(chat_id).reserve()
        return max(global_wait, chat_wait)

    def _bucket_for(self, chat_id: ChatId) -> TokenBucket:
        key = str(chat_id)
        with self._chat_lock:
            bucket = self._per_chat.get(key)
            if bucket is None:
                bucket = TokenBucket(
                    capacity=max(1.0, self._chat_rate * 2.0),
                    refill_per_second=self._chat_rate,
                    clock=self._clock,
                )
                self._per_chat[key] = bucket
            return bucket
