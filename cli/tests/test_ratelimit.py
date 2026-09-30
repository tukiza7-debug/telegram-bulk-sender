"""Token buckets: exact waits under a fake clock, no real sleeping."""

from __future__ import annotations

import threading

import pytest

from telegram_bulk_image_sender.config import LimitsConfig
from telegram_bulk_image_sender.ratelimit import RateLimiter, TokenBucket


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0
        self.lock = threading.Lock()

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        with self.lock:
            self.now += seconds


def test_bucket_starts_full_and_paces_after_burst() -> None:
    clock = FakeClock()
    # 30/minute = 0.5/s, capacity 1 (2 seconds worth, min 1).
    bucket = TokenBucket(capacity=1.0, refill_per_second=0.5, clock=clock)
    assert bucket.reserve() == 0.0  # initial token available
    second = bucket.reserve()
    assert second == pytest.approx(2.0)  # one token takes 2 s at 0.5/s
    clock.advance(1.0)
    third = bucket.reserve()
    # The bucket owed 1 token (2 s). 1 s of refill credits 0.5 tokens, and
    # this reservation consumes another: debt 1.5 tokens -> 3.0 s.
    assert third == pytest.approx(3.0)


def test_refill_accrues_while_idle() -> None:
    clock = FakeClock()
    bucket = TokenBucket(capacity=1.0, refill_per_second=1.0, clock=clock)
    bucket.reserve()
    clock.advance(10.0)
    assert bucket.reserve() == 0.0  # bucket refilled to capacity while idle


def test_capacity_never_exceeds_burst() -> None:
    clock = FakeClock()
    bucket = TokenBucket(capacity=2.0, refill_per_second=1.0, clock=clock)
    clock.advance(100.0)
    assert bucket.reserve() == 0.0
    assert bucket.reserve() == 0.0
    assert bucket.reserve() == pytest.approx(1.0)  # third consecutive goes into deficit


def test_reservations_overdraw_and_queue_up() -> None:
    clock = FakeClock()
    bucket = TokenBucket(capacity=1.0, refill_per_second=1.0, clock=clock)
    assert bucket.reserve() == 0.0
    waits = [bucket.reserve() for _ in range(3)]
    assert waits == [pytest.approx(1.0), pytest.approx(2.0), pytest.approx(3.0)]


def test_invalid_bucket_parameters() -> None:
    with pytest.raises(ValueError):
        TokenBucket(capacity=0.5, refill_per_second=1.0)
    with pytest.raises(ValueError):
        TokenBucket(capacity=1.0, refill_per_second=0.0)


def test_rate_limiter_per_recipient_isolation() -> None:
    clock = FakeClock()
    # 6/minute per recipient = 0.1/s -> 10 s between sends to the same chat.
    limiter = RateLimiter(
        LimitsConfig(global_per_minute=600.0, per_recipient_per_minute=6.0), clock=clock
    )
    assert limiter.reserve("chat-a") == 0.0
    assert limiter.reserve("chat-a") == pytest.approx(10.0)
    assert limiter.reserve("chat-b") == pytest.approx(0.0)  # different chat: unaffected


def test_rate_limiter_global_cap_applies() -> None:
    clock = FakeClock()
    limiter = RateLimiter(
        LimitsConfig(global_per_minute=6.0, per_recipient_per_minute=600.0), clock=clock
    )
    assert limiter.reserve("chat-a") == 0.0
    assert limiter.reserve("chat-b") == pytest.approx(10.0)  # global bucket


def test_rate_limiter_takes_the_longer_wait() -> None:
    clock = FakeClock()
    limiter = RateLimiter(
        LimitsConfig(global_per_minute=6.0, per_recipient_per_minute=12.0), clock=clock
    )
    assert limiter.reserve("chat-a") == 0.0
    # per-recipient needs 5 s, global needs 10 s -> wait 10 s (conservative).
    assert limiter.reserve("chat-a") == pytest.approx(10.0)


def test_rate_limiter_accepts_int_and_str_chat_ids() -> None:
    clock = FakeClock()
    limiter = RateLimiter(
        LimitsConfig(global_per_minute=600.0, per_recipient_per_minute=6.0), clock=clock
    )
    assert limiter.reserve(42) == 0.0
    assert limiter.reserve("@chan") == 0.0
    assert limiter.reserve(42) == pytest.approx(10.0)
