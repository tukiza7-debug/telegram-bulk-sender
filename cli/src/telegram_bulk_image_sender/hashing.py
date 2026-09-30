"""Streaming SHA-256 hashing.

Images can be up to 10 MB (Telegram sendPhoto limit) but the pipeline never
loads a whole file into memory: hashing reads fixed-size chunks. Perf-sanity
requirement (spec 7.6): bounded memory even for a 1,000-file run.
"""

from __future__ import annotations

import hashlib

# 1 MiB chunks: small enough for bounded memory, large enough to keep syscall
# overhead negligible. Exported for tests, which assert chunked reading.
CHUNK_SIZE = 1024 * 1024


def sha256_of_file(path: str) -> str:
    """Return the hex SHA-256 of a file, reading it in CHUNK_SIZE chunks."""
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()
