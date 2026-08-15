"""What a small phone gets, and why each piece of it is where it is.

Measured on an emulated iPhone 12 (390x844) and Galaxy S9 (360x740), against the running app. Four
things were wrong and all four were invisible on a laptop:

* the score wrapped to THREE lines -- "0/0", "· 0", "pts" -- so the app bar read vertically and
  stood 78px tall instead of 48;
* the hamburger carried Pico's `margin-bottom: var(--pico-spacing)`, which on a flex item is 16px
  of the bar's own height. That is where the missing 16 went, and no amount of squeezing the
  contents would have found it;
* `--topbar-h` claimed 3rem while the bar actually measured 62px (the 44px touch target plus its
  padding), so the drawer opened 14px underneath the bar -- and anything else positioned off the
  token would have hidden behind it;
* the countdown sat BELOW the question card, in flow: with five choices it is already at the fold,
  and the phone's own URL bar slides back over the bottom of the viewport the moment you scroll up.
  The one element that is worthless off-screen was the one most likely to be off-screen.

These pin the fixes in all three stylesheets, because the variants are standalone copies and a
phone fix applied to one of them is a phone fix that vanishes when the picker moves.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from litestar.testing import TestClient

import app as app_module
import render

STATIC = Path(render.__file__).resolve().parent / "static"
SHEETS = ("app.css", "app-pico.css", "app-bulma.css")
STYLESHEETS = {name: (STATIC / name).read_text(encoding="utf-8") for name in SHEETS}

# 44px of touch target plus the app bar's 0.55rem of padding, in rem
BAR_HEIGHT_REM = 3.875


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


def rule(css: str, selector: str) -> str:
    """The body of a TOP-LEVEL rule (anchored, so `.timer` is not `.sidebar .timer`)."""
    match = re.search(rf"^{re.escape(selector)}\s*\{{([^}}]*)\}}", css, re.MULTILINE)
    assert match, f"no rule for {selector}"
    return match.group(1)


def media_blocks(css: str, query: str) -> str:
    """Everything inside every `@media <query>` block, concatenated.

    Nested braces are counted rather than regexed, because a media block contains rules.
    """
    found = []
    for match in re.finditer(rf"@media\s+{re.escape(query)}\s*\{{", css):
        depth, start = 1, match.end()
        index = start
        while depth and index < len(css):
            depth += (css[index] == "{") - (css[index] == "}")
            index += 1
        found.append(css[start : index - 1])
    return "\n".join(found)


def rule_in(block: str, selector: str) -> str:
    match = re.search(rf"(?:^|\n)\s*{re.escape(selector)}\s*\{{([^}}]*)\}}", block)
    assert match, f"no rule for {selector} in that block"
    return match.group(1)


# --- the app bar ------------------------------------------------------------


@pytest.mark.parametrize("name", SHEETS)
def test_the_score_is_one_line_and_does_not_shrink(name):
    """A score that wraps is not a score: at 390px it came out as three stacked fragments, read
    vertically, and the bar grew 30px to hold them. The title is the item that gives way instead --
    it has `min-width: 0` and an ellipsis -- and below 400px the fraction leaves entirely."""
    body = rule(STYLESHEETS[name], ".topbar-score")
    assert "white-space: nowrap" in body, f"{name}: the score may still wrap"
    assert re.search(r"flex:\s*none", body), f"{name}: the score can be squeezed until it wraps"


@pytest.mark.parametrize("name", SHEETS)
def test_the_hamburger_carries_no_button_margin(name):
    """Pico gives every button `margin-bottom: var(--pico-spacing)`. On a flex item that is 16px of
    the APP BAR, not of the page -- the bar was 78px tall with a 44px hamburger in it. Skip and the
    theme toggle already zeroed it; this one was the leak. Stated in all three sheets so the
    variants measure the same."""
    body = rule(STYLESHEETS[name], ".nav-toggle")
    assert re.search(r"margin:\s*0", body), f"{name}: a base sheet's button margin can inflate the bar"


@pytest.mark.parametrize("name", SHEETS)
def test_the_bar_height_token_matches_the_bar(name):
    """`--topbar-h` is not decoration: the drawer and the sticky countdown are both positioned FROM
    it, so a token that is 14px short puts them behind the bar. It said 3rem from before the touch
    targets went in, when the bar really was 48px."""
    css = STYLESHEETS[name]
    declared = re.search(r"--topbar-h:\s*([\d.]+)rem", css)
    assert declared, f"{name}: no --topbar-h"
    assert float(declared.group(1)) == pytest.approx(BAR_HEIGHT_REM), (
        f"{name}: --topbar-h is {declared.group(1)}rem, the bar measures {BAR_HEIGHT_REM}rem"
    )
    assert "min-height: var(--topbar-h)" in rule(css, ".topbar"), f"{name}: the bar ignores its own token"


@pytest.mark.parametrize("name", SHEETS)
def test_the_drawer_hangs_off_the_token_not_a_literal(name):
    """The overlay drawer was `top: 3rem` written out by hand, so it opened under the bar."""
    drawer = media_blocks(STYLESHEETS[name], "(max-width: 900px)")
    sidebar = rule_in(drawer, ".sidebar")
    assert "top: var(--topbar-h)" in sidebar, f"{name}: the drawer is positioned off a magic number"


# --- the shedding ladder ----------------------------------------------------


def test_the_score_fraction_is_wrapped_so_it_can_be_shed(client):
    """The bar sheds in order of what you can live without: the gauge at 760px, then the fraction.
    Shedding the fraction means the POINTS survive -- they are what the skips are earned against --
    which needs the fraction in an element of its own rather than `.topbar-score` hidden whole."""
    body = client.get("/").text
    score = re.search(r'<span class="topbar-score">(.*?)</span>\s*\n', body, re.DOTALL)
    assert score, "no score in the app bar"
    # the spans nest, so this is a slice rather than a regex: everything from the opening tag of the
    # fraction up to the points is what a `display: none` on `.score-fraction` takes away
    inner = score.group(1)
    assert 'class="score-fraction"' in inner, "the fraction is not separable from the points"
    assert "$_points" in inner, "the points are not in the bar at all"
    shed = inner[inner.index('class="score-fraction"') : inner.index("$_points")]
    assert "$_correct" in shed, "the correct count is not inside the wrapper"
    assert "$_attempted" in shed, "the attempted count is not inside the wrapper"
    assert shed.count("</span>") == shed.count("<span"), "the wrapper does not close before the points"


@pytest.mark.parametrize("name", SHEETS)
def test_the_fraction_goes_after_the_gauge_and_before_nothing_else(name):
    """One ladder, in order: the gauge drops at 760px, the fraction below 400 (chosen so 390 and 360
    -- the two commonest phone widths -- are on the same side of it). Skip and the streak never
    drop, and the whole score never drops."""
    css = STYLESHEETS[name]
    gauge = re.search(r"@media \(max-width: (\d+)px\) \{\s*\.hud-meter \{\s*display: none", css)
    assert gauge, f"{name}: the gauge does not drop"
    fraction = re.search(r"@media \(max-width: (\d+)px\) \{\s*\.score-fraction \{\s*display: none", css)
    assert fraction, f"{name}: the fraction never drops, so a narrow bar has to hold everything"
    assert int(fraction.group(1)) <= 400, f"{name}: the fraction drops at {fraction.group(1)}px"
    assert int(fraction.group(1)) < int(gauge.group(1)), f"{name}: the fraction drops before the gauge"
    assert not re.search(r"\.topbar-score \{\s*display: none", css), f"{name}: the whole score drops"


# --- the countdown ----------------------------------------------------------


@pytest.mark.parametrize("name", SHEETS)
def test_the_countdown_sticks_to_the_bar_on_a_phone(name):
    """Below the card it is under the fold with five choices, and under the phone's URL bar the
    moment you scroll up. Above the card and stuck to the app bar it is always the same 22px.

    `order: -1` and nothing in the markup: the DOM order (and so the screen-reader order, and every
    template) is unchanged, and the desktop layout keeps the countdown where it was.
    """
    phone = media_blocks(STYLESHEETS[name], "(max-width: 900px)")
    main = rule_in(phone, ".main")
    # `order` does nothing outside a flex container
    assert "display: flex" in main, f"{name}: the column is not a flex container"
    assert "flex-direction: column" in main, f"{name}: a flex ROW would put the countdown beside the card"
    timer = rule_in(phone, ".timer")
    assert "order: -1" in timer, f"{name}: the countdown is still below the question"
    assert "position: sticky" in timer, f"{name}: the countdown scrolls away"
    assert "top: var(--topbar-h)" in timer, f"{name}: the countdown is not parked on the app bar"
    z_index = re.search(r"z-index:\s*(\d+)", timer)
    assert z_index, f"{name}: a sticky bar with no z-index is scrolled over by the card"
    bar_z = re.search(r"z-index:\s*(\d+)", rule(STYLESHEETS[name], ".topbar"))
    assert bar_z, f"{name}: the app bar has no z-index of its own"
    assert int(z_index.group(1)) < int(bar_z.group(1)), f"{name}: the countdown would cover the app bar"


@pytest.mark.parametrize("name", SHEETS)
def test_the_desktop_countdown_is_untouched(name):
    """The move is a phone fix, not a redesign: on a wide screen the bar stays under the question,
    where the reveal appears next to it."""
    css = STYLESHEETS[name]
    base = rule(css, ".timer")
    assert "position:" not in base, f"{name}: the base countdown is positioned"
    assert "order:" not in base, f"{name}: the base countdown is reordered"


# --- vertical budget --------------------------------------------------------


@pytest.mark.parametrize("name", SHEETS)
def test_the_phone_spends_less_height_between_the_choices(name):
    """ "Not all the answers fit at once" is a sum of small things: the gap between one-column cards,
    the space under the prompt, and the card minimum. Each is smaller under 560px than the desktop
    value it overrides -- and the numbers are what make the fifth choice reachable without a
    scroll on a 740px-tall phone."""
    phone = media_blocks(STYLESHEETS[name], "(max-width: 560px)")
    candidates = rule_in(phone, ".candidates")
    gap = re.search(r"gap:\s*([\d.]+)rem", candidates)
    assert gap, f"{name}: the phone grid does not state its gap"
    desktop_gap = re.search(r"gap:\s*([\d.]+)rem", rule(STYLESHEETS[name], ".candidates"))
    assert desktop_gap, f"{name}: the desktop grid states no gap to be tighter than"
    assert float(gap.group(1)) < float(desktop_gap.group(1)), f"{name}: the phone gap is not tighter"
    answer = rule_in(phone, ".answer")
    assert "margin-bottom" in answer, f"{name}: the prompt keeps its desktop margin under the fold"
