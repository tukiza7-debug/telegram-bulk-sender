"""CLI surface: exit codes, usage errors, version, and the README contract
that documents exactly what the parser implements (both directions)."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from telegram_bulk_image_sender.cli import build_parser, main
from telegram_bulk_image_sender.errors import ExitCode

README = Path(__file__).resolve().parents[1] / "README.md"


def _subparsers(parser: argparse.ArgumentParser) -> dict[str, argparse.ArgumentParser]:
    action = next(a for a in parser._actions if isinstance(a, argparse._SubParsersAction))
    choices: dict[str, argparse.ArgumentParser] = action.choices
    return choices


def _all_help(parser: argparse.ArgumentParser) -> str:
    parts = [parser.format_help()]
    parts.extend(sub.format_help() for sub in _subparsers(parser).values())
    return "\n".join(parts)


def test_usage_error_exits_4_not_2(capsys: object) -> None:
    # argparse's default exit code 2 would collide with partial failure.
    assert main(["folder", "--no-such-flag"]) == ExitCode.VALIDATION_ERROR


def test_missing_required_argument_exits_4(capsys: object) -> None:
    assert main(["folder"]) == ExitCode.VALIDATION_ERROR


def test_missing_file_is_validation_error(capsys: object) -> None:
    assert (
        main(["single", "--file", "/nonexistent/x.jpg", "--recipient", "news"])
        == ExitCode.VALIDATION_ERROR
    )


def test_bad_source_dir_is_validation_error(capsys: object) -> None:
    assert (
        main(["folder", "--source-dir", "/nonexistent/dir", "--recipient", "news"])
        == ExitCode.VALIDATION_ERROR
    )


def test_missing_token_exits_fatal_3(tmp_path: Path, capsys: object) -> None:
    from conftest import make_jpeg

    img = make_jpeg(tmp_path / "a.jpg")
    config = tmp_path / "cfg.yaml"
    config.write_text("recipients:\n  - name: news\n    chat_id: 1\n", encoding="utf-8")
    # The allowlist passes validation, then the missing token is fatal.
    assert (
        main(["single", "--file", str(img), "--recipient", "news", "--config", str(config)])
        == ExitCode.FATAL
    )


def test_version_flag(capsys: object) -> None:
    try:
        main(["--version"])
    except SystemExit as exc:
        assert exc.code == 0
    out = capsys.readouterr().out  # type: ignore[attr-defined]
    assert "tbis 2." in out


# -- README contract (anti-slop rule 10) ---------------------------------------


def _cli_reference_text() -> str:
    full = README.read_text(encoding="utf-8")
    match = re.search(r"^## CLI reference$(.*?)(?=^## )", full, re.M | re.S)
    assert match is not None, "README must contain a '## CLI reference' section"
    return match.group(1)


def _readme_flags() -> set[str]:
    """Flags documented in the CLI reference section (the contract area)."""
    return set(re.findall(r"(--[a-z][a-z0-9-]*)", _cli_reference_text()))


def test_every_readme_flag_exists_in_the_parser() -> None:
    parser = build_parser()
    help_text = _all_help(parser)
    unknown = sorted(f for f in _readme_flags() if f not in help_text)
    assert unknown == [], f"README documents flags the parser lacks: {unknown}"


def test_every_parser_option_is_documented() -> None:
    parser = build_parser()
    help_text = _all_help(parser)
    documented = _readme_flags()
    parser_flags = set(re.findall(r"(--[a-z][a-z0-9-]*)", help_text))
    # --version is documented separately in the README; allow both spellings
    # of negated flags to map to their documented form.
    missing = sorted(parser_flags - documented)
    assert missing == [], f"parser has flags the README does not document: {missing}"


def test_readme_exit_codes_match_the_enum() -> None:
    text = README.read_text(encoding="utf-8")
    claimed = {int(code) for code, _ in re.findall(r"^\|\s*(\d)\s*\|\s*(.+?)\s*\|", text, re.M)}
    assert claimed == {int(c) for c in ExitCode}
