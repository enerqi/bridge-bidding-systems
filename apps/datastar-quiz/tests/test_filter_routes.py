"""The bidding-tree filter: preview never commits, apply does, and both agree."""

from __future__ import annotations

import json
import re

import pytest
from litestar.testing import TestClient
from markup import found

import app as app_module
import corpus
import engine
import render
import state


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        test_client.get("/")
        yield test_client


def _session(client: TestClient) -> state.Session:
    session = app_module.STORE.get(client.cookies[state.SESSION_COOKIE])
    assert session is not None, "the fixture's GET / should have created one"
    return session


# whether this variant's topics file offers anything to pick, decided once
HAS_TOPICS = bool(render.topic_choices(state.new_session(corpus.DEFAULT_VARIANT)))
needs_topics = pytest.mark.skipif(not HAS_TOPICS, reason="this variant offers no topics")


def _get_with_signals(client: TestClient, path: str, signals: dict):
    # datastar sends signals as a `datastar` query parameter on GET
    return client.get(path, params={"datastar": json.dumps(signals)})


def test_preview_reports_a_count_without_applying(client):
    session = _session(client)
    everything = len(session.sequences)

    response = _get_with_signals(client, "/filter/preview", {"filterText": "1C"})

    assert response.status_code == 200
    assert "auctions match" in response.text
    assert "press Enter to apply" in response.text
    assert len(session.sequences) == everything  # nothing committed
    assert session.filter_text == ""


def test_preview_reports_unusable_input_and_escapes_it(client):
    response = _get_with_signals(client, "/filter/preview", {"filterText": "<script>x</script>"})

    assert response.status_code == 200
    assert "not a topic or pattern" in response.text
    # the offending entry is the user's own text, so it must arrive escaped
    assert "<script>" not in response.text
    assert "&lt;script&gt;" in response.text or "&lt;" in response.text


def test_apply_narrows_the_working_set_and_restarts(client):
    session = _session(client)
    everything = len(session.sequences)
    session.score.total_points = 300

    response = client.post("/filter/apply", json={"filterText": "1C"})

    assert response.status_code == 200
    assert len(session.sequences) < everything
    assert session.filter_text == "1C"
    assert session.score.total_points == 0  # a real change restarts, as in panel
    # the box is told the canonical text, and the picker its ticks
    assert "datastar-patch-signals" in response.text
    assert "filterText" in response.text


def test_reapplying_the_same_filter_does_not_restart(client):
    session = _session(client)
    client.post("/filter/apply", json={"filterText": "1C"})
    session.score.total_points = 300

    response = client.post("/filter/apply", json={"filterText": "1c"})  # same, different case

    assert response.status_code == 200
    assert session.score.total_points == 300  # no restart: the filter did not change


def test_unusable_filter_falls_back_to_the_whole_system(client):
    session = _session(client)
    everything = len(corpus.bid_sequences(session.variant.bml_file))

    client.post("/filter/apply", json={"filterText": "not-a-bid"})

    assert len(session.sequences) == everything
    # and questions can still be built from it
    assert client.post("/restart").status_code == 200
    assert len(session.question.candidates) == session.settings.difficulty


@needs_topics
def test_topics_apply_uses_the_ticked_slugs(client):
    session = _session(client)
    choices = render.topic_choices(session)
    first = choices[0]

    # the browser sends the camel-cased key the binding wrote, not the kebab attribute slug
    response = client.post("/filter/apply-topics", json={"topics": {first["key"]: True}})

    assert response.status_code == 200
    assert session.filter_text == first["name"]


def test_unknown_topic_slug_selects_nothing(client):
    session = _session(client)
    client.post("/filter/apply-topics", json={"topics": {"no_such_topic": True}})
    assert session.filter_text == ""
    assert len(session.sequences) == len(corpus.bid_sequences(session.variant.bml_file))


@needs_topics
def test_topics_preview_targets_the_dialog_status(client):
    session = _session(client)
    choices = render.topic_choices(session)

    response = _get_with_signals(client, "/filter/preview-topics", {"topics": {choices[0]["key"]: True}})

    assert "selector #topics-status" in response.text
    assert session.filter_text == ""  # preview commits nothing


def test_filter_status_matches_check_filter(client):
    """The preview and the applied result come from the same function, so they cannot disagree."""
    session = _session(client)
    check = corpus.check_filter(session.variant.bml_file, session.variant.key, "1C", engine.MAX_DIFFICULTY)
    rendered = render.filter_status(check, in_force="")

    preview = _get_with_signals(client, "/filter/preview", {"filterText": "1C"}).text

    assert f"<strong>{len(check.hits)}</strong>" in rendered
    assert f"<strong>{len(check.hits)}</strong>" in preview


@needs_topics
def test_clear_writes_the_leaves_rather_than_replacing_the_namespace(client):
    """`$topics = {}` looked obvious and did nothing: every box stayed ticked.

    The boxes bind one signal each (`data-bind:topics.<slug>`), so `topics` is a NAMESPACE, not a
    value -- assigning an object to it replaces the branch the bindings watch instead of writing the
    leaves they are bound to. `@setAll` walks the tree and writes each matching leaf.
    """
    body = client.get("/").text
    clear = re.search(r"<button[^>]*>Clear</button>", body, re.DOTALL)
    assert clear, "no Clear button"
    handler = found(r'data-on:click="([^"]+)"', clear.group(0), re.DOTALL).group(1)
    assert "$topics = {}" not in handler, handler
    assert "$topics={}" not in handler, handler
    assert "@setAll(false" in handler, handler
    assert "topics" in handler, handler
    # ...and the status line under the list is server-rendered from the ticks, so clearing them
    # without asking for a new one leaves "N topics selected" under an empty list
    assert "/filter/preview-topics" in handler, handler


@needs_topics
def test_shell_seeds_topic_ticks_from_the_filter_in_force(client):
    session = _session(client)
    choices = render.topic_choices(session)
    client.post("/filter/apply-topics", json={"topics": {choices[0]["key"]: True}})

    body = client.get("/").text

    # the ticks are seeded from the filter, so a typed filter and a picked one agree
    assert f"&#34;{choices[0]['key']}&#34;: true" in body
    # and the checkbox binds the kebab form of the same name
    assert f"data-bind:topics.{choices[0]['slug']}" in body


@needs_topics
def test_the_drawer_asks_its_questions_in_order(client):
    """Difficulty, then how it is scored, then WHICH auctions -- and the pattern language last.

    Topics and the filter answer the same question at very different prices: a topic is a name you
    recognise ("Weak twos"), the filter is a syntax with six rules. The filter box sat at the top for
    months because it was built first, which put the hardest control in the most prominent place.
    The status line stays OUT of the fold: it reports the working set, which is worth seeing whether
    or not you are editing a pattern.
    """
    body = client.get("/").text
    controls = body[body.index('class="panel box controls"') : body.index('class="appearance"')]
    order = [
        controls.index("data-bind:difficulty"),
        controls.index("data-bind:ladder-mode"),
        controls.index("data-bind:target-on"),
        controls.index("$_topicsOpen = true"),
        controls.index('id="filter-status"'),
        controls.index('class="advanced"'),
        controls.index("data-bind:filter-text"),
    ]
    assert order == sorted(order), order
    assert controls.index('class="advanced"') < controls.index("Filter syntax"), (
        "the syntax help belongs inside the fold with the box it explains"
    )
