"""The Base CSS picker and the stylesheets that exist must agree.

`shell.html.j2` BUILDS the href from the `$_css` signal -- `/static/app.css` for `hand`,
`/static/app-<value>.css` for anything else -- so the file naming is the contract and a fourth
variant needs no template edit. The failure mode that buys is silent: a typo in an `<option>` value
or a missing file gives a 404 on the stylesheet and an unstyled page, with nothing in the server log
to say so. These tests are the check the browser cannot make for us.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import corpus
import render
import state

STATIC = Path(render.__file__).resolve().parent / "static"
TEMPLATES = Path(render.__file__).resolve().parent / "templates"


@pytest.fixture(scope="module")
def shell_markup():
    """A DEBUG session: the picker is debug-only now, so a plain one has no <select> to check.

    The variants themselves are not debug-only -- `$_css` still swaps the sheet for anyone who has
    the signal set -- so everything below is still testing what ships.
    """
    session = state.new_session(corpus.DEFAULT_VARIANT)
    session.debug = True
    return render.shell(session)


@pytest.fixture(scope="module")
def player_markup():
    return render.shell(state.new_session(corpus.DEFAULT_VARIANT))


def stylesheet_for(value: str) -> Path:
    """The same rule the template's expression implements."""
    return STATIC / Path(render.stylesheet_href(value)).name


def picker_values(markup: str) -> list[str]:
    select = re.search(r'<select data-bind="_css"[^>]*>(.*?)</select>', markup, re.DOTALL)
    assert select, "no Base CSS picker in the rendered shell"
    return re.findall(r'<option value="([^"]+)"', select.group(1))


def test_the_href_is_built_from_the_signal_rather_than_a_ternary_chain(shell_markup):
    """Pinned because the convention is what lets a variant be added without touching the shell."""
    assert "'/static/app-' + $_css + '.css'" in shell_markup


def test_the_href_expression_survives_an_undeclared_signal(shell_markup):
    """The link is in <head>, so it is evaluated before <body> declares any signal.

    An undefined signal reads as `''` in a datastar expression, and building the name from that
    fetched `/static/app-.css` -- a 404 on every page load, in the console but nowhere else. So the
    expression tests the signal first, and an empty one means the DEFAULT sheet: the same string as
    the static `href`, so the fallback repaints nothing.
    """
    expression = re.search(r'data-attr:href="([^"]+)"', shell_markup)
    assert expression, "no data-attr:href on the stylesheet link"
    assert expression.group(1).startswith("$_css ?"), expression.group(1)
    assert expression.group(1).endswith(f"'{render.stylesheet_href(render.DEFAULT_CSS)}'"), expression.group(1)


def test_the_base_css_picker_is_debug_only(shell_markup, player_markup):
    """The comparison is settled and the differences are invisible to a player -- so the choice is
    ours, not theirs. It stays reachable with `?debug`, which is how the spike is still checked."""
    assert 'data-bind="_css"' in shell_markup
    assert 'data-bind="_css"' not in player_markup
    # ...and the other two Appearance controls are NOT debug-only: a font and the game-feel toggle
    # are differences you can see
    assert 'data-bind="_font"' in player_markup
    assert 'data-bind="_juice"' in player_markup


def test_every_offered_variant_has_a_stylesheet(shell_markup):
    values = picker_values(shell_markup)
    assert set(values) >= {"hand", "pico", "bulma"}
    for value in values:
        assert stylesheet_for(value).is_file(), f"option {value!r} points at a missing stylesheet"


def test_the_default_variant_is_the_one_the_link_falls_back_to(player_markup):
    """The static `href` paints before datastar has evaluated anything; it must be the default.

    It stopped being `app.css` when the default became Pico, and getting this wrong is a real cost
    rather than a tidiness point: the browser fetches and paints one sheet, then swaps to another a
    tick later.
    """
    default = render.local_ui_signals()["_css"]
    assert default == render.DEFAULT_CSS
    assert stylesheet_for(default).is_file()
    assert f'href="{render.stylesheet_href(default)}"' in player_markup


@pytest.mark.parametrize("vendored", ["pico.classless.min.css", "bulma.min.css"])
def test_the_vendored_frameworks_are_imported_not_fetched_from_a_cdn(vendored):
    """Same rule as `datastar.js`: vendored, so the app works offline and pins what was tested."""
    assert (STATIC / vendored).is_file()
    importers = [css for css in STATIC.glob("app-*.css") if f'@import url("{vendored}")' in css.read_text()]
    assert importers, f"{vendored} is vendored but no adapter imports it"


def test_no_stylesheet_url_is_rooted_at_slash_static():
    """The one URL in the app that CANNOT have the deployment prefix pasted into it.

    Every URL the templates emit is prepended with `render.url_prefix()`; a stylesheet is not a
    template, so `@import url("/static/x.css")` is frozen at the root and 404s under a prefix
    (`/bridge-system-quiz/...`). Relative is prefix-agnostic: an @import resolves against the
    importing stylesheet's own URL.

    It bit as a DARK MODE bug, which is why it survived so long: with Pico's sheet missing, every
    `--pico-*` token was undefined, `.card` fell through to its `#fff` fallback, and the quiz card
    sat white on a canvas the adapter's own tokens had correctly painted dark. Local dev has no
    prefix, so it only ever appeared on the deployed box.
    """
    for css in STATIC.glob("app*.css"):
        rooted = re.findall(r'url\(\s*["\']?/static/[^)]*\)', css.read_text(encoding="utf-8"))
        assert not rooted, f"{css.name}: root-absolute URL(s) {rooted} -- 404 under a deployment prefix"


def test_a_framework_that_styles_aria_busy_is_neutralised_on_the_choice_group():
    """ARIA state attributes are style hooks too, which is not obvious until it bites.

    The choice group carries `aria-busy="true"` while an answer is in flight. Pico reads that as its
    LOADING component: `white-space: nowrap` plus a spinner `::before`. On a grid of wrapped
    multi-line choices that snapped every candidate to one line and spilled the text out of its box
    for the 2.5-3.5s the toast sequence runs -- it read as the page breaking, and only in Pico.

    So: any adapter whose vendored framework has an opinion about `aria-busy` must state its own.
    """
    for adapter in STATIC.glob("app-*.css"):
        text = adapter.read_text(encoding="utf-8")
        imported = re.search(r'@import url\("([^"]+)"\)', text)
        if not imported:
            continue
        framework = (STATIC / imported.group(1)).read_text(encoding="utf-8")
        if "[aria-busy=true]" not in framework:
            continue
        assert '.candidates[aria-busy="true"]' in text, (
            f"{adapter.name}: {imported.group(1)} styles [aria-busy], so the choice group needs an override"
        )


@pytest.mark.parametrize("name", ["app.css", "app-pico.css", "app-bulma.css"])
def test_the_disclosures_under_the_question_have_a_surface(name):
    """`<details>` is a native element, so a framework may give it no surface at all.

    Pico styles the summary and the marker but not the box, which left Notation and System Notes as
    a heading and a chevron floating on the page background -- present, but not reading as panels.
    Every variant states a background for them.
    """
    css = (STATIC / name).read_text(encoding="utf-8")
    rules = re.findall(r"^(?:\.main > )?\.notes\s*\{([^}]*)\}", css, re.MULTILINE)
    assert rules, f"{name}: no rule for the notes disclosures"
    assert any("background" in body for body in rules), f"{name}: the notes disclosures have no surface"


def test_bulmas_class_strings_ride_with_our_semantic_ones():
    """Bulma is class-based, so a button without `.button` is unstyled in that variant only.

    The pairing is easy to forget when adding a control, and the other two stylesheets keep working,
    so nothing complains until someone switches the picker. `.nav-toggle` is exempt: it is a bare
    hamburger that all three sheets style themselves.
    """
    exempt = {"nav-toggle"}
    for template in TEMPLATES.glob("*.html.j2"):
        for tag in re.findall(r"<button\b[^>]*>", template.read_text(encoding="utf-8"), re.DOTALL):
            classes = re.search(r'class="([^"]*)"', tag)
            names = set(classes.group(1).split()) if classes else set()
            if names & exempt:
                continue
            assert "button" in names, f"{template.name}: <button> without Bulma's `button` class: {tag}"
