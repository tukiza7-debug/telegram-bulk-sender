"""Image validation: real-format checks by magic bytes, size limits,
optional dimension checks, optional EXIF orientation normalisation and
optional resized derivatives. Everything happens BEFORE the queue; failures
are collected and reported, never skipped silently.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError

from .config import ValidationConfig
from .formats import JPEG, PNG, WEBP, sniff_format
from .hashing import sha256_of_file
from .model import ImageCandidate, ValidatedImage

# Official sendPhoto limits; source: https://core.telegram.org/bots/api#sendphoto
# (fetched 2026-09-30): "The photo must be at most 10 MB in size. The photo's
# width and height must not exceed 10000 in total. Width and height ratio must
# be at most 20."
MAX_DIMENSION_SUM = 10000
MAX_ASPECT_RATIO = 20


class ImageRejected(Exception):
    """Raised per-file with a concrete, user-facing reason."""

    def __init__(self, path: str, reason: str) -> None:
        super().__init__(f"{path}: {reason}")
        self.path = path
        self.reason = reason


def validate_image(candidate: ImageCandidate, config: ValidationConfig) -> ValidatedImage:
    """Validate one candidate fully; raise ImageRejected on any failure."""
    path = candidate.path
    if not os.path.exists(path):
        raise ImageRejected(path, "file disappeared between scan and validation")
    if not os.access(path, os.R_OK):
        raise ImageRejected(path, "file is not readable (permission denied)")

    size_mb = candidate.size / (1024 * 1024)
    if size_mb > config.max_file_mb:
        raise ImageRejected(
            path, f"file is {size_mb:.2f} MB, over the configured limit of {config.max_file_mb} MB"
        )

    actual_format = sniff_format(path)
    if actual_format is None:
        raise ImageRejected(path, "content is not a JPEG/PNG/WebP image (magic bytes check)")
    declared_suffix = Path(path).suffix.lower()
    if declared_suffix in (".jpg", ".jpeg") and actual_format != JPEG:
        raise ImageRejected(path, f"extension says JPEG but content is {actual_format}")
    if declared_suffix == ".png" and actual_format != PNG:
        raise ImageRejected(path, f"extension says PNG but content is {actual_format}")
    if declared_suffix == ".webp" and actual_format != WEBP:
        raise ImageRejected(path, f"extension says WebP but content is {actual_format}")

    if actual_format == JPEG:
        # Pillow's verify() accepts JPEGs truncated at the tail; the EOI
        # marker (FF D9) must be the final two bytes of a well-formed file.
        with open(path, "rb") as fh:
            fh.seek(-2, os.SEEK_END)
            if fh.read(2) != b"\xff\xd9":
                raise ImageRejected(path, "truncated JPEG: missing end-of-image marker")

    width: int | None = None
    height: int | None = None
    exif_orientation: int | None = None
    truncated_reason = _check_integrity(path)
    if truncated_reason is not None:
        raise ImageRejected(path, truncated_reason)

    with Image.open(path) as img:
        width, height = img.size
        orientation = img.getexif().get(274)  # 274 = EXIF Orientation tag
        exif_orientation = int(orientation) if orientation else None

    if config.verify_dimensions:
        total = width + height
        if total > config.max_total_dimension:
            raise ImageRejected(
                path,
                f"dimensions {width}x{height} sum to {total}, over the limit "
                f"{config.max_total_dimension}",
            )
        if width > 0 and height > 0:
            ratio = max(width, height) / min(width, height)
            if ratio > MAX_ASPECT_RATIO:
                raise ImageRejected(
                    path, f"aspect ratio {ratio:.1f} exceeds the maximum of {MAX_ASPECT_RATIO}"
                )

    return ValidatedImage(
        candidate=candidate,
        sha256=sha256_of_file(path),
        format=actual_format,
        width=width,
        height=height,
        exif_orientation=exif_orientation,
    )


def _check_integrity(path: str) -> str | None:
    """Detect truncated files. Returns a reason string, or None when intact."""
    try:
        with Image.open(path) as img:
            img.verify()  # verifies structure; cheap, no full decode
    except (UnidentifiedImageError, OSError, SyntaxError) as exc:
        return f"truncated or corrupt image ({type(exc).__name__}: {exc})"
    return None


def build_derivative(image: ValidatedImage, config: ValidationConfig) -> ValidatedImage:
    """Create a resized/EXIF-normalised derivative in a temp directory.

    The original file is never modified. Only called when
    validation.resize_if_over_limit or validation.normalize_exif is on and
    the original actually needs it. Callers must keep the returned
    derivative_path alive (the runner owns the temp dir lifecycle).
    """
    needs_resize = image.width is not None and image.height is not None and (
        image.width + image.height > config.max_total_dimension
    )
    needs_exif = config.normalize_exif and image.exif_orientation not in (None, 1)
    if not needs_resize and not needs_exif:
        return image

    tmp_dir = tempfile.mkdtemp(prefix="tbis-derivative-")
    src = image.candidate.path
    stem = Path(src).stem
    out_path = os.path.join(tmp_dir, f"{stem}.jpg")
    notes: list[str] = []
    with Image.open(src) as img:
        work = ImageOps.exif_transpose(img) if needs_exif else img
        if needs_resize:
            # Long edge target: fit the sum constraint while keeping ratio.
            w, h = work.size
            scale = min(1.0, MAX_DIMENSION_SUM / (w + h))
            new_size = (max(1, int(w * scale)), max(1, int(h * scale)))
            work = work.resize(new_size, Image.Resampling.LANCZOS)
            notes.append(f"resized {w}x{h} -> {new_size[0]}x{new_size[1]}")
        if needs_exif:
            notes.append("EXIF orientation normalised")
        # Derivatives are JPEG: universal support, no alpha surprises after
        # resize of palette/RGBA sources.
        work.convert("RGB").save(out_path, format="JPEG", quality=88)
    new_size_bytes = os.path.getsize(out_path)
    new_mb = new_size_bytes / (1024 * 1024)
    if new_mb > config.max_file_mb:
        raise ImageRejected(
            src, f"resized derivative is still {new_mb:.2f} MB, over {config.max_file_mb} MB"
        )
    return ValidatedImage(
        candidate=image.candidate,
        sha256=sha256_of_file(out_path),
        format=JPEG,
        width=None,
        height=None,
        exif_orientation=1,
        derivative_path=out_path,
        derivative_note="; ".join(notes),
    )
