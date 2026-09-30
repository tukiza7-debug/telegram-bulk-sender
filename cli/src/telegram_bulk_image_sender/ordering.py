"""Deterministic natural ordering.

Natural sort comparison: runs of ASCII digits compare as integers, everything
else compares case-insensitively with a raw-string tiebreak, so the ordering
is stable and identical on any machine (spec 2.1: "img2 < img10").
"""

from __future__ import annotations

import re

_DIGIT_RUN = re.compile(r"(\d+)")


def natural_key(name: str) -> tuple[object, ...]:
    """Sort key implementing deterministic natural order.

    The key is a tuple so Python's lexicographic tuple comparison does the
    work: digit runs compare numerically, text runs casefolded, and the raw
    string is the final tiebreak (guarantees total order across machines).
    """
    parts: list[tuple[int, object, str, int]] = []
    for i, chunk in enumerate(_DIGIT_RUN.split(name)):
        if chunk == "":
            continue
        if chunk.isdigit():
            parts.append((0, int(chunk), "", i))
        else:
            parts.append((1, chunk.casefold(), chunk, i))
    # Raw name as the final element: "img02" vs "img2" compare numerically
    # equal, so the raw string guarantees a total, machine-independent order.
    return (*tuple(parts), name)
