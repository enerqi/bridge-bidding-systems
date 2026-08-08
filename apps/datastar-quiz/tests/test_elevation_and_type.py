"""Two token systems that only work if nothing opts out of them.

**Elevation.** A shadow is a claim about where the light is. One page, one light: every rung is
`x = 0`, `blur = 2x offset`, and each is a direct cast plus a tighter ambient one. Before this the
app had seven ad-hoc alphas, a mobile drawer lit from nowhere (`0 0 40px`, no offset at all) and
Pico's own six-layer, right-offset, blue-tinted shadow under the notes -- three light sources on one
screen. The tests below pin the ladder AND the discipline: a cast shadow has to come from a token.

**Type.** `--ui-font` is what you read and what the picker changes; `--display-font` is the game's
voice (app bar, HUD, toasts, finale). Plus the domain rule that outranks both: the suits are text
glyphs, so `--suit-symbols` sits in every stack, before the generic, or a spade arrives in whatever
last-resort face the browser picks and does not match the bid beside it.

Reasoning for both: DESIGN.md, "Elevation and shadow" and "Type: three roles".
"""

from __future__ import annotations

import re
from pathlib import Path

import palette
import pytest

import render

STATIC = Path(render.__file__).resolve().parent / "static"
SHEETS = ("app.css", "app-pico.css", "app-bulma.css")
# the game-feel layer is not a base sheet, but it draws lifts and presses and must use the ladder too
SHADOW_FILES = (*SHEETS, "juice.css")
RUNGS = ("--elev-1", "--elev-2", "--elev-3", "--elev-4")


def source(name: str) -> str:
    return (STATIC / name).read_text(encoding="utf-8")


def without_comments(css: str) -> str:
    return re.sub(r"/\*.*?\*/", "", css, flags=re.DOTALL)


def token(css: str, name: str, *, dark: bool) -> str:
    """One custom property's value, resolved for one palette.

    Both palettes live in `light-dark()` pairs on a single declaration rather than in two blocks --
    a media query answers to the OS, and the app has a manual toggle. `palette.resolve` picks a side.
    """
    match = re.search(rf"(?<![\w-]){re.escape(name)}:\s*([^;]+);", without_comments(css))
    assert match, f"{name} is not declared"
    return palette.resolve(match.group(1), dark=dark)


def layers(value: str) -> list[str]:
    """A shadow value split on its top-level commas (colours contain commas of their own)."""
    depth, out, current = 0, [], ""
    for char in value:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            out.append(current.strip())
            current = ""
        else:
            current += char
    if current.strip():
        out.append(current.strip())
    return out


def offsets(layer: str) -> tuple[float, float, float]:
    """(x, y, blur) in px from one shadow layer. A zero is written unitless, so `px` is optional."""
    numbers = re.findall(r"(?<![\w(-])(-?[\d.]+)(?:px)?(?=\s|$)", layer.split("rgb")[0])
    assert len(numbers) >= 3, layer
    return float(numbers[0]), float(numbers[1]), float(numbers[2])


def first_alpha(value: str) -> float:
    match = re.search(r"/\s*([\d.]+)%", value)
    assert match, value
    return float(match.group(1))


# --- the ladder ---------------------------------------------------------------


@pytest.mark.parametrize("sheet", SHEETS)
@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
def test_every_rung_exists_in_both_palettes(sheet, dark):
    css = source(sheet)
    for name in ("--elev-inset", *RUNGS):
        assert token(css, name, dark=dark)


@pytest.mark.parametrize("sheet", SHEETS)
@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
@pytest.mark.parametrize("rung", RUNGS)
def test_one_light_source_overhead(sheet, dark, rung):
    """`x = 0` and `y > 0` in every layer of every rung. A shadow with a sideways offset is a second
    sun; the drawer's old `0 0 40px` was no sun at all."""
    for layer in layers(token(source(sheet), rung, dark=dark)):
        if "0 0 0 1px" in layer:  # the hairline ring is an edge, not a cast
            continue
        x, y, _ = offsets(layer)
        assert x == 0, f"{sheet} {rung}: sideways offset in `{layer}`"
        assert y > 0, f"{sheet} {rung}: nothing casts upward -- `{layer}`"


@pytest.mark.parametrize("sheet", SHEETS)
@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
@pytest.mark.parametrize("rung", RUNGS)
def test_blur_is_twice_the_offset(sheet, dark, rung):
    """The one geometric rule that keeps four rungs looking like the same light at four heights."""
    for layer in layers(token(source(sheet), rung, dark=dark)):
        if "0 0 0 1px" in layer:
            continue
        _, y, blur = offsets(layer)
        assert blur == 2 * y, f"{sheet} {rung}: blur {blur} is not 2x offset {y} in `{layer}`"


@pytest.mark.parametrize("sheet", SHEETS)
@pytest.mark.parametrize("dark", [False, True], ids=["light", "dark"])
def test_the_rungs_climb(sheet, dark):
    """Higher rung = further from the surface = larger offset and a stronger cast. Without this the
    ladder is four shadows rather than an order of depth."""
    css = source(sheet)
    heights = [offsets(layers(token(css, rung, dark=dark))[0])[1] for rung in RUNGS]
    alphas = [first_alpha(layers(token(css, rung, dark=dark))[0]) for rung in RUNGS]
    assert heights == sorted(heights), heights
    assert len(set(heights)) == len(heights), f"two rungs at the same height: {heights}"
    assert alphas == sorted(alphas), alphas


@pytest.mark.parametrize("sheet", SHEETS)
def test_dark_casts_harder_than_light(sheet):
    """A cast shadow barely registers on a dark ground -- see the palette note. Same geometry, more
    alpha; elevation itself is carried by lightening the surface."""
    css = source(sheet)
    for rung in RUNGS:
        light = first_alpha(layers(token(css, rung, dark=False))[0])
        dark = first_alpha(layers(token(css, rung, dark=True))[0])
        assert dark > light, f"{sheet} {rung}: dark alpha {dark} <= light {light}"


@pytest.mark.parametrize("name", SHADOW_FILES)
def test_no_rule_casts_its_own_shadow(name):
    """The discipline, and the reason the audit in DESIGN.md was possible at all.

    Anything that reads as *depth* must name a rung. Three things are still allowed to write a shadow
    literal, because none of them is depth: `inset` rings and fills, spread-only rings
    (`0 0 0 <n>px`, which is a border drawn where a border would change the box), and coloured glows
    (the streak chip, the full gauge, the timer alarm) -- those are light sources of their own, not
    objects above a surface.
    """
    css = without_comments(source(name))
    for match in re.finditer(r"box-shadow:\s*([^;]+);", css):
        value = " ".join(match.group(1).split())
        if value in {"none"} or "var(--elev-" in value:
            continue
        for layer in layers(value):
            if "inset" in layer or layer.startswith("0 0 0"):  # a ring: no offset and no blur
                continue
            if "var(--suit-" in layer or "color-mix" in layer:  # a coloured glow
                continue
            if re.match(r"^0 0 [\d.]+px", layer):  # a glow: no offset, so no claim about the light
                continue
            pytest.fail(f"{name}: `{layer}` casts a shadow without naming a rung")


def test_the_notes_do_not_keep_picos_own_shadow():
    """The specific bug this system exists to prevent coming back: Pico's card shadow is six layers,
    offset to the RIGHT and tinted blue-grey, so the two disclosures under the question were the one
    thing on the page lit from a different direction."""
    css = without_comments(source("app-pico.css"))
    notes = re.search(r"\.main > \.notes\s*\{([^}]*)\}", css)
    assert notes, "no .notes rule in the Pico adapter"
    assert "var(--elev-" in notes.group(1)
    assert "--pico-card-box-shadow" not in notes.group(1)


@pytest.mark.parametrize("sheet", SHEETS)
def test_the_thing_you_press_is_not_flat(sheet):
    """The answer cards had no resting shadow in the Pico and Bulma variants, while `juice.css`
    animated a lift and a press for them -- a press that started from nothing."""
    css = without_comments(source(sheet))
    card = re.search(r"^\.candidate(?:\.button)?\s*\{([^}]*)\}", css, re.MULTILINE)
    assert card, f"{sheet}: no .candidate rule"
    assert "box-shadow: var(--elev-" in card.group(1), f"{sheet}: the answer cards rest flat"


# --- type ---------------------------------------------------------------------


@pytest.mark.parametrize("sheet", SHEETS)
def test_both_type_roles_are_declared(sheet):
    css = source(sheet)
    assert token(css, "--ui-font", dark=False)
    assert token(css, "--display-font", dark=False)
    assert token(css, "--suit-symbols", dark=False)


@pytest.mark.parametrize("sheet", SHEETS)
def test_every_stack_names_the_symbol_fonts_before_its_generic(sheet):
    """The suits are text glyphs. A face without them falls back to whatever the browser picks last,
    so a spade can arrive in a different font from the bid beside it -- and the picker offers faces
    (Nunito, Cascadia Code) where coverage is not guaranteed. Naming the symbol fonts makes the
    fallback deterministic; it has to come BEFORE the generic, because a generic always matches and
    nothing after it is reachable.
    """
    css = without_comments(source(sheet))
    generics = ("sans-serif", "serif", "monospace", "system-ui", "cursive", "fantasy")
    for match in re.finditer(r"--(?:ui|display)-font:\s*([^;]+);", css):
        stack = " ".join(match.group(1).split())
        assert "var(--suit-symbols)" in stack, f"{sheet}: no suit fallback in `{stack}`"
        families = [f.strip() for f in stack.split(",")]
        assert families[-1] in generics, f"{sheet}: `{stack}` does not end in a generic family"
        symbols_at = families.index("var(--suit-symbols)")
        assert symbols_at == len(families) - 2, f"{sheet}: the suit fallback is unreachable in `{stack}`"


@pytest.mark.parametrize("sheet", SHEETS)
def test_the_symbol_fallback_is_not_itself_a_generic(sheet):
    """`--suit-symbols` is spliced in *before* the generic, so a generic inside it would swallow the
    stack's own last-resort choice -- a serif stack would end up falling back to a sans."""
    value = token(source(sheet), "--suit-symbols", dark=False)
    for generic in ("sans-serif", "serif", "monospace", "system-ui"):
        assert generic not in value, f"{sheet}: --suit-symbols contains `{generic}`"


@pytest.mark.parametrize("sheet", SHEETS)
def test_the_picker_changes_what_you_read_not_the_chrome(sheet):
    """Each `[data-font]` option re-points `--ui-font` only. `--display-font` is the app's voice and
    stays put -- that is what makes a personality face affordable there."""
    css = without_comments(source(sheet))
    options = re.findall(r'body\[data-font="[a-z]+"\]\s*\{([^}]*)\}', css)
    assert len(options) >= 4, f"{sheet}: expected the picker's options"
    for body in options:
        assert "--ui-font" in body
        assert "--display-font" not in body, f"{sheet}: an option re-points the display face"


@pytest.mark.parametrize("sheet", SHEETS)
def test_the_party_asks_for_the_colour_emoji_face(sheet):
    """The cost of naming the symbol fonts, and worth a test of its own.

    "Segoe UI Symbol" carries the party popper as well as the suits -- in MONOCHROME -- so putting it
    in every stack turned the finale's poppers and confetti into black line art. The suits want a
    text face (they are coloured by CSS); the party wants a colour one. Both are now explicit, and
    this is the half that would silently regress if `--suit-symbols` were ever reordered.
    """
    css = without_comments(source(sheet))
    rule = re.search(r"\.pop,\s*\.confetti-bit\s*\{([^}]*)\}", css)
    assert rule, f"{sheet}: the emoji elements do not name a face"
    assert "Color Emoji" in rule.group(1) or "Segoe UI Emoji" in rule.group(1)
    assert "var(--suit-symbols)" not in rule.group(1), f"{sheet}: the party is back on the text face"


@pytest.mark.parametrize("sheet", SHEETS)
def test_the_reveal_marks_stay_on_the_text_face(sheet):
    """The other side of the same coin: the tick and the cross are coloured by CSS
    (`--suit-club` / `--suit-heart`), so they must NOT be handed to a colour emoji font -- an emoji
    glyph ignores `color`. They inherit `--ui-font`, and nothing may give them a family of their own.
    """
    css = without_comments(source(sheet))
    for selector, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
        if ".mark" in selector and "font-family" in body:
            pytest.fail(f"{sheet}: `{selector.strip()}` gives the reveal marks a font of their own")


@pytest.mark.parametrize("sheet", SHEETS)
def test_the_chrome_actually_uses_the_display_face(sheet):
    """Declared but unused is how a two-role system quietly becomes a one-role system."""
    css = without_comments(source(sheet))
    users = {
        selector
        for selector, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css)
        if "font-family: var(--display-font)" in body
    }
    flat = " ".join(users)
    for wanted in (".topbar h1", ".topbar-score", ".toast"):
        assert wanted in flat, f"{sheet}: {wanted} is not on the display face"
