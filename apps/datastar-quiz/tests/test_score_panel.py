"""The score panel's readouts.

The points bar used to carry a "% of goal" label inside it, with the milestone lines running
straight through the text — two things competing for the same 1.6rem. The number now sits above the
bar as a fraction, and the bar carries only the notches.
"""

from __future__ import annotations

import re

import corpus
import engine
import render
import state


def shell_markup() -> str:
    return render.shell(state.new_session(corpus.DEFAULT_VARIANT))


def test_points_are_shown_as_a_fraction_of_the_goal():
    body = shell_markup()
    assert f"/ {engine.POINTS_GOAL}" in body
    assert 'data-text="$_points"' in body


def test_nothing_is_overlaid_on_the_points_bar():
    body = shell_markup()
    assert "meter-label" not in body
    css = (render.TEMPLATE_DIR.parent / "static" / "app.css").read_text(encoding="utf-8")
    assert ".meter-label" not in css  # the rule went with the markup


def test_a_notch_per_milestone_below_the_goal():
    """The end of the bar already is the goal, so the 100% milestone gets no notch."""
    body = shell_markup()
    notches = re.findall(r'class="meter-tick"[^>]*left:\s*(\d+)%', body)
    expected = [str(round(m * 100)) for m in engine.SCORE_MILESTONES if m < 1]
    assert notches == expected
    assert "100%" not in [f"{n}%" for n in notches]


def test_notches_mark_themselves_earned():
    body = shell_markup()
    for milestone in engine.SCORE_MILESTONES:
        if milestone < 1:
            pct = round(milestone * 100)
            assert f"{{earned: $_pointsPct >= {pct}}}" in body


def test_points_gradient_spans_the_track_not_the_fill():
    """A colour must mean the same score wherever the bar has reached.

    The gradient was originally painted on the growing fill element, so the whole red-to-green ramp
    was squeezed into whatever had been earned: at 100/1000 points the bar was already fully green.
    The track carries the gradient now, and a mask covers the unearned remainder.
    """
    css = (render.TEMPLATE_DIR.parent / "static" / "app.css").read_text(encoding="utf-8")
    body = shell_markup()

    # the gradient is on the track
    track = re.search(r"\.points-meter\s*\{([^}]*)\}", css)
    assert track, "no .points-meter rule"
    assert "linear-gradient" in track.group(1)

    # nothing whose width is driven by the score carries a gradient
    assert "meter-fill" not in css
    assert "meter-fill" not in body

    # and the mask shrinks as points grow, rather than a fill growing
    assert "data-style:width=\"(100 - $_pointsPct) + '%'\"" in body
    mask = re.search(r"\.meter-mask\s*\{([^}]*)\}", css)
    assert mask, "no .meter-mask rule"
    assert "right: 0" in mask.group(1)
    assert "linear-gradient" not in mask.group(1)
