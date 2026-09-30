"""Retry policy: exponential backoff with jitter and 429 flood handling.

This module contains only the *policy* (pure delay computation). The
executor owns the actual sleeping, with injected sleep functions so tests
never wait in real time. Error classification lives in errors.py; the
mapping from exceptions to delays happens here.

- TRANSIENT errors: delay = min(cap, base * 2^(attempt-1)) scaled by a
  uniform jitter factor in [0.5, 1.0] (never exceeds the cap).
- HTTP 429: the server-requested retry_after is honoured first, with a
  small additive jitter (0..0.5 s) so many workers do not wake in lockstep.
- PERMANENT errors: no retry (executor responsibility).
- FATAL errors: abort the run (executor responsibility).
"""

from __future__ import annotations

import random
from typing import Callable

from .errors import ErrorKind, RateLimitedError, TbisError

RNG = Callable[[], float]


class RetryPolicy:
    def __init__(
        self,
        *,
        max_attempts: int,
        base_seconds: float,
        max_seconds: float,
        rng: RNG | None = None,
    ) -> None:
        if max_attempts < 1:
            raise ValueError("max_attempts must be >= 1")
        self.max_attempts = max_attempts
        self.base_seconds = base_seconds
        self.max_seconds = max_seconds
        self._rng: RNG = rng if rng is not None else random.random

    def should_retry(self, exc: TbisError, attempts_done: int) -> bool:
        """True when the error kind allows another attempt within the cap."""
        if attempts_done >= self.max_attempts:
            return False
        return exc.kind is ErrorKind.TRANSIENT

    def delay_for(self, exc: TbisError, attempt: int) -> float:
        """Seconds to wait before the next attempt (attempt is 1-based)."""
        if isinstance(exc, RateLimitedError):
            return exc.retry_after + self._rng() * 0.5
        raw = self.base_seconds * (2 ** (attempt - 1))
        capped = min(raw, self.max_seconds)
        # Jitter in [0.5, 1.0] of the capped delay: keeps thundering-herd
        # away without ever exceeding the configured maximum.
        return capped * (0.5 + 0.5 * self._rng())
