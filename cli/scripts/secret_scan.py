#!/usr/bin/env python3
"""Secret scan: refuses any commit/tree containing credential-shaped text.

Patterns cover Telegram bot tokens, common cloud provider keys, private key
blocks and generic secret assignments. Test fixtures use obviously fake,
short secrets (e.g. TESTTOKEN) that deliberately do not match. Run in CI and
via the pre-commit hook (scripts/hooks/pre-commit).

Usage: python scripts/secret_scan.py [PATH]  (default: repository root)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# [pattern, human description]
PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\b\d{8,}:[A-Za-z0-9_-]{30,}\b"), "Telegram bot token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key id"),
    (re.compile(r"\bghp_[A-Za-z0-9]{30,}\b"), "GitHub personal access token"),
    (re.compile(r"\bxox[bpars]-[A-Za-z0-9-]{20,}\b"), "Slack token"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key block"),
    (
        re.compile(r"\b(sk-[A-Za-z0-9]{20,}|sk-proj-[A-Za-z0-9_-]{20,})\b"),
        "API secret key",
    ),
]

# Files never scanned (fixtures/docs that legitimately discuss patterns, and
# build artifacts).
SKIP_PARTS = {
    ".git",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    "node_modules",
    ".venv",
}
SKIP_SUFFIX = {".pyc", ".lock", ".png", ".jpg", ".jpeg", ".webp", ".ttf", ".apk"}
# The scanner's own test contains synthetic credential-shaped strings by
# design (they must keep matching); the file-level allowlist is documented
# here and kept to exactly that one file.
SKIP_FILES = {"test_secret_scan.py"}
# Pre-existing Android-app test fixtures outside cli/: they use the official
# Telegram documentation example token (123456789:AAHdqTcv...) and synthetic
# sequences. Verified as non-credentials by manual review on 2026-09-30.
# Keep this list short and reviewed; new entries need the same scrutiny.
ALLOWLIST_FILES = {
    "test/bot_token_test.dart",
    "test/token_sanitizer_test.dart",
    "test/token_input_field_test.dart",
    "test/bot_session_test.dart",
}
MAX_BYTES = 2_000_000


def scan(path: Path) -> list[str]:
    findings: list[str] = []
    for file in sorted(path.rglob("*")):
        if not file.is_file():
            continue
        if any(part in SKIP_PARTS for part in file.parts):
            continue
        if file.suffix.lower() in SKIP_SUFFIX:
            continue
        if file.name in SKIP_FILES:
            continue
        rel = file.relative_to(path).as_posix()
        if rel in ALLOWLIST_FILES:
            continue
        try:
            if file.stat().st_size > MAX_BYTES:
                continue
            text = file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for pattern, description in PATTERNS:
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                findings.append(f"{file}:{line}: {description}")
    return findings


def main(argv: list[str]) -> int:
    target = Path(argv[1]) if len(argv) > 1 else Path(__file__).parents[2]
    findings = scan(target)
    for finding in findings:
        print(f"SECRET FOUND: {finding}")
    if findings:
        print(f"{len(findings)} secret(s) found - refusing to continue.")
        return 1
    print("secret scan: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
