"""End-to-end runs through runner.run() with the in-memory client.

Covers: full folder run + resume idempotence, limit + resume, mixed
success/failure exit code, manifest mode ordering, single mode.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from conftest import make_jpeg, make_png
from telegram_bulk_image_sender import (
    Config,
    ExitCode,
    FakeTelegramClient,
    RunRequest,
    run,
)
from telegram_bulk_image_sender.errors import (
    AuthError,
    PermanentSendError,
    ValidationError,
)
from telegram_bulk_image_sender.model import CaptionMode
from telegram_bulk_image_sender.runner import ClientFactory
from telegram_bulk_image_sender.telegram.base import SentMessage


def _request(config: Config, **kwargs: Any) -> RunRequest:
    kwargs.setdefault("mode", "folder")
    return RunRequest(config=config, **kwargs)


def _config(tmp_path: Path, **sections: object) -> Config:
    from telegram_bulk_image_sender.config import parse_config

    sections.setdefault("recipients", [{"name": "news", "chat_id": 1}])
    sections.setdefault(
        "storage",
        {
            "state_file": str(tmp_path / "state" / "cp.json"),
            "report_dir": str(tmp_path / "reports"),
        },
    )
    return parse_config(sections)


def _images_dir(tmp_path: Path) -> Path:
    """Dedicated scan directory: state/ and reports/ live outside it so a
    second run's directory scan never sees the first run's artifacts."""
    src = tmp_path / "imgs"
    src.mkdir(exist_ok=True)
    return src


def _factory(client: FakeTelegramClient) -> ClientFactory:
    return lambda config, env: client


def test_full_folder_run_delivers_each_pair_once(tmp_path: Path) -> None:
    src = _images_dir(tmp_path)
    imgs = [
        make_jpeg(src / "img1.jpg", color=(1, 0, 0)),
        make_png(src / "img2.png", color=(2, 0, 0)),
        make_jpeg(src / "img10.jpg", color=(3, 0, 0)),
    ]
    config = _config(tmp_path, defaults={"recipients": ["news"]})
    client = FakeTelegramClient()
    result = run(
        _request(config, source_dir=_src_dir(tmp_path, imgs), recipients=("news",)),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert result.exit_code is ExitCode.OK
    assert result.summary.sent == 3
    # natural order: img1, img2, img10
    names = [Path(c.photo_path).name for c in client.calls]
    assert names == ["img1.jpg", "img2.png", "img10.jpg"]
    # checkpoint written to the configured path
    assert (tmp_path / "state" / "cp.json").exists()
    # report files exist and are consistent
    report_dir = Path(result.report_location)
    assert (report_dir / "report.json").exists()
    assert (report_dir / "report.csv").exists()
    assert (report_dir / "log.jsonl").exists()


def _src_dir(tmp_path: Path, imgs: list[Path]) -> str:
    return str(imgs[0].parent)


def test_rerun_is_idempotent_nothing_resent(tmp_path: Path) -> None:
    src = _images_dir(tmp_path)
    imgs = [make_jpeg(src / "a.jpg", color=(9, 0, 0)), make_jpeg(src / "b.jpg", color=(0, 9, 0))]
    config = _config(tmp_path)
    client = FakeTelegramClient()
    kwargs: dict[str, object] = {
        "mode": "folder",
        "source_dir": _src_dir(tmp_path, imgs),
        "recipients": ("news",),
    }
    first = run(
        _request(config, **kwargs),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert first.exit_code is ExitCode.OK
    second = run(
        _request(config, **kwargs),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert second.exit_code is ExitCode.OK
    assert second.summary.sent == 0
    assert second.summary.skipped_duplicate == 2
    assert len(client.calls) == 2  # only the first run's sends


def test_limit_then_resume_completes_without_duplicates(tmp_path: Path) -> None:
    src = _images_dir(tmp_path)
    imgs = [
        make_jpeg(src / "a.jpg", color=(1, 1, 0)),
        make_jpeg(src / "b.jpg", color=(0, 1, 1)),
        make_jpeg(src / "c.jpg", color=(1, 0, 1)),
    ]
    config = _config(tmp_path)
    client = FakeTelegramClient()
    kwargs: dict[str, object] = {
        "mode": "folder",
        "source_dir": _src_dir(tmp_path, imgs),
        "recipients": ("news",),
        "limit": 1,
    }
    first = run(
        _request(config, **kwargs),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert first.exit_code is ExitCode.PARTIAL_FAILURE  # 1 sent, 2 not-sent-limit
    assert first.summary.not_sent_limit == 2
    second = run(
        _request(config, mode="folder", source_dir=_src_dir(tmp_path, imgs), recipients=("news",)),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert second.exit_code is ExitCode.OK
    assert second.summary.sent == 2
    assert len(client.calls) == 3  # 1 + 2, nothing resent


def test_mixed_failure_is_partial_exit(tmp_path: Path) -> None:
    src = _images_dir(tmp_path)
    imgs = [make_jpeg(src / "ok.jpg", color=(2, 2, 2)), make_jpeg(src / "bad.jpg", color=(3, 3, 3))]
    config = _config(tmp_path)
    client = FakeTelegramClient()
    original = client.send_photo

    def fail_on_bad(**kwargs: Any) -> SentMessage:
        if "bad.jpg" in str(kwargs.get("photo_path")):
            raise PermanentSendError(
                "chat not found",
                http_status=404,
                api_error_code=404,
                api_description="chat not found",
            )
        return original(**kwargs)

    # Intentional runtime replacement of the fake's method (test seam).
    client.send_photo = fail_on_bad  # type: ignore[method-assign]
    result = run(
        _request(config, source_dir=_src_dir(tmp_path, imgs), recipients=("news",)),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert result.exit_code is ExitCode.PARTIAL_FAILURE
    assert result.summary.sent == 1
    assert result.summary.failed_permanent == 1


def test_manifest_mode_is_strictly_sequential(tmp_path: Path) -> None:
    a = make_jpeg(tmp_path / "a.jpg", color=(1, 2, 3))
    b = make_jpeg(tmp_path / "b.jpg", color=(4, 5, 6))
    manifest = tmp_path / "m.csv"
    manifest.write_text(
        f"file,recipient\n{b.name},news\n{a.name},news\n",
        encoding="utf-8",
    )
    config = _config(tmp_path, send={"concurrency": 4})
    client = FakeTelegramClient()
    result = run(
        _request(config, mode="manifest", manifest_path=str(manifest)),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert result.exit_code is ExitCode.OK
    # manifest order preserved even though concurrency 4 was requested
    assert [Path(c.photo_path).name for c in client.calls] == ["b.jpg", "a.jpg"]


def test_single_mode_sends_one_image(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "only.jpg", color=(7, 7, 7))
    config = _config(tmp_path)
    client = FakeTelegramClient()
    result = run(
        _request(config, mode="single", single_file=str(img), recipients=("news",)),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert result.exit_code is ExitCode.OK
    assert len(client.calls) == 1


def test_dry_run_needs_no_client_and_makes_no_calls(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg", color=(8, 8, 8))
    config = _config(tmp_path)
    client = FakeTelegramClient()
    lines: list[str] = []
    result = run(
        _request(config, mode="single", single_file=str(img), recipients=("news",), dry_run=True),
        env={},
        client_factory=_factory(client),
        print_fn=lines.append,
    )
    assert result.exit_code is ExitCode.OK
    assert client.calls == [] and client.get_me_calls == 0
    assert any("DRY RUN" in line for line in lines)
    assert any("a.jpg" in line for line in lines)


def test_preflight_401_aborts_before_any_send(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg", color=(8, 8, 8))
    config = _config(tmp_path)
    client = FakeTelegramClient()
    client.fail_get_me = AuthError("Unauthorized", http_status=401)
    with pytest.raises(AuthError):
        run(
            _request(config, mode="single", single_file=str(img), recipients=("news",)),
            env={},
            client_factory=_factory(client),
            print_fn=lambda *_: None,
        )
    assert client.calls == []


def test_unknown_recipient_is_validation_error(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg", color=(8, 8, 8))
    config = _config(tmp_path)
    with pytest.raises(ValidationError, match="not in the allowlist"):
        client = FakeTelegramClient()
        run(
            _request(config, mode="single", single_file=str(img), recipients=("ghost",)),
            env={},
            client_factory=_factory(client),
            print_fn=lambda *_: None,
        )


def test_caption_mode_none_omits_caption(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg", color=(8, 8, 8))
    config = _config(tmp_path)
    client = FakeTelegramClient()
    run(
        _request(
            config,
            mode="single",
            single_file=str(img),
            recipients=("news",),
            caption_mode=CaptionMode.NONE,
        ),
        env={},
        client_factory=_factory(client),
        print_fn=lambda *_: None,
    )
    assert client.calls[0].caption is None
