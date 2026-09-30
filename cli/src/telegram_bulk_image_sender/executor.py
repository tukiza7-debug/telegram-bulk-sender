"""RateLimitedExecutor: bounded, paced, resumable dispatch of the plan.

One pipeline for all three modes. Responsibilities:
- bounded concurrency (thread pool with at most send.concurrency workers);
- pacing via RateLimiter (global + per-recipient token buckets);
- retry policy per the error taxonomy (TRANSIENT retries with backoff /
  server-requested 429 waits; PERMANENT no retry; FATAL aborts the run);
- kill-switch: halt when the failure rate over the configured window is
  exceeded;
- graceful stop: on the stop event no new work is dispatched, sleeps are cut
  short, the in-flight send finishes, and remaining items are recorded as
  not-sent-interrupted (failure is data, never hidden).

The executor never touches the network directly and never imports the real
HTTP client - only the TelegramClient interface.
"""

from __future__ import annotations

import random
import threading
import time
from collections import deque
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable
from zoneinfo import ZoneInfo

from .backoff import RetryPolicy
from .config import Config
from .errors import ErrorKind, TbisError
from .model import PlannedSend, ResultStatus, SendOutcome
from .ratelimit import RateLimiter
from .reporter import Reporter
from .state import CheckpointStore
from .telegram.base import TelegramClient

Clock = Callable[[], float]
Sleeper = Callable[[float], None]
NowFn = Callable[[], datetime]
RNG = Callable[[], float]

_ABORT_FATAL = "fatal error: the run cannot continue"
_ABORT_KILL_SWITCH = ("kill-switch: failure rate over the configured window "
                      "exceeded the configured limit")
_ABORT_INTERRUPT = "interrupted by stop signal"

_FAILURE_STATUSES = frozenset(
    {ResultStatus.FAILED_TRANSIENT, ResultStatus.FAILED_PERMANENT, ResultStatus.FAILED_FATAL}
)


@dataclass
class RunResult:
    events: list[SendOutcome] = field(default_factory=list)
    abort_reason: str | None = None

    @property
    def aborted_fatal(self) -> bool:
        return self.abort_reason is not None


class RateLimitedExecutor:
    def __init__(
        self,
        *,
        client: TelegramClient,
        config: Config,
        checkpoint: CheckpointStore,
        reporter: Reporter,
        stop_event: threading.Event | None = None,
        clock: Clock = time.monotonic,
        sleeper: Sleeper = time.sleep,
        now_fn: NowFn = datetime.now,
        rng: RNG | None = None,
    ) -> None:
        self._client = client
        self._config = config
        self._checkpoint = checkpoint
        self._reporter = reporter
        self._stop = stop_event if stop_event is not None else threading.Event()
        self._clock = clock
        self._sleeper = sleeper
        self._now_fn = now_fn
        self._limiter = RateLimiter(config.limits, clock=clock)
        self._policy = RetryPolicy(
            max_attempts=config.send.max_attempts,
            base_seconds=config.send.backoff_base_seconds,
            max_seconds=config.send.backoff_max_seconds,
            rng=rng if rng is not None else random.random,
        )

    # -- public ------------------------------------------------------------

    def run(self, plan: list[PlannedSend], limit: int | None) -> RunResult:
        """Execute the plan; returns every outcome in completion order plus
        the abort reason (None when the plan ran to the end). Policy errors
        are recorded as outcomes; unexpected internal exceptions propagate
        after being recorded. Always leaves the checkpoint flushed."""
        result = RunResult()
        failure_window: deque[tuple[float, bool]] = deque()
        window_seconds = self._config.kill_switch.window_minutes * 60.0
        pending = deque(plan)
        inflight: dict[Future[SendOutcome], PlannedSend] = {}
        dispatched = 0

        max_workers = min(self._config.send.concurrency, max(1, len(plan)))
        unexpected: BaseException | None = None
        try:
            with ThreadPoolExecutor(max_workers=max_workers,
                                    thread_name_prefix="tbis-send") as pool:
                while pending or inflight:
                    if result.abort_reason is None and not self._stop.is_set():
                        while (pending and len(inflight) < max_workers
                               and result.abort_reason is None and not self._stop.is_set()):
                            item = pending.popleft()
                            gate = self._gate(item, dispatched, limit)
                            if gate is not None:
                                self._record(gate, result, failure_window, window_seconds)
                                continue
                            future = pool.submit(self._attempt, item)
                            inflight[future] = item
                            dispatched += 1
                    else:
                        status = self._remaining_status(result.abort_reason)
                        note = ("not dispatched: " + (result.abort_reason or _ABORT_INTERRUPT))
                        while pending:
                            self._record(
                                SendOutcome(plan=pending.popleft(), status=status, note=note),
                                result, failure_window, window_seconds,
                            )

                    if not inflight:
                        continue
                    done, _ = wait(set(inflight), return_when=FIRST_COMPLETED)
                    for future in done:
                        item = inflight.pop(future)
                        try:
                            outcome = future.result()
                        except TbisError:
                            raise
                        except Exception as exc:
                            # A bug, not a policy outcome: record it, abort
                            # the run, and propagate (no silent swallowing).
                            self._record(
                                SendOutcome(
                                    plan=item,
                                    status=ResultStatus.FAILED_PERMANENT,
                                    note=f"unexpected error, run aborted: "
                                    f"{type(exc).__name__}: {exc}",
                                ),
                                result, failure_window, window_seconds,
                            )
                            result.abort_reason = (
                                f"unexpected internal error: {type(exc).__name__}: {exc}"
                            )
                            unexpected = exc
                        else:
                            self._record(outcome, result, failure_window, window_seconds)
                            if outcome.status is ResultStatus.FAILED_FATAL:
                                result.abort_reason = _ABORT_FATAL
                            elif self._kill_switch_triggered(failure_window, window_seconds):
                                result.abort_reason = _ABORT_KILL_SWITCH
        finally:
            self._checkpoint.flush()
        if unexpected is not None:
            raise unexpected
        return result

    # -- gating ------------------------------------------------------------

    def _gate(self, item: PlannedSend, dispatched: int, limit: int | None) -> SendOutcome | None:
        """Pre-dispatch checks. Returns an outcome to record, or None to send."""
        if self._quiet_now():
            return SendOutcome(
                plan=item,
                status=ResultStatus.SKIPPED_QUIET_HOURS,
                note=f"quiet hours {self._config.limits.quiet_hours.start}-"
                f"{self._config.limits.quiet_hours.end} "
                f"({self._config.limits.quiet_hours.timezone})",
            )
        cap = self._config.limits.daily_cap_per_recipient
        if self._checkpoint.count_today(
            item.recipient.chat_id, now_utc=self._now_fn()
        ) >= cap:
            return SendOutcome(
                plan=item,
                status=ResultStatus.SKIPPED_DAILY_CAP,
                note=f"daily cap {cap} reached for {item.recipient.chat_id}",
            )
        if self._config.dedupe.across_runs and self._checkpoint.is_delivered(
            item.image.sha256, item.recipient.chat_id
        ):
            return SendOutcome(
                plan=item,
                status=ResultStatus.SKIPPED_DUPLICATE,
                note="already delivered in a previous run",
            )
        if limit is not None and dispatched >= limit:
            return SendOutcome(
                plan=item,
                status=ResultStatus.NOT_SENT_LIMIT,
                note=f"--limit {limit} reached",
            )
        return None

    def _quiet_now(self) -> bool:
        quiet = self._config.limits.quiet_hours
        if not quiet.enabled:
            return False
        local = self._now_fn().astimezone(ZoneInfo(quiet.timezone))
        minutes = local.hour * 60 + local.minute
        start = _parse_hhmm(quiet.start)
        end = _parse_hhmm(quiet.end)
        if start <= end:
            return start <= minutes < end
        return minutes >= start or minutes < end

    # -- sending -----------------------------------------------------------

    def _attempt(self, item: PlannedSend) -> SendOutcome:
        attempts = 0
        while True:
            if self._stop.is_set():
                return SendOutcome(
                    plan=item,
                    status=ResultStatus.NOT_SENT_INTERRUPTED,
                    attempts=attempts,
                    note="not sent: stop requested before this attempt",
                )
            pacing_wait = self._limiter.reserve(item.recipient.chat_id)
            if pacing_wait > 0 and not self._sleep_slices(pacing_wait):
                return SendOutcome(
                    plan=item,
                    status=ResultStatus.NOT_SENT_INTERRUPTED,
                    attempts=attempts,
                    note="not sent: stop requested while pacing",
                )
            attempts += 1
            started = self._clock()
            try:
                message = self._client.send_photo(
                    chat_id=item.recipient.chat_id,
                    photo_path=item.image.derivative_path or item.image.candidate.path,
                    caption=item.caption,
                    parse_mode=item.parse_mode,
                    filename=_upload_filename(item),
                )
            except TbisError as exc:
                latency_ms = int((self._clock() - started) * 1000)
                if exc.kind is ErrorKind.FATAL:
                    return SendOutcome(
                        plan=item,
                        status=ResultStatus.FAILED_FATAL,
                        attempts=attempts,
                        error_code=exc.api_error_code,
                        error_description=exc.api_description or exc.message,
                        error_kind=exc.kind.name,
                        latency_ms=latency_ms,
                        note="run aborted: " + exc.message,
                    )
                if exc.kind is ErrorKind.PERMANENT or attempts >= self._policy.max_attempts:
                    status = (ResultStatus.FAILED_PERMANENT
                              if exc.kind is ErrorKind.PERMANENT
                              else ResultStatus.FAILED_TRANSIENT)
                    return SendOutcome(
                        plan=item,
                        status=status,
                        attempts=attempts,
                        error_code=exc.api_error_code,
                        error_description=exc.api_description or exc.message,
                        error_kind=exc.kind.name,
                        latency_ms=latency_ms,
                        note=None if exc.kind is ErrorKind.PERMANENT
                        else f"exhausted {attempts} attempts",
                    )
                backoff = self._policy.delay_for(exc, attempts)
                if not self._sleep_slices(backoff):
                    return SendOutcome(
                        plan=item,
                        status=ResultStatus.NOT_SENT_INTERRUPTED,
                        attempts=attempts,
                        error_code=exc.api_error_code,
                        error_description=exc.api_description or exc.message,
                        error_kind=exc.kind.name,
                        note="not retried: stop requested during backoff",
                    )
            else:
                latency_ms = int((self._clock() - started) * 1000)
                return SendOutcome(
                    plan=item,
                    status=ResultStatus.SENT,
                    attempts=attempts,
                    telegram_message_id=message.message_id,
                    latency_ms=latency_ms,
                )

    # -- helpers -----------------------------------------------------------

    def _sleep_slices(self, seconds: float) -> bool:
        """Sleep in slices, checking the stop event. True = slept fully."""
        deadline = self._clock() + max(0.0, seconds)
        while True:
            remaining = deadline - self._clock()
            if remaining <= 0:
                return True
            if self._stop.is_set():
                return False
            self._sleeper(min(remaining, 0.1))

    def _record(
        self,
        outcome: SendOutcome,
        result: RunResult,
        failure_window: deque[tuple[float, bool]],
        window_seconds: float,
    ) -> None:
        result.events.append(outcome)
        self._reporter.log_event(outcome)
        if outcome.status is ResultStatus.SENT:
            self._checkpoint.record(
                outcome.plan.image.sha256,
                outcome.plan.recipient.chat_id,
                outcome.telegram_message_id or 0,
            )
            self._checkpoint.flush()
            failure_window.append((self._clock(), False))
        elif outcome.status in _FAILURE_STATUSES:
            # Only real send attempts enter the kill-switch window; skips
            # (duplicates, caps, quiet hours) are not sends.
            failure_window.append((self._clock(), True))
        _prune(failure_window, window_seconds, self._clock)

    def _kill_switch_triggered(
        self, failure_window: deque[tuple[float, bool]], window_seconds: float
    ) -> bool:
        _prune(failure_window, window_seconds, self._clock)
        sample = len(failure_window)
        if sample < self._config.kill_switch.min_sample:
            return False
        failures = sum(1 for _, failed in failure_window if failed)
        return failures / sample > self._config.kill_switch.failure_rate

    def _remaining_status(self, abort_reason: str | None) -> ResultStatus:
        if abort_reason is None:
            return ResultStatus.NOT_SENT_INTERRUPTED
        if abort_reason == _ABORT_KILL_SWITCH:
            return ResultStatus.NOT_SENT_KILL_SWITCH
        if abort_reason == _ABORT_FATAL:
            return ResultStatus.NOT_SENT_FATAL
        return ResultStatus.NOT_SENT_FATAL


def _prune(window: deque[tuple[float, bool]], window_seconds: float, clock: Clock) -> None:
    horizon = clock() - window_seconds
    while window and window[0][0] < horizon:
        window.popleft()


def _parse_hhmm(value: str) -> int:
    hours, minutes = value.split(":")
    return int(hours) * 60 + int(minutes)


def _upload_filename(item: PlannedSend) -> str:
    source = item.image.derivative_path or item.image.candidate.path
    name = source.replace("\\", "/").rsplit("/", 1)[-1]
    return name
