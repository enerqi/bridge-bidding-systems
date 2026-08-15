"""The two countdown push models, which are the point of the whole port.

`client` (default): the browser walks the bar down from an allowance stated once per question.
`stream` (`DSQUIZ_TIMER=stream`): a held SSE connection pushes the value every tick, which is what
panel did over its websocket. Exactly one of the two is ever wired into the page.
"""

from __future__ import annotations

import pytest
from litestar.testing import TestClient

import app as app_module
import render

# The one file that needs the app's real `asyncio.sleep`: the held stream ticks on it against a
# wall-clock deadline, so the suite-wide no-sleep fixture (`conftest._skip_toast_pacing`) would turn
# its loop into a spin. Everything else is faster without it.
pytestmark = pytest.mark.real_pacing


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


@pytest.fixture
def stream_mode(monkeypatch):
    monkeypatch.setattr(app_module, "TIMER_MODE", "stream")
    # keep the held stream short enough to assert on
    monkeypatch.setattr(app_module, "TIMER_STREAM_MAX_SECONDS", 0.35)
    monkeypatch.setattr(app_module, "TIMER_TICK_SECONDS", 0.05)


def test_default_mode_is_the_client_interval(client):
    assert app_module.TIMER_MODE == "client"
    body = client.get("/").text
    assert "data-on-interval__duration.100ms" in body
    assert "@get('/timer?squad')" not in body


def test_stream_mode_wires_the_connection_instead(client, stream_mode):
    body = client.get("/").text
    assert "@get('/timer?squad')" in body
    # the two must never both be live, or the bar is driven from both ends
    assert "data-on-interval" not in body


def test_timer_route_is_inert_in_client_mode(client):
    client.get("/")
    assert client.get("/timer").status_code == 204


def test_timer_route_streams_signal_patches(client, stream_mode):
    client.get("/")

    with client.stream("GET", "/timer") as response:
        assert response.status_code == 200
        body = "".join(response.iter_text())

    frames = body.count("event: datastar-patch-signals")
    assert frames >= 2, body[:400]
    assert "_timeLeftPct" in body
    # only the timer signal travels -- a tick must not re-send the whole score panel
    assert "_points" not in body
    assert "datastar-patch-elements" not in body


def test_stream_stops_when_the_quiz_is_over(client, stream_mode):
    client.get("/")
    session = app_module.STORE.get(client.cookies["dsq_sid"])
    assert session is not None
    session.complete()

    with client.stream("GET", "/timer") as response:
        body = "".join(response.iter_text())

    # one final zero, then the generator returns rather than ticking on a finished quiz
    assert body.count("event: datastar-patch-signals") == 1
    assert '"_timeLeftPct":0' in body.replace(" ", "")


def test_render_reads_the_mode_lazily(monkeypatch):
    monkeypatch.setattr(app_module, "TIMER_MODE", "stream")
    assert render.timer_mode() == "stream"


# --- the clock stops when the question is answered ---------------------------
#
# It did not: the interval gated on `$_playing`, which is only false once the whole quiz is over, so
# the bar kept draining after an answer was scored -- running down to empty behind the revealed
# answer, and through the 2.5-3.5s of toasts on a correct one. Time pressure on a question that was
# already decided.


def test_the_client_interval_only_runs_while_a_question_is_being_timed(client):
    body = client.get("/").text
    expression = body.split('data-on-interval__duration.100ms="')[1].split('"')[0]
    assert "$_ticking" in expression
    assert "$_answering" in expression, "the click-to-patch window is part of 'already answered'"
    assert "$_playing ?" not in expression, "playing is the whole quiz, not this question"


def test_answering_freezes_the_clock_rather_than_letting_it_run(client):
    """Time is simulated by moving `question_start` back, NOT by patching `time.monotonic`.

    Patching the module attribute patches it for asyncio too -- a frozen clock means `asyncio.sleep`
    never returns, and the whole suite hangs rather than fails.
    """
    client.get("/")
    session = app_module.STORE.get(client.cookies["dsq_sid"])
    assert session is not None

    # a quarter of the allowance has gone
    session.question_start -= session.question_seconds * 0.25
    at_answer = session.percent_time_left()
    assert 60 <= at_answer <= 80, at_answer

    client.post(f"/answer/{session.qid}/{_wrong_index(session)}", content="{}")
    assert session.awaiting_next

    # the player reads the reveal for another long while
    session.question_start -= session.question_seconds * 0.65
    assert session.percent_time_left() == at_answer
    assert render.signals(session)["_timeLeftPct"] == at_answer
    assert render.signals(session)["_ticking"] is False

    # and the next question starts a fresh, running clock
    client.post("/next", content="{}")
    assert session.frozen_time_left is None
    assert render.signals(session)["_ticking"] is True


def test_the_stream_holds_its_value_while_parked_on_a_reveal(client, stream_mode):
    client.get("/")
    session = app_module.STORE.get(client.cookies["dsq_sid"])
    assert session is not None
    session.awaiting_next = True
    session.freeze_question_clock()

    with client.stream("GET", "/timer") as response:
        body = "".join(response.iter_text())

    # nothing to say: the value cannot change until a new question is served
    assert body.count("event: datastar-patch-signals") == 0, body[:300]


def _wrong_index(session) -> int:
    """An index that is not the answer, so the session parks on the reveal."""
    candidates = session.question.candidates
    return next(i for i, c in enumerate(candidates) if c != session.question.answer_candidate)
