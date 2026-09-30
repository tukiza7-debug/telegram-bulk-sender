"""Caption templating and parse-mode escaping.

Substitution happens FIRST (raw values), escaping happens LAST on the final
string, so manifest data can never inject markup (unit-tested with hostile
inputs: underscores, brackets, quotes, newlines).

Template variables: {filename}, {stem}, {index}, {total}, {date} and any
custom manifest column. Unknown variables are a validation error, not a
silent pass-through. Telegram literals "{{" and "}}" escape braces.

Escaping rules are quoted verbatim from https://core.telegram.org/bots/api
(section "Formatting options", fetched 2026-09-30):
  - MarkdownV2: "In all other places characters '_', '*', '[', ']', '(',
    ')', '~', '`', '>', '#', '+', '-', '=', '|', '{', '}', '.', '!' must be
    escaped with the preceding character '\'." Also: "Any character with
    code between 1 and 126 inclusively can be escaped anywhere with a
    preceding '\' character."
  - Legacy Markdown (parse_mode "Markdown"): no official per-character
    escaping table is documented -> UNVERIFIED. To stay safe the CLI escapes
    the characters that carry markup meaning ('_', '*', '`', '[') with a
    backslash, which the legacy parser treats as literal (same convention
    MarkdownV2 documents). Captions needing exact legacy behaviour can use
    parse_mode "none".
  - HTML: only &, <, > are special.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Mapping

from .errors import ValidationError
from .model import ParseMode

_TEMPLATE_VAR = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")

_BUILTIN_VARS = ("filename", "stem", "index", "total", "date")

_MARKDOWNV2_SPECIALS = set("_*[]()~`>#+-=|{}.!")  # verbatim list from the docs
_LEGACY_MARKDOWN_SPECIALS = set("_*`[")

_HTML_ESCAPE = {"&": "&amp;", "<": "&lt;", ">": "&gt;"}


def template_variables(template: str) -> set[str]:
    """Variable names referenced by a template (excluding {{ }} literals)."""
    without_literals = template.replace("{{", "").replace("}}", "")
    return set(_TEMPLATE_VAR.findall(without_literals))


def check_template(template: str, known_custom: set[str], where: str) -> None:
    """Fail with a key-accurate error when a template uses unknown variables."""
    known = set(_BUILTIN_VARS) | known_custom
    unknown = sorted(template_variables(template) - known)
    if unknown:
        raise ValidationError(
            [f"{where}: unknown template variable(s) {', '.join(unknown)}; "
             f"known: {', '.join(sorted(known))}"]
        )


def render_caption(
    template: str,
    *,
    filename: str,
    index: int,
    total: int,
    custom: Mapping[str, str] | None = None,
    now: datetime | None = None,
) -> str:
    """Substitute template variables. Values are inserted raw; callers escape
    afterwards via escape_caption()."""
    current = now if now is not None else datetime.now(timezone.utc)
    values: dict[str, str] = {
        "filename": filename,
        "stem": filename.rsplit(".", 1)[0] if "." in filename else filename,
        "index": str(index),
        "total": str(total),
        "date": current.date().isoformat(),
    }
    if custom:
        values.update({k: str(v) for k, v in custom.items()})

    def _sub(match: re.Match[str]) -> str:
        return values[match.group(1)]

    rendered = _TEMPLATE_VAR.sub(_sub, template.replace("{{", "\x00").replace("}}", "\x01"))
    return rendered.replace("\x00", "{").replace("\x01", "}")


def escape_caption(text: str, parse_mode: ParseMode) -> str:
    """Escape a final caption string for the given parse mode."""
    if parse_mode is ParseMode.NONE:
        return text
    if parse_mode is ParseMode.HTML:
        return "".join(_HTML_ESCAPE.get(ch, ch) for ch in text)
    if parse_mode is ParseMode.MARKDOWN_V2:
        return "".join(f"\\{ch}" if ch in _MARKDOWNV2_SPECIALS else ch for ch in text)
    # Legacy Markdown; see module docstring: UNVERIFIED per-character table,
    # conservative backslash escaping of markup-meaning characters.
    return "".join(f"\\{ch}" if ch in _LEGACY_MARKDOWN_SPECIALS else ch for ch in text)


def build_and_escape(
    template: str,
    parse_mode: ParseMode,
    *,
    filename: str,
    index: int,
    total: int,
    custom: Mapping[str, str] | None = None,
    now: datetime | None = None,
) -> str:
    """Render then escape in the only correct order (substitute -> escape)."""
    raw = render_caption(template, filename=filename, index=index, total=total,
                         custom=custom, now=now)
    return escape_caption(raw, parse_mode)
