"""Server-side session state -- the authoritative quiz.

Datastar's doctrine (`data-star.dev/guide/the_tao_of_datastar`): "Most state should live in the
backend. Since the frontend is exposed to the user, the backend should be the source of truth
for your application state." Everything here is state the browser must not own:

* the current `Question`, because it carries `answer_candidate` -- signals are readable in
  devtools and are uploaded with every request, so an answer in a signal is a cheat code;
* the score, streak and milestone ledger, for the same reason;
* the working set of auctions, which is a slice of the per-process `.bml` corpus and cannot
  travel to the browser at all.

Signals carry only what the browser originates: bound form inputs (difficulty, ladder mode,
target %, filter draft) and `_`-prefixed local view state (modal open, timer animation).

Sessions live in a plain process-local dict keyed by a cookie. Not litestar's session
middleware: this state holds references *into* the shared corpus, so a serialise/deserialise
round trip per request would be pure cost. One process only -- the same constraint the panel
app already had (see the `session_key_func` notes at `apps/quiz/quiz_app.py:49`).
"""

from __future__ import annotations

import itertools
import time
import uuid

import msgspec

import corpus
import engine

# see the note in engine.py: `quiz` is only importable once corpus has run
from corpus import quiz

# The cookie identifies the BROWSER, not the quiz: sessions are keyed by (browser, variant), so the
# squad quiz and the swedish one coexist instead of one replacing the other. Deliberately still one
# cookie under one name -- nginx pins a browser to a worker with `hash $cookie_dsq_sid consistent`
# (DEPLOY.md), and a name that varied by variant would leave that directive hashing on a cookie half
# the requests do not carry.
SESSION_COOKIE = "dsq_sid"
SESSION_TTL_SECONDS = 6 * 60 * 60
_SWEEP_EVERY_SECONDS = 10 * 60

# THE QUESTION NONCE IS PROCESS-WIDE, and that is the whole point of it.
#
# It used to be per session, starting at 1. So a page whose session had been REPLACED -- and there
# are three ordinary ways for that to happen: `?swedish` discards the old session and the session
# cookie is one per browser, the store is emptied by a restart (`--reload` does this constantly),
# and a session ages out after six hours -- posted `qid=1` at a brand new session whose first
# question was *also* `qid=1`. The staleness guard in `score_answer` then passed by coincidence and
# the answer was scored against a question that had never been on screen: the reveal came back for
# a different auction, marked wrong, and with `?swedish` involved from a different SYSTEM. That is
# the "I answered one question and it showed me another" report, and it is not a race -- it is two
# counters that both start at 1.
#
# A counter that never repeats within a process makes the collision impossible, so a stale answer is
# always recognised as stale (and now answered with a resync rather than silence -- see `app._stale`).
_qids = itertools.count(1)


def next_qid() -> int:
    """The next question nonce. Unique per process, not per session."""
    return next(_qids)


class Settings(msgspec.Struct):
    """The bound signals, as last seen from the browser. Mirrors of client-originated state:
    the browser is the source of truth for these, and every request re-states them."""

    difficulty: int = engine.INITIAL_DIFFICULTY
    ladder_mode: bool = True
    target_on: bool = False
    target_pct: int = 70


class Session(msgspec.Struct):
    """One quiz in progress. Mutated in place by the route handlers."""

    sid: str
    variant: corpus.Variant
    settings: Settings
    score: engine.Score
    sequences: list  # the working set questions are drawn from (filtered or the whole system)
    question: quiz.Question
    qid: int = 0  # set from `next_qid()`; the answer route rejects a stale one. Never per-session.
    skips_left: int = engine.INITIAL_SKIPS
    last_correct_points: int = 0
    filter_text: str = ""
    quiz_start_wall: float = 0.0
    completion_wall: float | None = None
    question_start: float = 0.0  # monotonic
    question_seconds: float = 0.0
    touched: float = 0.0
    # Set when a wrong answer has been scored: the question stays on screen with the right answer
    # marked, and nothing moves on until the player asks (`POST /next`). Panel instead blocked for
    # 4.2s behind a centre-screen toast.
    awaiting_next: bool = False
    wrong_index: int | None = None
    # Per-session so the debug panel can shorten a quiz without mutating a module constant -- and so
    # two browsers against one process can disagree about it.
    points_goal: int = engine.POINTS_GOAL
    # Set when the session was opened with `?debug` (or `DSQUIZ_DEBUG=1`): shows the debug panel and
    # arms its routes. Sticky, like the variant, because the query is gone after the first navigation.
    debug: bool = False
    # What was left on the clock when the question was answered. The allowance stops mattering the
    # moment an answer is scored, so it is frozen rather than left running against `question_start`:
    # otherwise a reload while parked on the reveal reports a smaller number than the one the answer
    # was actually scored with, and `GET /timer` keeps pushing a shrinking value at a bar that should
    # be holding still.
    frozen_time_left: int | None = None

    @property
    def still_playing(self) -> bool:
        return self.completion_wall is None

    @property
    def on_the_clock(self) -> bool:
        """Whether a live, unanswered question is being timed.

        False while parked on a reveal and after completion -- the two states where the countdown
        must stop rather than keep draining.
        """
        return self.still_playing and not self.awaiting_next

    @property
    def elapsed_seconds(self) -> float:
        """How long the completed quiz took (the panel completion screen's number)."""
        if self.completion_wall is None:
            return round(time.time() - self.quiz_start_wall, 1)
        return round(self.completion_wall - self.quiz_start_wall, 1)

    def percent_time_left(self) -> int:
        if self.frozen_time_left is not None:
            return self.frozen_time_left
        return engine.percent_time_left(time.monotonic() - self.question_start, self.question_seconds)

    def freeze_question_clock(self) -> None:
        """Stop the countdown where it stands, because this question has been answered."""
        self.frozen_time_left = self.percent_time_left()

    def next_question(self) -> None:
        """Draw a new question and restart its clock. `qid` changes, which is what makes the
        previous question's answer buttons dead -- a double click cannot score twice."""
        self.awaiting_next = False
        self.wrong_index = None
        self.question = engine.new_question(self.sequences, self.settings.difficulty)
        self.qid = next_qid()
        self.question_seconds = engine.seconds_for_difficulty(self.settings.difficulty)
        self.start_question_clock()

    def start_question_clock(self) -> None:
        """(Re)start the allowance for the current question.

        Called again when the question actually reaches the browser: the answer stream spends
        up to several seconds showing notifications after the next question has been drawn, and
        charging the player for that time would cost them a chunk of their bonus. Panel reset
        its `TimeBonus` after the same awaits.
        """
        self.question_start = time.monotonic()
        self.frozen_time_left = None

    def apply_filter(self, text: str | None, min_hits: int) -> tuple[corpus.FilterCheck, bool]:
        """Commit a bidding-tree filter, narrowing the working set questions are drawn from.

        Port of the panel `_commit_filter_text` / `apply_bid_filter` pair: anything other than a
        usable filter falls back to the whole system, the stored text is the *canonical* form
        (topic prefixes resolved, whitespace tidied) so the input box can show what is really in
        force, and the caller restarts the quiz only if the filter actually changed.
        """
        check = corpus.check_filter(self.variant.bml_file, self.variant.key, text, min_hits)
        self.sequences = check.hits if check.usable else corpus.bid_sequences(self.variant.bml_file)
        canonical = check.parsed.canonical_text
        changed = canonical != self.filter_text
        self.filter_text = canonical
        return check, changed

    def restart(self) -> None:
        """Port of `reset_skips_and_scoring_and_timer_and_question` (`quiz_app.py:877`).
        Every settings or filter change goes through here, as in the panel app."""
        self.score.reset()
        self.skips_left = engine.INITIAL_SKIPS
        self.last_correct_points = 0
        self.quiz_start_wall = time.time()
        self.completion_wall = None
        self.next_question()

    def complete(self) -> None:
        self.completion_wall = time.time()


def new_session(variant: corpus.Variant, sid: str | None = None) -> Session:
    sequences = corpus.bid_sequences(variant.bml_file)
    settings = Settings()
    return Session(
        sid=sid or uuid.uuid4().hex,
        variant=variant,
        settings=settings,
        score=engine.Score(),
        sequences=sequences,
        question=engine.new_question(sequences, settings.difficulty),
        # from the process-wide counter, so this session's first question cannot share a nonce with
        # the first question of the session it replaced -- see the note on `next_qid`
        qid=next_qid(),
        question_seconds=engine.seconds_for_difficulty(settings.difficulty),
        question_start=time.monotonic(),
        quiz_start_wall=time.time(),
        touched=time.time(),
    )


class SessionStore:
    """Process-local session registry with lazy TTL eviction, keyed by (browser, variant).

    ONE QUIZ PER VARIANT PER BROWSER, which is what panel had for free by keying its sessions on the
    variant (`session_key_func`, `quiz_app.py:49`). The single-session version replaced the whole
    quiz whenever `?swedish` was opened, and with one cookie per browser that reached across tabs:
    the squad tab, the back-history entry and the phone's first tab were all left holding a quiz that
    no longer existed, mid-score. Now switching systems parks one and resumes the other, both keep
    their score, and the two can be played in two tabs at once.

    The `sid` still identifies the browser, so it stays a single cookie (see `SESSION_COOKIE`).
    `_current` remembers which variant a browser last *navigated* to, for the one request that cannot
    say: a page load with a query that names no variant (`?debug`), which must not be read as "take
    me back to squad".

    Lazy sweeping rather than a background task: a sweep is cheap, sessions are few, and this keeps
    the store usable from tests without an event loop.
    """

    def __init__(self, ttl: float = SESSION_TTL_SECONDS) -> None:
        self._sessions: dict[tuple[str, str], Session] = {}
        self._current: dict[str, str] = {}
        self._ttl = ttl
        self._last_sweep = 0.0

    def get(self, sid: str | None, variant_key: str | None = None) -> Session | None:
        """This browser's session for `variant_key`, or for whatever it is currently on.

        The default is what makes every caller that only ever plays one system -- most of the
        tests, and every request before this existed -- read the same as it always did.
        """
        self._maybe_sweep()
        if not sid:
            return None
        key = variant_key or self._current.get(sid)
        if key is None:
            return None
        session = self._sessions.get((sid, key))
        if session is not None:
            session.touched = time.time()
        return session

    def current_variant(self, sid: str | None) -> str | None:
        """The variant this browser last navigated to, if the store still has it."""
        self._maybe_sweep()
        return self._current.get(sid) if sid else None

    def create(self, variant: corpus.Variant, sid: str | None = None) -> Session:
        """A quiz for `variant`, under the given browser id (a new browser if there is none)."""
        self._maybe_sweep()
        session = new_session(variant, sid=sid or uuid.uuid4().hex)
        self._sessions[(session.sid, variant.key)] = session
        # `setdefault`, not an assignment: a browser with NO mark has to get one from somewhere, and
        # the quiz it just had built is the only candidate. A browser that already has one keeps it
        # -- moving the mark is a navigation's job, so a rebuild triggered by a background tab's
        # click cannot decide what the next `?debug` page load resumes.
        self._current.setdefault(session.sid, variant.key)
        return session

    def remember(self, session: Session) -> None:
        """Note which variant this browser is on. Page loads only: an interaction from a background
        tab must not move the mark, since that is the cross-tab bleed this store exists to end."""
        self._current[session.sid] = session.variant.key

    def discard(self, sid: str, variant_key: str | None = None) -> None:
        """Drop one of a browser's quizzes, or (with no variant) every one of them."""
        for key in [(sid, variant_key)] if variant_key else [k for k in self._sessions if k[0] == sid]:
            self._sessions.pop(key, None)
        if variant_key is None or self._current.get(sid) == variant_key:
            self._current.pop(sid, None)

    def __len__(self) -> int:
        return len(self._sessions)

    def _maybe_sweep(self) -> None:
        now = time.time()
        if now - self._last_sweep < _SWEEP_EVERY_SECONDS:
            return
        self._last_sweep = now
        stale = [key for key, s in self._sessions.items() if now - s.touched > self._ttl]
        for key in stale:
            del self._sessions[key]
        live = {sid for sid, _ in self._sessions}
        for sid in [sid for sid in self._current if sid not in live]:
            del self._current[sid]
