"""Directory discovery and deterministic ordering (Folder mode source).

Supported formats: jpg, jpeg, png, webp. Unsupported files are surfaced to
the caller as rejections with a reason (spec 2.1: "rejected at validation
with a clear reason, not skipped silently") — this module only flags them;
collecting them into a ValidationError is the validator's job.
"""

from __future__ import annotations

import fnmatch
import os
from pathlib import Path

from .model import ImageCandidate, OrderKey
from .ordering import natural_key

IMAGE_EXTENSIONS: frozenset[str] = frozenset({".jpg", ".jpeg", ".png", ".webp"})


def scan_directory(
    source_dir: str,
    *,
    recursive: bool,
    include: tuple[str, ...],
    exclude: tuple[str, ...],
) -> tuple[list[ImageCandidate], list[tuple[str, str]]]:
    """Scan source_dir for image candidates.

    Returns (candidates, rejections) where rejections are (path, reason)
    pairs for files present in the tree that are not supported images.
    Directories and hidden files are never candidates.
    """
    root = Path(source_dir)
    candidates: list[ImageCandidate] = []
    rejections: list[tuple[str, str]] = []
    if not root.is_dir():
        raise NotADirectoryError(source_dir)

    iterator = root.rglob("*") if recursive else root.glob("*")
    for entry in sorted(iterator, key=lambda p: natural_key(p.name)):
        if entry.is_dir() or not entry.is_file():
            continue
        rel = entry.relative_to(root).as_posix()
        if _matches_any(rel, exclude):
            continue
        if include and not _matches_any(rel, include):
            continue
        suffix = entry.suffix.lower()
        if suffix not in IMAGE_EXTENSIONS:
            rejections.append((rel, f"unsupported file type {suffix or '(none)'}"))
            continue
        stat = entry.stat()
        if stat.st_size == 0:
            rejections.append((rel, "zero-byte file"))
            continue
        candidates.append(
            ImageCandidate(path=str(entry), mtime_ns=stat.st_mtime_ns, size=stat.st_size)
        )
    return candidates, rejections


def _matches_any(rel_path: str, patterns: tuple[str, ...]) -> bool:
    """Glob match against both the relative path and the bare filename."""
    name = os.path.basename(rel_path)
    return any(fnmatch.fnmatch(rel_path, pat) or fnmatch.fnmatch(name, pat) for pat in patterns)


def order_candidates(
    candidates: list[ImageCandidate],
    order: OrderKey,
    reverse: bool,
) -> list[ImageCandidate]:
    """Order candidates deterministically. manifest-row order is handled by
    the manifest source itself (rows arrive pre-ordered)."""
    if order is OrderKey.MTIME:
        # mtime_ns then natural name: identical timestamps stay deterministic.
        ordered = sorted(candidates, key=lambda c: (c.mtime_ns, natural_key(Path(c.path).name)))
    else:
        ordered = sorted(candidates, key=lambda c: natural_key(Path(c.path).name))
    if reverse:
        ordered.reverse()
    return ordered
