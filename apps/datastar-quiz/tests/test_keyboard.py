"""The keyboard path: digit accelerators, Enter on the reveal, and what may swallow a keystroke.

All of it is window-level keydown, which means every one of these handlers sees every keystroke on
the page -- so the interesting content is the GUARDS, and each of these tests pins one that was
wrong in a way no test caught: the shortcuts kept working in the happy path and went silently inert
in a state nobody thought to try.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import corpus
import render
import state

TEMPLATE_DIR = Path(render.__file__).resolve().parent / "templates"
_COMMENT = re.compile(r"\{#.*?#\}", re.DOTALL)


def markup_of(template: Path) -> str:
    """Template text without `{# ... #}` -- the comments quote the wrong forms on purpose."""
    return _COMMENT.sub("", template.read_text(encoding="utf-8"))


def window_keydown_handlers(markup: str) -> list[str]:
    return re.findall(r'data-on:keydown__window="([^"]+)"', markup, re.DOTALL)


@pytest.fixture(scope="module")
def quiz_body():
    return render.quiz_body(state.new_session(corpus.DEFAULT_VARIANT))


def test_one_digit_handler_for_the_whole_choice_group(quiz_body):
    """It was one per button: five registrations and five teardowns per patch, and five copies of
    the same guard to keep in step. The group maps the digit to an index instead."""
    handlers = window_keydown_handlers(quiz_body)
    assert len(handlers) == 1, f"expected one digit handler, found {len(handlers)}"
    assert 'class="candidates"' in quiz_body.replace("\n", " ") or "candidates" in quiz_body
    # and none of them hang off a button any more
    for tag in re.findall(r"<button\b[^>]*>", quiz_body, re.DOTALL):
        assert "keydown" not in tag, f"digit handler back on a button: {tag}"


def test_the_digit_range_matches_the_number_of_choices(quiz_body):
    """A hard-coded ceiling would either ignore a real choice or post an index the server rejects."""
    ceiling = re.search(r"Number\(evt\.key\) <= (\d+)", quiz_body)
    assert ceiling, "the digit handler does not bound the key against the choice count"
    assert int(ceiling.group(1)) == quiz_body.count('class="candidate button"')


def test_the_digit_handler_posts_the_index_not_the_digit(quiz_body):
    """The route is 0-indexed and the accelerators are 1-indexed; off by one is a wrong answer."""
    assert "(Number(evt.key) - 1)" in quiz_body


def test_the_digit_handler_still_refuses_while_an_answer_is_in_flight(quiz_body):
    """This guard looks like a cosmetic double-click block and is not.

    The server mutates before it streams, so once the toasts are playing the NEXT question is
    already the live one -- a keypress accepted here would answer a question the player has not
    been shown. Removing `$_answering` from this expression is the tempting fix for "the shortcuts
    feel dead for a moment"; it would silently score blind answers instead.
    """
    (handler,) = window_keydown_handlers(quiz_body)
    assert "!$_answering" in handler


def test_the_element_that_owns_the_digit_handler_owns_an_indicator_too(quiz_body):
    """`data-indicator` is per REQUESTING element, which is easy to miss when a handler moves.

    Moving the digit handler off the buttons and onto the group left the indicator behind on the
    buttons, so a keyboard answer set `_answering` for nobody: the choices never greyed out, and the
    in-flight guard above could never be true. Two quick digits then both posted, and the second
    answered the next question -- already live server-side -- before it had been rendered.
    """
    group = re.search(r"<div class=\"candidates\"(.*?)>", quiz_body, re.DOTALL)
    assert group, "no choice group in the rendered fragment"
    assert 'data-indicator="_answering"' in group.group(1)


def test_aria_busy_is_an_enumerated_string_not_a_boolean(quiz_body):
    """A boolean `true` renders as `aria-busy=""`, which is not a valid ARIA state -- it reads as
    neither busy nor idle. Also pins the object form: `data-attr:aria-busy` as a KEY is camel-cased
    to `ariaBusy` and never reaches the DOM at all."""
    assert "data-attr:aria-busy" not in quiz_body
    assert "'aria-busy': $_answering ? 'true' : 'false'" in quiz_body


@pytest.mark.parametrize("template", sorted(TEMPLATE_DIR.glob("*.j2")))
def test_window_keydown_guards_are_focus_aware(template):
    """`evt.target.tagName` only sees the exact element the event fired on.

    A `<select>` keeps focus after it is clicked, and Bulma wraps its selects in a `<div>`; the
    tagName form also misses a focused control inside any wrapper, and rich fields entirely. So the
    test is: exclude form controls with `closest`, never with a tagName list.

    ESCAPE is the exception, and deliberately: dismissing is global by convention -- a dialog closes
    on Escape whatever has focus inside it. A printable key is the opposite, which is what the rest
    of this file is about.
    """
    for handler in window_keydown_handlers(markup_of(template)):
        if "'Escape'" in handler:
            assert "closest" not in handler, f"{template.name}: Escape should dismiss regardless of focus"
            continue
        assert "closest" in handler, f"{template.name}: keydown guard is not focus-aware: {handler}"
        assert "INPUT" not in handler, f"{template.name}: tagName-list guard left in place: {handler}"


@pytest.mark.parametrize("template", ["quiz.html.j2", "reveal.html.j2", "app.html.j2"])
def test_the_quiz_stops_listening_while_the_picker_is_open(template):
    """A dialog on top of the quiz must take the keyboard with it.

    The topics picker is a non-modal `<dialog open>`, so nothing stops a window handler firing
    underneath it: with the picker open, `1` ANSWERED the question behind it, `s` spent a skip, and
    Enter on a ticked checkbox advanced the reveal. None of those keys reach a form control the guard
    would catch -- a checkbox has no claim on a digit, which is exactly why it was allowed through.
    """
    for handler in window_keydown_handlers(markup_of(TEMPLATE_DIR / template)):
        if "'Escape'" in handler:
            continue  # that one is the picker's own
        assert "!$_topicsOpen" in handler, f"{template}: fires while the picker is open: {handler}"


def test_only_controls_with_a_claim_on_the_key_swallow_it(quiz_body):
    """The guard was "any form control", and that killed the accelerators in ordinary use.

    A range input keeps focus after you click it -- it has to, or you could not arrow it -- so
    nudging the difficulty slider left 1-9 dead for the rest of the session. Same for a ticked
    checkbox. Neither has any use for a digit; a text box does, and `<select>` type-aheads.
    """
    (handler,) = window_keydown_handlers(quiz_body)
    assert "input:not([type=range]):not([type=checkbox]):not([type=radio])" in handler, handler
    for still_excluded in ("select", "textarea", "[contenteditable]"):
        assert still_excluded in handler, f"{still_excluded} should still swallow a digit"


def test_space_still_belongs_to_a_focused_checkbox():
    """The reveal's Enter/Space handler keeps a WIDER exclusion than the digits do, on purpose:
    Space activates a focused checkbox or radio, so one keystroke would both tick the box and
    advance the question. A range has no such claim on either key."""
    markup = markup_of(TEMPLATE_DIR / "reveal.html.j2")
    (handler,) = window_keydown_handlers(markup)
    assert "ACTIVATION_TARGETS" in handler, handler
    assert "TYPING_TARGETS" not in handler, "Space would then activate a checkbox AND advance"


def test_the_two_exclusion_lists_differ_only_where_they_should():
    """Both live in `render.py` so three templates cannot drift apart; this pins the difference."""
    assert "[type=range]" in render.TYPING_TARGETS
    assert "[type=checkbox]" in render.TYPING_TARGETS
    assert "[type=range]" in render.ACTIVATION_TARGETS
    assert "[type=checkbox]" not in render.ACTIVATION_TARGETS
    for shared in ("select", "textarea", "[contenteditable]"):
        assert shared in render.TYPING_TARGETS
        assert shared in render.ACTIVATION_TARGETS


def test_the_guards_are_rendered_not_left_as_template_variables():
    """A jinja global that is not in scope renders as the EMPTY STRING, and `closest('')` throws --
    which is how this landed the first time: the selector vanished and every keystroke was swallowed
    by the resulting error instead."""
    body = render.quiz_body(state.new_session(corpus.DEFAULT_VARIANT))
    assert "closest?.('')" not in body
    assert "TYPING_TARGETS" not in body, "the global did not resolve"


def test_a_control_hands_focus_back_when_its_interaction_ends():
    """The other half of the guard above, and the half a guard cannot fix: a focused text box is
    *supposed* to eat digits, so the accelerators can only come back when it lets go.

    The rule is about when an interaction is FINISHED. Picking a font finishes on change; pressing
    Enter in the filter box finishes on commit -- both hand focus back. Typing and arrowing do not
    finish, so `input` and the difficulty slider must never blur, or the control ejects you mid-use.
    """
    markup = markup_of(TEMPLATE_DIR / "app.html.j2")
    for select in re.findall(r"<select\b[^>]*>", markup, re.DOTALL):
        assert "evt.target.blur()" in select, f"appearance picker keeps focus: {select}"

    for control in re.findall(r'<input\b[^>]*type="range"[^>]*>', markup, re.DOTALL):
        assert "blur()" not in control, f"the slider must keep focus to be arrowed: {control}"

    for control in re.findall(r'<input\b[^>]*type="text"[^>]*>', markup, re.DOTALL):
        commit = re.search(r'data-on:keydown="([^"]*)"', control)
        assert commit, f"the filter box has no commit handler: {control}"
        assert "blur()" in commit.group(1), "committing a filter must hand focus back to the page"
        typing = re.search(r'data-on:input[^=]*="([^"]*)"', control)
        assert typing, f"the filter box does not preview as you type: {control}"
        assert "blur()" not in typing.group(1), "blurring per keystroke would eject you after one"


def test_returning_to_the_question_takes_the_keyboard_back_from_the_notes():
    """The reported "the shortcuts randomly stop working", reproduced in firefox and chrome alike:
    click inside the System Notes to scroll them, come back to the quiz, and 1-9 do nothing while
    the mouse still works.

    Nothing here is broken when that happens. The notes are a cross-origin `<iframe>`, so a click
    inside them moves focus to ANOTHER DOCUMENT, and every accelerator in this app is a `__window`
    listener on ours -- the keys are delivered, just not to us. No guard we own can see it
    (`$_answering`, `$_topicsOpen` and the qid are all healthy), and the mouse is unaffected because
    a click is delivered by position rather than by focus.

    So the pointer arriving back on the question -- the gesture that means "I am playing again" --
    takes focus back. Deliberately narrow: only when an IFRAME is what holds it, so a half-typed
    filter box or a slider mid-arrow is left alone.
    """
    markup = markup_of(TEMPLATE_DIR / "app.html.j2")
    card = re.search(r"<section class=\"card\" id=\"quiz\"(.*?)>", markup, re.DOTALL)
    assert card, "no quiz card"
    reclaim = re.search(r'data-on:mouseenter="([^"]+)"', card.group(1), re.DOTALL)
    assert reclaim, "coming back to the question does not reclaim the keyboard"
    expression = reclaim.group(1)
    assert "IFRAME" in expression, "the guard must name what it takes focus from"
    assert "blur()" in expression
    assert "window.focus()" in expression, "blurring the iframe is not the same as focusing us"
