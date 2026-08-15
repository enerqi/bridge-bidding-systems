"""Route tests over the real app, asserting the SSE wire format.

The toast pacing is real `asyncio.sleep` in production; the suite patches it out
(`conftest._skip_toast_pacing`), so a test answers a question in milliseconds instead of the ~3
seconds a human sees.
"""

from __future__ import annotations

import pytest
from litestar.testing import TestClient

import app as app_module
import engine
import state


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        # every fetch datastar makes carries this header, and `read_signals` returns None
        # without it -- so a client that omits it is not exercising the real request shape
        test_client.headers.update({"Datastar-Request": "true"})
        test_client.get("/")  # establishes the session cookie
        yield test_client


def _session(client: TestClient) -> state.Session:
    session = app_module.STORE.get(client.cookies[state.SESSION_COOKIE])
    assert session is not None, "the fixture's GET / should have created one"
    return session


def test_index_is_a_complete_page(client):
    response = client.get("/")
    assert response.status_code == 200
    body = response.text
    # server-rendered state, not a bootstrap shell
    assert 'id="quiz"' in body
    assert "data-signals=" in body
    assert 'src="/static/datastar.js"' in body  # vendored, not the CDN
    assert client.cookies[state.SESSION_COOKIE]


def test_answer_streams_elements_and_signals(client):
    session = _session(client)
    question = session.question
    qid = session.qid
    correct_index = question.candidates.index(question.answer_candidate)

    response = client.post(f"/answer/{qid}/{correct_index}")

    assert response.status_code == 200
    assert "event: datastar-patch-elements" in response.text
    assert "event: datastar-patch-signals" in response.text
    assert "selector #app" in response.text  # fat morph: the whole page below <body>
    assert session.score.questions_correct == 1
    assert session.score.questions_attempted == 1
    assert session.qid != qid  # nonce moved on with the question


def test_new_question_clock_starts_when_it_reaches_the_player(client):
    session = _session(client)
    correct_index = session.question.candidates.index(session.question.answer_candidate)

    response = client.post(f"/answer/{session.qid}/{correct_index}")

    # the notification sequence runs for seconds before the next question is patched in; the
    # allowance must not have been ticking through it
    assert session.percent_time_left() == 100
    assert '"_timeLeftPct":100' in response.text.replace(" ", "")


def test_stale_qid_scores_nothing_and_resyncs_the_page(client):
    """It used to be a bare 204. Correct as far as scoring goes, and useless from the player's
    chair: the button is dead and the page is still showing the question that moved on, so the
    next click is stale too. It now re-renders the page from the session that actually exists."""
    session = _session(client)
    qid = session.qid
    correct_index = session.question.candidates.index(session.question.answer_candidate)

    first = client.post(f"/answer/{qid}/{correct_index}")
    assert first.status_code == 200

    # the same click again -- a double click, a replay, or a stale tab
    second = client.post(f"/answer/{qid}/{correct_index}")
    assert second.status_code == 200
    assert session.score.questions_attempted == 1, "a stale answer must not score"
    assert "datastar-patch-elements" in second.text, "the stale page was left as it was"
    assert "#app" in second.text, "a stale page needs the whole page back, not just the question"


def test_out_of_range_candidate_is_a_no_op(client):
    session = _session(client)
    response = client.post(f"/answer/{session.qid}/99")
    assert response.status_code == 204
    assert session.score.questions_attempted == 0


def test_wrong_answer_reveals_in_place_and_waits(client):
    """Panel spelled the answer out in a 4.2s centre-screen toast; the reveal is inline and the
    player advances when ready, so reading it costs no time bonus on the next question."""
    session = _session(client)
    question = session.question
    qid = session.qid
    correct_index = question.candidates.index(question.answer_candidate)
    wrong_index = 0 if correct_index != 0 else 1

    response = client.post(f"/answer/{qid}/{wrong_index}")

    assert response.status_code == 200
    assert session.score.questions_correct == 0
    assert session.score.questions_attempted == 1
    # parked on the reveal: same question, marked up, nothing advanced
    assert session.awaiting_next
    assert session.qid == qid
    assert session.question is question
    assert "candidate revealed" in response.text
    assert "Next question" in response.text
    # and the answer is not read out in a toast to be waited behind
    assert "Answer:" not in response.text


def test_next_leaves_the_reveal(client):
    session = _session(client)
    correct_index = session.question.candidates.index(session.question.answer_candidate)
    wrong_index = 0 if correct_index != 0 else 1
    client.post(f"/answer/{session.qid}/{wrong_index}")
    qid = session.qid

    response = client.post("/next")

    assert response.status_code == 200
    assert not session.awaiting_next
    assert session.qid != qid
    assert session.percent_time_left() == 100  # the new question's clock starts now


def test_next_is_a_no_op_when_not_revealing(client):
    """Otherwise it would be a free skip -- that is what Skip is for, and it costs a skip."""
    session = _session(client)
    qid = session.qid

    assert client.post("/next").status_code == 204
    assert session.qid == qid


def test_skip_consumes_a_skip_and_moves_on(client):
    session = _session(client)
    before_qid, before_skips = session.qid, session.skips_left

    response = client.post("/skip")

    assert response.status_code == 200
    assert session.skips_left == before_skips - 1
    assert session.qid != before_qid


def test_skip_refused_when_none_left(client):
    session = _session(client)
    session.skips_left = 0
    response = client.post("/skip")
    assert response.status_code == 204


def test_restart_resets_the_score(client):
    session = _session(client)
    session.score.total_points = 500
    session.score.questions_attempted = 4
    session.skips_left = 0

    response = client.post("/restart")

    assert response.status_code == 200
    assert session.score.total_points == 0
    assert session.score.questions_attempted == 0
    assert session.skips_left == 3


def test_settings_adopt_bound_signals_and_restart(client):
    session = _session(client)
    session.score.total_points = 200

    # POST: datastar sends the signals as the whole JSON body
    response = client.post("/settings", json={"difficulty": 7, "ladderMode": False, "targetOn": True, "targetPct": 90})

    assert response.status_code == 200
    assert session.settings.difficulty == 7
    assert session.settings.ladder_mode is False
    assert session.settings.target_on is True
    assert session.settings.target_pct == 90
    assert session.score.total_points == 0  # a settings change restarts, as in panel
    assert len(session.question.candidates) == 7  # difficulty is the candidate count


def test_unchanged_settings_do_not_restart(client):
    session = _session(client)
    session.score.total_points = 200
    difficulty = session.settings.difficulty

    response = client.post("/settings", json={"difficulty": difficulty})

    assert response.status_code == 204
    assert session.score.total_points == 200


def test_reaching_the_goal_shows_the_completion_screen(client):
    session = _session(client)
    session.score.total_points = engine.POINTS_GOAL - 1
    correct_index = session.question.candidates.index(session.question.answer_candidate)

    response = client.post(f"/answer/{session.qid}/{correct_index}")

    assert response.status_code == 200
    assert 'class="finale"' in response.text
    assert not session.still_playing
    # and the completion screen is what a reload serves, not a fresh question
    reloaded = client.get("/").text
    assert 'class="finale"' in reloaded
    # the numbers are the payoff, and they are assembled from per-character spans, so a plain
    # substring search for the score would not find them -- count the digits instead
    assert reloaded.count('class="digit"') >= len(str(session.score.total_points))


def test_answering_a_finished_quiz_is_a_no_op(client):
    session = _session(client)
    session.score.total_points = engine.POINTS_GOAL - 1
    correct_index = session.question.candidates.index(session.question.answer_candidate)
    client.post(f"/answer/{session.qid}/{correct_index}")
    assert not session.still_playing

    assert client.post(f"/answer/{session.qid}/0").status_code == 204
    assert client.post("/skip").status_code == 204
    # restart is the way out
    assert client.post("/restart").status_code == 200
    assert session.still_playing


def test_settings_clamp_out_of_range_difficulty(client):
    session = _session(client)
    client.post("/settings", json={"difficulty": 999})
    assert session.settings.difficulty == 8


def test_a_malformed_signals_body_is_not_a_server_error(client):
    """`read_signals` raises on junk; that must not surface as a 500.

    Found while benchmarking, when a bad harness sent `{}{}{}` as one body and every request came
    back as a stack trace. Absent or unusable signals mean "nothing to adopt", which every handler
    already copes with.
    """
    session = _session(client)
    before = (session.skips_left, session.settings.difficulty)

    for body in ("{}{}", "not json at all", "", "[1, 2, 3]", '{"difficulty": '):
        for path in ("/skip", "/restart", "/settings", "/next"):
            response = client.post(path, content=body, headers={"Content-Type": "application/json"})
            assert response.status_code < 500, f"{path} with body {body!r} -> {response.status_code}"

    # and a junk body cannot have changed the settings
    assert session.settings.difficulty == before[1]


def test_a_malformed_signals_query_is_not_a_server_error(client):
    for query in ("datastar=nonsense", "datastar=%7B", "datastar="):
        response = client.get(f"/filter/preview?{query}")
        assert response.status_code < 500, f"{query} -> {response.status_code}"
