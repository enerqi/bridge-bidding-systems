"""Mounting the app somewhere other than the root of a host (`DSQUIZ_PREFIX`).

Two halves have to agree, and only one of them is litestar's problem:

* **routing** — `Litestar(path=...)` prefixes every handler and both static routers. One argument.
* **URL generation** — the templates write `@post('/answer/…')` and `<link href="/static/app.css">`.
  Those are root-absolute: under a prefix the browser would ask the *site root* for them, get the
  wrong app (or a 404 from a static file server), and the page would load unstyled with dead buttons.

So the prefix is threaded into the templates too, and these tests pin both halves together. The
default is the empty prefix, which renders byte-identically to the root-absolute URLs the app had
before it could be mounted anywhere — that is why the rest of the suite is unaffected.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from litestar.testing import TestClient

import app as app_module
import render

PREFIX = "/bridge-quiz-ds"


@pytest.fixture
def prefixed(monkeypatch):
    """The app rebuilt as it would be under `DSQUIZ_PREFIX=bridge-quiz-ds`."""
    monkeypatch.setattr(app_module, "URL_PREFIX", PREFIX)
    with TestClient(app=app_module.create_app()) as client:
        client.headers.update({"Datastar-Request": "true"})
        yield client


def test_the_page_is_served_under_the_prefix(prefixed):
    assert prefixed.get(f"{PREFIX}/").status_code == 200


def test_the_root_is_not_served_when_a_prefix_is_set(prefixed):
    """Nothing should answer at `/`: that path belongs to whatever else the host serves."""
    assert prefixed.get("/").status_code == 404


def test_static_files_move_with_the_app(prefixed):
    assert prefixed.get(f"{PREFIX}/static/app.css").status_code == 200
    assert prefixed.get("/static/app.css").status_code == 404


def test_every_url_the_page_emits_carries_the_prefix(prefixed):
    """The half litestar does not do for you, and the half that fails silently in a browser."""
    body = prefixed.get(f"{PREFIX}/").text

    emitted = set(re.findall(r"@(?:post|get)\('([^']+)'", body))
    emitted |= set(re.findall(r'(?:href|src)="(/[^"]*)"', body))
    assert emitted, "no URLs found in the rendered page"
    for url in emitted:
        assert url.startswith(PREFIX), f"{url} would be requested from the site root"


def test_the_answer_route_posted_by_the_page_actually_exists(prefixed):
    """End to end rather than by inspection: take the URL the page emits and post it."""
    body = prefixed.get(f"{PREFIX}/").text
    # `?squad` on the end is the variant every action URL carries -- see `render.variant_query`
    posted = re.search(rf"@post\('({re.escape(PREFIX)}/answer/\d+/\d+\?\w+)'\)", body)
    assert posted, body[:400]
    assert prefixed.post(posted.group(1), content="{}").status_code == 200


def test_the_session_cookie_is_scoped_to_the_mount_point(prefixed):
    """Two apps on one host share the cookie NAME, so only the path keeps them apart."""
    response = prefixed.get(f"{PREFIX}/")
    cookie = response.headers["set-cookie"]
    assert f"Path={PREFIX}" in cookie, cookie


def test_the_default_is_the_root_and_changes_nothing():
    assert app_module.URL_PREFIX == ""
    assert render.url_prefix() == ""


def test_a_prefix_is_normalised(monkeypatch):
    """`DSQUIZ_PREFIX=bridge-quiz-ds/` and `/bridge-quiz-ds` must mean the same thing."""
    import importlib

    for raw in ("bridge-quiz-ds", "/bridge-quiz-ds", "bridge-quiz-ds/", "/bridge-quiz-ds/"):
        monkeypatch.setenv("DSQUIZ_PREFIX", raw)
        reloaded = importlib.reload(app_module)
        assert reloaded.URL_PREFIX == PREFIX, raw

    # and restore the module every other test in the session shares
    monkeypatch.delenv("DSQUIZ_PREFIX")
    importlib.reload(app_module)
    assert app_module.URL_PREFIX == ""


def test_the_vendored_bundle_can_find_its_source_map():
    """The bundle ends with `//# sourceMappingURL=datastar.js.map`, so devtools asks for it.

    Without the map the static router raises `NotFoundException` and the log gets a stack trace every
    time anyone opens devtools -- which is exactly how this was found. Either vendor the map or stop
    referencing it; this asserts the pair stays consistent (`just vendor-datastar` copies both).
    """
    static = Path(render.__file__).resolve().parent / "static"
    bundle = (static / "datastar.js").read_text(encoding="utf-8")
    referenced = re.search(r"sourceMappingURL=(\S+)", bundle)
    if referenced is None:
        return  # a build without a map reference is fine too
    assert (static / referenced.group(1)).is_file(), f"{referenced.group(1)} is referenced but not vendored"
