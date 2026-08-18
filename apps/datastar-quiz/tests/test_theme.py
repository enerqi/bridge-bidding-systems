"""The theme toggle: auto / light / dark, always reachable, no JavaScript of ours.

The app had a dark palette for months and no way to ask for it -- it was `@media
(prefers-color-scheme: dark)`, which answers to the OS and to nothing else. A media query is not
overridable: the only way to add a manual switch on top of one is to write the whole palette a second
time under a class or an attribute, and then keep two copies in step forever.

So the palettes moved into `light-dark()` pairs, which resolve against the element's computed
`color-scheme` -- and forcing a palette becomes ONE declaration. These tests pin the mechanism (no
media query left to fight, both forcings present, the claim on `:root` where the canvas reads it) and
the control (three states, in the app bar, working while an answer is in flight).
"""

from __future__ import annotations

import re
from pathlib import Path

import palette
import pytest
from litestar.testing import TestClient
from markup import found

import app as app_module
import render

TEMPLATE_DIR = Path(render.__file__).resolve().parent / "templates"
SHEETS = palette.SHEETS


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


def stylesheet(name: str) -> str:
    return palette.strip_comments(palette.source(name))


# --- the mechanism ------------------------------------------------------------


@pytest.mark.parametrize("name", SHEETS)
def test_no_palette_is_locked_behind_a_media_query(name):
    """The reason this refactor happened. A `prefers-color-scheme` block cannot be overridden by a
    toggle, only duplicated -- so there must not be one left to fight with."""
    assert "@media (prefers-color-scheme" not in stylesheet(name), f"{name}: a palette the toggle cannot reach"


@pytest.mark.parametrize("name", SHEETS)
def test_both_palettes_are_forceable_from_the_root(name):
    """`color-scheme` on the ROOT, because the canvas and the scrollbars read it there and nowhere
    else -- the same lesson as the black rim, and the reason `data-theme` is on <html> rather than
    <body>. `only`, not a bare `dark`: a plain `color-scheme: dark` still lets the UA pick light for
    a light-only widget."""
    css = stylesheet(name)
    for theme, scheme in (("dark", "only dark"), ("light", "only light")):
        rule = re.search(rf':root\[data-theme="{theme}"\]\s*\{{([^}}]*)\}}', css)
        assert rule, f"{name}: nothing forces the {theme} palette"
        assert f"color-scheme: {scheme}" in rule.group(1), f"{name}: {theme} does not force `{scheme}`"


@pytest.mark.parametrize("name", SHEETS)
def test_auto_is_the_absence_of_a_forcing(name):
    """`auto` is a real third state, not a synonym for light: it is the only one that follows the
    machine when it switches at sunset, and it is what `color-scheme: light dark` already does."""
    css = stylesheet(name)
    assert "color-scheme: light dark" in css, f"{name}: no OS-following default"
    assert '[data-theme="auto"]' not in css, f"{name}: auto should be the absence of an attribute"


@pytest.mark.parametrize("name", SHEETS)
@pytest.mark.parametrize("token", ["--face", "--card-edge", "--suit-spade"])
def test_the_palettes_travel_together_in_one_declaration(name, token):
    """Two values, one place. The duplication this replaced is what let a palette drift."""
    light = palette.token(name, token, dark=False)
    dark = palette.token(name, token, dark=True)
    assert light != dark, f"{name}: {token} does not change between palettes"


# --- the control --------------------------------------------------------------


def test_the_signal_is_declared_local_and_defaults_to_the_os():
    assert render.local_ui_signals()["_theme"] == "auto"


def test_the_root_mirrors_the_signal_and_omits_it_when_auto(client):
    """On <html>: Pico paints the root from its own `--pico-background-color`, and with the attribute
    one level below on <body> the page BEHIND the app kept the OS palette while everything inside it
    switched. Both frameworks document the attribute there too.

    `false`, not `''`: datastar removes an attribute set to false, and an empty `data-theme` is still
    an attribute -- Pico treats a present one as "themed"."""
    page = client.get("/").text
    root = re.search(r"<html[^>]*>", page)
    assert root, "no <html> tag?"
    attr = re.search(r'data-attr:data-theme="([^"]+)"', root.group(0))
    assert attr, f"the root does not mirror the theme signal: {root.group(0)}"
    assert "'auto'" in attr.group(1), f"auto is not special-cased: {attr.group(1)}"
    assert "false" in attr.group(1), f"auto must REMOVE the attribute, not blank it: {attr.group(1)}"


# --- remembered -----------------------------------------------------------------


def test_a_remembered_theme_is_in_the_first_paint(client):
    """The whole reason this is a cookie and not `localStorage`: it arrives ON the request, so the
    server can render `data-theme` into the document. Local storage is only readable after JS runs,
    which is a frame of the OS palette on every load for anyone who chose against it."""
    client.cookies.set(render.THEME_COOKIE, "dark")
    root = found(r"<html[^>]*>", client.get("/").text).group(0)
    assert 'data-theme="dark"' in root, root


def test_the_remembered_theme_and_the_signal_agree(client):
    """Two halves of the same value: the attribute paints, the signal is what the toggle mutates. If
    they disagreed the first click would jump to whatever the signal happened to say."""
    client.cookies.set(render.THEME_COOKIE, "light")
    body = client.get("/").text
    signals = found(r'data-signals="([^"]+)"', body).group(1)
    assert "&#34;_theme&#34;: &#34;light&#34;" in signals or '"_theme": "light"' in signals, signals


def test_auto_writes_no_attribute(client):
    """`auto` is the absence of the attribute, in the rendered document as much as in the CSS."""
    client.cookies.set(render.THEME_COOKIE, "auto")
    root = found(r"<html[^>]*>", client.get("/").text).group(0)
    assert "data-theme=" not in root.replace("data-attr:data-theme=", ""), root


@pytest.mark.parametrize("raw", [None, "", "DARK", "midnight", "dark; --hack", "auto "])
def test_an_unrecognised_cookie_is_auto(raw):
    """A cookie is user input and this one is interpolated into an attribute. Anything not exactly
    one of the three states is the default, so nothing unexpected can reach the page."""
    assert render.theme_from(raw) == "auto"


def test_the_toggle_writes_the_cookie_itself(client):
    """No round trip and no new route: the browser writes it, the server only reads it back. Scoped
    like the session cookie -- cookies ignore the PORT, so two instances on one host share a name,
    and only the path keeps a prefixed deployment separate."""
    body = client.get("/").text
    toggle = found(r"<button[^>]*class=\"theme-toggle[^\"]*\"(.*?)</button>", body, re.DOTALL).group(1)
    click = found(r'data-on:click="([^"]+)"', toggle, re.DOTALL).group(1)
    assert "document.cookie" in click, "the choice is not remembered"
    assert render.THEME_COOKIE in click
    assert "max-age=31536000" in click, "a preference should outlive the session"
    assert "samesite=lax" in click
    assert "path=/" in click


def test_the_toggle_is_in_the_app_bar_and_always_available(client):
    """In the bar rather than in Appearance: the drawer starts closed, and "this is too bright right
    now" is fixed the moment it is noticed. Not gated on debug, and not on `$_playing` -- unlike
    Skip, changing the palette is not a move in the game, so it also works mid-answer."""
    body = client.get("/").text
    toggle = re.search(r"<button[^>]*class=\"theme-toggle[^\"]*\"(.*?)</button>", body, re.DOTALL)
    assert toggle, "no theme toggle in the rendered page"
    markup = toggle.group(1)
    assert "$_theme" in markup
    assert "disabled" not in markup, "the theme toggle must not be disabled by game state"
    header = body[body.index("<header") : body.index("</header>")]
    assert "theme-toggle" in header, "the toggle is not in the app bar"


def test_the_toggle_sits_with_the_chrome_and_not_with_the_game(client):
    """The app bar is two clusters split by `.topbar-spacer`: chrome on the left (hamburger, title),
    live game state on the right (score, gauge, streak, Skip). This app sorts controls by WHEN you
    touch them, and a palette is not a move in the game -- it first shipped beside Skip, which put a
    preference inside the game cluster and next to the one control that spends a resource, where a
    mis-tap costs a skip.
    """
    header = client.get("/").text
    header = header[header.index("<header") : header.index("</header>")]
    spacer = header.index("topbar-spacer")
    assert header.index("theme-toggle") < spacer, "the theme toggle drifted into the HUD"
    assert header.index('class="skip') > spacer, "Skip belongs on the game side"
    assert header.index("nav-toggle") < spacer, "the hamburger is chrome too"


def test_the_toggle_cycles_all_three_states(client):
    """One button, three states -- and the cycle has to be closed, or `auto` becomes unreachable
    after the first click and the OS-following default is lost for the session."""
    body = client.get("/").text
    toggle = found(r"<button[^>]*class=\"theme-toggle[^\"]*\"(.*?)</button>", body, re.DOTALL).group(1)
    click = re.search(r'data-on:click="([^"]+)"', toggle)
    assert click, "the toggle does nothing"
    for state in ("'auto'", "'light'", "'dark'"):
        assert state in click.group(1), f"{state} is not in the cycle: {click.group(1)}"


def test_the_toggle_says_which_state_it_is_in(client):
    """The glyph alone is a rebus -- especially `auto`, which is neither a sun nor a moon."""
    body = client.get("/").text
    toggle = found(r"<button[^>]*class=\"theme-toggle[^\"]*\"(.*?)</button>", body, re.DOTALL).group(1)
    assert "data-attr:aria-label" in toggle
    assert "$_theme" in found(r'data-attr:aria-label="([^"]+)"', toggle).group(1)


def test_the_toggle_needs_no_javascript_of_ours(client):
    """Same rule as the game-feel layer: datastar attributes and CSS, no helper script."""
    markup = re.sub(r"\{#.*?#\}", "", (TEMPLATE_DIR / "app.html.j2").read_text(encoding="utf-8"), flags=re.DOTALL)
    assert "<script" not in markup


@pytest.mark.parametrize("name", SHEETS)
def test_the_toggle_is_a_touch_target(name):
    """It sits between the score and Skip; a 24px target there is a mis-tap on the thing beside it."""
    css = stylesheet(name)
    rule = re.search(r"^\.theme-toggle\s*\{([^}]*)\}", css, re.MULTILINE)
    assert rule, f"{name}: the toggle is unstyled"
    assert "min-height: 32px" in rule.group(1)
    coarse = re.search(r"@media \(pointer: coarse\)\s*\{(.*?)\n\}", css, re.DOTALL)
    assert coarse, f"{name}: no coarse-pointer block"
    assert ".theme-toggle" in coarse.group(1), f"{name}: no bigger target on a touch screen"
