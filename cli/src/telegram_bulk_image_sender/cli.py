"""Command-line interface: three subcommands, one common flag set.

Exit codes (documented in README.md and asserted by tests):
  0 all sent | 2 partial failure | 3 fatal | 4 validation error
Usage errors are validation errors of the operator's input -> exit 4 (the
argparse default of 2 would collide with partial-failure).
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from typing import NoReturn

from .config import load_config
from .errors import ConfigError, ExitCode, SecretError, TbisError, ValidationError
from .model import CaptionMode, OrderKey
from .runner import RunRequest, run
from .signals import GracefulStop

_VERSION = "2.0.0"

USAGE_EPILOG = """\
exit codes:
  0  every planned send succeeded (or dry run completed)
  2  partial failure (some sends failed or the run was interrupted/limited)
  3  fatal (bad token, kill-switch, broken state, config error)
  4  validation error (bad files, bad manifest, unknown recipients, usage)

Compliance: only send to recipients who explicitly opted in. You are
responsible for complying with Telegram's Terms of Service and applicable
anti-spam/privacy law.
"""


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:  # exit 4, not argparse's 2
        raise ValidationError([f"usage: {message}"])


def _add_common_flags(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--config", metavar="PATH", help="config file (.yaml/.yml or .toml); defaults to built-ins"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the full plan (file -> recipient -> caption -> estimated "
        "API calls) and exit without any network call",
    )
    parser.add_argument(
        "--recipient",
        action="append",
        default=[],
        metavar="NAME",
        help="allowlist recipient name or chat_id; repeatable",
    )
    parser.add_argument(
        "--caption",
        metavar="TEXT",
        help="caption template for per-image/per-run modes; "
        "variables: {filename} {stem} {index} {total} {date} + "
        "custom manifest columns; use {{ and }} for literal braces",
    )
    parser.add_argument(
        "--caption-mode",
        choices=[m.value for m in CaptionMode],
        help="none | per-image | per-run | manifest-column (default: from config, per-image)",
    )
    parser.add_argument(
        "--limit", type=int, metavar="N", help="cap the number of sends dispatched this run"
    )
    parser.add_argument(
        "--state-file",
        metavar="PATH",
        help="checkpoint file for resume/dedupe (default from config)",
    )
    parser.add_argument(
        "--report-dir", metavar="PATH", help="directory for run reports (default from config)"
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        metavar="N",
        help="max parallel sends (default 1; manifest mode forces 1)",
    )
    parser.add_argument(
        "--max-attempts",
        type=int,
        metavar="N",
        help="retry budget for transient failures (default 4)",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        metavar="S",
        help="per-request network timeout (default 60)",
    )
    parser.add_argument(
        "--resize-if-over-limit",
        action="store_true",
        help="send a resized derivative when a file exceeds the configured "
        "image limits; the original stays untouched",
    )
    parser.add_argument(
        "--normalize-exif",
        action="store_true",
        help="normalise EXIF orientation via a derivative file",
    )
    parser.add_argument(
        "--api-base-url",
        metavar="URL",
        help="Bot API base URL (default https://api.telegram.org); "
        "point at a self-hosted/local Bot API server for testing",
    )
    parser.add_argument("--version", action="version", version=f"tbis {_VERSION}")


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(
        prog="tbis",
        description="Bulk-send images to allowlisted Telegram chats via the Bot API. "
        "Start with --dry-run; see docs/SMOKE.md for the test checklist.",
        epilog=USAGE_EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--version", action="version", version=f"tbis {_VERSION}")
    sub = parser.add_subparsers(dest="mode", required=True)

    folder = sub.add_parser(
        "folder",
        help="scan a directory and send its images to one or more recipients",
        description="Folder mode: deterministic queue of the images found in --source-dir "
        "(natural order by default), sent to every --recipient.",
    )
    folder.add_argument(
        "--source-dir",
        required=True,
        metavar="DIR",
        help="directory to scan for jpg/jpeg/png/webp images",
    )
    folder.add_argument(
        "--no-recursive",
        dest="recursive",
        action="store_false",
        help="do not recurse into subdirectories (default: recursive)",
    )
    # Sentinel default so config.defaults.recursive applies unless the flag
    # is passed explicitly on the CLI.
    folder.set_defaults(recursive=None)
    folder.add_argument(
        "--include",
        action="append",
        default=[],
        metavar="GLOB",
        help="only files matching this glob (repeatable, e.g. --include 'holiday-*.jpg')",
    )
    folder.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="GLOB",
        help="skip files matching this glob (repeatable)",
    )
    folder.add_argument(
        "--order",
        choices=[o.value for o in OrderKey],
        help="name (natural) | mtime | manifest-row (default: name)",
    )
    folder.add_argument("--reverse", action="store_true", help="reverse the chosen order")
    _add_common_flags(folder)

    manifest = sub.add_parser(
        "manifest",
        help="send images strictly sequentially, driven by a CSV/JSON manifest",
        description="One-by-one mode: manifest order is preserved, concurrency is forced "
        "to 1, and the run is resumable via the checkpoint file.",
    )
    manifest.add_argument(
        "--manifest",
        required=True,
        metavar="PATH",
        help="CSV or JSON manifest with 'file' and 'recipient' columns; "
        "optional 'caption' column; other columns become template "
        "variables",
    )
    manifest.add_argument(
        "--order", choices=[o.value for o in OrderKey], help="manifest-row (default) | name | mtime"
    )
    manifest.add_argument("--reverse", action="store_true", help="reverse the chosen order")
    _add_common_flags(manifest)

    single = sub.add_parser(
        "single",
        help="send exactly one image (useful for testing a setup)",
        description="Single mode: one file to one or more explicitly allowlisted recipients.",
    )
    single.add_argument(
        "--file", required=True, metavar="PATH", help="path to one jpg/jpeg/png/webp image"
    )
    _add_common_flags(single)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    stop = GracefulStop()
    stop.install()
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        config = load_config(args.config)

        caption_mode = CaptionMode(args.caption_mode) if args.caption_mode else None
        order = OrderKey(args.order) if getattr(args, "order", None) else None
        request = RunRequest(
            config=config,
            mode=args.mode,
            source_dir=getattr(args, "source_dir", None),
            manifest_path=getattr(args, "manifest", None),
            single_file=getattr(args, "file", None),
            recipients=tuple(args.recipient),
            caption_mode=caption_mode,
            caption_text=args.caption,
            order=order,
            reverse=getattr(args, "reverse", None) or None,
            recursive=getattr(args, "recursive", None),
            include=tuple(getattr(args, "include", []) or ()),
            exclude=tuple(getattr(args, "exclude", []) or ()),
            limit=args.limit,
            dry_run=args.dry_run,
            state_file=args.state_file,
            report_dir=args.report_dir,
            stop_event=stop.event,
            max_attempts=args.max_attempts,
            concurrency=args.concurrency,
            timeout_seconds=args.timeout_seconds,
            api_base_url=args.api_base_url,
            resize_if_over_limit=True if args.resize_if_over_limit else None,
            normalize_exif=True if args.normalize_exif else None,
        )
        result = run(request, print_fn=print)
        print(result.human_summary)
        return int(result.exit_code)
    except (ValidationError, ConfigError, SecretError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return int(
            ExitCode.VALIDATION_ERROR if isinstance(exc, ValidationError) else ExitCode.FATAL
        )
    except TbisError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return int(ExitCode.FATAL)
    except KeyboardInterrupt:
        # Double Ctrl-C: the graceful path is in signals.GracefulStop.
        print("error: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
