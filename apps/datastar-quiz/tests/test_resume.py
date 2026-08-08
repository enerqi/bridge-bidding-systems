"""Resumability, and how much state a response carries.

`GET /` renders the whole page from session state, so a reload, a second tab or a recovered
connection all resume exactly where the quiz was -- including mid-reveal. Interactions patch a
fragment plus the server-owned signals, which is the "backend drives the frontend" rule applied to
the round trip: anything the server decides must come back, or the live page and the session
disagree until the next load.

The exception is drafts. `filterText` and the topic ticks belong to the user while they are being
edited, and re-stating them on an unrelated patch would wipe what was being typed.
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
        test_client.headers.update({"Datastar-Request": "true"})
        test_client.get("/")
        yield test_client


def _session(client: TestClient) -> state.Session:
    session = app_module.STORE.get(client.cookies[state.SESSION_COOKIE])
    assert session is not None
    return session


# --- what a response carries -------------------------------------------------


def test_clamped_settings_are_echoed_back(client):
    """Send an impossible difficulty: the server clamps it and must say so.

    Without the echo the slider kept reading 99 while the questions had 8 candidates, and only a
    reload revealed the disagreement.
    """
    response = client.post("/settings", json={"difficulty": 99})

    assert response.status_code == 200
    assert _session(client).settings.difficulty == engine.MAX_DIFFICULTY
    assert f'"difficulty":{engine.MAX_DIFFICULTY}' in response.text.replace(" ", "")


def test_out_of_range_target_is_echoed_back(client):
    response = client.post("/settings", json={"targetOn": True, "targetPct": 999})
    assert _session(client).settings.target_pct == 90
    assert '"targetPct":90' in response.text.replace(" ", "")


def test_an_unrelated_patch_does_not_restate_the_draft_signals(client):
    """A Skip must not patch `filterText` or the topic ticks as SIGNALS.

    Under fat morph the input's markup is re-sent, which is harmless: the morph only writes
    `input.value` when the value *attribute* differs, and typing changes the property, not the
    attribute (`patchElements.ts`, "many bothans died to bring us this information"). Patching the
    signal, by contrast, would overwrite the draft outright.
    """
    response = client.post("/skip")
    assert response.status_code == 200

    signal_frames = [line for line in response.text.splitlines() if line.startswith("data: signals")]
    assert signal_frames, response.text
    for frame in signal_frames:
        assert "filterText" not in frame
        assert "topics" not in frame


def test_committing_a_filter_does_restate_it(client):
    """On commit the server's canonical text *is* authoritative, so it is sent."""
    response = client.post("/filter/apply", json={"filterText": "1c"})

    assert "filterText" in response.text
    assert _session(client).filter_text == "1C"  # canonicalised
    assert '"filterText":"1C"' in response.text.replace(" ", "")


# --- resuming ----------------------------------------------------------------


def test_a_reload_resumes_the_same_question(client):
    session = _session(client)
    first = client.get("/").text
    assert session.question.answer_candidate

    again = client.get("/").text

    # same question, same qid: a reload is not a new deal
    assert f"/answer/{session.qid}/0" in first
    assert f"/answer/{session.qid}/0" in again


def test_a_reload_mid_reveal_resumes_the_reveal(client):
    session = _session(client)
    correct = session.question.candidates.index(session.question.answer_candidate)
    wrong = 0 if correct != 0 else 1
    client.post(f"/answer/{session.qid}/{wrong}")
    assert session.awaiting_next

    body = client.get("/").text

    assert "candidate revealed" in body
    assert "Next question" in body
    # and advancing still works after the reload
    assert client.post("/next").status_code == 200
    assert not session.awaiting_next


def test_a_reload_carries_the_score_and_skips(client):
    session = _session(client)
    session.score.total_points = 275
    session.score.questions_correct = 4
    session.score.questions_attempted = 6
    session.skips_left = 1

    # in the page the signals live in an attribute, so the json quotes arrive escaped;
    # over SSE the same payload is raw
    body = client.get("/").text.replace(" ", "").replace("&#34;", '"')

    assert '"_points":275' in body
    assert '"_correct":4' in body
    assert '"_attempted":6' in body
    assert '"_skipsLeft":1' in body


def test_a_reload_carries_the_applied_filter(client):
    client.post("/filter/apply", json={"filterText": "1C"})
    narrowed = len(_session(client).sequences)

    body = client.get("/").text

    assert 'value="1C"' in body
    assert "auctions match" in body
    assert len(_session(client).sequences) == narrowed


def test_a_second_tab_shares_the_session(client):
    """One cookie per browser, so a second tab is the same quiz -- not a second one."""
    session = _session(client)
    before = app_module.STORE.__len__()

    other_tab = client.get("/").text

    assert f"/answer/{session.qid}/0" in other_tab
    assert app_module.STORE.__len__() == before


def test_a_lost_session_starts_a_fresh_quiz_rather_than_erroring(client):
    """Process-local sessions do not survive a restart or the TTL sweep. The recovery is a new
    quiz, not a 500 -- the cookie is honoured if it resolves and replaced if it does not."""
    sid = client.cookies[state.SESSION_COOKIE]
    app_module.STORE.discard(sid)

    response = client.get("/")

    assert response.status_code == 200
    assert 'id="quiz"' in response.text
    assert app_module.STORE.get(client.cookies[state.SESSION_COOKIE]) is not None
