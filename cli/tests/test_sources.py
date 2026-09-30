"""Manifest sources: schema, row-accurate errors, ordering, custom columns."""

from __future__ import annotations

from pathlib import Path

import pytest

from conftest import make_jpeg
from telegram_bulk_image_sender.errors import ValidationError
from telegram_bulk_image_sender.model import OrderKey
from telegram_bulk_image_sender.sources import read_manifest


def test_csv_manifest_round_trip(tmp_path: Path) -> None:
    a = make_jpeg(tmp_path / "a.jpg")
    b = make_jpeg(tmp_path / "b.jpg")
    manifest = tmp_path / "m.csv"
    manifest.write_text(
        f"file,recipient,caption,campaign\n{a.name},news,First,launch\n{b.name},42,,launch\n",
        encoding="utf-8",
    )
    rows = read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=False)
    assert [r.row_number for r in rows] == [2, 3]
    assert rows[0].recipient_ref == "news"
    assert rows[0].caption == "First"
    assert rows[0].custom == {"campaign": "launch"}
    assert rows[1].caption is None
    assert rows[1].recipient_ref == "42"
    assert rows[0].resolved_path == str(a)


def test_relative_paths_resolve_against_manifest_dir(tmp_path: Path) -> None:
    (tmp_path / "sub").mkdir()
    make_jpeg(tmp_path / "sub" / "x.jpg")
    manifest = tmp_path / "m.csv"
    manifest.write_text("file,recipient\nsub/x.jpg,news\n", encoding="utf-8")
    rows = read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=False)
    assert rows[0].resolved_path == str(tmp_path / "sub" / "x.jpg")


def test_json_manifest(tmp_path: Path) -> None:
    a = make_jpeg(tmp_path / "a.jpg")
    manifest = tmp_path / "m.json"
    manifest.write_text(
        f'[{{"file": "{a.name}", "recipient": "news", "topic": "cats"}}]',
        encoding="utf-8",
    )
    rows = read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=False)
    assert rows[0].custom == {"topic": "cats"}


def test_missing_required_columns(tmp_path: Path) -> None:
    manifest = tmp_path / "m.csv"
    manifest.write_text("file,who\na.jpg,news\n", encoding="utf-8")
    with pytest.raises(ValidationError, match="missing required column\\(s\\): recipient"):
        read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=False)


def test_missing_file_and_bad_extension_reported_with_rows(tmp_path: Path) -> None:
    good = make_jpeg(tmp_path / "good.jpg")
    (tmp_path / "notes.txt").write_text("not an image", encoding="utf-8")
    manifest = tmp_path / "m.csv"
    manifest.write_text(
        f"file,recipient\n{good.name},news\nghost.jpg,news\nnotes.txt,news\n",
        encoding="utf-8",
    )
    with pytest.raises(ValidationError) as excinfo:
        read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=False)
    text = str(excinfo.value)
    assert "row 3" in text and "ghost.jpg" in text
    assert "row 4" in text and "unsupported file type .txt" in text


def test_manifest_row_order_preserved_and_reversible(tmp_path: Path) -> None:
    z = make_jpeg(tmp_path / "z.jpg", color=(1, 1, 1))
    a = make_jpeg(tmp_path / "a.jpg", color=(2, 2, 2))
    manifest = tmp_path / "m.csv"
    manifest.write_text(
        f"file,recipient\n{z.name},news\n{a.name},news\n",
        encoding="utf-8",
    )
    rows = read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=False)
    assert [Path(r.resolved_path).name for r in rows] == ["z.jpg", "a.jpg"]
    rows = read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=True)
    assert [Path(r.resolved_path).name for r in rows] == ["a.jpg", "z.jpg"]


def test_name_ordering_overrides_manifest_order(tmp_path: Path) -> None:
    z = make_jpeg(tmp_path / "z.jpg", color=(1, 1, 1))
    a = make_jpeg(tmp_path / "a.jpg", color=(2, 2, 2))
    manifest = tmp_path / "m.csv"
    manifest.write_text(
        f"file,recipient\n{z.name},news\n{a.name},news\n",
        encoding="utf-8",
    )
    rows = read_manifest(str(manifest), order=OrderKey.NAME, reverse=False)
    assert [Path(r.resolved_path).name for r in rows] == ["a.jpg", "z.jpg"]


def test_bad_json_manifest(tmp_path: Path) -> None:
    manifest = tmp_path / "m.json"
    manifest.write_text("[{broken", encoding="utf-8")
    with pytest.raises(ValidationError, match="not valid JSON"):
        read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=False)


def test_unsupported_manifest_type(tmp_path: Path) -> None:
    manifest = tmp_path / "m.xlsx"
    manifest.write_text("nope", encoding="utf-8")
    with pytest.raises(ValidationError, match=r"manifest must be \.csv or \.json"):
        read_manifest(str(manifest), order=OrderKey.MANIFEST_ROW, reverse=False)
