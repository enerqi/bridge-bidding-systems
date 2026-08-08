"""Suit glyphs must be text glyphs wrapped in bml's colour classes.

The panel app wrote `♥️` / `♦️` with the U+FE0F variation selector, which asks for *emoji*
presentation: those two were drawn by the colour emoji font while `♠` and `♣` stayed text glyphs
and inherited the element's colour -- a white spade on the dark card. An emoji glyph also ignores
`color`, so no stylesheet can give the four suits four colours while VS16 is present.
"""

from __future__ import annotations

import re

import palette
import pytest
from markupsafe import Markup

import corpus
import render
import state

VS16 = "️"


@pytest.fixture(scope="module")
def session():
    return state.new_session(corpus.DEFAULT_VARIANT)


def test_glyphs_have_no_variation_selector():
    for glyph in render.SUIT_CLASSES:
        assert VS16 not in glyph


def test_emoji_text_auction_emits_plain_glyphs():
    out = render.emoji_text_auction("1H --> 2S --> 3D --> 4C")
    assert VS16 not in out
    for glyph in "♥♠♦♣":
        assert glyph in out


def test_suits_wraps_each_glyph_in_the_bml_class():
    out = render.suits("1♠ 2♥ 3♦ 4♣")
    assert isinstance(out, Markup)
    assert '<span class="scolor">♠</span>' in out
    assert '<span class="hcolor">♥</span>' in out
    assert '<span class="dcolor">♦</span>' in out
    assert '<span class="ccolor">♣</span>' in out


def test_suits_escapes_its_input():
    out = render.suits("<b>1♠</b>")
    assert "<b>" not in out
    assert "&lt;b&gt;" in out
    assert '<span class="scolor">♠</span>' in out  # the spans it adds are still markup


CSS = (render.TEMPLATE_DIR.parent / "static" / "app.css").read_text(encoding="utf-8")


def css_var(name: str, scope: str | None = None) -> str:
    """The value of a custom property in the light palette, or the dark one when asked.

    Both sides are one `light-dark()` declaration now -- the app has a manual theme toggle, and a
    `prefers-color-scheme` block cannot be overridden by one. See `palette.py`.
    """
    value = palette.token("app.css", name, dark=scope == "dark")
    assert re.fullmatch(r"#[0-9a-fA-F]{3,8}", value), (
        f"{name} is not a hex colour in the {scope or 'light'} palette: {value}"
    )
    return value


def _channel(value: int) -> float:
    c = value / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(colour: str) -> float:
    h = colour.lstrip("#")
    r, g, b = (int(h[i : i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b)


def contrast(first: str, second: str) -> float:
    a, b = luminance(first), luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)


def test_class_names_still_match_bml():
    """The class NAMES are bml's, so `bml2html`'s markup and this app's CSS agree.

    The VALUES deliberately diverge -- see the contrast test below.
    """
    assert render.SUIT_CLASSES == {"♣": "ccolor", "♦": "dcolor", "♥": "hcolor", "♠": "scolor"}
    for cls in render.SUIT_CLASSES.values():
        assert re.search(rf"\.{cls}\s*\{{[^}}]*color:\s*var\(--suit-", CSS), cls
    # text presentation is forced, or `color` would be ignored on hearts and diamonds
    assert "font-variant-emoji: text" in CSS


@pytest.mark.parametrize("suit", ["club", "diamond", "heart", "spade"])
@pytest.mark.parametrize("scope", [None, "dark"])
def test_suit_colour_contrast_passes_aa(suit, scope):
    """4.5:1 is AA for normal text, and the filter status line renders these small.

    Both palettes are checked. bml's own values fail on a near-white face (MediumSeaGreen 2.6:1,
    Orange 1.9:1, Red 3.9:1), and on a *dark* face the darkened light-mode values fail in the other
    direction -- black is 1.37:1, an invisible spade -- which is why the dark block re-picks all four
    rather than reusing them.
    """
    ratio = contrast(css_var(f"--suit-{suit}", scope), css_var("--face", scope))
    assert ratio >= 4.5, f"--suit-{suit} is {ratio:.2f}:1 on --face ({scope or 'light'})"


def test_the_dark_spade_is_not_black():
    """The one suit that cannot survive the switch: near-white, as four-colour decks do in dark."""
    assert contrast(css_var("--suit-spade", "dark"), css_var("--face", "dark")) > 10
    assert css_var("--suit-spade", "dark") != css_var("--suit-spade")


def test_dark_ink_reads_on_the_dark_face():
    assert contrast(css_var("--ink", "dark"), css_var("--face", "dark")) >= 7


def test_suits_remain_distinguishable_from_each_other():
    """Darkening must not collapse the four into one muddy family."""
    colours = {suit: css_var(f"--suit-{suit}") for suit in ("club", "diamond", "heart", "spade")}
    assert len(set(colours.values())) == 4


def test_rendered_quiz_has_no_bare_suit_glyphs(session):
    """Every glyph reaching the page must be inside a coloured span."""
    body = render.quiz_body(session)
    stripped = re.sub(r'<span class="[cdhs]color">[♠♥♦♣]</span>', "", body)
    assert not re.search(r"[♠♥♦♣]", stripped), stripped


def test_toast_answer_text_is_coloured():
    import engine

    toast = engine.Toast("warning", "Answer: 1♠ ‣ 2♥", 4.2)
    out = render.toast(toast)
    assert '<span class="scolor">♠</span>' in out
    assert '<span class="hcolor">♥</span>' in out


def test_font_signal_is_declared_and_mirrored(session):
    assert render.local_ui_signals()["_font"] == "notes"
    body = render.shell(session)
    assert 'data-attr:data-font="$_font"' in body
    assert 'data-bind="_font"' in body  # value form: the name starts with an underscore
