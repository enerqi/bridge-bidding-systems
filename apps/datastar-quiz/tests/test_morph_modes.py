"""Fat morph: the default, per the Tao.

    "Morphing ensures that only modified parts of the DOM are updated, preserving state and improving
     performance. This allows you to send down large chunks of the DOM tree (all the way up to the
     `html` tag), sometimes known as 'fat morph'"
    -- data-star.dev/guide/the_tao_of_datastar

So an interaction patches `#app` -- everything below `<body>` -- and the server stops having to
remember which fragments a state change touches. `DSQUIZ_MORPH=fragment` keeps the old fine-grained
behaviour for comparison. Compression is what makes the fat default cheap; measured in COMPARISON.md.

Browser-verified alongside these (see COMPARISON.md): a fat morph preserves input focus, a typed
filter draft, `<details open>`, the open topics dialog, scroll position, and does not reload the
system-notes iframe.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from litestar.testing import TestClient

import app as app_module
import corpus
import render
import state

TEMPLATE_DIR = Path(render.__file__).resolve().parent / "templates"


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        test_client.get("/")
        yield test_client


@pytest.fixture
def fragment_mode(monkeypatch):
    monkeypatch.setattr(app_module, "MORPH_MODE", "fragment")


def test_fat_is_the_default():
    assert app_module.MORPH_MODE == "fat"


def test_the_document_wraps_the_page_in_the_morph_target():
    body = render.shell(state.new_session(corpus.DEFAULT_VARIANT))
    assert '<div id="app">' in body
    # the signal declarations stay OUTSIDE it, or a patch would re-declare them
    signals_at = body.index("data-signals=")
    app_at = body.index('<div id="app">')
    assert signals_at < app_at


def test_a_patch_carries_the_whole_page(client):
    response = client.post("/skip")

    assert "selector #app" in response.text
    # HUD, drawer and play area all travel, which is the point: no fragment bookkeeping.
    # `#score` / `#skips` were the old sidebar panels -- the score and Skip are in the app bar now, so
    # the markers are the HUD's pieces plus what is left in the drawer.
    for marker in ('class="topbar', 'class="skip', 'id="progress"', 'id="quiz"', 'id="toasts"', "candidates"):
        assert marker in response.text, marker


def test_fragment_mode_patches_only_the_question(client, fragment_mode):
    response = client.post("/skip")

    assert "selector #quiz" in response.text
    assert "selector #app" not in response.text
    assert 'id="score"' not in response.text  # the sidebar is not re-sent


def test_the_timer_stream_init_is_outside_the_morph_target(monkeypatch):
    """Otherwise every patch re-runs `data-init` and opens another held connection.

    The client-interval expression is safe to re-create; opening a stream is not.
    """
    monkeypatch.setattr(app_module, "TIMER_MODE", "stream")
    session = state.new_session(corpus.DEFAULT_VARIANT)

    document = render.shell(session)
    patched = render.app_body(session)

    assert "@get('/timer?squad')" in document
    assert "@get('/timer?squad')" not in patched
    # and it is on the body tag, before the morph target opens
    assert document.index("@get('/timer?squad')") < document.index('<div id="app">')


def test_the_client_interval_is_inside_the_morph_target(monkeypatch):
    monkeypatch.setattr(app_module, "TIMER_MODE", "client")
    patched = render.app_body(state.new_session(corpus.DEFAULT_VARIANT))
    assert "data-on-interval" in patched


def test_responses_are_compressed_when_asked(client):
    """Fat morph's cost is bytes, and this is what makes those bytes cheap."""
    plain = client.get("/", headers={"Accept-Encoding": "identity"})
    compressed = client.get("/", headers={"Accept-Encoding": "br"})

    assert compressed.headers.get("content-encoding") == "br"
    assert "accept-encoding" in compressed.headers.get("vary", "").lower()
    # httpx decodes for us, so compare the decoded bodies rather than the framing
    assert plain.text == compressed.text


def test_sse_responses_are_compressed_too(client):
    """The datastar SDK warns compression middleware can interfere with flushing; litestar's brotli
    facade flushes per chunk, so the stream stays incremental. Pacing is measured in
    `tools/measure.py`, not here -- this only pins that the encoding is applied."""
    response = client.post("/skip", headers={"Accept-Encoding": "br"})
    assert response.headers.get("content-encoding") == "br"
    assert "datastar-patch-elements" in response.text


def test_brotli_quality_is_pinned_at_the_knee():
    """Not left to litestar's default, which happens to agree today but could move.

    Measured on this app's fat patch: q6 costs 68% more time for 0.4% fewer bytes, q9 is 8x the CPU
    for 1%, q11 is 40x for 10%. q5 also beats gzip -9 on size at about twice its cost.
    """
    config = app_module.app.compression_config
    assert config is not None
    assert config.backend == "brotli"
    assert config.brotli_quality == 5
    assert config.brotli_gzip_fallback is True  # so a client without br still gets something


def test_the_document_and_the_fat_patch_render_the_same_markup():
    """They must be one template, not two copies.

    The split that introduced fat morph left a *duplicate* of the page inside `shell.html.j2` instead
    of including `app.html.j2`. The copies drifted within the hour: collapsing the appearance controls
    changed what patches sent but not what a page load rendered, which reads as a rendering bug with
    no obvious cause. The shell now includes the same template the patch renders.
    """
    session = state.new_session(corpus.DEFAULT_VARIANT)
    document = render.shell(session)
    patch = render.app_body(session)

    # the patch is the document's #app content, so every line of it must appear in the document
    lines = [line.strip() for line in patch.splitlines() if len(line.strip()) > 20]
    assert lines, "app_body rendered nothing recognisable"
    missing = [line for line in lines if line not in document]
    assert not missing, f"the document is missing markup the patch sends: {missing[:3]}"


def test_the_shell_holds_no_page_markup_of_its_own():
    """A guard on the same mistake from the other direction: if the shell grows its own copy of the
    layout, this fails long before the two drift."""
    shell_source = (render.TEMPLATE_DIR / "shell.html.j2").read_text(encoding="utf-8")

    assert '{% include "app.html.j2" %}' in shell_source
    for marker in ('class="topbar"', 'class="layout"', 'class="sidebar"', 'id="quiz"'):
        assert marker not in shell_source, f"shell.html.j2 duplicates {marker} instead of including it"


@pytest.mark.parametrize("template", sorted(TEMPLATE_DIR.glob("*.j2")))
def test_every_disclosure_survives_a_morph(template):
    """`open` is state the PLAYER set and the server knows nothing about.

    A fat morph rewrites `#app` from markup that never carries the attribute, so without
    `data-preserve-attr` the morph removes it and the disclosure snaps shut -- on every answer, skip,
    settings change and restart. Exactly one `<details>` had the attribute, so exactly one survived,
    which is the kind of inconsistency that reads as a random bug rather than a missing line.
    """
    markup = re.sub(r"\{#.*?#\}", "", template.read_text(encoding="utf-8"), flags=re.DOTALL)
    for tag in re.findall(r"<details\b[^>]*>", markup, re.DOTALL):
        assert 'data-preserve-attr="open"' in tag, f"{template.name}: closes on the next morph: {tag}"
