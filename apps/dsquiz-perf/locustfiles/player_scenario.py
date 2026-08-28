"""The main scenario: people playing quizzes.

One user is one browser tab with one session cookie, working the loop the app is built around --
load the page, answer, read the reveal, press Next, occasionally skip, occasionally change a setting
(which restarts the quiz), occasionally abandon and arrive as a new visitor.

What it exercises, per request name:

    GET /            the full document: shell + app body + the bid-table render behind it
    POST /answer     scoring (see `datastar.answer` for why this is NOT the whole SSE stream)
    POST /next       leaving a reveal, which re-renders the quiz body
    POST /skip       the same, minus a milestone
    POST /settings   adopting a changed signal, which restarts the quiz
    POST /restart    a fresh quiz on the same session
"""

from __future__ import annotations

import random
import sys

import gclocust

# locust loads this file by path, so the project root is not on sys.path yet and `common` cannot be
# imported without help. `abs_parent_dir` is gclocust's helper for exactly this.
sys.path.append(gclocust.abs_parent_dir(__file__))

from gclocust import MilliSeconds, Percentile, do_latency_threshold_checks
from locust import FastHttpUser, events, task
from locust.env import Environment

import common
from common import config, datastar, profiles


class PlayerUser(FastHttpUser):
    """One person, one session, one quiz at a time."""

    host = config.HOST
    # A player never makes parallel requests -- one click, one round trip -- so a small pool is
    # right. Larger only wastes server-side connections at a few hundred users.
    concurrency = 2
    # The answer route holds its connection open for the length of the toast choreography (up to
    # ~4s of deliberate server-side sleeping), so the default network timeout is not generous
    # enough once the machine is loaded.
    network_timeout = 60.0
    connection_timeout = 15.0

    def on_start(self) -> None:
        self.profile = profiles.random_profile()
        self.view = datastar.load_page(self, self.profile.variant_query)

    # Locust's documented way to make think time depend on the user: the base class holds a
    # callable attribute (`wait_time = constant(0)`), and a method overrides it. ty reads that as a
    # method whose first parameter went missing, which is what the ignore is for -- drawn per user
    # rather than per class, so a fast player is fast all evening.
    def wait_time(self) -> float:  # ty: ignore[invalid-method-override]
        return self.profile.think()

    @task(24)
    def play(self) -> None:
        """One beat of the quiz loop, whichever beat the page is currently showing."""
        view = self.view
        if not view.playing or view.completed:
            self._new_quiz()
            return
        if view.awaiting_next:
            self.view = datastar.post_action(self, view, "/next", self.profile.signals)
            return
        if not view.can_answer():
            # the page said nothing we can act on -- reload rather than guess a question id
            self.view = datastar.load_page(self, self.profile.variant_query)
            return
        if view.skips_left > 0 and random.random() < config.SKIP_CHANCE:
            self.view = datastar.post_action(self, view, "/skip", self.profile.signals)
            return
        self._answer()

    @task(2)
    def change_settings(self) -> None:
        """Move the difficulty slider or a toggle. The server restarts the quiz when a value
        actually changes, so this is the settings round trip AND a fresh question draw."""
        signals = self.profile.signals
        choice = random.random()
        if choice < 0.5:
            signals.difficulty = random.randint(4, 8)
        elif choice < 0.75:
            signals.ladder_mode = not signals.ladder_mode
        else:
            signals.target_on = not signals.target_on
        self.view = datastar.post_action(self, self.view, "/settings", signals)

    @task(1)
    def start_over(self) -> None:
        self._new_quiz()

    def _answer(self) -> None:
        """Pick a candidate at random.

        The correct answer is not knowable from the page -- that is the point of the quiz -- so the
        hit rate is 1/difficulty, around 12-25%. Both outcomes are exercised: a wrong answer parks
        on the reveal (a short stream, then a `/next`), a right one advances immediately behind a
        longer stream. Completions are rare at that hit rate, which is worth knowing when reading
        the report: the finale render is barely covered here.
        """
        index = random.randrange(self.view.candidates)
        self.view, stream_ms = datastar.answer(self, self.view, index, self.profile.signals)
        common.record_answer_stream(stream_ms)

    def _new_quiz(self) -> None:
        """Restart, or leave and come back as somebody else.

        Abandoning drops the cookie jar, so the next page load is a first visit: a new session is
        created server-side while the old one sits in `state.SessionStore` until its six-hour TTL
        sweeps it. At a few hundred users that difference is the memory profile of the run.
        """
        if random.random() < config.ABANDON_CHANCE:
            self.client.cookiejar.clear()
            self.profile = profiles.random_profile()
            self.view = datastar.load_page(self, self.profile.variant_query, name="GET / (new visitor)")
        else:
            self.view = datastar.post_action(self, self.view, "/restart", self.profile.signals)


@events.quitting.add_listener
def player_threshold_checks(environment: Environment, **_kwargs: object) -> None:
    """Per-route checks. The aggregate ones are in `common`.

    `POST /answer` is the interesting one: it is the server's scoring work per answer, and it is
    also the request every player makes most often, so it is the first number to degrade when the
    single-process event loop runs out of room.
    """
    do_latency_threshold_checks(
        common.stat_entry(environment, "POST /answer"),
        {Percentile(0.95): MilliSeconds(config.ANSWER_P95_MS)},
        environment,
    )
    do_latency_threshold_checks(
        common.stat_entry(environment, "GET /", method="GET"),
        {Percentile(0.95): MilliSeconds(config.PAGE_P95_MS)},
        environment,
    )
