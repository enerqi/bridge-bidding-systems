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

import time
import uuid

import msgspec

import corpus
import engine

# see the note in engine.py: `quiz` is only importable once corpus has run
from corpus import quiz

SESSION_COOKIE = "dsq_sid"
SESSION_TTL_SECONDS = 6 * 60 * 60
_SWEEP_EVERY_SECONDS = 10 * 60


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
    qid: int = 1  # bumped per question; the answer route rejects a stale qid
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
        self.qid += 1
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
        question_seconds=engine.seconds_for_difficulty(settings.difficulty),
        question_start=time.monotonic(),
        quiz_start_wall=time.time(),
        touched=time.time(),
    )


class SessionStore:
    """Process-local session registry with lazy TTL eviction.

    Lazy rather than a background task: a sweep is cheap, sessions are few, and this keeps the
    store usable from tests without an event loop.
    """

    def __init__(self, ttl: float = SESSION_TTL_SECONDS) -> None:
        self._sessions: dict[str, Session] = {}
        self._ttl = ttl
        self._last_sweep = 0.0

    def get(self, sid: str | None) -> Session | None:
        self._maybe_sweep()
        if not sid:
            return None
        session = self._sessions.get(sid)
        if session is not None:
            session.touched = time.time()
        return session

    def create(self, variant: corpus.Variant) -> Session:
        self._maybe_sweep()
        session = new_session(variant)
        self._sessions[session.sid] = session
        return session

    def discard(self, sid: str) -> None:
        self._sessions.pop(sid, None)

    def __len__(self) -> int:
        return len(self._sessions)

    def _maybe_sweep(self) -> None:
        now = time.time()
        if now - self._last_sweep < _SWEEP_EVERY_SECONDS:
            return
        self._last_sweep = now
        stale = [sid for sid, s in self._sessions.items() if now - s.touched > self._ttl]
        for sid in stale:
            del self._sessions[sid]
