"""HTML rendering: the page shell, the patchable fragments, and the signal payloads.

Two things worth knowing about how the fragments are split:

* Only `#quiz` and `#toasts` are ever patched as *elements*. The score panel, the skip
  counter and the timer bar are markup that never changes -- their values arrive as signals
  and are applied by `data-text` / `data-style`. That is datastar's "backend drives the
  frontend by patching elements *and* signals" with the cheap half used where it fits.
* Those server-owned display signals are `_`-prefixed (`$_points`, `$_scorePct`, ...). The
  underscore means datastar excludes them from every outgoing request
  (`exclude = /(^|\\.)_/` in the engine's fetch plugin), which is exactly right: the server
  told the browser these values, so it must not have them echoed back on the next click.

`emoji_text_auction` and its regexes are copied from `apps/quiz/quiz_app.py:639-719` rather
than imported -- that module imports panel. It is presentation-only, and the copy is the one
piece of deliberate duplication in this port.
"""

from __future__ import annotations

import functools
import json
import re
from collections.abc import MutableMapping
from pathlib import Path
from typing import TYPE_CHECKING, Any, cast

from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape
from markupsafe import Markup, escape

import corpus
import engine
import sfx

if TYPE_CHECKING:
    import state

TEMPLATE_DIR = Path(__file__).resolve().parent / "templates"

# The base stylesheet everyone gets. The A/B/C between the hand-rolled sheet, Pico and Bulma is over
# (COMPARISON.md): the three are near-indistinguishable to a player, so the picker is now a
# DEBUG-only control and this is what a session starts with. Pico wins on maintenance, not looks --
# <details>, <dialog>, <kbd>, focus rings and the light/dark switch are the framework's problem there.
DEFAULT_CSS = "pico"


def build_stamp() -> str:
    """A short fingerprint of the SERVER-SIDE sources, shown in the debug panel.

    Not vanity. Three times now, a "the app is broken again" has turned out to be a process serving
    code from before the fix -- templates are re-read from disk on every render, but this module is
    not, so a half-reloaded server renders new markup with stale constants and the failure looks like
    a fresh bug. The stamp changes when the code does, so "am I looking at what I just edited" is a
    glance rather than an investigation.

    Computed per call from mtimes: cheap, and a cached value would defeat the point on the one path
    that matters (a reload that did not happen).
    """
    here = Path(__file__).resolve().parent
    sources = sorted([here / "render.py", here / "app.py", *TEMPLATE_DIR.glob("*.j2")])
    newest = max(int(path.stat().st_mtime) for path in sources)
    return f"{newest:x}"[-6:]


# The theme preference, remembered in a COOKIE rather than in `localStorage`, and the choice is not
# arbitrary:
#   * a cookie is on the request, so the server can render `data-theme` into the FIRST PAINT. Local
#     storage can only be read after JS runs, which is one frame of the wrong palette for anyone who
#     chose against their OS -- and reading it in a blocking <head> script is the `<script>` this app
#     has a test against;
#   * scope. `localStorage` is keyed by ORIGIN, so `localhost:5006` and `localhost:5008` are separate
#     stores; cookies are keyed by host and PATH and ignore the port, so one choice covers every
#     instance on the machine. Path-scoped like the session cookie, so two apps under one host on
#     different prefixes still do not overwrite each other.
# Written by the browser (`document.cookie` in the toggle's expression), read here. No round trip and
# no new route -- the server does not have an opinion about the theme, it just relays what it was
# told. `data-persist` would be the datastar-native answer and is Pro-only.
THEME_COOKIE = "dsq_theme"
THEMES = ("auto", "light", "dark")


def theme_from(raw: str | None) -> str:
    """A cookie is user input: anything unrecognised is `auto`, never interpolated into the page."""
    return raw if raw in THEMES else "auto"


def stylesheet_href(value: str, prefix: str = "") -> str:
    """The naming contract, in python: `hand` is `app.css`, anything else is `app-<value>.css`.

    The template builds the same string from `$_css` at runtime; this is for the two places the
    server has to state it -- the static `href` that paints before datastar runs, and the fallback
    that expression uses when the signal has not been declared yet (it is in <head>).
    """
    name = "app.css" if value == "hand" else f"app-{value}.css"
    return f"{prefix}/static/{name}"


_env = Environment(
    loader=FileSystemLoader(TEMPLATE_DIR),
    autoescape=select_autoescape(default_for_string=True, default=True),
    trim_blocks=True,
    lstrip_blocks=True,
    # LOUD, not blank. Jinja's default renders an unknown name as the empty string, and in this app
    # the templates are mostly *expressions for the browser*: a missing `{{ TYPING_TARGETS }}` becomes
    # `closest?.('')`, which throws inside a datastar handler and takes every keyboard shortcut on the
    # page with it -- silently, and only at runtime. A NameError while rendering is the same bug,
    # found in a test instead of in the browser.
    undefined=StrictUndefined,
)

# What may swallow a keystroke aimed at the window. Every accelerator (1-9, `s`, Enter on the reveal)
# is a window keydown, so each one has to decide whether the focused control has a better claim on
# the key -- and the first version of this said "any form control", which is too many.
#
# Focus a RANGE input (the difficulty slider) or tick a CHECKBOX and the digits went dead for the
# rest of the session, because a slider keeps focus by design -- it has to, or you could not arrow
# it. But a range has no use for `1`, a checkbox has no use for `s`: the only controls with a claim
# on a printable key are the ones you TYPE into, plus `<select>`, which type-aheads.
TYPING_TARGETS = "input:not([type=range]):not([type=checkbox]):not([type=radio]), select, textarea, [contenteditable]"
# Enter and Space are different: Space ACTIVATES a focused checkbox or radio, so those keep their
# claim here even though they have none on a digit. A range still does nothing with either.
ACTIVATION_TARGETS = "input:not([type=range]), select, textarea, [contenteditable]"
# The width at which the drawer stops being a column beside the quiz and becomes an overlay ON TOP
# of it. Below this it hides the thing you are configuring, so the handlers that mean "done" close it;
# above it, closing the drawer would just take the settings away for no reason. Written once here
# because it has to agree with the `@media` block that does the repositioning -- pinned by
# `tests/test_hud.py`, since a drawer that stays open over the quiz is invisible in every unit test.
DRAWER_OVERLAY_QUERY = "(max-width: 900px)"

# Jinja documents `Environment.globals` as `MutableMapping[str, Any]`, but it is only ever ASSIGNED
# (`self.globals = DEFAULT_NAMESPACE.copy()`, environment.py), so a type checker infers its value type
# from what that namespace happens to hold -- `range`, `dict` and the `lipsum` function. Every string
# put here is then an error. One named alias with the documented type, rather than three suppressions.
_globals = cast("MutableMapping[str, Any]", _env.globals)
_globals["DRAWER_OVERLAY_QUERY"] = DRAWER_OVERLAY_QUERY
_globals["TYPING_TARGETS"] = TYPING_TARGETS
_globals["ACTIVATION_TARGETS"] = ACTIVATION_TARGETS

# --- suit emoji presentation (copied from the panel app) ---------------------

# The plain text glyphs, deliberately WITHOUT the U+FE0F variation selector the panel app used
# (`heart_emoji_black = "♥️"`). VS16 asks for emoji presentation, so hearts and diamonds were
# drawn by the colour emoji font while spades and clubs stayed text glyphs inheriting the
# element's colour -- which is why a spade went white on the dark card. All four are text glyphs
# now, and `suits` colours them with bml's own classes so the quiz matches the system notes.
SPADE = "♠"
HEART = "♥"
DIAMOND = "♦"
CLUB = "♣"

# letter -> (bml css class, glyph). Same names and glyphs as `bml2html._SUIT`, so the colours
# defined in `bml.css` (.ccolor MediumSeaGreen / .dcolor Orange / .hcolor Red / .scolor Black)
# are the colours here.
SUIT_CLASSES = {
    CLUB: "ccolor",
    DIAMOND: "dcolor",
    HEART: "hcolor",
    SPADE: "scolor",
}
_SUIT_GLYPH_RE = re.compile(f"[{''.join(SUIT_CLASSES)}]")

_suit_replace_regex = re.compile(
    r"""
    \d  # a number
    (
        [CDHS]  # CDHS to replace with spans, but will have to check it's not in [] or () somehow
        | # or an N (but not NT which will become NT after replacement)
        N(?!T)
    )+ # 1+ suit or N symbols to replace
    """,
    re.VERBOSE,
)
_link_regex = re.compile(r"\(#.*\)")

# silly, but a button strips excess internal whitespace, so the separator carries its own
_INVIS_SEP = "⁣"
_BID_SEPARATOR = f"{_INVIS_SEP * 4}‣{_INVIS_SEP * 4}"


def _suit_replace(matchobj: re.Match[str]) -> str:
    text = matchobj.group(0)
    text = text.replace("C", CLUB)
    text = text.replace("D", DIAMOND)
    text = text.replace("H", HEART)
    text = text.replace("S", SPADE)
    return text.replace("N", "NT")


def emoji_text_auction(auction: str) -> str:
    a = auction

    if auction.count("(") == 1 and auction.count(")") == 1 and "(Pass)" in auction:
        # superfluous (pass); better fixed in the data source, or by making all opposition
        # bids explicit
        a = a.replace("(Pass)", _BID_SEPARATOR)

    a = re.sub(_suit_replace_regex, _suit_replace, a)
    a = a.replace("!c", CLUB).replace("!d", DIAMOND).replace("!h", HEART).replace("!s", SPADE)

    a = a.replace(" C ", f" {CLUB} ").replace(" D ", f" {DIAMOND} ")
    a = a.replace(" H ", f" {HEART} ").replace(" S ", f" {SPADE} ")

    a = re.sub(r"\bC ", f"{CLUB} ", a)
    a = re.sub(r"\bD ", f"{DIAMOND} ", a)
    a = re.sub(r"\bH ", f"{HEART} ", a)
    a = re.sub(r"\bS ", f"{SPADE} ", a)

    a = a.replace("Cs", f"{CLUB}s").replace("Ds", f"{DIAMOND}s")
    a = a.replace("Hs", f"{HEART}s").replace("Ss", f"{SPADE}s")

    a = a.replace("-->", _BID_SEPARATOR).replace("--", "-")

    # link text stays, link target goes
    a = a.replace("[", "").replace("]", "")
    return re.sub(_link_regex, "", a)


def suits(text: str) -> Markup:
    """Colour the suit glyphs: `♠` -> `<span class="scolor">♠</span>`.

    Registered as the `suits` jinja filter and applied wherever auction text is rendered. The
    input is escaped first, so this is safe for anything -- including the bml descriptions, which
    are corpus text rather than user input, and the auctions inside toast messages.

    A filter rather than part of `emoji_text_auction` because that function's output also travels
    through `engine`'s toast strings, where markup would be escaped again on the way out.
    """
    escaped = str(escape(text))
    return Markup(  # noqa: S704 -- the interpolated text was escaped on the line above
        _SUIT_GLYPH_RE.sub(lambda m: f'<span class="{SUIT_CLASSES[m.group(0)]}">{m.group(0)}</span>', escaped)
    )


_env.filters["suits"] = suits


# --- view models ------------------------------------------------------------

_INTRO = {
    "Auctions": "In which auction is the final bid best described by:",
    "Descriptions": "Which description matches the final bid in this sequence:",
}


def _quiz_context(session: state.Session) -> dict:
    question = session.question
    answer = emoji_text_auction(question.answer)
    return {
        "intro": _INTRO[question.choice_type.value],
        "answer": answer[:1].upper() + answer[1:],
        "candidates": [emoji_text_auction(c) for c in question.candidates],
        "qid": session.qid,
        "prefix": url_prefix(),
        "variant_query": variant_query(session.variant),
    }


def signals(session: state.Session) -> dict:
    """Every signal the server owns, as a patch payload.

    Local (`_`-prefixed) so they are never uploaded back. `_timeLeftPct` and `_questionMs`
    drive the timer bar: the server states the allowance and resets the bar to 100 per
    question, and the browser's 100ms interval walks it down by `10000 / $_questionMs` per
    tick. No clock is shared, because the bar is cosmetic -- the bonus that actually scores is
    recomputed server-side from `question_start` when the answer arrives.
    """
    score = session.score
    return {
        "_correct": score.questions_correct,
        "_attempted": score.questions_attempted,
        "_scorePct": score.percentage(),
        "_points": score.total_points,
        "_pointsPct": min(round(score.total_points / session.points_goal * 100), 100),
        "_streak": score.streak,
        "_skipsLeft": session.skips_left,
        "_playing": session.still_playing,
        # Whether the countdown should be running at all. `_playing` is not the same question: a
        # scored answer parks on the reveal with the quiz very much still in play, and the bar kept
        # draining there -- time pressure on a question that had already been answered, running down
        # to empty behind the right answer. The client interval and the held stream both gate on it.
        "_ticking": session.on_the_clock,
        "_questionMs": round(session.question_seconds * 1000),
        "_timeLeftPct": session.percent_time_left() if session.still_playing else 0,
    }


def settings_signals(session: state.Session) -> dict:
    """The *effective* settings, to be echoed back after the server has adopted them.

    The browser originates these, but the server clamps them (`engine.clamp_difficulty`, the 70-90
    target range), so after adopting a value the two can disagree -- send `difficulty: 99` and the
    server uses 8 while the slider still reads 99 until the next page load. Echoing the effective
    values is the "backend is the source of truth" rule applied to the round trip, not just the load.

    Note what is deliberately NOT here: `filterText` and the `topics` ticks. Those are drafts the user
    may be in the middle of editing, and re-stating them on an unrelated patch (a Skip, say) would
    wipe what they were typing. Full-state patching is right for state the server owns and wrong for
    state the client is still editing -- `bound_signals` is used only where a commit has just made the
    server's version authoritative.
    """
    settings = session.settings
    return {
        "difficulty": settings.difficulty,
        "ladderMode": settings.ladder_mode,
        "targetOn": settings.target_on,
        "targetPct": settings.target_pct,
    }


def bound_signals(session: state.Session, active_topics: tuple[str, ...] = ()) -> dict:
    """The signals the *browser* owns: form inputs bound with `data-bind`.

    These have no underscore, so datastar uploads them with every request -- that is how the
    server learns the slider moved. The session's copy is only a mirror of what the browser
    last said (`read_signals` on the next request is the authority).

    `topics` is seeded from the filter in force, so the picker's ticks agree with it even when
    the filter was typed rather than picked -- the panel app kept the same invariant by
    assigning `topics_checkbox_group.value` on every commit.
    """
    settings = session.settings
    ticked = {topic_signal_key(name) for name in active_topics}
    return {
        "difficulty": settings.difficulty,
        "ladderMode": settings.ladder_mode,
        "targetOn": settings.target_on,
        "targetPct": settings.target_pct,
        "filterText": session.filter_text,
        "topics": {choice["key"]: choice["key"] in ticked for choice in topic_choices(session)},
    }


def url_prefix() -> str:
    """Where the app is mounted, for the URLs the templates write (`app.URL_PREFIX`).

    Empty for a root mount, which is the default and the only case the tests exercise by name --
    every template renders `{{ prefix }}/answer/...`, so an empty prefix is byte-identical to the
    root-absolute URLs this app had before it could be mounted anywhere.

    Read lazily through the app module for the same reason as `timer_mode`: a test can set it
    without reimporting anything.
    """
    # deferred, not a module-level import: app imports render, so this would be circular
    import app

    return app.URL_PREFIX


def variant_query(variant: corpus.Variant) -> str:
    """The query every ACTION url carries, naming the system this page belongs to (`?swedish`).

    The session cookie is one per browser, so it cannot say which quiz a given *page* is playing:
    open `?swedish` and the squad tab, the back-history entry and the phone's other tab all still
    hold the old markup while the cookie has moved on. The page's own URLs can say it, and they are
    written by the server that knows.

    It is read only when a session has to be BUILT (`app._session_for`): a restart, a six-hour gap
    or a switch in another tab used to hand a swedish page a squad session -- questions from the
    wrong system under a title from the right one, which is what "the header does not match the URL"
    was. It never switches a live session; see the note there for why that would be worse.
    """
    return f"?{variant.key}"


def timer_mode() -> str:
    """Which countdown push model the shell should wire up (see `app.TIMER_MODE`).

    Read lazily through the app module so a test can flip it without reimporting anything.
    """
    # deferred, not a module-level import: app imports render, so this would be circular
    import app

    return app.TIMER_MODE


def local_ui_signals(theme: str = "auto") -> dict:
    """View-local signals the server never sets, declared so they exist from the first paint.

    They must be declared: an undefined signal reads as `''` in an expression, and `data-attr`
    treats `''` as "set the attribute" (`library/src/plugins/attributes/attr.ts`), so an
    undeclared `$_topicsOpen` leaves `<dialog open>` -- the picker is stuck open.

    Declared here, in the `data-signals` *object*, rather than as `data-signals:_topics-open`:
    attribute keys are kebab-then-camel converted, which eats a leading underscore, and the
    underscore is what keeps these out of every request.
    """
    return {
        "_topicsOpen": False,
        "_answering": False,
        "_font": "notes",
        # `auto` | `light` | `dark`, remembered across reloads in `THEME_COOKIE` (see above) and
        # seeded from it here, so the signal and the server-rendered attribute agree from the first
        # frame. Mirrored onto <html> as `data-theme`, and DELIBERATELY absent
        # when it is auto: absent means `color-scheme: light dark`, which is the OS's choice and the
        # only value that needs no JavaScript to be right on the first paint. See the theme switch
        # note in `app.css`. Local, like every other appearance preference -- the server has no
        # opinion about which palette a player is looking at.
        "_theme": theme,
        # closed at every width now that the drawer holds only settings; `data-init`
        # sets it too, but a `True` here flashed the drawer open before init ran
        "_navOpen": False,
        # Pico, not the hand-rolled sheet: the A/B/C found no difference a player would notice, and
        # Pico is the one whose native-element chrome (<details>, <dialog>, <kbd>, focus rings) the
        # app gets for free rather than maintains. The picker itself is now debug-only -- see
        # `DEFAULT_CSS` below and `app.html.j2`.
        "_css": DEFAULT_CSS,
        # The "game feel" experiment: hit-stop and shake on the reveal, floating points on the card
        # you picked, and an escalating streak chip. Purely presentational, so purely local -- the
        # server streams the floaters either way and `body.juice` decides whether they are visible.
        "_juice": True,
        # Sound, OFF by default and the only appearance preference that is. Everything else here
        # changes how the page looks to the person who asked for it; audio arrives in a room, and a
        # quiz played in a lesson or on a train should make no noise until someone says so.
        #
        # It also gates the FETCH: the `<audio>` elements in `shell.html.j2` have no `src` until this
        # is true, so a player with sound off never asks the server for a single WAV.
        "_sound": False,
    }


def shell(session: state.Session, theme: str = "auto") -> str:
    """The whole document: server-rendered current state, no client-side bootstrap.

    `theme` comes from the cookie the toggle wrote. It is rendered STATICALLY onto <html> as well as
    declared as a signal: the attribute is what makes the first paint right, and the signal is what
    keeps it right when the toggle is clicked.
    """
    context = _page_context(session)
    initial = {
        **bound_signals(session, context["_check"].parsed.topic_names),
        **signals(session),
        **local_ui_signals(theme),
    }
    return _env.get_template("shell.html.j2").render(
        initial_signals=json.dumps(initial),
        # `auto` is the absence of the attribute -- see the theme switch note in `app.css`
        theme=theme if theme != "auto" else "",
        # the `<audio>` elements, which live outside `#app` and so exist only in the document
        sfx_names=sfx.NAMES,
        **context,
    )


def _page_context(session: state.Session) -> dict:
    """Everything both the document and the fat-morph fragment need."""
    check = corpus.check_filter(
        session.variant.bml_file, session.variant.key, session.filter_text, engine.MAX_DIFFICULTY
    )
    return {
        "variant": session.variant,
        "settings": session.settings,
        "playing": session.still_playing,
        "quiz_body": quiz_body(session),
        "min_difficulty": engine.MIN_DIFFICULTY,
        "max_difficulty": engine.MAX_DIFFICULTY,
        "milestones": engine.SCORE_MILESTONES,
        "points_goal": session.points_goal,
        "debug": session.debug,
        "qid": session.qid,  # the debug panel's status line; the quiz fragment has its own copy
        "timer_mode": timer_mode(),
        "build_stamp": build_stamp(),
        # both the static href and the expression's empty-signal branch, from one place
        "css_href": stylesheet_href(DEFAULT_CSS, url_prefix()),
        # the toggle writes this cookie itself; python owns the name and the scope
        "theme_cookie": THEME_COOKIE,
        "cookie_path": url_prefix() or "/",
        "topics": topic_choices(session),
        "filter_text": session.filter_text,
        "filter_status": filter_status(check, in_force=session.filter_text),
        "prefix": url_prefix(),
        "variant_query": variant_query(session.variant),
        "_check": check,
    }


def app_body(session: state.Session) -> str:
    """The whole page below `<body>`: the fat-morph unit.

    Sending this rather than a hand-picked fragment is what the Tao asks for, and it removes a class
    of bug -- the server no longer has to remember which fragments a state change touches.
    """
    return _env.get_template("app.html.j2").render(**_page_context(session))


def quiz_body(session: state.Session) -> str:
    """The `#quiz` fragment: prompt, the thing to match, and the candidate buttons -- or the
    revealed answer after a wrong one, or the completion screen once the points goal is met."""
    if not session.still_playing:
        score = session.score
        return _env.get_template("completed.html.j2").render(
            # rounded to whole seconds: the finale renders this at 2.4rem, one span per character, and
            # "137" assembles better than "137.4" -- the tenth was never information anybody wanted
            elapsed=round(session.elapsed_seconds),
            # the finale assembles these digit by digit, so it needs the numbers rather than a
            # sentence -- and they were already computed for the sidebar
            points=score.total_points,
            correct=score.questions_correct,
            attempted=score.questions_attempted,
            percentage=score.percentage(),
            goal=session.points_goal,
            confetti=_CONFETTI,
            prefix=url_prefix(),
            variant_query=variant_query(session.variant),
        )
    context = _quiz_context(session)
    if session.awaiting_next:
        question = session.question
        return _env.get_template("reveal.html.j2").render(
            **context,
            correct_index=question.candidates.index(question.answer_candidate),
            wrong_index=session.wrong_index,
        )
    return _env.get_template("quiz.html.j2").render(**context)


# --- datastar attribute-key naming ------------------------------------------
#
# HTML lowercases attribute names, so `data-bind:filterText` reaches datastar as
# `data-bind:filtertext` and binds a *different* signal from the `filterText` the server seeded.
# Datastar's answer is to write attribute keys in kebab-case and convert: `bind.ts` runs the key
# through `camel`, which is `kebab` then de-dashing (`library/src/utils/text.ts`). `kebab` also
# splits letter/digit boundaries, so `1c_opening` becomes the signal `1COpening` -- which is why
# a slug cannot simply be assumed to survive the trip. These two mirror that transform, so the
# markup and the server agree on the name.


# MEMOISED, all four of them. The yappi profile of a 60-user minute counted 37,868 calls to
# `datastar_kebab`, 25,236 to `topic_slug` and 12,632 to `topic_signal_key` -- five regex passes each,
# recomputed on every render, for values that are pure functions of a topic name that never changes
# within a process. `maxsize` rather than an unbounded cache as a matter of habit: nothing user-typed
# reaches these today (the names come from the topics file), and a bound means it cannot start to.
@functools.lru_cache(maxsize=1024)
def datastar_kebab(text: str) -> str:
    out = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", text)
    out = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", out)
    out = re.sub(r"([a-z])([0-9]+)", r"\1-\2", out, flags=re.IGNORECASE)
    out = re.sub(r"([0-9]+)([a-z])", r"\1-\2", out, flags=re.IGNORECASE)
    out = re.sub(r"[\s_]+", "-", out)
    return out.lower()


@functools.lru_cache(maxsize=1024)
def datastar_camel(text: str) -> str:
    return re.sub(r"-(.)", lambda m: m.group(1).upper(), datastar_kebab(text))


@functools.lru_cache(maxsize=1024)
def topic_slug(name: str) -> str:
    """The attribute form of a topic name: `data-bind:topics.<slug>`."""
    slug = datastar_kebab(re.sub(r"[^0-9A-Za-z\s_-]+", " ", name))
    return re.sub(r"-{2,}", "-", slug).strip("-") or "topic"


@functools.lru_cache(maxsize=1024)
def topic_signal_key(name: str) -> str:
    """The name that same binding actually writes into the signal store."""
    return datastar_camel(topic_slug(name))


def topic_choices(session: state.Session) -> tuple[dict, ...]:
    """The topics picker's rows. Built once per variant, not once per render.

    A TUPLE, and shared between sessions: the rows are read-only everywhere (the templates iterate
    them, `_topics_text_from` reads two keys), and an immutable container says so. The topics
    themselves were already `functools.cache`d -- only this derivation was not.
    """
    return _topic_choices(session.variant.bml_file, session.variant.key)


@functools.cache
def _topic_choices(bml_file: str, variant_key: str) -> tuple[dict, ...]:
    return tuple(
        {
            "name": topic.name,
            "slug": topic_slug(topic.name),
            "key": topic_signal_key(topic.name),
            "description": topic.description,
        }
        for topic in corpus.topics_for(bml_file, variant_key).values()
    )


def filter_status(check: corpus.FilterCheck, *, in_force: str, pending_hint: str = "") -> str:
    """The `#filter-status` fragment: what the text in the box *would* select.

    Port of `_filter_feedback`. Asking never commits anything, so this is safe to render on
    every keystroke -- which is the point: the validation lives with `bidfilter`, on the server,
    and the browser needs to know nothing about bidding.
    """
    parsed = check.parsed
    lines: list[Markup] = []
    if parsed.errors:
        # the unrecognised entries are whatever the user typed, so they are escaped, not trusted
        offenders = Markup(", ").join(Markup("<code>{}</code>").format(e) for e in parsed.errors)
        lines.append(Markup("⚠ not a topic or pattern: ") + offenders)
    if check.status == "too_few":
        lines.append(
            Markup("⚠ only {} match, need {}+ — the whole system is used").format(
                len(check.hits), engine.MAX_DIFFICULTY
            )
        )
    elif check.status == "error":
        lines.append(Markup("⚠ nothing usable — the whole system is used"))
    elif not parsed.entries:
        lines.append(Markup("the whole system, <strong>{}</strong> auctions").format(len(check.hits)))
    else:
        lines.append(Markup("<strong>{}</strong> auctions match").format(len(check.hits)))
    if pending_hint and parsed.canonical_text != in_force:
        lines.append(Markup("<em>{}</em>").format(pending_hint))
    return _env.get_template("filter_status.html.j2").render(lines=lines)


# The confetti burst on the completion screen: fixed, not random, because the server renders it and a
# reload should not re-roll the party. Each entry is (glyph, horizontal drift %, rotation deg, delay
# step) -- the numbers are spread by hand so the burst looks scattered rather than combed, which is
# the one thing a formula (`i * 37 % 100`) visibly fails at.
_CONFETTI: tuple[tuple[str, int, int, int], ...] = (
    ("🎉", -42, -35, 0),
    ("🎊", -28, 24, 3),
    ("✨", -35, -12, 7),
    ("🥳", -14, 41, 1),
    ("🎉", -6, -28, 5),
    ("🎊", 9, 16, 2),
    ("✨", 18, -44, 8),
    ("🎉", 27, 31, 4),
    ("🥳", 36, -19, 6),
    ("🎊", 44, 38, 1),
    ("✨", -21, 9, 9),
    ("🎉", 3, -40, 7),
    ("🎊", 31, 12, 3),
    ("✨", -47, 27, 5),
    ("🥳", 22, -33, 8),
    ("🎉", -11, 44, 2),
)


def toast(item: engine.Toast) -> str:
    """The `#toasts` fragment. An empty text renders an empty container -- the panel handler's
    bare `await asyncio.sleep(1.0)` beat between the last toast and the next question."""
    return _env.get_template("toast.html.j2").render(toast=item)


# The floater says what you SCORED, so only the beats carrying a number get one -- "Correct!" and
# "Not quite" are already said by the card's own tick or cross, and repeating them over the card was
# noise. `+1 SKIP!` earns one because it is a reward the corner toast makes too easy to miss.
_FLOATER_NUMBER_RE = re.compile(r"[+-]\d+")


def floater(item: engine.Toast, *, final: bool = False) -> str:
    """The number that floats up off the card the player chose, or `""` for a beat without one.

    `final` marks the answer that crossed the points goal: the same number, in gold, larger and
    slower, because it is the last one the player will ever see on that card.

    The text is the toast's own -- trimmed to the part that is a score -- so the two can never
    disagree about what was awarded. `engine.Toast` phrases those as `+22!`, `Streak 3, Bonus +15`,
    `Time Bonus +15`, `Ladder mode: -30 points`, `+1 SKIP!`.
    """
    text = item.text.strip()
    if "SKIP" in text.upper():
        label = "+1 SKIP"
    else:
        number = _FLOATER_NUMBER_RE.search(text)
        if number is None:
            return ""
        label = number.group(0)
    kind = "gain" if label.startswith("+") else "loss"
    if final:
        kind += " final"
    return _env.get_template("floater.html.j2").render(label=label, kind=kind)


def sfx_beat(beat: str) -> str:
    """One sound beat: markup that plays `<audio id="sfx-<beat>">`, which is already in the page.

    Appended to `#sfx` (see `app._answer_stream`), which is the same trick as the floaters -- the
    server knows when the beat happened, so the beat is a patch rather than something the browser has
    to work out. Two things are deliberate:

    * **`$_sound &&` first.** The preference is a LOCAL signal, so the server cannot know it and
      streams the beat either way; the expression is the gate, exactly as `body.juice` gates the
      floaters. ~90 bytes for a player who has sound off, and the audio elements have no `src` in
      that case anyway, so nothing is fetched.
    * **`play()` and nothing else.** An element that has ENDED rewinds itself on the next `play()`
      (the spec seeks to the start), and one that is still playing ignores the call -- which is what
      makes `tick` self-spacing. So there is no `currentTime` to reset and no state to keep, which is
      why this is an attribute expression and not a helper script. `.catch` because a play() that the
      browser refuses (no `src` yet, no user gesture) rejects a promise, and an unhandled rejection is
      a console error per beat.
    """
    if beat not in sfx.SOUNDS:
        raise KeyError(beat)
    return _env.get_template("sfx.html.j2").render(beat=beat)


def meter_sweep() -> str:
    """The shine that crosses the points gauge when a milestone has just paid for a skip.

    Appended to the gauge itself, so it needs no signal and no cleanup: the fat morph at the end of
    the answer stream rewrites `#app` from markup that never contains it. Inert unless `body.juice` --
    it is game feel, like the floaters, and it is styled only in `juice.css`.
    """
    return _env.get_template("meter_sweep.html.j2").render()
