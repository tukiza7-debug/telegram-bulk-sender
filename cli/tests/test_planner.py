"""Planner: queue construction, ordering, dedupe, captions per mode."""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from pathlib import Path

import pytest

from conftest import make_jpeg
from telegram_bulk_image_sender.config import Config, parse_config
from telegram_bulk_image_sender.model import (
    CaptionMode,
    ImageCandidate,
    ParseMode,
    Recipient,
    ValidatedImage,
)
from telegram_bulk_image_sender.planner import Planner
from telegram_bulk_image_sender.sources import ManifestRow
from telegram_bulk_image_sender.state import CheckpointStore
from telegram_bulk_image_sender.validation import validate_image

NEWS = Recipient(name="news", chat_id=1)
LOG = Recipient(name="log", chat_id="@chan")
FIXED_NOW = datetime(2026, 9, 30, 12, 0, tzinfo=UTC)


def _validated(paths: list[Path]) -> list[ValidatedImage]:
    out = []
    for p in paths:
        stat = p.stat()
        out.append(
            validate_image(
                ImageCandidate(path=str(p), mtime_ns=stat.st_mtime_ns, size=stat.st_size),
                Config().validation,
            )
        )
    return out


def _config(**sections: object) -> Config:
    return parse_config(sections)


def _planner(tmp_path: Path, config: Config, now: datetime | None = None) -> Planner:
    return Planner(
        config,
        CheckpointStore(str(tmp_path / "state.json")),
        now=now if now is not None else FIXED_NOW,
    )


def test_folder_mode_cross_product_in_natural_order(tmp_path: Path) -> None:
    imgs = [
        make_jpeg(tmp_path / "img1.jpg", color=(1, 0, 0)),
        make_jpeg(tmp_path / "img2.jpg", color=(2, 0, 0)),
        make_jpeg(tmp_path / "img10.jpg", color=(3, 0, 0)),
    ]
    config = _config(
        recipients=[{"name": "news", "chat_id": 1}, {"name": "log", "chat_id": "@chan"}]
    )
    build = _planner(tmp_path, config).build(
        images=_validated(imgs),
        recipients=[NEWS, LOG],
        rows=None,
        caption_mode=CaptionMode.NONE,
        caption_template="",
        caption_column="caption",
    )
    assert [i.image.candidate.path for i in build.plan] == [
        str(imgs[0]),
        str(imgs[1]),
        str(imgs[2]),
        str(imgs[0]),
        str(imgs[1]),
        str(imgs[2]),
    ]
    assert [i.recipient.name for i in build.plan] == ["news", "news", "news", "log", "log", "log"]
    assert all(i.total_for_recipient == 3 for i in build.plan)
    assert [i.index_for_recipient for i in build.plan] == [1, 2, 3, 1, 2, 3]
    assert build.estimated_api_calls == 7  # 6 sends + getMe


def test_caption_per_image_with_index_and_escaping(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "my_file.jpg", color=(1, 1, 1))
    config = _config(
        recipients=[{"name": "news", "chat_id": 1}], telegram={"parse_mode": "markdownv2"}
    )
    build = _planner(tmp_path, config).build(
        images=_validated([img]),
        recipients=[NEWS],
        rows=None,
        caption_mode=CaptionMode.PER_IMAGE,
        caption_template="Shot {index}/{total} {filename}",
        caption_column="caption",
    )
    assert build.plan[0].caption == "Shot 1/1 my\\_file\\.jpg"
    assert build.plan[0].parse_mode is ParseMode.MARKDOWN_V2


def test_within_run_duplicate_skipped(tmp_path: Path) -> None:
    img_a = make_jpeg(tmp_path / "a.jpg", color=(7, 7, 7))
    img_b = tmp_path / "b.jpg"
    img_b.write_bytes(img_a.read_bytes())  # identical content, different name
    config = _config(recipients=[{"name": "news", "chat_id": 1}])
    build = _planner(tmp_path, config).build(
        images=_validated([img_a, img_b]),
        recipients=[NEWS],
        rows=None,
        caption_mode=CaptionMode.NONE,
        caption_template="",
        caption_column="caption",
    )
    assert len(build.plan) == 1
    assert len(build.skipped) == 1
    assert build.skipped[0].status.value == "skipped-duplicate"
    assert build.skipped[0].note == Planner.NOTE_DUP_WITHIN


def test_across_run_duplicate_from_checkpoint(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg", color=(8, 8, 8))
    checkpoint = CheckpointStore(str(tmp_path / "s.json"))
    checkpoint.load()
    validated = _validated([img])[0]
    checkpoint.record(validated.sha256, 1, 999)
    config = _config(recipients=[{"name": "news", "chat_id": 1}])
    build = Planner(config, checkpoint).build(
        images=[validated],
        recipients=[NEWS],
        rows=None,
        caption_mode=CaptionMode.NONE,
        caption_template="",
        caption_column="caption",
    )
    assert build.plan == []
    assert build.skipped[0].note == Planner.NOTE_DUP_ACROSS


def test_dedupe_can_be_disabled(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg", color=(8, 8, 8))
    checkpoint = CheckpointStore(str(tmp_path / "s.json"))
    checkpoint.load()
    validated = _validated([img])[0]
    checkpoint.record(validated.sha256, 1, 999)
    config = _config(recipients=[{"name": "news", "chat_id": 1}], dedupe={"across_runs": False})
    build = Planner(config, checkpoint).build(
        images=[validated],
        recipients=[NEWS],
        rows=None,
        caption_mode=CaptionMode.NONE,
        caption_template="",
        caption_column="caption",
    )
    assert len(build.plan) == 1


def test_manifest_mode_preserves_rows_and_resolves_recipients(tmp_path: Path) -> None:
    a = make_jpeg(tmp_path / "a.jpg", color=(1, 1, 1))
    b = make_jpeg(tmp_path / "b.jpg", color=(2, 2, 2))
    config = _config(recipients=[{"name": "news", "chat_id": 1}, {"name": "log", "chat_id": 2}])
    rows = [
        ManifestRow(
            row_number=1,
            file_value="b.jpg",
            resolved_path=str(b),
            recipient_ref="news",
            caption=None,
            custom={},
        ),
        ManifestRow(
            row_number=2,
            file_value="a.jpg",
            resolved_path=str(a),
            recipient_ref="2",
            caption="From column",
            custom={},
        ),
    ]
    build = _planner(tmp_path, config).build(
        images=_validated([a, b]),
        recipients=[NEWS, Recipient(name="log", chat_id=2)],
        rows=rows,
        caption_mode=CaptionMode.MANIFEST_COLUMN,
        caption_template="",
        caption_column="caption",
    )
    assert [p.image.candidate.path for p in build.plan] == [str(b), str(a)]
    assert [p.recipient.name for p in build.plan] == ["news", "log"]
    assert build.plan[0].caption is None
    assert build.plan[1].caption == "From column"
    assert build.plan[1].manifest_row == 2


def test_per_run_caption_is_constant(tmp_path: Path) -> None:
    imgs = [
        make_jpeg(tmp_path / "a.jpg", color=(1, 1, 1)),
        make_jpeg(tmp_path / "b.jpg", color=(2, 2, 2)),
    ]
    config = _config(recipients=[{"name": "news", "chat_id": 1}])
    build = _planner(tmp_path, config).build(
        images=_validated(imgs),
        recipients=[NEWS],
        rows=None,
        caption_mode=CaptionMode.PER_RUN,
        caption_template="Daily drop {date}",
        caption_column="caption",
    )
    assert [p.caption for p in build.plan] == ["Daily drop 2026-09-30"] * 2


def test_none_mode_sends_without_caption(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg", color=(3, 3, 3))
    config = _config(recipients=[{"name": "news", "chat_id": 1}])
    build = _planner(tmp_path, config).build(
        images=_validated([img]),
        recipients=[NEWS],
        rows=None,
        caption_mode=CaptionMode.NONE,
        caption_template="ignored",
        caption_column="caption",
    )
    assert build.plan[0].caption is None


def test_sha256_matches_hashlib(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg")
    validated = _validated([img])[0]
    assert validated.sha256 == hashlib.sha256(img.read_bytes()).hexdigest()


def test_unknown_template_variable_fails_in_planner(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "a.jpg", color=(4, 4, 4))
    config = _config(recipients=[{"name": "news", "chat_id": 1}])
    with pytest.raises(Exception, match="usrname"):
        _planner(tmp_path, config).build(
            images=_validated([img]),
            recipients=[NEWS],
            rows=None,
            caption_mode=CaptionMode.PER_IMAGE,
            caption_template="hi {usrname}",
            caption_column="caption",
        )
