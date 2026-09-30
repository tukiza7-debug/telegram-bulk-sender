"""Deterministic natural ordering.

Natural sort comparison: runs of ASCII digits compare as integers (zero-
padded to a fixed width inside the key), text chunks compare casefolded,
and the raw name is appended as the final tiebreak. The key is a plain
string, so ordering is a lexicographic comparison: stable and identical on
any machine (spec 2.1: "img2 < img10").
"""

from __future__ import annotations

import re

_DIGIT_RUN = re.compile(r"(\d+)")

# Digit runs longer than this are pathological for filenames; zfill keeps
# numeric and lexicographic order identical up to this width.
_DIGIT_WIDTH = 16
_SEP = "\x00"


def natural_key(name: str) -> str:
    """Return the natural-order sort key for a filename as a string."""
    chunks = [c for c in _DIGIT_RUN.split(name) if c != ""]
    normalized = _SEP.join(
        chunk.zfill(_DIGIT_WIDTH) if chunk.isdigit() else chunk.casefold() for chunk in chunks
    )
    # Raw name as the tiebreak: "img02" and "img2" compare numerically
    # equal, so the raw string guarantees a total, machine-independent order.
    return f"{normalized}{_SEP}{_SEP}{name}"
