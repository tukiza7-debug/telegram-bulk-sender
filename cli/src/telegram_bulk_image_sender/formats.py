"""Image format detection by magic bytes (single source of truth).

Used by the validator (reject non-images) and by the HTTP client (choose
the multipart Content-Type). Extension checks elsewhere compare against
these results; nobody re-implements the byte signatures.
"""

from __future__ import annotations

JPEG = "jpeg"
PNG = "png"
WEBP = "webp"

_MAGIC_JPEG = b"\xff\xd8\xff"
_MAGIC_PNG = b"\x89PNG\r\n\x1a\n"


def sniff_format(path: str) -> str | None:
    """Return "jpeg" | "png" | "webp" from the file's first 12 bytes, else None."""
    with open(path, "rb") as fh:
        head = fh.read(12)
    return sniff_bytes(head)


def sniff_bytes(head: bytes) -> str | None:
    if head.startswith(_MAGIC_JPEG):
        return JPEG
    if head.startswith(_MAGIC_PNG):
        return PNG
    if head.startswith(b"RIFF") and head[8:12] == b"WEBP":
        return WEBP
    return None
