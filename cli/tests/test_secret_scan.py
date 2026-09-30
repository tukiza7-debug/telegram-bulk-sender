"""Secret scanning: the repo must never contain a bot token or key material."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "secret_scan.py"
REPO_ROOT = SCRIPT.parents[2]


def _run_scan(target: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(target)],
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_repo_tree_is_clean_of_secrets() -> None:
    result = _run_scan(REPO_ROOT / "cli")
    assert result.returncode == 0, result.stdout + result.stderr


def test_planted_token_is_detected(tmp_path: Path) -> None:
    # Synthetic token-shaped string; never a real credential.
    (tmp_path / "leak.yaml").write_text(
        "token: 9876543210:AAAAQQQsyntheticSecretValue0123456789abcd\n",
        encoding="utf-8",
    )
    result = _run_scan(tmp_path)
    assert result.returncode != 0
    assert "leak.yaml" in result.stdout


def test_planted_generic_secret_is_detected(tmp_path: Path) -> None:
    (tmp_path / "creds.txt").write_text(
        "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n", encoding="utf-8"
    )
    result = _run_scan(tmp_path)
    assert result.returncode != 0


def test_fake_test_tokens_do_not_trip_scanner(tmp_path: Path) -> None:
    (tmp_path / "fixture.py").write_text(
        'TOKEN = "123456789:TESTTOKEN_notarealtoken"\n', encoding="utf-8"
    )
    result = _run_scan(tmp_path)
    assert result.returncode == 0
