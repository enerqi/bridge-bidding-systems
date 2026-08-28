"""Litestar routes: the hypermedia surface of the quiz.

Every handler is the same shape -- mutate the authoritative session, then stream back the
patches that make the browser agree. There is no client-side model to keep in step, which is
the whole point of the experiment: the panel version reached into client state
(`button.disabled`, `skip_button.disabled`, `open_modal()`), this one re-states the view.

Two element targets exist (`#quiz`, `#toasts`); everything else the server owns arrives as
`_`-prefixed signals and is applied by `data-text` / `data-style` in the shell.

The action lives in the URL (`/answer/<qid>/<index>`), not in a signal, so a stale or repeated
click is rejected by comparing the question nonce -- replacing panel's "clicks occurred too
quickly" guard with something a reload cannot defeat.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import uuid
from collections.abc import AsyncGenerator
from json import JSONDecodeError
from pathlib import Path
from typing import Any

from datastar_py import ServerSentEventGenerator as SSE  # noqa: N814 -- the SDK's own documented alias
from datastar_py.consts import ElementPatchMode
from datastar_py.litestar import DatastarResponse, read_signals
from datastar_py.sse import DatastarEvent
from litestar import Litestar, MediaType, Request, Response, get, post
from litestar.config.compression import CompressionConfig
from litestar.datastructures import CacheControlHeader, Cookie
from litestar.di import NamedDependency, Provide
from litestar.exceptions import NotFoundException
from litestar.params import FromPath
from litestar.static_files import create_static_files_router

import corpus
import engine
import profiling
import render
import sfx
import state
import telemetry

APP_DIR = Path(__file__).resolve().parent
STORE = state.SessionStore()

# Which push model drives the countdown bar. The whole point of the port is comparing these, so both
# exist and the choice is one env var:
#
#   "client" (default) -- the browser walks `$_timeLeftPct` down with `data-on-interval`. No held
#       connection; the server states the allowance once per question and nothing else. The bonus
#       that scores is recomputed server-side either way, so the bar is only ever an animation.
#   "stream"           -- `GET /timer` is held open and pushes `patch_signals` every tick, panel's
#       model exactly (its `add_periodic_callback` pushed over the websocket). Costs one connection
#       per tab and per-tick server work per client; browsers also cap HTTP/1.1 at 6 connections
#       per host, which is the reason to keep it to ONE stream.
TIMER_MODE = os.environ.get("DSQUIZ_TIMER", "client")

# How much DOM a state change sends back. The Tao's advice is "fat morph": send large chunks and let
# the morph work out what changed, rather than hand-picking fragments.
#
#   "fat" (default) -- patch #app, the whole page below <body>. The server never has to remember which
#       fragments a change touches, which is the class of bug that let a clamped `difficulty` sit stale
#       in the sidebar. ~20KB raw, and compression is what makes that a non-issue.
#   "fragment"      -- patch #quiz only, as this app originally did. Smaller, but every server-owned
#       value outside that fragment has to be re-stated as a signal or it drifts.
MORPH_MODE = os.environ.get("DSQUIZ_MORPH", "fat")

# Where this app is mounted, when it is not at the root of a host (`DSQUIZ_PREFIX=/bridge-quiz-ds`).
#
# Litestar's `path=` prefixes every route AND both static routers, so the server side is one
# argument. The reason a prefix needs more than that is URL *generation*: the templates emit
# `@post('/answer/...')` and `<link href="/static/app.css">`, which are root-absolute and would miss
# the mount point entirely -- the browser would ask the site's root for them. So the same value is
# handed to the templates (`render.url_prefix`), which prepend it to every URL they write.
#
# Requests must therefore arrive WITH the prefix still attached: `proxy_pass http://ds_quiz;` with no
# trailing slash. A trailing slash strips it, litestar's routes stop matching, and everything 404s.
# See DEPLOY.md.
URL_PREFIX = "/" + os.environ.get("DSQUIZ_PREFIX", "").strip("/") if os.environ.get("DSQUIZ_PREFIX") else ""

# The debug panel: the panel app's `debug_enabled = pn.config.autoreload or "debug" in search`, with a
# kill switch it did not have.
#
#   unset (default) -- `?debug` on the URL turns it on for that session, and it sticks (the query is
#       gone after the first navigation, so the flag lives on the session like the variant does).
#   "1"             -- on for every session. What `just dev` sets.
#   "0"             -- OFF, and `?debug` cannot turn it on. The one to set on a public deployment,
#       because the panel can hand itself points and jump to the end -- see DEPLOY.md.
#
# Autoreload is deliberately NOT a trigger, unlike panel: `just serve` uses `--reload` for the
# convenience of it, and that should not silently arm a route that rewrites the score.
DEBUG_MODE = os.environ.get("DSQUIZ_DEBUG", "")

# Parse both systems' bid tables when the server starts rather than when a request needs them; see
# the `on_startup` note in `create_app`.
PREWARM = os.environ.get("DSQUIZ_PREWARM", "1") != "0"

TIMER_TICK_SECONDS = 0.1
# A held stream needs an upper bound, or an abandoned tab keeps a worker slot and a session alive
# forever. Ten minutes is far longer than any question; the client reopens on the next page load.
TIMER_STREAM_MAX_SECONDS = 600.0

APP_SELECTOR = "#app"
QUIZ_SELECTOR = "#quiz"
TOASTS_SELECTOR = "#toasts"
# The sound sink lives OUTSIDE `#app`, with the `<audio>` elements, so a fat morph cannot disturb a
# sound mid-play (see shell.html.j2). The gauge is inside it, which is exactly what the milestone
# sweep wants: the next view patch takes the shine away with no cleanup, like the floaters.
SFX_SELECTOR = "#sfx"
METER_SELECTOR = f"{APP_SELECTOR} .points-meter"


# --- session plumbing -------------------------------------------------------


def _session_for(request: Request, wanted: corpus.Variant | None) -> state.Session:
    """This browser's session for the variant this request belongs to, or a new one.

    The variant is resolved FIRST, because it is half the key: sessions live under (browser, variant)
    so the two systems coexist (see `state.SessionStore`). `wanted` is what the request names -- the
    query on a navigation, the query every action URL carries (`render.variant_query`) on an
    interaction. When it names none, the browser's last navigated-to variant stands in, and failing
    that the default.

    Switching systems is therefore no longer a replacement: `?swedish` parks the squad quiz and
    resumes (or starts) the swedish one, both keep their score, and a squad tab left open in the same
    browser goes on being about the squad session. That is what made a background tab dangerous
    before -- one cookie, one session, so the tab you had forgotten about was answering into the quiz
    you were playing.

    `request.state.session_replaced` records that the browser arrived with an identity we no longer
    have a quiz for -- a restart, a six-hour gap -- so the play routes can resync the page instead of
    quietly scoring against a question it has never shown.
    """
    sid = request.cookies.get(state.SESSION_COOKIE)
    variant = wanted or corpus.variant_by_key(STORE.current_variant(sid)) or corpus.DEFAULT_VARIANT
    session = STORE.get(sid, variant.key)
    if session is None:
        request.state.session_replaced = bool(sid)
        return STORE.create(variant, sid=sid)
    return session


async def provide_session(request: Request) -> state.Session:
    """The cookie is the only client state the server insists on. A missing or expired session
    is silently replaced -- a quiz is not worth an error page -- but the play routes then resync the
    page rather than acting on it (`_stale`).

    Reading a *bare* path as "take me to the default" would throw a swedish player back to squad on
    their first click, so only `index` does that -- the same trap the `?debug` flag avoids by being
    read on the page load only. In practice every action URL names its variant anyway.
    """
    return _session_for(request, corpus.requested_variant(request.url.query))


async def provide_page_session(request: Request) -> state.Session:
    """`provide_session` for the full page, where a **bare** URL additionally means the default.

    Only a real navigation can carry that meaning, which is why this is a separate dependency used
    by `index` alone -- `variant_switch_for_query` explains the three cases.
    """
    return _session_for(request, corpus.variant_switch_for_query(request.url.query))


def _stale(request: Request, session: state.Session, qid: int | None = None) -> bool:
    """Whether the page this request came from is talking about a quiz that no longer exists.

    Two ways, and they used to be handled differently for no reason:

    * the session itself is gone (`session_replaced`), so *nothing* the page says applies here;
    * the question nonce has moved on -- a double click, a replayed request, a background tab.

    Since `qid`s are unique per process (see `state.next_qid`), the second test is now exact: it can
    no longer pass by coincidence because two sessions both started counting at 1.
    """
    if getattr(request.state, "session_replaced", False):
        return True
    return qid is not None and qid != session.qid


def _resync(session: state.Session) -> DatastarResponse:
    """Answer a stale interaction by making the page tell the truth again.

    The old answer was a bare 204: correct, in that nothing should be scored, but from the player's
    chair it is a dead button -- and the page stays wrong, so the next click is stale too. This
    re-renders the whole page from the session that actually exists, which is the one thing that
    ends the loop, and says so, because the question changing under your finger needs an explanation.

    The FAT patch even in fragment morph mode: what is stale here is not just the question. The
    title, the score, the drawer and the topics all belong to a quiz this browser is no longer in.
    """
    return DatastarResponse(
        [
            SSE.patch_elements(render.app_body(session), selector=APP_SELECTOR, mode=ElementPatchMode.INNER),
            SSE.patch_signals({**render.signals(session), **render.settings_signals(session)}),
            SSE.patch_elements(
                render.toast(engine.Toast(kind="warning", text="Quiz reloaded — this page has caught up", pause=0)),
                selector=TOASTS_SELECTOR,
                mode=ElementPatchMode.INNER,
            ),
        ],
        cookies=_cookies(session),
    )


def debug_allowed(query: str = "") -> bool:
    """Whether the debug panel should be armed, given this page load's query (see `DEBUG_MODE`)."""
    if DEBUG_MODE == "0":
        return False
    if DEBUG_MODE == "1":
        return True
    return "debug" in query.lower()


def _cookies(session: state.Session) -> list[Cookie]:
    return [
        Cookie(
            key=state.SESSION_COOKIE,
            value=session.sid,
            # scoped to the mount point, so two apps sharing a host cannot overwrite each other's
            # session cookie -- the name is the same in both, only the path differs
            path=URL_PREFIX or "/",
            httponly=True,
            samesite="lax",
        )
    ]


async def _signals(request: Request) -> dict[str, Any] | None:
    """The datastar signals on this request, or None if the body is not usable.

    `read_signals` json-decodes the body (or the `datastar` query param) and raises on junk. A
    malformed payload is a client mistake, not a server error, and a stack-trace 500 is the wrong
    answer to it -- every handler here treats absent signals as "nothing to adopt" already.
    """
    try:
        return await read_signals(request)
    except JSONDecodeError, UnicodeDecodeError:
        return None


def _sync_settings(session: state.Session, signals: dict[str, Any] | None) -> bool:
    """Adopt the bound signals the browser just sent. Returns whether anything changed.

    The browser is the source of truth for these -- they originate there and are uploaded with
    every request -- so the session merely mirrors them. A change restarts the quiz, exactly as
    the panel watchers did (`difficulty_change`, `ladder_mode_toggle`, ...).
    """
    if not signals:
        return False
    settings = session.settings
    before = (settings.difficulty, settings.ladder_mode, settings.target_on, settings.target_pct)

    if "difficulty" in signals:
        settings.difficulty = engine.clamp_difficulty(signals["difficulty"])
    if "ladderMode" in signals:
        settings.ladder_mode = bool(signals["ladderMode"])
    if "targetOn" in signals:
        settings.target_on = bool(signals["targetOn"])
    if "targetPct" in signals:
        with contextlib.suppress(TypeError, ValueError):
            settings.target_pct = max(70, min(90, int(signals["targetPct"])))

    return before != (settings.difficulty, settings.ladder_mode, settings.target_on, settings.target_pct)


def _view_patches(session: state.Session) -> list[DatastarEvent]:
    """The standard "make the browser agree with the session" set.

    Server-owned signals *and* the effective settings: the browser proposed those, but the server
    clamps them, so echoing them is what stops a rejected value sitting in the UI until a reload.
    Drafts (`filterText`, topic ticks) are excluded -- see `render.settings_signals`.
    """
    if MORPH_MODE == "fragment":
        elements = SSE.patch_elements(render.quiz_body(session), selector=QUIZ_SELECTOR, mode=ElementPatchMode.INNER)
    else:
        elements = SSE.patch_elements(render.app_body(session), selector=APP_SELECTOR, mode=ElementPatchMode.INNER)
    return [
        elements,
        SSE.patch_signals({**render.signals(session), **render.settings_signals(session)}),
    ]


def _picked_card_selector(index: int) -> str:
    """The card the player just chose, as a CSS selector.

    `nth-child` rather than `nth-of-type`: every child of the group is a button, so they agree, and
    nth-child does not care if a future revision wraps them. The floaters need no cleanup -- both
    outcomes replace `#quiz` wholesale a moment later (the next question, or the reveal), so they
    cannot outlive the beat they belong to.
    """
    return f"{QUIZ_SELECTOR} .candidates > :nth-child({index + 1})"


def _clear_toasts() -> DatastarEvent:
    return SSE.patch_elements("", selector=TOASTS_SELECTOR, mode=ElementPatchMode.INNER)


def _clear_sfx() -> DatastarEvent:
    """Empty the sound sink before an answer appends its beats to it.

    The markers are appended rather than morphed (see `templates/sfx.html.j2`), so without this they
    would accumulate for the life of the page. Clearing at the START rather than the end also means a
    marker is never removed while the sound it started is still playing -- the `<audio>` element is
    what plays, and it lives outside the sink.
    """
    return SSE.patch_elements("", selector=SFX_SELECTOR, mode=ElementPatchMode.INNER)


# --- routes -----------------------------------------------------------------


# NO-STORE, and not as a nicety: this page IS session state -- the current question, the score, the
# reveal you are parked on -- rendered into HTML. A cached copy is a different player's answer sheet
# at worst and a stale question at best. It also ends a recurring confusion during development: the
# response carried no cache headers at all, so the browser was free to apply heuristic freshness,
# and a window that had the app open kept serving itself an old document while a private window
# (empty cache) showed the fix. "Works in a private window" is that bug's signature.
@get(
    "/",
    media_type=MediaType.HTML,
    dependencies={"session": Provide(provide_page_session)},
    sync_to_thread=False,
    cache_control=CacheControlHeader(no_store=True),
)
def index(session: NamedDependency[state.Session], request: Request) -> Response[str]:
    """Full page. Everything the browser knows starts here, in view-source.

    Also where the debug flag is decided, and only here: the datastar interactions POST to bare paths
    (`/answer/3/1`) with no query, so re-reading `?debug` per request would switch the panel off on the
    first click. Set on page load, sticky for the session -- `?debug` arms it, a plain reload disarms
    it, which is the same lifetime panel's `pn.state.location.search` gave it.

    `provide_page_session` rather than `provide_session` for the same reason: a bare URL means "back
    to the default variant", and only a navigation can mean that.
    """
    session.debug = debug_allowed(request.url.query)
    # A NAVIGATION is the only thing that moves the mark for "which system this browser is on", which
    # is what an ambiguous later page load (`?debug`, naming no variant) resolves against. Doing it
    # on interactions instead would let a background tab drag the answer back to its own system --
    # the cross-tab bleed the (browser, variant) keying exists to end.
    STORE.remember(session)
    # The theme is the browser's preference, not the session's: it is written by the toggle into its
    # own cookie and only relayed here, so it survives a new session, a restart and a second tab.
    theme = render.theme_from(request.cookies.get(render.THEME_COOKIE))
    return Response(render.shell(session, theme), media_type=MediaType.HTML, cookies=_cookies(session))


@post("/answer/{qid:int}/{index:int}", dependencies={"session": Provide(provide_session)})
async def answer(
    session: NamedDependency[state.Session],
    qid: FromPath[int],
    index: FromPath[int],
    request: Request,
) -> DatastarResponse:
    """The route. The work is in `score_answer`, which is a plain function so that other handlers can
    reach it -- a litestar route handler is an object, not something you can call."""
    return await score_answer(session, qid=qid, index=index, request=request)


async def score_answer(
    session: state.Session,
    *,
    qid: int,
    index: int,
    request: Request,
    floaters: bool = True,
) -> DatastarResponse:
    """Score one answer, then stream the notifications the way panel showed them.

    A stale `qid` (double click, back button, replay, a page whose session was replaced) scores
    nothing and RESYNCS the page instead: the nonce moved on when the question did, and the browser
    is showing a quiz that no longer exists. A finished quiz is still a plain no-op -- the completion
    screen is already what the page is showing.
    """
    with telemetry.span("answer"):
        if _stale(request, session, qid):
            return _resync(session)
        if not session.still_playing:
            return DatastarResponse(cookies=_cookies(session))
        if not 0 <= index < len(session.question.candidates):
            return DatastarResponse(cookies=_cookies(session))

        _sync_settings(session, await _signals(request))

        question = session.question
        candidate = question.candidates[index]
        # the bonus that scores is measured here, from the server's own clock -- the browser's
        # countdown bar is only an animation
        percent_left = session.percent_time_left()

        outcome, last_correct_points = engine.answer(
            score=session.score,
            question=question,
            candidate=candidate,
            percent_left=percent_left,
            ladder_mode=session.settings.ladder_mode,
            target_on=session.settings.target_on,
            target_pct=session.settings.target_pct,
            last_correct_points=session.last_correct_points,
            points_goal=session.points_goal,
        )
        session.last_correct_points = last_correct_points
        session.skips_left += outcome.awarded_skips

        # the clock stops the moment the answer is scored -- `percent_left` above is the last thing
        # that reads it, and everything after this point (the toast sequence, the reveal, a reload
        # while parked) should report what was left, not keep draining
        session.freeze_question_clock()

        # state is settled before a single byte is streamed, so a reload mid-notification shows
        # the finished score and the next question rather than a half-applied answer
        if outcome.completed:
            session.complete()
        elif outcome.correct:
            session.next_question()
        else:
            # park on the reveal instead: the answer is shown in place, and the player advances
            session.awaiting_next = True
            session.wrong_index = index

    return DatastarResponse(
        _answer_stream(session, outcome, picked_index=index if floaters else None),
        cookies=_cookies(session),
    )


async def _answer_stream(
    session: state.Session, outcome: engine.Answered, *, picked_index: int | None
) -> AsyncGenerator[DatastarEvent]:
    """The panel notification chain, as one long SSE response.

    `on_answer_click` awaited `asyncio.sleep` between `pn.state.notifications.*` calls; the
    same pacing survives here, with each beat as an element patch instead of a websocket
    message.

    Each beat that carries points is *also* appended to the card the player chose, as a floating
    number (the "game feel" experiment -- see `static/juice.css`). The server can do that because the
    choice is in the URL it was called on, so it knows which card to aim at; the alternative was a
    client-side signal remembering the last click, which is state the browser would then own for no
    reason. The floaters are inert unless `body.juice` is set, which is why they are streamed
    unconditionally: `$_juice` is a local view signal and never reaches the server. That costs one
    small extra frame per scoring beat -- ~60 bytes -- and keeps the choreography in one place.
    """
    # The streak lands with the FIRST beat, not with the view patch at the end of the stream: the
    # chip is the reward for the answer that was just given, and arriving two or three seconds late
    # (after the toasts, with the next question) read as belonging to the following question.
    yield SSE.patch_signals({"_streak": session.score.streak})

    # Sound rides the same beats, gated client-side on `$_sound` -- see `render.sfx_beat`. The verdict
    # chime goes FIRST, before the toast it belongs to, because a sound that arrives after the words
    # have appeared reads as a response to reading them.
    yield _clear_sfx()
    yield SSE.patch_elements(
        render.sfx_beat("correct" if outcome.correct else "wrong"),
        selector=SFX_SELECTOR,
        mode=ElementPatchMode.APPEND,
    )

    for toast in outcome.toasts:
        yield SSE.patch_elements(render.toast(toast), selector=TOASTS_SELECTOR, mode=ElementPatchMode.INNER)
        # A milestone has just paid for a skip: the gauge that measures milestones says so itself,
        # rather than leaving it to one toast among four. Both halves are one-shot appends -- the
        # shine is taken away by the view patch at the end of the stream, the sound marker by the
        # `_clear_sfx` of the next answer.
        if toast.awards_skip:
            yield SSE.patch_elements(render.meter_sweep(), selector=METER_SELECTOR, mode=ElementPatchMode.APPEND)
            yield SSE.patch_elements(render.sfx_beat("skip"), selector=SFX_SELECTOR, mode=ElementPatchMode.APPEND)
        if toast.points_after is not None:
            yield SSE.patch_signals(
                {
                    "_points": toast.points_after,
                    # `session.points_goal`, NOT the module constant: with a debug goal of 200 these
                    # mid-stream percentages were computed against 1000 while `render.signals` used
                    # 200, so the gauge jumped backwards when the final view patch arrived
                    "_pointsPct": min(round(toast.points_after / session.points_goal * 100), 100),
                }
            )
        if picked_index is not None and (floater := render.floater(toast, final=outcome.completed)):
            yield SSE.patch_elements(
                floater,
                selector=_picked_card_selector(picked_index),
                mode=ElementPatchMode.APPEND,
            )
        await asyncio.sleep(toast.pause)

    # The finale's own sound, once per quiz, with the completion screen rather than with the answer:
    # the gold floater and the confetti are the same beat, and the fanfare is long enough that firing
    # it beside the "Correct!" chime would be two flourishes over each other.
    if outcome.completed:
        yield SSE.patch_elements(render.sfx_beat("final"), selector=SFX_SELECTOR, mode=ElementPatchMode.APPEND)

    yield _clear_toasts()
    # the clock starts when the question reaches the player, not when it was drawn -- the
    # notifications above took real seconds and they are not the player's thinking time
    if session.still_playing and not session.awaiting_next:
        session.start_question_clock()
    for event in _view_patches(session):
        yield event


@post("/next", dependencies={"session": Provide(provide_session)})
async def next_question(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    """Leave the revealed answer and draw the next question.

    Only valid while parked on a reveal, so a stray press cannot skip a live question -- that is
    what `Skip` is for, and it costs a skip.
    """
    if _stale(request, session):
        return _resync(session)
    _sync_settings(session, await _signals(request))
    if not session.awaiting_next or not session.still_playing:
        return DatastarResponse(cookies=_cookies(session))
    session.next_question()
    return DatastarResponse([_clear_toasts(), *_view_patches(session)], cookies=_cookies(session))


@get("/timer", dependencies={"session": Provide(provide_session)})
async def timer(session: NamedDependency[state.Session]) -> DatastarResponse:
    """The held-connection countdown: panel's push model, for comparison with the client interval.

    Only reachable when `DSQUIZ_TIMER=stream`; the shell wires `data-init` to it in that mode and
    omits the `data-on-interval` attribute, so exactly one of the two is ever live.
    """
    if TIMER_MODE != "stream":
        return DatastarResponse(cookies=_cookies(session))
    return DatastarResponse(_timer_stream(session), cookies=_cookies(session))


async def _timer_stream(session: state.Session) -> AsyncGenerator[DatastarEvent]:
    """Push the remaining percentage until the quiz ends or the cap is reached.

    Note what this costs against the client-interval default: a tick per 100ms per connected tab,
    each one a signal patch over the wire, whether or not the value changed.
    """
    elapsed = 0.0
    while elapsed < TIMER_STREAM_MAX_SECONDS:
        if not session.still_playing:
            yield SSE.patch_signals({"_timeLeftPct": 0})
            return
        # Nothing to push while parked on a reveal: the question has been answered, so the clock is
        # frozen and every tick would restate the same number. The client interval gates on the same
        # condition (`$_ticking`) -- the two push models must agree about when the bar is stopped, or
        # the mode becomes visible to the player, which defeats the comparison.
        if session.on_the_clock:
            yield SSE.patch_signals({"_timeLeftPct": session.percent_time_left()})
        await asyncio.sleep(TIMER_TICK_SECONDS)
        elapsed += TIMER_TICK_SECONDS


@post("/skip", dependencies={"session": Provide(provide_session)})
async def skip(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    """Skip the question if a milestone has paid for it."""
    if _stale(request, session):
        return _resync(session)
    _sync_settings(session, await _signals(request))
    if session.skips_left <= 0 or not session.still_playing:
        return DatastarResponse(cookies=_cookies(session))
    session.skips_left -= 1
    session.next_question()
    return DatastarResponse([_clear_toasts(), *_view_patches(session)], cookies=_cookies(session))


# --- debug panel ------------------------------------------------------------
#
# The panel app had `debug_enabled` and a row of buttons for exactly this: reaching a state that takes
# minutes of honest play. Every route here is a no-op unless the session is armed (see `DEBUG_MODE`),
# so an unarmed instance answers them with a 204 rather than a 404 -- the same "nothing to do" answer
# a stale `qid` gets from `/answer`, and it does not advertise whether the routes exist.


def _debug_refused(session: state.Session) -> DatastarResponse | None:
    return None if session.debug else DatastarResponse(cookies=_cookies(session))


@post("/debug/points/{delta:int}", dependencies={"session": Provide(provide_session)})
async def debug_points(session: NamedDependency[state.Session], delta: FromPath[int]) -> DatastarResponse:
    """Add or remove points without answering anything.

    Deliberately does NOT check the goal: crossing it by hand should not fake a completion, because
    then the finale would be reachable without the code path that produces it. `/debug/complete` is
    the honest way to see that screen.
    """
    if (refused := _debug_refused(session)) is not None:
        return refused
    session.score.total_points = max(0, session.score.total_points + delta)
    return DatastarResponse(_view_patches(session), cookies=_cookies(session))


@post("/debug/goal/{value:int}", dependencies={"session": Provide(provide_session)})
async def debug_goal(session: NamedDependency[state.Session], value: FromPath[int]) -> DatastarResponse:
    """Shorten (or lengthen) the quiz. Per session, so this is not a global mutation.

    The milestones that pay for skips are fractions of the goal, so lowering it also brings those
    forward -- which is the point: a 200-point goal exercises the whole ladder in a minute.
    """
    if (refused := _debug_refused(session)) is not None:
        return refused
    session.points_goal = max(10, min(value, 100_000))
    return DatastarResponse(_view_patches(session), cookies=_cookies(session))


@post("/debug/complete", dependencies={"session": Provide(provide_session)})
async def debug_complete(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    """Jump to the finale, through the real scoring path.

    Points are set one short of the goal and the current question is answered *correctly*, so this
    goes through `engine.answer` -> `outcome.completed` -> the toast chain -> the completion screen,
    including the gold goal-crossing floater. Faking `session.complete()` would show the screen while
    skipping everything that makes it happen, which is the opposite of useful for testing it.
    """
    if (refused := _debug_refused(session)) is not None:
        return refused
    if not session.still_playing:
        session.restart()
    session.score.total_points = max(0, session.points_goal - 1)
    session.awaiting_next = False
    correct_index = session.question.candidates.index(session.question.answer_candidate)
    # No floaters on this path: the browser is showing whatever it was showing (often the previous
    # finale, since this restarts a finished quiz), so a patch aimed at `.candidates > :nth-child(n)`
    # finds no target and datastar logs `PatchElementsNoTargetsFound` for every scoring beat. The
    # player is not looking at the cards here anyway -- they asked to jump to the end.
    return await score_answer(session, qid=session.qid, index=correct_index, request=request, floaters=False)


@post("/debug/reveal", dependencies={"session": Provide(provide_session)})
async def debug_reveal(session: NamedDependency[state.Session]) -> DatastarResponse:
    """Park on the reveal without getting one wrong, for looking at the shake and the marks."""
    if (refused := _debug_refused(session)) is not None:
        return refused
    if not session.still_playing:
        session.restart()
    session.awaiting_next = True
    session.freeze_question_clock()
    correct_index = session.question.candidates.index(session.question.answer_candidate)
    session.wrong_index = (correct_index + 1) % len(session.question.candidates)
    return DatastarResponse(_view_patches(session), cookies=_cookies(session))


@get("/.well-known/appspecific/com.chrome.devtools.json", sync_to_thread=False)
def devtools_workspace() -> Response[dict | None]:
    """Chrome DevTools probes this path -- every page load with devtools open, and repeatedly in device
    simulation mode. Unanswered it is a 404, and with litestar's debug mode on (`just dev`) each one
    prints a full traceback, which is what filled the log.

    Answered, it is a small feature instead: DevTools offers to connect the page to a folder on disk, so
    edits made in the Styles panel are written straight back to `static/*.css` rather than lost on
    reload. Given how much of this app's design work happens by nudging CSS in devtools, that is worth
    the eight lines.

    Debug-only, and deliberately so: the payload is an absolute filesystem path, which is nobody's
    business on a deployment.
    """
    if DEBUG_MODE != "1":
        return Response(None, status_code=404)
    return Response(
        {
            "workspace": {
                "root": APP_DIR.as_posix(),
                # stable across restarts -- devtools remembers trust per uuid, and a fresh one each
                # boot would re-ask on every reload
                "uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, f"dsquiz:{APP_DIR.as_posix()}")),
            }
        },
        media_type=MediaType.JSON,
    )


def _quiet_not_found(request: Request, _: NotFoundException) -> Response[str]:
    """A 404 is a client asking for something that is not there, not a server fault.

    Litestar's debug mode logs uncaught exceptions with a traceback, and `NotFoundException` is an
    exception like any other -- so a missing source map or a devtools probe produced a 30-line stack
    trace in the middle of the log. Real errors stay loud; these are answered and dropped.
    """
    return Response(f"not found: {request.url.path}", status_code=404, media_type=MediaType.TEXT)


@post("/restart", dependencies={"session": Provide(provide_session)})
async def restart(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    _sync_settings(session, await _signals(request))
    session.restart()
    return DatastarResponse([_clear_toasts(), *_view_patches(session)], cookies=_cookies(session))


@post("/settings", dependencies={"session": Provide(provide_session)})
async def settings(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    """Difficulty / ladder mode / target percentage arrive as bound signals.

    Panel restarted the quiz on every such change (`difficulty_slider.param.watch(...)`), so
    this does too -- and only when a value actually moved, so a re-sent identical signal set is
    free.
    """
    if not _sync_settings(session, await _signals(request)):
        return DatastarResponse(cookies=_cookies(session))
    session.restart()
    return DatastarResponse([_clear_toasts(), *_view_patches(session)], cookies=_cookies(session))


# --- the bidding-tree filter ------------------------------------------------

FILTER_STATUS_SELECTOR = "#filter-status"
TOPICS_STATUS_SELECTOR = "#topics-status"


def _filter_text_from(signals: dict[str, Any] | None) -> str:
    return str((signals or {}).get("filterText") or "")


def _topics_text_from(session: state.Session, signals: dict[str, Any] | None) -> str:
    """Ticked topic slugs back into the filter text they stand for.

    Signal paths cannot hold spaces, so the picker binds kebab-case slugs
    (`data-bind:topics.long-auctions`), which datastar stores camel-cased (`longAuctions`) --
    `render.topic_signal_key` computes that name. The real topic names live here, on the server,
    so an unknown key simply does not select anything.
    """
    ticked = (signals or {}).get("topics") or {}
    names = [choice["name"] for choice in render.topic_choices(session) if ticked.get(choice["key"])]
    return ", ".join(names)


def _preview(session: state.Session, text: str, selector: str, hint: str) -> DatastarResponse:
    check = corpus.check_filter(session.variant.bml_file, session.variant.key, text, engine.MAX_DIFFICULTY)
    return DatastarResponse(
        SSE.patch_elements(
            render.filter_status(check, in_force=session.filter_text, pending_hint=hint),
            selector=selector,
            mode=ElementPatchMode.INNER,
        ),
        cookies=_cookies(session),
    )


@get("/filter/preview", dependencies={"session": Provide(provide_session)})
async def filter_preview(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    """What the text in the box *would* select. Commits nothing.

    This is the panel `value_input` watcher, except the validation never left the server. Cheap
    enough to run per keystroke because `bidfilter.prepare_sequence_bids` pre-parsed the corpus.
    """
    signals = await _signals(request)
    return _preview(session, _filter_text_from(signals), FILTER_STATUS_SELECTOR, "press Enter to apply")


@get("/filter/preview-topics", dependencies={"session": Provide(provide_session)})
async def topics_preview(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    signals = await _signals(request)
    return _preview(session, _topics_text_from(session, signals), TOPICS_STATUS_SELECTOR, "press Apply to use this")


@get("/filter/topics-reset", dependencies={"session": Provide(provide_session)})
async def topics_reset(session: NamedDependency[state.Session]) -> DatastarResponse:
    """Close (and Escape) DISCARD the ticks, putting them back to the filter in force.

    The picker has an explicit Apply and says so in its own first line, which makes Close the cancel
    path -- and a cancel that quietly keeps your edits is the odd one out among dialogs. Keeping them
    also left the picker disagreeing with the app: reopening showed ticks that select nothing, under
    a status line reading "N auctions match, press Apply" while the drawer reported the real working
    set. Two answers to "what am I being asked about", one of them false.

    Only the `topics` branch is patched. `bound_signals` also carries the difficulty and `filterText`,
    and `filterText` is a DRAFT the player may be part-way through typing in the drawer behind the
    dialog -- re-sending it here would wipe it, which is the same rule `_view_patches` follows.
    """
    check = corpus.check_filter(
        session.variant.bml_file, session.variant.key, session.filter_text, engine.MAX_DIFFICULTY
    )
    in_force = render.bound_signals(session, check.parsed.topic_names)["topics"]
    return DatastarResponse(
        [
            SSE.patch_signals({"topics": in_force}),
            # ...and the picker's own status line, which was previewing a selection that no longer
            # exists. Empty rather than re-rendered: with nothing pending there is nothing to say.
            SSE.patch_elements("", selector=TOPICS_STATUS_SELECTOR, mode=ElementPatchMode.INNER),
        ],
        cookies=_cookies(session),
    )


def _commit_filter(session: state.Session, text: str) -> DatastarResponse:
    """The one path that changes the filter in force."""
    check, changed = session.apply_filter(text, engine.MAX_DIFFICULTY)
    events = [
        SSE.patch_elements(
            render.filter_status(check, in_force=session.filter_text),
            selector=FILTER_STATUS_SELECTOR,
            mode=ElementPatchMode.INNER,
        ),
        SSE.patch_elements("", selector=TOPICS_STATUS_SELECTOR, mode=ElementPatchMode.INNER),
        # the box and the picker are brought into line with what was actually applied: the
        # canonical text has topic prefixes expanded and the whitespace tidied
        SSE.patch_signals(render.bound_signals(session, check.parsed.topic_names)),
    ]
    if changed:
        session.restart()
        events.append(_clear_toasts())
        events.extend(_view_patches(session))
    return DatastarResponse(events, cookies=_cookies(session))


@post("/filter/apply", dependencies={"session": Provide(provide_session)})
async def filter_apply(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    signals = await _signals(request)
    return _commit_filter(session, _filter_text_from(signals))


@post("/filter/apply-topics", dependencies={"session": Provide(provide_session)})
async def topics_apply(session: NamedDependency[state.Session], request: Request) -> DatastarResponse:
    """Apply replaces whatever is in the filter box with the ticked topics, as panel did."""
    signals = await _signals(request)
    return _commit_filter(session, _topics_text_from(session, signals))


# --- sound ------------------------------------------------------------------


@get("/sfx/{name:str}", sync_to_thread=False, cache_control=CacheControlHeader(max_age=31536000, public=True))
def sound(name: FromPath[str]) -> Response[bytes]:
    """One synthesised WAV. There is no `static/sfx/` directory -- see `sfx.py`.

    Generated at import and served from memory, which suits what these are: a few kilobytes of
    arithmetic that would otherwise be binary files in a documentation repo, with a licence to think
    about and a build step to regenerate them.

    Cached HARD (a year, and immutable in effect) because the bytes for a given name never change
    within a build; the `?v=` the page appends is the build stamp, so an edited synth arrives as a
    different URL rather than waiting out a cache. `preload="auto"` means the browser asks for all
    five the moment sound is switched on, and never again.
    """
    audio = sfx.SOUNDS.get(name)
    if audio is None:
        unknown = f"no sound named {name!r}"
        raise NotFoundException(unknown)
    return Response(audio, media_type="audio/wav")


# --- yappi (see profiling.py; nothing here is reachable unless DSQUIZ_YAPPI is set) ------------


@get("/debug/yappi", media_type=MediaType.TEXT, sync_to_thread=False)
def yappi_report() -> str:
    """The profile so far. Text, so `curl` is enough and no viewer is needed to read it."""
    return profiling.report()


@post("/debug/yappi/reset", media_type=MediaType.TEXT, sync_to_thread=False)
def yappi_reset() -> str:
    """Throw away what has been collected, so the next report covers one known window -- a load run
    that started AFTER the server's own startup work, which otherwise dominates the first report."""
    profiling.reset()
    return "profile cleared" + chr(10)


@post("/debug/yappi/save", media_type=MediaType.TEXT, sync_to_thread=False)
def yappi_save() -> str:
    """Write the text report and a callgrind file into .reports/ and say where they went.

    A route rather than only a shutdown hook because a load-test server is usually killed rather than
    stopped politely, and a profile that only survives a graceful shutdown is one you keep losing.
    """
    path = profiling.save()
    return (f"{path}" if path else "profiling is off") + chr(10)


def create_app() -> Litestar:
    return Litestar(
        # Fat morph sends the whole page per interaction, and compression is what makes that cheap:
        # the markup is highly repetitive, so it shrinks to a fraction of its size. brotli with a gzip
        # fallback covers every browser; zstd is not a litestar backend, and at these sizes the
        # difference between the three is noise.
        #
        # Compressing the SSE routes too is safe HERE, which is worth knowing because the datastar SDK
        # warns that "compression middleware may interfere" with flushing: litestar's brotli facade
        # calls `compressor.process(chunk)` followed by `compressor.flush()` for every ASGI chunk
        # (`litestar/middleware/compression/brotli_facade.py`), and the middleware forwards each
        # compressed chunk immediately while `more_body` is set. So a toast frame still leaves the
        # server when it is yielded. Verified by timing frame arrivals -- see COMPARISON.md.
        #
        # Quality 5 is pinned rather than left to litestar's default (also 5), because it is the knee
        # and a default can move. Measured on this app's own 23.6KB fat patch:
        #
        #   q1   5,021 B  4.7x   0.04 ms      q6   4,053 B  5.8x   0.94 ms
        #   q4   4,391 B  5.4x   0.32 ms      q9   4,022 B  5.9x   4.41 ms
        #   q5   4,069 B  5.8x   0.56 ms      q11  3,641 B  6.5x  22.34 ms
        #   gzip -9  4,350 B  5.4x  0.24 ms
        #
        # q6 costs 68% more time for 0.4% fewer bytes; q9 is 8x the CPU for 1%; q11 is 40x for 10%.
        # q5 also beats gzip -9 on size at ~2x its cost. Drop to q4 if the ~0.3ms matters more than
        # the 8% -- against a 1.8ms handler, q5 is roughly a third of the response's CPU.
        compression_config=CompressionConfig(
            backend="brotli",
            brotli_quality=5,
            brotli_gzip_fallback=True,
            minimum_size=256,
        ),
        # Parsing the corpora at STARTUP, not on whoever asks first. All of it is cached and happened
        # once either way -- but it happened inside a request, and the yappi profile caught it: 1.3s
        # of `load_bid_tables` plus 4.3s of `prepare_sequence_bids` landing on the first visitor to
        # open the second system. `DSQUIZ_PREWARM=0` puts it back to lazy, which is worth having while
        # iterating under `--reload`, where every save would otherwise pay for both corpora.
        #
        # The profiler start is here for a different reason: granian spawns a worker, and a profiler
        # started at import would measure the parent. It is a no-op unless DSQUIZ_YAPPI is set.
        on_startup=[
            *([lambda _app: corpus.prewarm()] if PREWARM else []),
            *([lambda _app: profiling.start()] if profiling.ENABLED else []),
        ],
        on_shutdown=[lambda _app: profiling.save()] if profiling.ENABLED else [],
        route_handlers=[
            index,
            answer,
            next_question,
            timer,
            skip,
            restart,
            settings,
            filter_preview,
            topics_preview,
            topics_reset,
            filter_apply,
            topics_apply,
            debug_points,
            debug_goal,
            debug_complete,
            debug_reveal,
            devtools_workspace,
            # NOT registered when profiling is off, so there is no endpoint to reach even by accident
            *([yappi_report, yappi_reset, yappi_save] if profiling.ENABLED else []),
            sound,
            # `no-cache` means REVALIDATE, not "do not cache": the browser keeps the file and asks
            # with its etag, so an unchanged sheet costs a 304 and a changed one arrives immediately.
            # Without it these responses carry only `last-modified`, and a browser is then entitled to
            # invent a freshness lifetime from it (commonly 10% of the file's age) -- which is how an
            # edited stylesheet or a fixed datastar handler kept not showing up until a hard reload.
            # Cheap here: everything is local and the largest file is 71KB.
            create_static_files_router(
                path="/static",
                directories=[APP_DIR / "static"],
                name="static",
                cache_control=CacheControlHeader(no_cache=True),
            ),
            # the completion image lives with the panel app; served read-only, never modified
            create_static_files_router(
                path="/media",
                directories=[APP_DIR.parent / "quiz"],
                name="media",
                cache_control=CacheControlHeader(no_cache=True),
            ),
        ],
        # prefixes every route and both static routers in one go; see URL_PREFIX
        path=URL_PREFIX or None,
        # 404s are answered, not logged with a stack trace -- see `_quiet_not_found`
        exception_handlers={NotFoundException: _quiet_not_found},
        # this is a hypermedia app: no json api, so no schema to publish
        openapi_config=None,
        plugins=telemetry.plugins(),
        # Litestar's debug mode: full tracebacks in the log AND in the response body. It was
        # unconditionally on, which is how a missing source map turned into a stack trace, and would
        # have shipped internals to visitors on any 500. Tied to the same flag as the debug panel, so
        # `just dev` keeps the tracebacks and everything else does not.
        debug=DEBUG_MODE == "1",
    )


app = create_app()
