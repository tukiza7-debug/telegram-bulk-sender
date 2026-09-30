"""Determinism: same input + config => identical queue and report
(modulo timestamps, message ids, run ids, latencies)."""

from __future__ import annotations

import json
from pathlib import Path

from conftest import make_jpeg
from telegram_bulk_image_sender import Config, FakeTelegramClient, RunRequest, run


def _config(tmp_path: Path, state_file: Path) -> Config:
    from telegram_bulk_image_sender.config import parse_config

    return parse_config(
        {
            "recipients": [{"name": "news", "chat_id": 1}, {"name": "log", "chat_id": 2}],
            "storage": {"state_file": str(state_file), "report_dir": str(tmp_path / "reports")},
            "send": {"concurrency": 1},
        }
    )


def _volatile(report: dict[str, object]) -> dict[str, object]:
    report = dict(report)
    report.pop("run_id", None)
    report.pop("started_at", None)
    report.pop("finished_at", None)
    config = report.get("config")
    if isinstance(config, dict):
        config = dict(config)
        storage = config.get("storage")
        if isinstance(storage, dict):
            storage = dict(storage)
            storage.pop("state_file", None)  # each run uses its own state file
            config["storage"] = storage
        report["config"] = config
    events = report.get("events")
    if isinstance(events, list):
        clean_events: list[object] = []
        for event in events:
            if isinstance(event, dict):
                event = dict(event)
                event.pop("telegram_message_id", None)
                event.pop("latency_ms", None)
                event.pop("run_id", None)  # modulo run ids, per spec
            clean_events.append(event)
        report["events"] = clean_events
    return report


def test_same_inputs_produce_identical_queue_and_report(tmp_path: Path) -> None:
    src = tmp_path / "imgs"
    src.mkdir()
    colors = [(i * 7 % 251, 13, 200) for i in range(6)]
    for i, color in enumerate(colors):
        make_jpeg(src / f"img{i + 1}.jpg", color=color)

    reports: list[dict[str, object]] = []
    orders: list[list[tuple[str, str]]] = []
    for run_index in range(2):
        state_file = tmp_path / f"state-{run_index}.json"
        config = _config(tmp_path, state_file)
        client = FakeTelegramClient()
        result = run(
            RunRequest(
                config=config, mode="folder", source_dir=str(src), recipients=("news", "log")
            ),
            env={},
            client_factory=lambda c, e, _cl=client: _cl,
            print_fn=lambda *_: None,
        )
        assert result.exit_code.value == 0
        orders.append(
            [
                (e.plan.recipient.name, Path(e.plan.image.candidate.path).name)
                for e in result.summary.events
            ]
        )
        report = json.loads(
            (Path(result.report_location) / "report.json").read_text(encoding="utf-8")
        )
        reports.append(_volatile(report))

    # queue order identical across runs
    assert orders[0] == orders[1]
    assert orders[0][0] == ("news", "img1.jpg") and orders[0][-1] == ("log", "img6.jpg")
    # machine report identical modulo volatile fields
    assert reports[0] == reports[1]
