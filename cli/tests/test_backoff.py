"""Retry policy: classification gates, exponential backoff, 429 handling."""

from __future__ import annotations

import pytest

from telegram_bulk_image_sender.backoff import RetryPolicy
from telegram_bulk_image_sender.errors import (
    AuthError,
    ErrorKind,
    PermanentSendError,
    RateLimitedError,
    TransientSendError,
)


def _deterministic_policy(**kwargs: object) -> RetryPolicy:
    kwargs.setdefault("max_attempts", 4)
    kwargs.setdefault("base_seconds", 1.0)
    kwargs.setdefault("max_seconds", 30.0)
    kwargs.setdefault("rng", lambda: 0.5)
    return RetryPolicy(**kwargs)  # type: ignore[arg-type]


def test_transient_retries_within_budget() -> None:
    policy = _deterministic_policy()
    exc = TransientSendError("timeout", http_status=599)
    assert policy.should_retry(exc, attempts_done=1) is True
    assert policy.should_retry(exc, attempts_done=4) is False  # budget exhausted


def test_permanent_never_retries() -> None:
    policy = _deterministic_policy()
    exc = PermanentSendError("chat not found", http_status=404)
    assert policy.should_retry(exc, attempts_done=0) is False


def test_fatal_never_retries() -> None:
    policy = _deterministic_policy()
    exc = AuthError("Unauthorized", http_status=401)
    assert policy.should_retry(exc, attempts_done=0) is False


def test_backoff_doubles_and_is_capped() -> None:
    policy = _deterministic_policy(base_seconds=1.0, max_seconds=10.0)
    delays = [policy.delay_for(TransientSendError("x"), attempt=a) for a in (1, 2, 3, 4, 5, 6)]
    # rng=0.5 -> jitter factor 0.75
    assert [
        d == pytest.approx(0.75 * min(10.0, 2 ** (a - 1)))
        for a, d in zip((1, 2, 3, 4, 5, 6), delays, strict=True)
    ] == [True] * 6


def test_backoff_stays_within_jitter_bounds() -> None:
    policy = RetryPolicy(max_attempts=5, base_seconds=2.0, max_seconds=60.0, rng=lambda: 0.0)
    assert policy.delay_for(TransientSendError("x"), attempt=3) == pytest.approx(4.0)
    policy = RetryPolicy(max_attempts=5, base_seconds=2.0, max_seconds=60.0, rng=lambda: 1.0)
    assert policy.delay_for(TransientSendError("x"), attempt=3) == pytest.approx(8.0)


def test_rate_limited_uses_server_retry_after_plus_small_jitter() -> None:
    policy = _deterministic_policy()
    exc = RateLimitedError("flood", retry_after=7.0)
    # rng 0.5 -> +0.25 s additive jitter
    assert policy.delay_for(exc, attempt=1) == pytest.approx(7.25)


def test_error_kinds_are_distinct() -> None:
    assert TransientSendError("x").kind is ErrorKind.TRANSIENT
    assert PermanentSendError("x").kind is ErrorKind.PERMANENT
    assert AuthError("x").kind is ErrorKind.FATAL


def test_zero_base_backoff_is_allowed() -> None:
    policy = RetryPolicy(max_attempts=3, base_seconds=0.0, max_seconds=0.0, rng=lambda: 0.7)
    assert policy.delay_for(TransientSendError("x"), attempt=1) == 0.0


def test_max_attempts_must_be_positive() -> None:
    with pytest.raises(ValueError, match="max_attempts"):
        RetryPolicy(max_attempts=0, base_seconds=1.0, max_seconds=10.0)
