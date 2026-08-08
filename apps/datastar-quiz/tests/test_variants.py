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


def test_a_plain_request_keeps_the_variant(client):
    client.get("/?swedish")
    # no query, and a query naming nothing: neither may drag the session back to the default
    assert "Swedish Club Quiz" in client.get("/").text
    assert "Swedish Club Quiz" in client.get("/?debug").text
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
