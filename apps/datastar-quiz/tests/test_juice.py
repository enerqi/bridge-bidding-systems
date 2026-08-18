"""The "game feel" experiment: hit-stop and shake, floating score, escalating streak.

Three properties are worth pinning, and they are the ones that would rot quietly:

* **it is genuinely optional** — every rule is scoped to `body.juice`, so with the toggle off the app
  renders exactly as it did. A single unscoped rule in `juice.css` would make it a fourth stylesheet
  variant by accident, on for everyone, and nothing would fail.
* **the floater and the toast agree** — the number over the card is derived from the toast's own text
  rather than recomputed, so they cannot drift.
* **the effects stay in CSS** — the temptation with game feel is a helper script. Nothing here needs
  one, and the test says so.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from litestar.testing import TestClient

import app as app_module
import engine
import render

STATIC = Path(render.__file__).resolve().parent / "static"
JUICE = (STATIC / "juice.css").read_text(encoding="utf-8")


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


# --- optional by construction ------------------------------------------------


def test_the_signal_is_declared_and_local():
    """Local (`_`-prefixed): a presentation preference the server has no opinion about, and one it
    never learns -- which is exactly why the floaters are streamed unconditionally."""
    assert render.local_ui_signals()["_juice"] is True


def test_the_stylesheet_is_loaded_after_the_base_sheet(client):
    body = client.get("/").text
    assert '<link rel="stylesheet" href="/static/juice.css" />' in body
    base = render.stylesheet_href(render.DEFAULT_CSS)
    assert body.index("juice.css") > body.index(f'href="{base}"')
    assert client.get("/static/juice.css").status_code == 200


def test_the_body_carries_the_class_the_stylesheet_hangs_off(client):
    """On `<body>`, outside the morph target, or it would be re-evaluated on every patch."""
    assert 'data-class="{juice: $_juice}"' in client.get("/").text


def selectors_of(css: str) -> list[str]:
    """Every selector in the file, ignoring at-rule blocks (`@keyframes`, `@media`) and comments."""
    without_comments = re.sub(r"/\*.*?\*/", "", css, flags=re.DOTALL)
    # drop the bodies of at-rules, keeping the selectors they contain out of scope-checking:
    # `@media (prefers-reduced-motion)` is allowed to restate the same selectors
    depth = 0
    out, current = [], ""
    for char in without_comments:
        if char == "{":
            depth += 1
            if depth == 1:
                out.append(current.strip())
            current = ""
        elif char == "}":
            depth -= 1
            current = ""
        elif depth == 0:
            current += char
    return [s for s in out if s and not s.startswith("@")]


def test_every_rule_is_scoped_to_the_toggle():
    """The property that makes this an experiment rather than a redesign.

    Three exceptions, all of which *hide* an element the server always streams: without them the
    floaters, the streak chip and the confetti would be visible with the experiment off.
    """
    hide_only = {".floater", ".streak", ".confetti"}
    for selector in selectors_of(JUICE):
        parts = [part.strip() for part in selector.split(",")]
        for part in parts:
            assert part in hide_only or "body.juice" in part, f"unscoped rule: {selector}"


def test_the_unscoped_rules_only_hide():
    """...and they must really only hide, or "off" would still change the layout."""
    without_comments = re.sub(r"/\*.*?\*/", "", JUICE, flags=re.DOTALL)
    for selector in (".floater", ".streak", ".confetti"):
        body = re.search(rf"^{re.escape(selector)}\s*\{{([^}}]*)\}}", without_comments, re.MULTILINE)
        assert body, selector
        declarations = [d.strip() for d in body.group(1).split(";") if d.strip()]
        assert declarations == ["display: none"], declarations


def test_motion_is_reducible():
    """Shake and float are exactly what `prefers-reduced-motion` exists for. The floater must stay
    visible though -- it carries a number, and the animation is not the message."""
    assert "@media (prefers-reduced-motion: reduce)" in JUICE
    reduced = JUICE[JUICE.index("@media (prefers-reduced-motion: reduce)") :]
    assert "animation: none" in reduced
    assert "opacity: 1" in reduced, "the floater should stop moving, not disappear"


# --- the countdown gets urgent -----------------------------------------------


def test_the_last_band_is_red_and_throbs():
    """`.spent` paints the bar grey in all three sheets, which read as "the timer is over" -- but the
    time bonus is continuous, so there are points on the table right down to zero."""
    assert "juice-timer-throb" in JUICE
    rule = re.search(r"body\.juice \.timer-fill\.spent\.ticking\s*\{([^}]*)\}", JUICE)
    assert rule, "no urgency rule for the last band"
    assert "var(--suit-heart)" in rule.group(1), "urgency should use the app's own red, not a new one"
    assert "animation" in rule.group(1)


def test_the_track_carries_the_alarm_so_an_empty_bar_still_says_something():
    """At 0% the fill has no width to animate; `.timer` glows instead. `overflow: hidden` clips the
    children, not the element's own shadow."""
    assert re.search(r"body\.juice \.timer:has\(\.timer-fill\.spent\.ticking\)\s*\{[^}]*animation", JUICE)


def test_the_throb_stops_when_the_clock_does():
    """`.ticking` on every urgency selector. Without it a bar frozen in the last band keeps throbbing
    behind the reveal -- time pressure on a question that has already been answered."""
    for selector in selectors_of(JUICE):
        if "timer" in selector:
            assert ".ticking" in selector, f"ungated timer rule: {selector}"


def test_the_bar_reports_whether_the_clock_is_running(client):
    """The class the rules above hang off, on the fill, from the two signals that already exist."""
    body = client.get("/").text
    # not `<div class="timer-fill"[^>]*>`: the band expressions contain `>` themselves
    fill = re.search(r'<div class="timer-fill".*?data-class="([^"]*)"', body, re.DOTALL)
    assert fill, "no timer fill"
    assert "ticking: $_ticking && !$_answering" in fill.group(1)


def test_the_urgency_colour_survives_reduced_motion():
    """The beat is how loudly it is said; the red is the information."""
    reduced = JUICE[JUICE.index("@media (prefers-reduced-motion: reduce)") :]
    assert ".timer-fill.spent.ticking" in reduced
    assert "box-shadow" in reduced, "the alarm should still be visible, just still"


# --- the milestone sweep -----------------------------------------------------


def test_the_sweep_crosses_the_gauge_and_is_clipped_to_it():
    """A pass, not a fade: it starts and ends off the ends of the bar, and `.meter` is
    `overflow: hidden` in all three base sheets, so the bar does the clipping."""
    rule = re.search(r"body\.juice \.meter-sweep\s*\{([^}]*)\}", JUICE)
    assert rule, "no sweep rule"
    assert "position: absolute" in rule.group(1)
    assert "animation: juice-meter-sweep" in rule.group(1)
    frames = re.search(r"@keyframes juice-meter-sweep\s*\{(.*?)\n\}", JUICE, re.DOTALL)
    assert frames
    assert "translateX(-120%)" in frames.group(1), "the shine should begin off the left end"


def test_the_shine_is_white_rather_than_a_colour():
    """The track is a red-to-green gradient, so a tinted shine would read as a different SCORE on
    the way past."""
    rule = re.search(r"body\.juice \.meter-sweep\s*\{([^}]*)\}", JUICE)
    assert rule
    assert "rgb(255 255 255" in rule.group(1)
    for token in ("--suit-", "--primary", "green", "gold"):
        assert token not in rule.group(1), token


def test_the_sweep_has_a_still_version():
    """Unlike the marks and floaters there is no state left behind when it finishes -- travel is all
    it is -- so reduced motion gets a brief flush of the bar instead of a frozen streak."""
    reduced = JUICE[JUICE.index("@media (prefers-reduced-motion: reduce)") :]
    assert ".meter-sweep" in reduced
    assert "juice-meter-flush" in reduced


def test_the_sweep_is_only_ever_appended_to_the_gauge():
    assert app_module.METER_SELECTOR.endswith(".points-meter")
    assert app_module.METER_SELECTOR.startswith(app_module.APP_SELECTOR)


def test_no_javascript_was_added_for_any_of_it():
    """Game feel is a CSS problem here. A `<script>` of ours would be the thing to argue about."""
    templates = Path(render.__file__).resolve().parent / "templates"
    for template in templates.glob("*.j2"):
        markup = re.sub(r"\{#.*?#\}", "", template.read_text(encoding="utf-8"), flags=re.DOTALL)
        assert "<script" not in markup or "datastar.js" in markup


# --- the floater says what the toast says ------------------------------------


@pytest.mark.parametrize(
    ("text", "expected", "kind"),
    [
        ("+22!", "+22", "gain"),
        ("Streak 3, Bonus +15", "+15", "gain"),
        ("Time Bonus +15", "+15", "gain"),
        ("Ladder mode: -30 points", "-30", "loss"),
        ("+1 SKIP!", "+1 SKIP", "gain"),
    ],
)
def test_a_scoring_beat_floats_its_own_number(text, expected, kind):
    out = render.floater(engine.Toast("info", text, 0.5))
    assert f">{expected}<" in out
    assert f'class="floater {kind}"' in out


@pytest.mark.parametrize("text", ["Correct!", "Not quite", "", "Current score 40%, target score 70%"])
def test_beats_without_a_score_float_nothing(text):
    """The tick and the cross already say correct/wrong; a percentage is not something you *won*."""
    assert render.floater(engine.Toast("info", text, 0.5)) == ""


# --- streamed at the card that was actually chosen ---------------------------


def test_the_floater_is_appended_to_the_card_the_player_picked(client):
    """The choice is in the URL the handler was called on, so the server can aim without being told.

    `nth-child(index + 1)`: CSS is 1-indexed and the route is 0-indexed, which is exactly the kind of
    off-by-one that would land the number on the wrong card and look like a rendering bug.
    """
    client.get("/")
    session = app_module.STORE.get(client.cookies["dsq_sid"])
    assert session is not None
    # the CORRECT index, deliberately: a first wrong answer scores nothing, so it has no number to
    # float and the test would pass or fail on which question was drawn
    picked = session.question.candidates.index(session.question.answer_candidate)

    body = client.post(f"/answer/{session.qid}/{picked}", content="{}").text

    assert f"selector #quiz .candidates > :nth-child({picked + 1})" in body
    assert "mode append" in body
    assert 'class="floater gain"' in body


def test_a_wrong_first_answer_floats_nothing(client):
    """Nothing was scored, so there is no number -- the cross on the card is the whole message."""
    client.get("/")
    session = app_module.STORE.get(client.cookies["dsq_sid"])
    assert session is not None
    wrong = next(i for i, c in enumerate(session.question.candidates) if c != session.question.answer_candidate)

    body = client.post(f"/answer/{session.qid}/{wrong}", content="{}").text

    assert 'class="floater' not in body
    # ...and nothing was aimed at the card either. Not "no append anywhere in the stream": the sound
    # beats append to `#sfx`, and a wrong answer has one (see test_sound.py).
    assert "selector #quiz .candidates" not in body


def test_the_selector_helper_is_one_indexed():
    assert app_module._picked_card_selector(0).endswith(":nth-child(1)")
    assert app_module._picked_card_selector(4).endswith(":nth-child(5)")


# --- the streak chip ---------------------------------------------------------


def test_the_streak_chip_grows_and_warms(client):
    body = client.get("/").text
    chip = re.search(r'<span class="streak".*?&times;', body, re.DOTALL)
    assert chip, "no streak chip in the app bar"
    markup = chip.group(0)
    # the growth is a transitioned transform driven by the signal, not a keyframe
    assert "data-style:transform" in markup
    assert "Math.min($_streak, 8)" in markup, "an uncapped scale eventually reflows the app bar"
    # and the bands
    assert "hot: $_streak >= 3" in markup
    assert "blazing: $_streak >= 6" in markup
    assert "cold: $_streak < 1" in markup
    assert "transition:" in JUICE


def test_the_streak_arrives_with_the_first_beat(client):
    """Not with the view patch at the end of the stream.

    The chip is the reward for the answer just given; two or three seconds of toasts later it reads as
    belonging to the *next* question. So `_streak` is patched before the first toast, and the rest of
    the score follows at its own pace.
    """
    client.get("/")
    session = app_module.STORE.get(client.cookies["dsq_sid"])
    assert session is not None
    picked = session.question.candidates.index(session.question.answer_candidate)

    body = client.post(f"/answer/{session.qid}/{picked}", content="{}").text

    first_streak = body.index('"_streak"')
    first_toast = body.index("selector #toasts")
    assert first_streak < first_toast, "the streak should land before the first toast, not after"


# --- the finale --------------------------------------------------------------


@pytest.fixture
def finished(client):
    """A session that has just crossed the points goal."""
    import engine as engine_module

    client.get("/")
    session = app_module.STORE.get(client.cookies["dsq_sid"])
    assert session is not None
    session.score.total_points = engine_module.POINTS_GOAL - 1
    correct = session.question.candidates.index(session.question.answer_candidate)
    body = client.post(f"/answer/{session.qid}/{correct}", content="{}").text
    assert not session.still_playing
    return session, body


def test_the_finale_numbers_its_own_pieces(finished):
    """CSS cannot count, so the server does: `--i` is what staggers the pops, the confetti and the
    digits. A piece without an index animates in lockstep with its neighbours, which is the difference
    between an event and a page load."""
    _, body = finished
    page = body[body.index('class="finale"') :]
    for cls in ("pop", "confetti-bit", "digit"):
        pieces = re.findall(rf'class="{cls}" style="([^"]*)"', page)
        assert pieces, f"no {cls} in the finale"
        assert all("--i:" in style for style in pieces), f"{cls} is not numbered"


def test_the_numbers_are_assembled_from_characters(finished):
    """One span per character -- that is what lets them fly in from different directions."""
    session, body = finished
    for value in (session.score.total_points, session.score.percentage()):
        digits = "".join(re.findall(r'class="digit"[^>]*>(.)</span>', body))
        for ch in str(value):
            assert ch in digits, f"{value} is not present digit by digit"


def test_the_confetti_is_fixed_rather_than_random():
    """The server renders this screen, so a reload should show the same party, not re-roll it.

    Also: the offsets are spread by hand. A formula (`i * 37 % 100`) produces a visibly combed burst,
    which is the sort of thing that looks fine in code review and wrong on screen.
    """
    assert len(render._CONFETTI) >= 12
    drifts = [drift for _, drift, _, _ in render._CONFETTI]
    assert len(set(drifts)) == len(drifts), "two bits share a drift; the burst will look paired"
    assert min(drifts) < -20, "the burst should reach the left"
    assert max(drifts) > 20, "the burst should reach the right"


def test_the_goal_crossing_floater_is_marked_final(finished):
    """Gold, bigger, slower -- the last number the player sees on a card."""
    _, body = finished
    assert 'class="floater gain final"' in body


def test_an_ordinary_correct_answer_is_not_final(client):
    client.get("/")
    session = app_module.STORE.get(client.cookies["dsq_sid"])
    assert session is not None
    correct = session.question.candidates.index(session.question.answer_candidate)
    body = client.post(f"/answer/{session.qid}/{correct}", content="{}").text
    assert 'class="floater gain"' in body
    # not a bare `"final" not in body`: the question prompt itself says "the final bid"
    assert 'class="floater gain final"' not in body


def test_the_gauge_celebrates_itself_at_the_goal(client):
    """No extra server signal: the percentage it already sends is the condition."""
    assert 'data-class="{full: $_pointsPct >= 100}"' in client.get("/").text


def test_the_finale_survives_reduced_motion_with_its_numbers_intact():
    """The confetti goes, the numbers stay. Sixteen emoji frozen over the page is worse than none."""
    reduced = JUICE[JUICE.index("@media (prefers-reduced-motion: reduce)") :]
    assert "body.juice .digit" in reduced
    assert "body.juice .confetti" in reduced
    assert "display: none" in reduced


def test_the_float_distance_is_a_variable_not_a_constant():
    """The card it rises out of is 103px tall on a desktop and 48px on a phone.

    At a fixed -68px the number climbed clear of its own card and landed on the one ABOVE it -- measured
    at 390x844, where the choices are one per row. Keyframes cannot be parameterised any other way, so
    the distance is a custom property the phone block overrides.
    """
    assert "var(--float-rise" in JUICE, "the rise is hard-coded in the keyframe"
    phone = JUICE[JUICE.index("@media (max-width: 560px)") :]
    assert "--float-rise" in phone, "nothing shrinks the rise on a phone"
    assert "font-size: 1.15rem" in phone, "a 1.6rem number is too big for a 48px card"


def test_several_beats_spread_sideways_on_a_phone():
    """The rising column only works when there is room above the card, which on a phone there is not."""
    phone = JUICE[JUICE.index("@media (max-width: 560px)") : JUICE.index("/* --- 3. streak chip")]
    assert "left: 28%" in phone
    assert "left: 72%" in phone
