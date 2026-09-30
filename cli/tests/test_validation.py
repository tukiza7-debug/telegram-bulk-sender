"""Validation: magic bytes, truncation, size/dimension limits, derivatives."""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from conftest import make_jpeg, make_png
from telegram_bulk_image_sender.config import ValidationConfig
from telegram_bulk_image_sender.formats import sniff_format
from telegram_bulk_image_sender.model import ImageCandidate
from telegram_bulk_image_sender.validation import (
    ImageRejected,
    build_derivative,
    validate_image,
)


def _candidate(path: Path) -> ImageCandidate:
    stat = path.stat()
    return ImageCandidate(path=str(path), mtime_ns=stat.st_mtime_ns, size=stat.st_size)


def test_magic_bytes_detect_real_formats(tmp_path: Path) -> None:
    jpeg = make_jpeg(tmp_path / "a.jpg")
    png = make_png(tmp_path / "b.png")
    assert sniff_format(str(jpeg)) == "jpeg"
    assert sniff_format(str(png)) == "png"


def test_text_file_with_image_extension_rejected(tmp_path: Path) -> None:
    fake = tmp_path / "c.jpg"
    fake.write_text("this is definitely not an image", encoding="utf-8")
    with pytest.raises(ImageRejected, match="magic bytes check"):
        validate_image(_candidate(fake), ValidationConfig())


def test_extension_content_mismatch_rejected(tmp_path: Path) -> None:
    png_named_jpg = tmp_path / "d.jpg"
    make_png(png_named_jpg)
    with pytest.raises(ImageRejected, match="extension says JPEG but content is png"):
        validate_image(_candidate(png_named_jpg), ValidationConfig())


def test_zero_byte_rejected(tmp_path: Path) -> None:
    empty = tmp_path / "e.jpg"
    empty.touch()
    with pytest.raises(ImageRejected, match="magic bytes"):
        validate_image(_candidate(empty), ValidationConfig())


def test_truncated_png_rejected(tmp_path: Path) -> None:
    full = make_png(tmp_path / "f.png")
    data = full.read_bytes()
    truncated = tmp_path / "g.png"
    truncated.write_bytes(data[: len(data) // 2])
    with pytest.raises(ImageRejected, match="truncated"):
        validate_image(_candidate(truncated), ValidationConfig())


def test_truncated_jpeg_rejected_by_missing_eoi(tmp_path: Path) -> None:
    full = make_jpeg(tmp_path / "h.jpg")
    data = full.read_bytes()
    truncated = tmp_path / "i.jpg"
    truncated.write_bytes(data[:-2])  # strip the FF D9 EOI marker
    with pytest.raises(ImageRejected, match="truncated JPEG"):
        validate_image(_candidate(truncated), ValidationConfig())


def test_oversize_file_rejected_before_reading(tmp_path: Path) -> None:
    img = make_jpeg(tmp_path / "j.jpg")
    config = ValidationConfig(max_file_mb=0.000001)
    with pytest.raises(ImageRejected, match="over the configured limit"):
        validate_image(_candidate(img), config)


def test_dimension_sum_limit(tmp_path: Path) -> None:
    big = make_jpeg(tmp_path / "k.jpg", size=(1000, 9501))
    with pytest.raises(ImageRejected, match="dimensions 1000x9501"):
        validate_image(_candidate(big), ValidationConfig(max_total_dimension=10000))


def test_dimension_check_can_be_disabled(tmp_path: Path) -> None:
    big = make_jpeg(tmp_path / "l.jpg", size=(1000, 9501))
    validated = validate_image(
        _candidate(big), ValidationConfig(verify_dimensions=False, max_total_dimension=10000)
    )
    assert (validated.width, validated.height) == (1000, 9501)


def test_aspect_ratio_limit(tmp_path: Path) -> None:
    tall = make_jpeg(tmp_path / "m.jpg", size=(100, 3000))
    with pytest.raises(ImageRejected, match="aspect ratio"):
        validate_image(_candidate(tall), ValidationConfig(max_total_dimension=100000))


def test_exif_orientation_is_reported(tmp_path: Path) -> None:
    path = tmp_path / "n.jpg"
    img = Image.new("RGB", (10, 10), (1, 2, 3))
    exif = img.getexif()
    exif[274] = 6  # Orientation: rotate 90
    img.save(path, format="JPEG", exif=exif)
    validated = validate_image(_candidate(path), ValidationConfig())
    assert validated.exif_orientation == 6


def test_resize_derivative_scales_down_and_keeps_original(
    tmp_path: Path,
) -> None:
    original = make_jpeg(tmp_path / "o.jpg", size=(2000, 2000), color=(9, 9, 9))
    validated = validate_image(_candidate(original), ValidationConfig())
    derivative = build_derivative(
        validated, ValidationConfig(max_total_dimension=1000, resize_if_over_limit=True)
    )
    assert derivative.derivative_path is not None
    assert derivative.derivative_path != str(original)
    assert original.read_bytes() == Path(str(original)).read_bytes()  # untouched
    with Image.open(derivative.derivative_path) as img:
        w, h = img.size
    assert w + h <= 1000
    assert "resized 2000x2000" in (derivative.derivative_note or "")


def test_derivative_not_built_when_not_needed(tmp_path: Path) -> None:
    small = make_jpeg(tmp_path / "p.jpg", size=(50, 50))
    validated = validate_image(_candidate(small), ValidationConfig())
    same = build_derivative(validated, ValidationConfig())
    assert same is validated


def test_missing_file_rejected(tmp_path: Path) -> None:
    ghost = tmp_path / "q.jpg"
    ghost.write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 50)
    ghost.unlink()
    candidate = ImageCandidate(path=str(ghost), mtime_ns=0, size=52)
    with pytest.raises(ImageRejected, match="disappeared"):
        validate_image(candidate, ValidationConfig())
