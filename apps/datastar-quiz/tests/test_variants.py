"""The `?swedish` variant: a different bml system, title, notes link and topics file.

Panel keyed its sessions on the variant, so a differing query naturally produced a different
session. Here there is one cookie per browser, so the query has to be honoured explicitly -- it was
silently ignored for anyone who already had a session, which is the bug these tests pin.
"""

from __future__ import annotations

import pytest
from litestar.testing import TestClient

import app as app_module
import corpus
import render
import state


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


def _session(client: TestClient) -> state.Session:
    session = app_module.STORE.get(client.cookies[state.SESSION_COOKIE])
    assert session is not None
    return session


def test_requested_variant_only_answers_when_asked():
    swedish = corpus.requested_variant("swedish")
    squad = corpus.requested_variant("?squad")
    assert swedish is not None
    assert squad is not None
    assert swedish.key == "swedish"
    assert squad.key == "squad"
    # an unrelated query must not read as "switch me to the default"
    assert corpus.requested_variant("debug") is None
    assert corpus.requested_variant("") is None
    assert corpus.requested_variant(None) is None


def test_fresh_session_honours_the_query(client):
    body = client.get("/?swedish").text
    assert "Swedish Club Quiz" in body
    assert _session(client).variant.bml_file == "bidding-system.bml"


def test_existing_session_switches_variant(client):
    client.get("/")
    assert _session(client).variant.key == "squad"

    body = client.get("/?swedish").text

    assert "Swedish Club Quiz" in body
    assert _session(client).variant.key == "swedish"
    assert _session(client).variant.bml_file == "bidding-system.bml"


# --- one quiz per variant, per browser ---------------------------------------
#
# Sessions are keyed by (browser, variant), which is what panel had by keying on the variant.
# Switching used to REPLACE the single session, and since the cookie is one per browser that reached
# across tabs: the squad tab was left holding a quiz that no longer existed, and its next click
# landed in the swedish one (COMPARISON.md 15).


def test_switching_systems_parks_the_other_quiz_rather_than_ending_it(client):
    """The score is the point: a system switch is "let me look at the other one", not "throw this
    away". Both quizzes stay in the store, each under its own key."""
    client.get("/")
    squad = _session(client)
    squad.score.questions_attempted = 7
    squad.score.questions_correct = 5

    client.get("/?swedish")
    swedish = _session(client)

    assert swedish is not squad
    assert swedish.score.questions_attempted == 0, "the swedish quiz started with the squad score"
    assert app_module.STORE.get(squad.sid, "squad") is squad, "the squad quiz was discarded"


def test_switching_back_resumes_the_quiz_you_left(client):
    client.get("/")
    squad = _session(client)
    squad.score.questions_attempted = 7
    qid = squad.qid

    client.get("/?swedish")
    body = client.get("/").text

    assert _session(client) is squad, "going back started a new squad quiz"
    assert _session(client).score.questions_attempted == 7
    assert _session(client).qid == qid, "the parked quiz lost the question it was on"
    assert "7" in body


def test_the_two_quizzes_share_one_cookie_and_one_browser_id(client):
    """One cookie, because a load balancer pins a player to a worker by hashing it (DEPLOY.md).
    The variant is the other half of the key, and it comes from the URL rather than the cookie."""
    client.get("/")
    squad = _session(client)
    client.get("/?swedish")
    swedish = _session(client)

    assert squad.sid == swedish.sid
    assert client.cookies[state.SESSION_COOKIE] == squad.sid


def test_a_click_in_the_other_system_s_tab_stays_in_that_system(client):
    """The cross-tab bug, from the other side: the squad tab's action URLs carry `?squad`, so its
    clicks reach the squad quiz even while the browser is 'on' swedish."""
    client.get("/")
    squad = _session(client)
    client.get("/?swedish")
    swedish = _session(client)
    assert swedish.skips_left == squad.skips_left

    client.post("/skip?squad")

    assert squad.skips_left == swedish.skips_left - 1, "the skip was spent in the wrong quiz"


def test_variant_switch_distinguishes_bare_from_unrelated():
    """`requested_variant` says what was named; `variant_switch_for_query` says what to do about it."""
    named = corpus.variant_switch_for_query("swedish")
    assert named is not None
    assert named.key == "swedish"
    # a bare URL is "take me home", so it resolves rather than abstaining
    for bare in ("", None):
        home = corpus.variant_switch_for_query(bare)
        assert home is not None, bare
        assert home.key == "squad", bare
    # a query that names no variant abstains, so an odd link cannot flip a swedish session
    assert corpus.variant_switch_for_query("debug") is None


def test_a_bare_url_returns_to_the_default(client):
    """The shared URL has to be the way home: nothing in the UI hints that `?squad` exists."""
    client.get("/?swedish")

    assert "U16 Squad System Quiz" in client.get("/").text
    assert _session(client).variant.key == "squad"


def test_an_unrelated_query_keeps_the_variant(client):
    """`?debug` and friends must not drag a swedish session back to the default."""
    client.get("/?swedish")

    assert "Swedish Club Quiz" in client.get("/?debug").text
    assert _session(client).variant.key == "swedish"


def test_interactions_never_switch_the_variant(client):
    """The bare-URL rule is for NAVIGATIONS only.

    Every datastar interaction posts to a bare path with no query, so applying "no query means the
    default" to them would reset a swedish player to squad on their first click -- silently, since
    the reply is a DOM patch and not a page load.
    """
    client.get("/?swedish")
    session = _session(client)

    client.post("/skip")
    client.post("/next")
    client.get("/filter/topics-reset")

    assert _session(client).sid == session.sid
    assert _session(client).variant.key == "swedish"


def test_switching_back(client):
    client.get("/?swedish")
    assert "U16 Squad System Quiz" in client.get("/?squad").text
    assert _session(client).variant.key == "squad"


def test_the_swedish_quiz_actually_works(client):
    """The whole loop on the other bml system: its own corpus, topics file and questions."""
    client.get("/?swedish")
    session = _session(client)

    assert len(session.sequences) > 100
    assert session.question.candidates
    topics = render.topic_choices(session)
    assert topics, "swedish_topics.toml should offer topics"

    correct_index = session.question.candidates.index(session.question.answer_candidate)
    response = client.post(f"/answer/{session.qid}/{correct_index}")
    assert response.status_code == 200
    assert session.score.questions_correct == 1

    # and its filter uses the swedish corpus
    applied = client.post("/filter/apply", json={"filterText": topics[0]["name"]})
    assert applied.status_code == 200
    assert session.filter_text == topics[0]["name"]


def test_variants_draw_on_different_corpora():
    squad = corpus.bid_sequences(corpus.VARIANTS["squad"].bml_file)
    swedish = corpus.bid_sequences(corpus.VARIANTS["swedish"].bml_file)
    assert len(squad) != len(swedish)
