"""Layout invariants that a browser check can miss.

The nav-collapse bug: `.layout.nav-closed` set `grid-template-columns: 0 minmax(0, 1fr)` while also
hiding the sidebar. Hiding it removes it from grid flow, so `main` was auto-placed into the FIRST
track -- the zero-width one -- and the quiz collapsed instead of widening. Asserting "the sidebar is
hidden" passed the whole time; the collapsed layout needs a single track.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from litestar.testing import TestClient

import app as app_module
import render


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


STATIC = Path(render.__file__).resolve().parent / "static"
CSS = (STATIC / "app.css").read_text(encoding="utf-8")
STYLESHEETS = {
    name: (STATIC / name).read_text(encoding="utf-8") for name in ("app.css", "app-pico.css", "app-bulma.css")
}


def rule_body(selector: str) -> str:
    match = re.search(rf"{re.escape(selector)}\s*\{{([^}}]*)\}}", CSS)
    assert match, f"no rule for {selector}"
    return match.group(1)


def declaration(selector: str, prop: str) -> str:
    body = rule_body(selector)
    match = re.search(rf"{prop}\s*:\s*([^;]+);", body)
    assert match, f"{selector} does not set {prop}"
    return match.group(1).strip()


def track_count(template: str) -> int:
    """Top-level track count, ignoring commas inside functions like minmax(0, 1fr)."""
    depth = 0
    tracks, current = [], ""
    for char in template:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == " " and depth == 0:
            if current:
                tracks.append(current)
            current = ""
        else:
            current += char
    if current:
        tracks.append(current)
    return len(tracks)


def test_open_layout_has_a_sidebar_track_and_a_main_track():
    assert track_count(declaration(".layout", "grid-template-columns")) == 2


@pytest.mark.parametrize("selector", [".layout.nav-closed"])
def test_collapsed_layout_has_exactly_one_track(selector):
    """Otherwise `main`, auto-placed after the hidden sidebar, lands in the wrong track."""
    template = declaration(selector, "grid-template-columns")
    assert track_count(template) == 1, template
    assert not template.startswith("0"), f"a zero-width first track swallows main: {template}"


def test_collapsed_layout_hides_the_sidebar_not_the_main():
    assert "display: none" in rule_body(".layout.nav-closed .sidebar")
    assert not re.search(r"\.layout\.nav-closed\s+\.main\s*\{[^}]*display:\s*none", CSS)


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_declared_colour_scheme_matches_what_ships(name):
    """`color-scheme` is a claim, not a courtesy.

    Declaring `light dark` without dark rules makes the browser paint its own surfaces dark on a
    dark-OS machine -- the canvas beyond the document, which reads as a black rim around the page,
    and the scrollbars -- while the content stays light. This app shipped exactly that bug. Both are
    now allowed, but only in agreement: claim `light dark` if and only if a dark block exists.
    """
    css = re.sub(r"/\*.*?\*/", "", STYLESHEETS[name], flags=re.DOTALL)
    claims_dark = "color-scheme: light dark" in css
    # "ships a dark palette" used to mean a `prefers-color-scheme` block; it now means `light-dark()`
    # pairs, which is what let the palette become a toggle rather than an OS reading (see test_theme)
    has_dark_values = "light-dark(" in css
    assert "color-scheme:" in css, "say something, or the UA decides"
    assert claims_dark == has_dark_values, (
        f"{name}: color-scheme claims dark={claims_dark} but dark values present={has_dark_values}"
    )


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_root_element_paints_the_canvas(name):
    """The other half of the `color-scheme` story, and the half a body background does not cover.

    A background on `body` is propagated to the canvas, but the browser also needs a colour for the
    parts no element covers: a document shorter than the viewport, the scrollbars, and the strip a
    window exposes on resize before the page repaints. That comes from the ROOT element, and with
    nothing there the UA picks from `color-scheme` -- black on a dark-OS machine under a page that is
    rendering light. Reported as a black rim down the right and along the bottom.
    """
    css = STYLESHEETS[name]
    root = re.search(r"^html\s*\{([^}]*)\}", css, re.MULTILINE)
    assert root, f"{name}: no `html` rule, so the canvas is whatever the UA decides"
    assert "background" in root.group(1), f"{name}: the root element states no background"


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_reading_column_is_capped_and_centred(name):
    """At 74rem the column was wider than the window on a 1100-1300px monitor, so the quiz ran edge
    to edge -- a phone layout stretched. Capped narrower, centred, with gutters that grow."""
    css = STYLESHEETS[name]
    main = re.search(r"^\.main\s*\{([^}]*)\}", css, re.MULTILINE)
    assert main, f"{name}: no .main rule"
    width = re.search(r"max-width:\s*([\d.]+)rem", main.group(1))
    assert width, f"{name}: the reading column has no cap: {main.group(1)}"
    assert float(width.group(1)) <= 64, f"{name}: reading column is {width.group(1)}rem wide"
    assert "margin-inline: auto" in main.group(1), f"{name}: the column is capped but not centred"
    layout = re.search(r"^\.layout\s*\{([^}]*)\}", css, re.MULTILINE)
    assert layout, f"{name}: no .layout rule"
    padding = re.search(r"padding:([^;]*);", layout.group(1))
    assert padding, f"{name}: the layout states no padding"
    assert "clamp(" in padding.group(1), f"{name}: the layout gutters do not scale with the window"


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_topics_picker_scrolls_its_list_not_its_buttons(name):
    """With nineteen topics the whole card scrolled, so Apply / Clear / Close were sliced in half at
    the bottom edge -- the actions of a dialog are the last thing that should need scrolling to.

    The card is a flex column: `.topics-scroll` holds everything that can grow, the actions sit
    outside it. `align-items: stretch` is explicit because Pico's own `dialog` rule is a centring
    flex overlay, and inheriting its `center` made the children shrink-to-fit -- a 208px topic list
    inside an 896px card, so the columns below never appeared.
    """
    css = STYLESHEETS[name]
    card = re.search(r"\.topics-dialog(?:\[open\])?\s*\{([^}]*)\}", css)
    assert card, f"{name}: no .topics-dialog rule"
    opened = "".join(m.group(1) for m in re.finditer(r"\.topics-dialog\[open\]\s*\{([^}]*)\}", css))
    assert "display: flex" in opened, f"{name}: the card is not a column"
    assert "flex-direction: column" in opened
    assert "align-items: stretch" in opened
    whole = "".join(m.group(1) for m in re.finditer(r"\.topics-dialog(?:\[open\])?\s*\{([^}]*)\}", css))
    assert "overflow: hidden" in whole, f"{name}: the card itself still scrolls"
    scroller = re.search(r"^\.topics-scroll\s*\{([^}]*)\}", css, re.MULTILINE)
    assert scroller, f"{name}: no .topics-scroll rule"
    assert "overflow-y: auto" in scroller.group(1)
    # a flex item will not shrink below its content without this, so the card would grow instead
    assert "min-height: 0" in scroller.group(1), f"{name}: the scroller will push the card taller"


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_topic_list_uses_the_width_it_has(name):
    """Nineteen topics in one column is ~880px of list -- it scrolled on any laptop. In columns they
    are all visible at once, which is what a picker you scan wants. One column on a phone."""
    css = STYLESHEETS[name]
    rule = re.search(r"^\.topic-list\s*\{([^}]*)\}", css, re.MULTILINE)
    assert rule, f"{name}: no .topic-list rule"
    assert "repeat(auto-fit, minmax(" in rule.group(1), f"{name}: the list is single-column"
    # the card is fixed-positioned, so it shrink-to-fits: without a stated width the grid is happy
    # at one track and the columns never appear
    card = "".join(m.group(1) for m in re.finditer(r"\.topics-dialog(?:\[open\])?\s*\{([^}]*)\}", css))
    assert re.search(r"width:\s*min\(", card), f"{name}: the card has no stated width to fill"


def test_the_buttons_come_after_the_scrolling_part(client):
    """Source order is what keeps them out of the scroller; a stylesheet cannot fix a nesting bug."""
    body = client.get("/").text
    assert '<div class="topics-scroll">' in body
    assert body.index('class="dialog-actions"') > body.index('class="topics-scroll"')
    # ...and the legend went INSIDE the scroller with the list, or an open <details> would push the
    # actions off the bottom again
    assert body.index("What the topics mean") < body.index('class="dialog-actions"')


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_sidebar_scrolls_itself_rather_than_the_page(name):
    """The settings column is the tallest thing on the page; when the document scrolled with it, the
    question moved out from under the cursor. It gets its own scroll region, sized off the app bar's
    height rather than a guessed constant -- being 13px out was enough to put the scrollbar back."""
    css = STYLESHEETS[name]
    # anchored, so it is the `.sidebar` rule itself and not `.layout.nav-closed .sidebar`
    sidebar = re.search(r"^\.sidebar\s*\{([^}]*)\}", css, re.MULTILINE)
    assert sidebar, f"{name}: no .sidebar rule"
    body = sidebar.group(1)
    assert "position: sticky" in body
    assert "overflow-y: auto" in body
    assert "var(--topbar-h)" in body, "size the scroll region off the app bar, not a magic number"
    assert "--topbar-h:" in css, "and declare it"


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_drawer_packs_its_panels_to_the_top(name):
    """`align-content: start`, because as a phone drawer this grid has a DEFINITE height.

    At `position: fixed; top: 3rem; bottom: 0`, the default `normal` (which acts as stretch) hands
    all the leftover space to the auto rows, so every panel grows to fill the drawer. Measured at
    390x800 before the fix: the COLLAPSED `Progress` group was 145px tall against a natural 48 --
    folding it away saved nothing -- an open one carried ~90px of dead air under the dial, and the
    debug buttons came out as tall slabs. The desktop column is `sticky` with an auto height, which
    is why none of it showed there.
    """
    sidebar = re.search(r"^\.sidebar\s*\{([^}]*)\}", STYLESHEETS[name], re.MULTILINE)
    assert sidebar, f"{name}: no .sidebar rule"
    assert "display: grid" in sidebar.group(1)
    assert "align-content: start" in sidebar.group(1), (
        f"{name}: the drawer will stretch its panels to fill a phone screen"
    )


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_mobile_drawer_rules_come_after_the_base_sidebar_rule(name):
    """Ordering, not specificity -- which is why this hid for weeks.

    `@media (max-width: 900px) { .sidebar { position: fixed } }` and the base `.sidebar { position:
    sticky }` have the SAME specificity, so whichever is written last wins. In `app.css` the media
    query was above the base rule, so on a phone the off-canvas drawer never applied at all: the
    sidebar stayed a sticky 320px column. The other two stylesheets happened to declare it after their
    base rules, so only the default variant was broken -- and nothing failed, because every rule was
    present and correct in isolation.
    """
    css = STYLESHEETS[name]
    mobile = css.find("@media (max-width: 900px)")
    base = re.search(r"^\.sidebar\s*\{", css, re.MULTILINE)
    assert mobile != -1, f"{name}: no mobile block"
    assert base, f"{name}: no base .sidebar rule"
    assert mobile > base.start(), (
        f"{name}: the mobile drawer block is above the base .sidebar rule, so `position: fixed` loses"
    )


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_touch_targets_are_big_enough_to_hit(name):
    """Measured on an emulated 390x844 phone: the hamburger was 33x15px and Skip 70x27.

    ~44px is the usual floor for a finger. The hamburger gets it unconditionally (it is 44px of mostly
    padding either way); Skip gets a smaller floor with a mouse and the full 44 on a coarse pointer,
    because a 44px-tall button would otherwise make the app bar taller for everyone.
    """
    css = STYLESHEETS[name]
    # every `.nav-toggle` rule, not the first: each sheet declares one for looks and one for the target
    # size, and which comes first is not the point
    declarations = " ".join(re.findall(r"^\.nav-toggle\s*\{([^}]*)\}", css, re.MULTILINE))
    assert declarations, f"{name}: no .nav-toggle rule"
    assert "min-height: 44px" in declarations, f"{name}: the hamburger is too small to tap"
    assert "min-width: 44px" in declarations, f"{name}: the hamburger is too small to tap"
    assert "@media (pointer: coarse)" in css, f"{name}: no coarse-pointer bump for Skip"


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_topics_picker_sits_above_the_drawer(name):
    """The Topics button lives IN the drawer, so on a phone -- where the drawer is a z-index 30 overlay
    -- a lower dialog opened *behind* the thing you opened it from and looked like a no-op. Desktop hid
    it: there the sidebar is a column and never overlaps the dialog."""
    css = STYLESHEETS[name]
    dialog = re.search(r"\.topics-dialog(?:\[open\])?\s*\{([^}]*)\}", css)
    assert dialog, f"{name}: no .topics-dialog rule"
    z = re.search(r"z-index:\s*(\d+)", dialog.group(1))
    assert z, f"{name}: the picker has no z-index, so the drawer can cover it"
    assert int(z.group(1)) > 30, f"{name}: picker z-index {z.group(1)} is not above the drawer's 30"


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_topics_picker_is_positioned_rather_than_left_in_flow(name):
    """A non-modal `<dialog open>` is `position: absolute` in normal flow. With no rule of its own the
    Bulma variant opened at `top: 819px` in an 844px phone viewport -- below the fold, invisible until
    you scrolled. Pico's own dialog styling hid the same omission by centring one for us."""
    css = STYLESHEETS[name]
    dialog = re.search(r"\.topics-dialog(?:\[open\])?\s*\{([^}]*)\}", css)
    assert dialog, f"{name}: no .topics-dialog rule"
    assert "position: fixed" in dialog.group(1), f"{name}: the picker is not pinned to the viewport"
    # The width is now STATED (the card shrink-to-fits otherwise and the topic columns never appear),
    # so the phone clamp lives on both properties: `width: min(56rem, 92vw)` and a `max-width` in vw.
    body = "".join(m.group(1) for m in re.finditer(r"\.topics-dialog(?:\[open\])?\s*\{([^}]*)\}", css))
    # not `(?:max-)?width` alone: that also matches the tail of `min-width: 0`
    widths = re.findall(r"(?<![\w-])(?:max-)?width:\s*([^;]+);", body)
    assert widths, f"{name}: the picker states no width"
    assert all("vw" in value for value in widths), (
        f"{name}: every width on the picker must be clamped to the viewport, got {widths}"
    )


@pytest.mark.parametrize("name", list(STYLESHEETS))
def test_the_hud_gauge_mask_is_opaque(name):
    """The track carries the red-to-green gradient and the mask covers what has NOT been earned, so a
    translucent mask lets the gradient through and the gauge reads as FULL at every score. It shipped
    that way for one commit, chosen to stop an opaque pale-green block looking like a stray rectangle
    on the green app bar; the fix is an opaque colour that belongs to the bar, not transparency."""
    css = STYLESHEETS[name]
    mask = re.search(r"\.hud-meter \.meter-mask\s*\{([^}]*)\}", css)
    assert mask, f"{name}: no HUD-specific mask rule"
    background = re.search(r"background:\s*([^;]+);", mask.group(1))
    assert background, f"{name}: the HUD mask sets no background"
    value = background.group(1)
    assert "%" not in value, f"{name}: translucent mask ({value}) shows the gradient through"
    assert "rgba" not in value, f"{name}: translucent mask ({value}) shows the gradient through"
