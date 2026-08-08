"""Attribute-key naming must agree with datastar's own transform.

HTML lowercases attribute names, so `data-bind:filterText` arrives as `data-bind:filtertext` and
binds a signal the server never seeded -- a silent split-brain where the server reads a stale
value forever. Datastar's convention is kebab-case keys, converted with `camel` (which is
`kebab` then de-dashing) in `library/src/utils/text.ts`.

These tests pin both halves: the transform (mirrored in `render`) and the templates (no
mixed-case `data-bind:` / `data-signals:` keys).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import render

TEMPLATE_DIR = Path(render.__file__).resolve().parent / "templates"

_COMMENT = re.compile(r"\{#.*?#\}", re.DOTALL)


def markup_of(template: Path) -> str:
    """Template text with `{# ... #}` removed -- the comments discuss the wrong forms on purpose."""
    return _COMMENT.sub("", template.read_text(encoding="utf-8"))


@pytest.mark.parametrize(
    ("text", "kebab", "camel"),
    [
        ("filterText", "filter-text", "filterText"),
        ("ladderMode", "ladder-mode", "ladderMode"),
        # the digit-boundary rule is the surprising one: a name like "1C opening" does not
        # survive as typed, which is why the server computes the key rather than assuming it
        ("1c_opening", "1-c-opening", "1COpening"),
        ("long auctions", "long-auctions", "longAuctions"),
        ("difficulty", "difficulty", "difficulty"),
    ],
)
def test_transform_matches_datastar(text, kebab, camel):
    assert render.datastar_kebab(text) == kebab
    assert render.datastar_camel(text) == camel


def test_topic_slug_and_key_are_consistent():
    name = "1NT opening — responses"
    slug = render.topic_slug(name)
    assert re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", slug), slug
    # the key is what the binding actually writes into the signal store
    assert render.topic_signal_key(name) == render.datastar_camel(slug)


def test_every_referenced_signal_is_declared():
    """An undeclared signal reads as `''`, which `data-attr` treats as "set the attribute".

    That is how the topics `<dialog>` ended up permanently open. Anything a template reads has
    to be in the initial `data-signals` payload.
    """
    import corpus
    import state

    session = state.new_session(corpus.DEFAULT_VARIANT)
    declared = set(render.bound_signals(session)) | set(render.signals(session)) | set(render.local_ui_signals())

    referenced: set[str] = set()
    for template in TEMPLATE_DIR.glob("*.j2"):
        for match in re.finditer(r"\$([A-Za-z_][\w]*)", markup_of(template)):
            referenced.add(match.group(1))

    assert referenced <= declared, f"undeclared signals: {sorted(referenced - declared)}"


def test_underscore_signals_are_never_attribute_keys():
    """`kebab` turns a leading underscore into a dash and `camel` then drops it, so
    `data-indicator:_answering` would name the signal `Answering` -- no longer local, and
    uploaded with every request. Underscore signals must use the value form."""
    assert render.datastar_camel("_answering") == "Answering"

    for template in TEMPLATE_DIR.glob("*.j2"):
        assert not re.search(r"data-(?:bind|signals|indicator|ref):_", markup_of(template)), template.name


@pytest.mark.parametrize("template", sorted(TEMPLATE_DIR.glob("*.j2")))
def test_no_mixed_case_binding_keys_in_templates(template):
    """A capital letter in an attribute *key* is silently lost by the HTML parser."""
    for match in re.finditer(r"data-(?:bind|signals|indicator|ref):([\w.{}| -]+)", markup_of(template)):
        key = match.group(1)
        if "{{" in key:  # rendered from a slug, covered by the tests above
            continue
        assert key == key.lower(), f"{template.name}: mixed-case attribute key {key!r}"


def test_no_element_binds_both_click_and_enter_keydown():
    """A focused button activates on Enter/Space by itself.

    Binding `data-on:click` and an Enter-handling `data-on:keydown__window` to the same element
    fired the action twice; the second request superseded and aborted the first *after* the server
    had mutated state, leaving the browser on a stale view. Window keydown handlers that act on
    Enter or Space must therefore exclude BUTTON targets.
    """
    for template in TEMPLATE_DIR.glob("*.j2"):
        markup = markup_of(template)
        for match in re.finditer(r"data-on:keydown__window=\"([^\"]+)\"", markup):
            expression = match.group(1)
            if "Enter" in expression or "' '" in expression:
                assert "BUTTON" in expression, (
                    f"{template.name}: Enter/Space window handler must exclude BUTTON targets"
                )
