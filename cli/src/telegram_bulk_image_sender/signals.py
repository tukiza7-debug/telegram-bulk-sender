"""Graceful shutdown on SIGINT/SIGTERM (spec 2.3).

The handler only sets an event and records the signal name: all real work
(finishing the in-flight send, flushing state, writing the partial report,
non-zero exit) belongs to the pipeline, which polls the event.
"""

from __future__ import annotations

import signal
import threading


class GracefulStop:
    def __init__(self) -> None:
        self.event = threading.Event()
        self.signal_name: str | None = None

    def install(self) -> bool:
        """Install handlers in the main thread. Returns False when signal
        handlers cannot be installed (e.g. non-main thread in library use),
        in which case the run simply stays uninterruptible by signals."""

        def handle(signum: int, frame: object) -> None:
            self.signal_name = signal.Signals(signum).name
            self.event.set()

        try:
            signal.signal(signal.SIGINT, handle)
            signal.signal(signal.SIGTERM, handle)
        except ValueError:
            # signal.signal works only in the main interpreter thread.
            return False
        return True
