"""A page whose session no longer exists, and why that used to score against a stranger's question.

Reported as: *"reload the url, click an answer, get shown it was wrong and see the correct answer,
but the question is redisplayed and it's a different question — as though I answered a different
question from what was seen"*, alongside `/` and `/?swedish` disagreeing with the app bar.

It was two counters that both started at 1, not a race:

* the session cookie is ONE PER BROWSER, and `?swedish` *replaces* the session (the variant decides
  which bml system the questions come from, so it cannot change in place). Every other page in that
  browser -- the other tab, the back-history entry, the phone's first tab -- is then showing a quiz
  that no longer exists;
* `qid` was per session and started at 1, so the stale page's `qid=1` MATCHED the brand new
  session's first question. The staleness guard passed by coincidence and the answer was scored
  against a question that had never been on screen: the reveal came back for a different auction --
  from a different SYSTEM, if the other page was `?swedish` -- and the app bar flipped its title.

Three things now stop it, and this file pins each: nonces are unique per process, a stale
interaction resyncs the page instead of scoring, and every action URL names its variant so a session
that has to be REBUILT (a restart, a six-hour gap) is rebuilt as the right system.
"""

from __future__ import annotations

import re

import pytest
from litestar.testing import TestClient

import app as app_module
import corpus
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


# --- the nonce ---------------------------------------------------------------


def test_the_question_nonce_is_unique_per_process_not_per_session():
    """The collision itself. Two sessions, both on their first question: with a per-session counter
    both said `qid=1`, so an answer aimed at one was accepted by the other."""
    first = state.new_session(corpus.DEFAULT_VARIANT)
    second = state.new_session(corpus.DEFAULT_VARIANT)
    assert first.qid != second.qid, "two fresh sessions share a question nonce"
    before = second.qid
    second.next_question()
    assert second.qid > before
    assert second.qid != first.qid


def test_a_replaced_session_cannot_inherit_the_old_page_s_nonce(client):
    """The report, end to end: answer from the page that `?swedish` replaced."""
    client.get("/")
    stale_qid = _session(client).qid

    client.get("/?swedish")  # replaces the session; the cookie is browser-wide
    swedish = _session(client)
    assert swedish.variant.key == "swedish"
    assert swedish.qid != stale_qid, "the new session started counting from 1 again"

    response = client.post(f"/answer/{stale_qid}/0")

    assert response.status_code == 200
    assert swedish.score.questions_attempted == 0, "the stale click scored in the new quiz"
    assert swedish.score.questions_correct == 0


# --- the resync --------------------------------------------------------------


def test_a_stale_click_resyncs_the_whole_page(client):
    """Not a 204. A dead button leaves the page showing the quiz that moved on, so the next click is
    stale too -- and on a variant switch the title, drawer and topics are wrong as well, which is why
    this is the fat patch even in fragment morph mode."""
    client.get("/")
    stale_qid = _session(client).qid
    client.get("/?swedish")

    body = client.post(f"/answer/{stale_qid}/0").text

    assert "event: datastar-patch-elements" in body
    assert "selector #app" in body, "a stale page needs the whole page, not just the question"
    assert "Swedish Club Quiz" in body, "the resync should carry the title the session actually has"
    assert "toast" in body, "the question changing under your finger needs saying"


def test_a_session_the_server_has_forgotten_resyncs_rather_than_scoring(client):
    """The other way a page goes stale, and the common one in development: the store is emptied by a
    restart (`--reload` does this all day) or by the six-hour sweep. The cookie still names a session,
    so the browser is not new -- it is behind."""
    client.get("/")
    session = _session(client)
    qid, sid = session.qid, session.sid
    app_module.STORE.discard(sid)  # what a restart does to every session at once

    response = client.post(f"/answer/{qid}/0")

    assert response.status_code == 200
    assert "selector #app" in response.text
    rebuilt = _session(client)
    assert rebuilt is not session, "a forgotten quiz is rebuilt, not resurrected"
    assert rebuilt.qid != qid, "the rebuilt quiz reused the nonce the stale page is holding"
    # the sid IS reused: it identifies the browser, not the quiz, so a rebuild keeps the cookie (and
    # with it the worker a load balancer pinned this player to -- see `state.SESSION_COOKIE`)
    assert rebuilt.sid == sid
    assert rebuilt.score.questions_attempted == 0, "the rebuilt session scored the stale click"


# --- the variant on the action URLs ------------------------------------------


ACTION_URL = re.compile(r"@(?:post|get)\('([^']+)'")


@pytest.mark.parametrize("query", ["", "?swedish"])
def test_every_action_url_names_its_variant(client, query):
    """The page's own URLs are the only place the variant can live: the cookie is per browser, so it
    cannot say which system a given PAGE is playing. A new action URL that forgets the query is a
    session that gets rebuilt as the wrong quiz, which is what this catches."""
    body = client.get(f"/{query}").text
    expected = "?" + (_session(client).variant.key)
    urls = {url for url in ACTION_URL.findall(body) if not url.startswith("/static")}
    assert urls, "no action URLs found -- the regex has drifted from the templates"
    for url in urls:
        # the digit accelerator builds its URL in three pieces; the variant is the last of them
        assert url.endswith((expected, "/")), f"{url} does not name its variant"


def test_the_digit_accelerator_puts_the_variant_after_the_index(client):
    """It concatenates `.../answer/<qid>/` + the index, so the query cannot sit in the middle."""
    body = client.get("/").text
    handler = re.search(r"data-on:keydown__window=\"!\$_answering(.*?)\">", body, re.DOTALL)
    assert handler, "no digit accelerator on the page"
    assert "+ (Number(evt.key) - 1) + '?squad'" in handler.group(1), handler.group(1)


def test_an_interaction_never_switches_the_variant(client):
    """A page left open on the other system must not be able to discard the session the player is
    using -- from a background tab, on a click they had forgotten about. The variant on an action URL
    only decides a session that has to be BUILT."""
    client.get("/?swedish")
    swedish = _session(client)

    client.post("/skip?squad")

    assert _session(client) is swedish
    assert _session(client).variant.key == "swedish"


def test_a_rebuilt_session_takes_its_variant_from_the_action_url(client):
    """`?swedish` page, session gone (restart / TTL): without the variant on the URL the replacement
    was built from the DEFAULT system, so the questions came from squad under a swedish title. That
    is "the header bar does not reflect the quiz the URL bar says we are on"."""
    client.get("/?swedish")
    app_module.STORE.discard(_session(client).sid)

    client.post("/skip?swedish")

    assert _session(client).variant.key == "swedish"


def test_a_bare_interaction_path_still_does_not_mean_the_default(client):
    """The older trap, still pinned: only a page load may read a bare URL as "back to squad"."""
    client.get("/?swedish")
    client.post("/skip")
    assert _session(client).variant.key == "swedish"
