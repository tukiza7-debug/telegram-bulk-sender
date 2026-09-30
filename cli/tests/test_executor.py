"""Executor behaviour with the in-memory client and fake clocks.

No test here sleeps in real time: sleeps are recorded, clocks are advanced
by hand. Every test asserts real state transitions (statuses, attempts,
checkpoint contents), never mock bookkeeping.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

from telegram_bulk_image_sender.config import Config, parse_config
from telegram_bulk_image_sender.errors import (
    AuthError,
    PermanentSendError,
    RateLimitedError,
    TransientSendError,
)
from telegram_bulk_image_sender.executor import RateLimitedExecutor
from telegram_bulk_image_sender.model import (
    ImageCandidate,
    ParseMode,
    PlannedSend,
    Recipient,
    ResultStatus,
    ValidatedImage,
)
from telegram_bulk_image_sender.reporter import Reporter
from telegram_bulk_image_sender.state import CheckpointStore
from telegram_bulk_image_sender.telegram.base import SentMessage
from telegram_bulk_image_sender.telegram.fake import FakeTelegramClient

NEWS = Recipient(name="news", chat_id=1)
FIXED_NOW = datetime(2026, 9, 30, 12, 0, tzinfo=UTC)


class Recorder:
    def __init__(self) -> None:
        self.sleeps: list[float] = []
        self.now = 1000.0

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def clock(self) -> float:
        return self.now


def _image(tmp_path: Path, name: str = "a.jpg") -> ValidatedImage:
    from conftest import make_jpeg

    path = make_jpeg(tmp_path / name, color=(5, 5, 5))
    stat = path.stat()
    return ValidatedImage(
        candidate=ImageCandidate(path=str(path), mtime_ns=stat.st_mtime_ns, size=stat.st_size),
        sha256="deadbeef" + name,
        format="jpeg",
        width=8,
        height=8,
    )


def _plan(tmp_path: Path, count: int = 1) -> list[PlannedSend]:
    return [
        PlannedSend(
            image=_image(tmp_path, f"img{i}.jpg"),
            recipient=NEWS,
            caption=None,
            parse_mode=ParseMode.NONE,
            index_for_recipient=i,
            total_for_recipient=count,
        )
        for i in range(1, count + 1)
    ]


def _executor(
    tmp_path: Path,
    client: FakeTelegramClient,
    *,
    recorder: Recorder | None = None,
    config: Config | None = None,
    stop_event: threading.Event | None = None,
    now_fn: Callable[[], datetime] | None = None,
) -> RateLimitedExecutor:
    recorder = recorder or Recorder()
    config = config or Config()
    reporter = Reporter(run_id="test0001", config=config, report_dir=str(tmp_path / "reports"))
    return RateLimitedExecutor(
        client=client,
        config=config,
        checkpoint=_checkpoint(tmp_path),
        reporter=reporter,
        stop_event=stop_event,
        clock=recorder.clock,
        sleeper=recorder.sleep,
        now_fn=now_fn if now_fn is not None else (lambda: FIXED_NOW),
        rng=lambda: 0.5,
    )


def _checkpoint(tmp_path: Path) -> CheckpointStore:
    store = CheckpointStore(str(tmp_path / "state" / "cp.json"))
    store.load()
    return store


def test_all_sends_succeed(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    executor = _executor(tmp_path, client)
    result = executor.run(_plan(tmp_path, 3), limit=None)
    assert [e.status for e in result.events] == [ResultStatus.SENT] * 3
    assert result.abort_reason is None
    assert len(client.calls) == 3
    assert all(e.attempts == 1 for e in result.events)
    assert all(e.telegram_message_id is not None for e in result.events)


def test_transient_failure_retries_then_succeeds(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    client.outcomes = [TransientSendError("timeout", http_status=599), SentMessage(message_id=42)]
    recorder = Recorder()
    config = parse_config(
        {
            "limits": {"global_per_minute": 6000.0, "per_recipient_per_minute": 6000.0},
            "send": {"backoff_base_seconds": 1.0},
        }
    )
    executor = _executor(tmp_path, client, recorder=recorder, config=config)
    result = executor.run(_plan(tmp_path), limit=None)
    assert result.events[0].status is ResultStatus.SENT
    assert result.events[0].attempts == 2
    # rng=0.5 -> backoff 1.0*0.75 = 0.75 s total, sliced <=0.1 s, never real
    assert sum(recorder.sleeps) == pytest.approx(0.75, abs=0.02)


def test_transient_exhausts_budget(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    client.outcomes = [
        TransientSendError("boom", http_status=500),
        TransientSendError("boom", http_status=500),
        TransientSendError("boom", http_status=500),
        TransientSendError("boom", http_status=500),
    ]
    config = parse_config({"send": {"max_attempts": 4}})
    recorder = Recorder()
    executor = _executor(tmp_path, client, recorder=recorder, config=config)
    result = executor.run(_plan(tmp_path), limit=None)
    event = result.events[0]
    assert event.status is ResultStatus.FAILED_TRANSIENT
    assert event.attempts == 4  # initial + 3 retries, then exhausted
    assert "exhausted 4 attempts" in (event.note or "")
    assert event.error_kind == "TRANSIENT"


def test_rate_limited_waits_server_retry_after(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    client.outcomes = [RateLimitedError("flood", retry_after=9.0), SentMessage(message_id=43)]
    recorder = Recorder()
    config = parse_config(
        {
            "limits": {"global_per_minute": 6000.0, "per_recipient_per_minute": 6000.0},
            "send": {"backoff_base_seconds": 1.0},
        }
    )
    executor = _executor(tmp_path, client, recorder=recorder, config=config)
    result = executor.run(_plan(tmp_path), limit=None)
    assert result.events[0].status is ResultStatus.SENT
    assert result.events[0].attempts == 2
    # retry_after 9 s + 0.25 s jitter, sliced <=0.1 s, never real sleeping
    assert sum(recorder.sleeps) == pytest.approx(9.25, abs=0.02)


def test_permanent_failure_never_retries(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    client.outcomes = [
        PermanentSendError(
            "chat not found", http_status=404, api_error_code=404, api_description="chat not found"
        )
    ]
    executor = _executor(tmp_path, client)
    result = executor.run(_plan(tmp_path), limit=None)
    event = result.events[0]
    assert event.status is ResultStatus.FAILED_PERMANENT
    assert event.attempts == 1
    assert event.error_code == 404


def test_fatal_401_aborts_remaining(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    client.outcomes = [
        AuthError(
            "Unauthorized", http_status=401, api_error_code=401, api_description="Unauthorized"
        ),
    ]
    executor = _executor(tmp_path, client)
    result = executor.run(_plan(tmp_path, 3), limit=None)
    statuses = [e.status for e in result.events]
    assert statuses.count(ResultStatus.FAILED_FATAL) == 1
    assert statuses.count(ResultStatus.NOT_SENT_FATAL) == 2
    assert result.abort_reason is not None
    # the fatal item was attempted exactly once: no retries on 401
    fatal = next(e for e in result.events if e.status is ResultStatus.FAILED_FATAL)
    assert fatal.attempts == 1
    assert fatal.error_code == 401


def test_kill_switch_halts_run(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    # 3 failures then successes: at the 4th completed send the window holds
    # 3 failures / 4 sends = 0.75 > 0.5, so the switch fires.
    client.outcomes = [
        PermanentSendError("x", http_status=400, api_error_code=400, api_description="bad"),
        PermanentSendError("x", http_status=400, api_error_code=400, api_description="bad"),
        PermanentSendError("x", http_status=400, api_error_code=400, api_description="bad"),
    ]
    config = parse_config(
        {"kill_switch": {"failure_rate": 0.5, "min_sample": 4, "window_minutes": 5}}
    )
    executor = _executor(tmp_path, client, config=config)
    result = executor.run(_plan(tmp_path, 6), limit=None)
    statuses = [e.status for e in result.events]
    assert statuses.count(ResultStatus.FAILED_PERMANENT) == 3
    assert statuses.count(ResultStatus.SENT) == 1  # the min_sample send
    assert statuses.count(ResultStatus.NOT_SENT_KILL_SWITCH) == 2
    assert result.abort_reason is not None
    assert "kill-switch" in result.abort_reason


def test_kill_switch_stays_quiet_below_min_sample(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    client.outcomes = [
        PermanentSendError("x", http_status=400, api_error_code=400, api_description="bad")
    ]
    config = parse_config({"kill_switch": {"failure_rate": 0.5, "min_sample": 4}})
    executor = _executor(tmp_path, client, config=config)
    result = executor.run(_plan(tmp_path, 2), limit=None)
    statuses = [e.status for e in result.events]
    assert ResultStatus.NOT_SENT_KILL_SWITCH not in statuses
    assert result.abort_reason is None


def test_limit_caps_dispatched_sends(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    executor = _executor(tmp_path, client)
    result = executor.run(_plan(tmp_path, 5), limit=2)
    statuses = [e.status for e in result.events]
    assert statuses.count(ResultStatus.SENT) == 2
    assert statuses.count(ResultStatus.NOT_SENT_LIMIT) == 3
    assert len(client.calls) == 2


def test_stop_before_run_sends_nothing(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    stop = threading.Event()
    stop.set()
    executor = _executor(tmp_path, client, stop_event=stop)
    result = executor.run(_plan(tmp_path, 2), limit=None)
    assert all(e.status is ResultStatus.NOT_SENT_INTERRUPTED for e in result.events)
    assert client.calls == []


def test_stop_during_run_finishes_inflight_only(tmp_path: Path) -> None:
    stop = threading.Event()
    client = FakeTelegramClient()
    original = client.send_photo
    calls = {"n": 0}

    def spy(**kwargs: Any) -> SentMessage:
        calls["n"] += 1
        if calls["n"] >= 2:
            stop.set()  # stop arrives while the second send is in flight
        return original(**kwargs)

    # Intentional runtime replacement of the fake's method (test seam).
    client.send_photo = spy  # type: ignore[method-assign]
    executor = _executor(tmp_path, client, stop_event=stop)
    result = executor.run(_plan(tmp_path, 4), limit=None)
    statuses = [e.status for e in result.events]
    assert statuses.count(ResultStatus.SENT) >= 2
    assert statuses.count(ResultStatus.NOT_SENT_INTERRUPTED) == 2
    assert calls["n"] == 2


def test_checkpoint_records_delivered_pairs(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    checkpoint = _checkpoint(tmp_path)
    reporter = Reporter(run_id="test0002", config=Config(), report_dir=str(tmp_path / "reports"))
    recorder = Recorder()
    image = _image(tmp_path)
    executor = RateLimitedExecutor(
        client=client,
        config=Config(),
        checkpoint=checkpoint,
        reporter=reporter,
        clock=recorder.clock,
        sleeper=recorder.sleep,
        now_fn=lambda: FIXED_NOW,
        rng=lambda: 0.5,
    )
    plan = [
        PlannedSend(
            image=image,
            recipient=NEWS,
            caption=None,
            parse_mode=ParseMode.NONE,
            index_for_recipient=1,
            total_for_recipient=1,
        )
    ]
    executor.run(plan, limit=None)
    assert checkpoint.is_delivered(image.sha256, 1)


def test_quiet_hours_skip(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    config = parse_config(
        {
            "limits": {
                "quiet_hours": {
                    "enabled": True,
                    "start": "22:00",
                    "end": "07:00",
                    "timezone": "UTC",
                }
            }
        }
    )
    # 23:30 UTC is inside the window
    executor = _executor(
        tmp_path, client, config=config, now_fn=lambda: datetime(2026, 9, 30, 23, 30, tzinfo=UTC)
    )
    result = executor.run(_plan(tmp_path, 2), limit=None)
    assert all(e.status is ResultStatus.SKIPPED_QUIET_HOURS for e in result.events)
    assert client.calls == []


def test_quiet_hours_wrap_past_midnight(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    config = parse_config(
        {
            "limits": {
                "quiet_hours": {
                    "enabled": True,
                    "start": "22:00",
                    "end": "07:00",
                    "timezone": "UTC",
                }
            }
        }
    )
    executor = _executor(
        tmp_path, client, config=config, now_fn=lambda: datetime(2026, 9, 30, 3, 0, tzinfo=UTC)
    )
    result = executor.run(_plan(tmp_path), limit=None)
    assert result.events[0].status is ResultStatus.SKIPPED_QUIET_HOURS


def test_daily_cap_skips_after_limit(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    checkpoint = _checkpoint(tmp_path)
    for i in range(3):
        checkpoint.record(f"hash{i}", 1, i)
    reporter = Reporter(run_id="test0003", config=Config(), report_dir=str(tmp_path / "reports"))
    config = parse_config({"limits": {"daily_cap_per_recipient": 3}})
    recorder = Recorder()
    executor = RateLimitedExecutor(
        client=client,
        config=config,
        checkpoint=checkpoint,
        reporter=reporter,
        clock=recorder.clock,
        sleeper=recorder.sleep,
        now_fn=lambda: FIXED_NOW,
        rng=lambda: 0.5,
    )
    plan = _plan(tmp_path, 2)
    result = executor.run(plan, limit=None)
    statuses = [e.status for e in result.events]
    assert statuses.count(ResultStatus.SKIPPED_DAILY_CAP) == 2
    assert client.calls == []


def test_pacing_sleep_recorded_not_slept(tmp_path: Path) -> None:
    client = FakeTelegramClient()
    config = parse_config({"limits": {"per_recipient_per_minute": 6.0}})
    recorder = Recorder()
    executor = _executor(tmp_path, client, recorder=recorder, config=config)
    executor.run(_plan(tmp_path, 3), limit=None)
    # 6/min = 10 s between sends to the same chat. Sleeps happen in <=0.1 s
    # slices (stop-event friendly); totals must match the pacing maths.
    assert recorder.sleeps, "pacing never slept"
    assert max(recorder.sleeps) <= 0.1 + 1e-9
    assert sum(recorder.sleeps) == pytest.approx(20.0, abs=0.05)
