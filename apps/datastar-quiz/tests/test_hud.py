"""Where each control lives, and why.

The sidebar used to mix three unrelated kinds of thing: live state (the score), an in-play action
(Skip), and configuration (difficulty, filter, target, Restart). Two consequences, both real:

* the score was rendered **twice** -- once in the app bar, once in a `#score` panel below it;
* spending a skip meant opening a settings drawer, because Skip sat next to the controls that
  *restart the quiz*.

Sorted by when you touch it: live state and Skip are in the HUD (always visible), everything that
restarts the quiz is in the drawer, and the drawer starts closed. These tests pin that split, because
it is the kind of thing a later "just add one more panel" quietly undoes.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from litestar.testing import TestClient
from markup import found

import app as app_module
import corpus
import engine
import render
import state


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


def markup() -> str:
    return render.shell(state.new_session(corpus.DEFAULT_VARIANT))


def topbar_of(body: str) -> str:
    return body[body.index('<header class="topbar"') : body.index("</header>")]


def sidebar_of(body: str) -> str:
    return body[body.index('<aside class="sidebar"') : body.index("</aside>")]


# --- the HUD carries live state and the one in-play action --------------------


def test_skip_is_in_the_hud_not_the_drawer():
    """The bug this fixes: spending a skip required opening the settings drawer."""
    body = markup()
    assert 'class="skip' in topbar_of(body)
    assert "/skip" not in sidebar_of(body)


def test_skip_keeps_its_count_visible():
    """`Skip 3` rather than `Skip` and a separate "3 left" line -- one glance, one element."""
    topbar = topbar_of(markup())
    assert 'class="skip-count"' in topbar
    assert 'data-text="$_skipsLeft"' in topbar


def test_skip_has_a_keyboard_accelerator_with_the_same_guards_as_the_digits():
    """A window handler does not inherit the button's `disabled`, so it restates the conditions."""
    topbar = topbar_of(markup())
    handler = re.search(r'data-on:keydown__window="([^"]+)"', topbar)
    assert handler, "no keyboard accelerator for skip"
    expression = handler.group(1)
    assert "evt.key === 's'" in expression
    assert "$_skipsLeft > 0" in expression, "the button is disabled at zero; the key must be too"
    assert "$_playing" in expression
    assert "!$_answering" in expression, "no skipping mid-answer, same as the digits"
    assert "closest" in expression, "and not while typing in the filter box"


def test_the_points_gauge_is_in_the_hud_with_its_milestone_notches():
    """The notches are why it earns HUD space: each one is a skip you can earn."""
    topbar = topbar_of(markup())
    assert "hud-meter" in topbar
    assert topbar.count('class="meter-tick"') == len([m for m in engine.SCORE_MILESTONES if m < 1])


def test_the_score_is_no_longer_rendered_twice():
    """It was in the app bar AND in a sidebar panel: the same numbers, maintained in two places."""
    body = markup()
    assert 'id="score"' not in body
    assert 'id="skips"' not in body
    assert body.count('data-text="$_correct"') == 2, "once in the HUD, once in the folded dial group"


# --- the drawer is only things that restart the quiz -------------------------


def test_the_drawer_starts_closed(client):
    """It holds difficulty, the filter, topics, ladder mode, the target, Restart and Appearance --
    every one of which restarts the quiz or is a one-off preference. It was also the tallest thing on
    the page, which is what used to make the whole document scroll."""
    body = client.get("/").text
    assert "$_navOpen = false" in body
    assert render.local_ui_signals()["_navOpen"] is False, "or it flashes open before data-init runs"


def test_the_dial_moved_into_a_folded_group():
    """Kept because it is pleasant, folded because it spends a lot of space on one number."""
    sidebar = sidebar_of(markup())
    progress = re.search(r"<details[^>]*class=\"panel box progress\"[^>]*>", sidebar)
    assert progress, "no Progress group in the drawer"
    assert 'class="dial"' in sidebar
    # closed by default -- the server never renders `open`; when the PLAYER opens it,
    # `data-preserve-attr` is what stops the next morph closing it again
    assert " open" not in progress.group(0), progress.group(0)
    assert 'data-preserve-attr="open"' in progress.group(0), progress.group(0)


@pytest.mark.parametrize("sheet", ["app.css", "app-pico.css", "app-bulma.css"])
def test_the_hud_sheds_the_gauge_before_the_score_on_narrow_screens(sheet):
    """The app bar is where running out of width is likely, so the order matters: the gauge goes
    first (the points number says the same thing less precisely), and Skip never goes at all."""
    css = (render.TEMPLATE_DIR.parent / "static" / sheet).read_text(encoding="utf-8")
    hidden = re.search(r"@media \(max-width: 760px\) \{\s*\.hud-meter \{\s*display: none;", css)
    assert hidden, f"{sheet}: the HUD gauge does not drop on a narrow screen"
    assert ".topbar .skip {\n    display: none" not in css, f"{sheet}: Skip must never be hidden"


def test_the_streak_chip_says_what_it_counts(client):
    """A bare "3x" is a rebus, and the panel that used to explain it (`Progress`) is collapsed by
    default -- so the app bar has to stand on its own. The word is dropped under 560px where there is
    no room for it, which is exactly why the `aria-label` carries the meaning independently."""
    body = client.get("/").text
    chip = re.search(r'<span class="streak"(.*?)</span>\s*\n', body, re.DOTALL)
    assert chip, "no streak chip"
    assert "streak" in chip.group(1), "the chip does not say what it is"
    label = re.search(r'data-attr:aria-label="([^"]+)"', chip.group(1))
    assert label, "the chip has no accessible name"
    assert "$_streak" in label.group(1), label.group(1)

    juice = (Path(render.__file__).resolve().parent / "static" / "juice.css").read_text(encoding="utf-8")
    narrow = juice[juice.index("@media (max-width: 560px)") :]
    assert ".streak-label" in narrow, "the word should fold away where the bar is tight"


def test_restart_closes_the_drawer_only_where_it_covers_the_quiz(client):
    """Below 900px the drawer is a fixed overlay ON TOP of the quiz, so an explicit "start again"
    that leaves it open makes you tap twice to see the new question. Above it the drawer is a column
    beside the quiz, and closing it would only take the controls away -- so the behaviour is
    conditional, client-side, and off the same media query the CSS repositions with.

    Only the explicit button: the sliders and checkboxes restart the quiz too, and you may be
    adjusting several of them in a row.
    """
    body = client.get("/").text
    restart = re.search(r"<button[^>]*>Restart</button>", body, re.DOTALL)
    assert restart, "no Restart button"
    handler = found(r'data-on:click="([^"]+)"', restart.group(0), re.DOTALL).group(1)
    assert "/restart" in handler
    assert "$_navOpen = false" in handler, "restarting leaves the drawer over the quiz on a phone"
    assert render.DRAWER_OVERLAY_QUERY in handler, "the width test must come from the shared constant"


@pytest.mark.parametrize("sheet", ["app.css", "app-pico.css", "app-bulma.css"])
def test_the_drawer_breakpoint_agrees_with_the_stylesheet(sheet):
    """The constant only works if it names the width the CSS actually switches at. Two numbers that
    have to agree and live in different files are a drift waiting to happen -- so this reads both."""
    css = (Path(render.__file__).resolve().parent / "static" / sheet).read_text(encoding="utf-8")
    overlay = re.search(rf"@media {re.escape(render.DRAWER_OVERLAY_QUERY)}\s*\{{(.*?)\n\}}", css, re.DOTALL)
    assert overlay, f"{sheet}: no @media {render.DRAWER_OVERLAY_QUERY} block"
    assert re.search(r"\.sidebar\s*\{[^}]*position:\s*fixed", overlay.group(1)), (
        f"{sheet}: the drawer is not an overlay at that width, so closing it would be wrong"
    )
