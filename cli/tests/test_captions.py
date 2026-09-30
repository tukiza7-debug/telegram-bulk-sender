"""Caption templating and escaping with hostile inputs (100% coverage module)."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from telegram_bulk_image_sender.captions import (
    build_and_escape,
    check_template,
    escape_caption,
    render_caption,
    template_variables,
)
from telegram_bulk_image_sender.errors import ValidationError
from telegram_bulk_image_sender.model import ParseMode

NOW = datetime(2026, 9, 30, 12, 0, tzinfo=UTC)


def _render(template: str, **overrides: object) -> str:
    kwargs: dict[str, object] = {
        "filename": "img2.jpg",
        "index": 2,
        "total": 10,
        "custom": {"mood": "great & <exciting>"},
        "now": NOW,
    }
    kwargs.update(overrides)
    return render_caption(template, **kwargs)  # type: ignore[arg-type]


def test_builtin_variables() -> None:
    assert _render("{filename}") == "img2.jpg"
    assert _render("{stem}") == "img2"
    assert _render("{index}/{total}") == "2/10"
    assert _render("{date}") == "2026-09-30"


def test_custom_manifest_variable() -> None:
    assert _render("mood={mood}") == "mood=great & <exciting>"


def test_literal_braces() -> None:
    assert _render("{{not_a_var}} {index}") == "{not_a_var} 2"


def test_unknown_variable_raises_in_check() -> None:
    with pytest.raises(ValidationError) as excinfo:
        check_template("hello {usrname}", set(), "caption template")
    assert "usrname" in str(excinfo.value)
    assert "filename" in str(excinfo.value)  # lists the known set


def test_template_variables_extraction() -> None:
    assert template_variables("{a} {{b}} {c1_d}") == {"a", "c1_d"}


# -- escaping -----------------------------------------------------------------


def test_html_escapes_only_specials() -> None:
    assert escape_caption('a_b & <c> "quote"', ParseMode.HTML) == 'a_b &amp; &lt;c&gt; "quote"'


def test_markdownv2_escapes_the_documented_set() -> None:
    specials = "_*[]()~`>#+-=|{}.!"
    escaped = escape_caption(specials, ParseMode.MARKDOWN_V2)
    assert escaped == "".join(f"\\{ch}" for ch in specials)


def test_markdownv2_filename_with_underscores() -> None:
    assert escape_caption("new_year_2026.jpg", ParseMode.MARKDOWN_V2) == "new\\_year\\_2026\\.jpg"


def test_legacy_markdown_conservative() -> None:
    assert escape_caption("a_b*c`d[e", ParseMode.MARKDOWN) == "a\\_b\\*c\\`d\\[e"


def test_none_mode_passes_through() -> None:
    assert escape_caption("<b>&</b>", ParseMode.NONE) == "<b>&</b>"


def test_newlines_and_quotes_survive_all_modes() -> None:
    nasty = "line1\nline2 'single' \"double\" [brackets] (parens)"
    for mode in ParseMode:
        escaped = escape_caption(nasty, mode)
        if mode is ParseMode.HTML:
            # nothing to escape beyond nothing special: HTML specials absent,
            # so the text must pass through byte-identical.
            assert escaped == nasty
        if mode is ParseMode.MARKDOWN_V2:
            assert "\\[" in escaped and "\\(" in escaped


def test_substitution_happens_before_escaping() -> None:
    # A manifest value containing markup must render as literal text.
    out = build_and_escape(
        "{mood} photo",
        ParseMode.MARKDOWN_V2,
        filename="x.jpg",
        index=1,
        total=1,
        custom={"mood": "*bold* <img>"},
        now=NOW,
    )
    # '<' is not in the documented MarkdownV2 must-escape set; '>' is.
    assert out == "\\*bold\\* <img\\> photo"


def test_escaped_output_never_contains_raw_markup() -> None:
    nasty = (
        "_under_ *star* [br] (par) {cur} ~tilde~ `tick` >gt #hash +plus -dash =eq |pipe .dot !bang"
    )
    escaped = escape_caption(nasty, ParseMode.MARKDOWN_V2)
    for ch in "_*[]()~`>#+-=|{}.!":
        assert f"\\{ch}" in escaped
