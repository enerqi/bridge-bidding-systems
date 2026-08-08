"""The surface ladder: the answer cards must be distinguishable from what they sit on.

They were not. Measured, the face was **1.03:1** against the quiz card behind it, and the quiz card
1.08:1 against the page — three surfaces inside the top 8% of the luminance range, so the cards read
as flat paint rather than as things you press.

The reason it could not be fixed by choosing a better card colour is worth keeping, because it is the
kind of constraint that gets "helpfully" undone later:

* `--face` is **pinned by the domain**. The four suit colours are contrast-tested against it
  (`test_suit_colours.py`, all >=4.9:1); darkening the face pushes clubs and diamonds under AA.
* Contrast up in the near-whites is gamma-compressed, so a *fill* has to fall to ~#dde7e2 before it
  reaches even 1.23:1 — by which point it is no longer white paper.

So the ladder is `page -> card -> well (recessed) -> face`, and the cards carry a **3:1 border** of
their own, which is what WCAG 1.4.11 asks for a non-text UI boundary and the only separation that
survives a cheap monitor, sunlight, or a colour-vision difference. These tests pin both halves, in
both palettes, in all three stylesheets.
"""

from __future__ import annotations

import re
from pathlib import Path

import palette
import pytest

import render

STATIC = Path(render.__file__).resolve().parent / "static"
SHEETS = ("app.css", "app-pico.css", "app-bulma.css")

# A visible surface step. Not a standards number -- there isn't one for "these are two surfaces" --
# but below about 1.15:1 the boundary stops being perceptible on ordinary hardware, which is exactly
# the bug this file exists to prevent coming back.
MIN_SURFACE_STEP = 1.15
# WCAG 2.2 SC 1.4.11 Non-text Contrast: the visual boundary of a control.
MIN_BOUNDARY = 3.0


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


def tokens(sheet: str, *, dark: bool) -> dict[str, str]:
    """The hex custom properties of one palette.

    A palette used to be a REGION of the file: everything before the `prefers-color-scheme` block or
    everything after it. Both sides now live in `light-dark()` pairs on the same declaration, because
    the app has a manual theme toggle and a media query cannot be overridden by one. So a palette is
    one side of every pair, and `palette.py` resolves it.
    """
    return palette.hex_tokens(sheet, dark=dark)


@pytest.mark.parametrize("sheet", SHEETS)
@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
def test_the_card_boundary_meets_non_text_contrast(sheet, dark):
    """The half that does not depend on telling two near-identical fills apart."""
    palette = tokens(sheet, dark=dark)
    for name in ("--card-edge", "--face"):
        assert name in palette, f"{sheet}: {name} missing from the {'dark' if dark else 'light'} palette"
    ratio = contrast(palette["--card-edge"], palette["--face"])
    assert ratio >= MIN_BOUNDARY, f"{sheet}: card edge is {ratio:.2f}:1 on the face"


@pytest.mark.parametrize("sheet", SHEETS)
@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
def test_the_cards_sit_in_a_well_they_are_distinguishable_from(sheet, dark):
    palette = tokens(sheet, dark=dark)
    assert "--well" in palette, f"{sheet}: no --well in the {'dark' if dark else 'light'} palette"
    ratio = contrast(palette["--face"], palette["--well"])
    assert ratio >= MIN_SURFACE_STEP, f"{sheet}: face is only {ratio:.2f}:1 on the well behind it"


@pytest.mark.parametrize("sheet", SHEETS)
def test_the_well_and_the_edge_are_actually_used(sheet):
    """Tokens that nothing references are decoration, and this bug was invisible for weeks."""
    css = (STATIC / sheet).read_text(encoding="utf-8")
    candidates = re.search(r"^\.candidates\s*\{([^}]*)\}", css, re.MULTILINE)
    assert candidates, f"{sheet}: no .candidates rule"
    assert "var(--well)" in candidates.group(1), f"{sheet}: the choice group is not a well"
    assert "inset" in candidates.group(1), f"{sheet}: the well needs an inset shadow to read as recessed"
    # the border lives on `.candidate` (hand-rolled, Pico) or `.candidate.button` (Bulma)
    card = re.search(r"^\.candidate(?:\.button)?\s*\{([^}]*)\}", css, re.MULTILINE)
    assert card, f"{sheet}: no .candidate rule"
    assert "var(--card-edge)" in card.group(1), f"{sheet}: the cards have no 3:1 boundary"


def test_the_face_did_not_move_to_fix_this():
    """The suit colours are contrast-tested against `--face`; changing it is how you break them.

    Kept as a named test rather than a comment so that anyone tempted to darken the face to solve a
    future flatness complaint gets told why the well exists instead.
    """
    for sheet in SHEETS:
        assert tokens(sheet, dark=False)["--face"] == "#fdfcf7", sheet
        assert tokens(sheet, dark=True)["--face"] == "#1d2724", sheet


@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
def test_the_hover_lift_stays_on_the_same_side_of_the_face(dark):
    """Hover was a literal `#fff`: a lift in light, a floodlight in dark.

    In the dark palette that painted the card you were pointing at white while `--ink` stayed
    near-white -- the one choice you could not read was the one under the cursor. The lift now moves
    the fill in the palette's own direction of elevation, and only far enough to be felt.
    """
    p = tokens("app.css", dark=dark)
    assert "--face-hover" in p, f"no --face-hover in the {'dark' if dark else 'light'} palette"
    face, hover = luminance(p["--face"]), luminance(p["--face-hover"])
    assert hover > face, "hover should lift the face, not invert it"
    assert contrast(p["--face-hover"], p["--face"]) < 1.15, "a hover lift, not a different surface"


@pytest.mark.parametrize("suit", ["club", "diamond", "heart", "spade"])
@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
def test_the_suits_survive_the_hover_fill(suit, dark):
    """The suits are pinned to `--face`; hovering must not quietly move them off it."""
    p = tokens("app.css", dark=dark)
    ratio = contrast(p[f"--suit-{suit}"], p["--face-hover"])
    assert ratio >= 4.5, f"--suit-{suit} is {ratio:.2f}:1 on the hovered face ({'dark' if dark else 'light'})"


@pytest.mark.parametrize("sheet", ["app.css", "juice.css"])
def test_hover_styling_is_gated_to_pointers_that_can_hover(sheet):
    """A touch device fires :hover on tap and leaves it there.

    That is the "last clicked button stays white on a phone" bug: the answered card kept the hover
    fill through the following question. Every `:hover` this project writes itself lives inside
    `@media (hover: hover)`; the frameworks' own hover rules are theirs.
    """
    css = re.sub(r"/\*.*?\*/", "", (STATIC / sheet).read_text(encoding="utf-8"), flags=re.DOTALL)
    unguarded = _outside_hover_guards(css)
    assert ":hover" not in unguarded, f"{sheet}: a :hover rule outside @media (hover: hover)"


def _outside_hover_guards(css: str) -> str:
    """`css` with every `@media (hover: hover)` block removed, braces balanced."""
    out, i = [], 0
    guard = "@media (hover: hover)"
    while (start := css.find(guard, i)) != -1:
        out.append(css[i:start])
        depth, j = 0, css.index("{", start)
        while True:
            if css[j] == "{":
                depth += 1
            elif css[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        i = j + 1
    out.append(css[i:])
    return "".join(out)


@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
def test_the_hand_rolled_ladder_steps_in_the_right_direction(dark):
    """Light: page darkest, face lightest. Dark: inverted -- elevation by lightening.

    Only the hand-rolled sheet, because the other two inherit page and card surfaces from their
    framework and only own the well and the cards.
    """
    p = tokens("app.css", dark=dark)
    page, card, well, face = (luminance(p[k]) for k in ("--side", "--card", "--well", "--face"))
    if dark:
        assert page < card, "the page should be the deepest surface in dark"
        assert well < face, "the cards must be lighter than the well they sit in"
    else:
        assert page < card, "the page should be a tint, the card paper"
        assert well < face, "the well must be recessed relative to the card faces"
