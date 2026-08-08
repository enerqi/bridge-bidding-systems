"""The debug panel: reaching states that take minutes of honest play.

The panel app had the same idea (`debug_enabled = pn.config.autoreload or "debug" in search`,
`quiz_app.py:93`). Two things make this version worth testing rather than trusting:

* **it can rewrite the score**, so "off" has to mean off. `DSQUIZ_DEBUG=0` must beat `?debug`, and an
  unarmed session must get nothing from the routes even if it posts to them directly.
* **`/debug/complete` goes through the real scoring path** rather than setting `completion_wall`.
  Faking it would show the finale while skipping everything that produces it -- which is precisely
  what you were trying to look at.
"""

from __future__ import annotations

import pytest
from litestar.testing import TestClient

import app as app_module
import engine
import render


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


def session_of(client):
    return app_module.STORE.get(client.cookies["dsq_sid"])


# --- when it is armed, and when it is not ------------------------------------


def test_off_by_default(client):
    assert "?debug" not in client.get("/").text
    assert 'id="debug"' not in client.get("/").text
    assert session_of(client).debug is False


def test_the_query_arms_it_for_the_session(client):
    body = client.get("/?debug").text
    assert 'id="debug"' in body
    assert session_of(client).debug is True
    # and it survives the interactions, which carry no query at all
    client.post("/skip", content="{}")
    assert session_of(client).debug is True


def test_a_plain_reload_disarms_it(client):
    client.get("/?debug")
    assert session_of(client).debug is True
    assert 'id="debug"' not in client.get("/").text
    assert session_of(client).debug is False


def test_the_env_flag_arms_every_session(client, monkeypatch):
    monkeypatch.setattr(app_module, "DEBUG_MODE", "1")
    assert 'id="debug"' in client.get("/").text


def test_zero_forbids_the_query(client, monkeypatch):
    """The setting a deployment wants: `?debug` is a URL anyone can type."""
    monkeypatch.setattr(app_module, "DEBUG_MODE", "0")
    assert 'id="debug"' not in client.get("/?debug").text
    assert session_of(client).debug is False


@pytest.mark.parametrize(
    "path",
    ["/debug/points/500", "/debug/goal/200", "/debug/complete", "/debug/reveal"],
)
def test_the_routes_do_nothing_unarmed(client, path):
    """Posting to them directly must not work either -- the guard is on the session, not the markup."""
    client.get("/")
    session = session_of(client)
    before = (session.score.total_points, session.points_goal, session.still_playing, session.awaiting_next)

    response = client.post(path, content="{}")

    # 204, the same "nothing to do" answer a stale `qid` gets from `/answer` -- consistency matters
    # more here than a bespoke status, and a 404 would leak whether the routes exist at all
    assert response.status_code == 204
    assert response.text == ""
    assert (session.score.total_points, session.points_goal, session.still_playing, session.awaiting_next) == before


# --- what each one does ------------------------------------------------------


@pytest.fixture
def armed(client):
    client.get("/?debug")
    return client, session_of(client)


def test_points_can_be_handed_out_and_taken_back(armed):
    client, session = armed
    client.post("/debug/points/250", content="{}")
    assert session.score.total_points == 250
    client.post("/debug/points/-100", content="{}")
    assert session.score.total_points == 150
    # and never below zero, which the scoring code assumes elsewhere
    client.post("/debug/points/-9999", content="{}")
    assert session.score.total_points == 0


def test_points_alone_do_not_fake_a_completion(armed):
    """Crossing the goal by hand must not end the quiz: the finale should only ever be reached by the
    code path that produces it, or looking at it proves nothing."""
    client, session = armed
    client.post(f"/debug/points/{engine.POINTS_GOAL + 500}", content="{}")
    assert session.still_playing


def test_the_goal_is_per_session_not_a_global(armed):
    client, session = armed
    client.post("/debug/goal/200", content="{}")
    assert session.points_goal == 200
    assert engine.POINTS_GOAL == 1000, "the module constant must not be mutated"


def test_a_shortened_goal_really_shortens_the_quiz(armed):
    """The goal is threaded into `engine.answer`, so completion and the skip milestones both follow."""
    client, session = armed
    client.post("/debug/goal/200", content="{}")
    session.score.total_points = 199
    correct = session.question.candidates.index(session.question.answer_candidate)

    client.post(f"/answer/{session.qid}/{correct}", content="{}")

    assert not session.still_playing


def test_show_the_finale_goes_through_the_real_scoring_path(armed):
    client, session = armed
    body = client.post("/debug/complete", content="{}").text

    assert not session.still_playing
    assert 'class="finale"' in body
    # the toast chain ran -- this went through `engine.answer`, not a faked `completion_wall`
    assert "Correct!" in body
    # ...but NO floaters: the browser is showing whatever it was showing (often the previous finale),
    # so cards to aim them at may not exist, and datastar logs an error per missed target
    assert "floater" not in body


def test_show_the_finale_restarts_a_finished_quiz_first(armed):
    client, session = armed
    client.post("/debug/complete", content="{}")
    assert not session.still_playing

    body = client.post("/debug/complete", content="{}").text

    assert 'class="finale"' in body
    assert session.score.questions_correct == 1, "the restart should have cleared the previous run"


def test_show_the_reveal_parks_without_getting_one_wrong(armed):
    client, session = armed
    body = client.post("/debug/reveal", content="{}").text

    assert session.awaiting_next
    assert 'class="candidate revealed' in body
    # the score is untouched: this is for looking at the shake, not for testing scoring
    assert session.score.questions_attempted == 0
    # and the clock is frozen, as it would be after a real answer
    assert session.frozen_time_left is not None


def test_the_panel_reports_the_state_it_can_change(armed):
    client, session = armed
    client.post("/debug/goal/300", content="{}")
    body = client.get("/?debug").text
    assert "goal 300" in body.replace("\n", " ") or f"goal {session.points_goal}" in body.replace("\n", " ")


# --- devtools noise ----------------------------------------------------------


def test_the_devtools_probe_is_answered_when_debug_is_on(client, monkeypatch):
    """Chrome asks for this on every page load with devtools open, and repeatedly in device simulation.

    Unanswered it is a 404 per probe, and litestar's debug mode prints a traceback for each one -- which
    is what filled the log. Answered, it is a feature: devtools can write Styles-panel edits back to
    `static/*.css` instead of losing them on reload.
    """
    monkeypatch.setattr(app_module, "DEBUG_MODE", "1")
    response = client.get("/.well-known/appspecific/com.chrome.devtools.json")
    assert response.status_code == 200
    workspace = response.json()["workspace"]
    assert workspace["root"].endswith("datastar-quiz")
    # stable across restarts, or devtools re-asks for folder trust on every reload
    assert (
        workspace["uuid"] == client.get("/.well-known/appspecific/com.chrome.devtools.json").json()["workspace"]["uuid"]
    )


def test_the_devtools_probe_is_refused_otherwise(client):
    """The payload is an absolute filesystem path, which is nobody's business on a deployment."""
    assert app_module.DEBUG_MODE != "1"
    assert client.get("/.well-known/appspecific/com.chrome.devtools.json").status_code == 404


def test_a_missing_path_is_a_plain_404_not_a_stack_trace(client):
    """`NotFoundException` is an exception like any other, so debug mode logged 30 lines for a missing
    source map or a devtools probe. Real errors stay loud; these are answered and dropped."""
    response = client.get("/definitely-not-a-route")
    assert response.status_code == 404
    assert "Traceback" not in response.text
    assert "not found: /definitely-not-a-route" in response.text


def test_the_debug_panel_shows_which_build_is_serving(client):
    """Three "it is broken again" reports have turned out to be a process running pre-fix code.

    Templates are re-read from disk on every render; `render.py` is not. So a server that did not
    reload serves NEW markup with STALE constants, and the result looks like a fresh bug rather than
    an old one. The stamp moves when the sources do, which makes "am I looking at what I just edited"
    a glance instead of an investigation.
    """
    body = client.get("/?debug").text
    assert f"build {render.build_stamp()}" in body

    stamp = render.build_stamp()
    assert stamp, "no build stamp"
    assert stamp.isalnum(), stamp
    # ...and it is not in a player's page, like everything else in that panel
    assert "build " not in client.get("/").text
