"""The bid-table filter: the app's per-keystroke server validation.

Separate from the player scenario because it is a different shape of load. A player makes one
request every few seconds and waits for the answer; someone narrowing the quiz to `1C--1D` produces
a burst of GETs 300ms apart (the box's debounce), each one re-checking the filter against the whole
parsed corpus, and none of them commits anything. `corpus.check_filter` is the hot path here, and
the claim it rests on -- "cheap enough to run per keystroke because `bidfilter.prepare_sequence_bids`
pre-parsed the corpus" -- is exactly the sort of claim a load test exists to check.

    GET /filter/preview          one keystroke pause in the filter box
    GET /filter/preview-topics   one tick in the topics dialog
    GET /filter/topics-reset     closing the dialog without applying
    POST /filter/apply           committing typed text (restarts the quiz)
    POST /filter/apply-topics    committing the ticks (restarts the quiz)
"""

from __future__ import annotations

import random
import sys

import gclocust

sys.path.append(gclocust.abs_parent_dir(__file__))

import gevent
from gclocust import MilliSeconds, Percentile, do_latency_threshold_checks
from locust import FastHttpUser, between, events, task
from locust.env import Environment

import common
from common import config, datastar, profiles


class FilterUser(FastHttpUser):
    """Someone deciding what to be quizzed on, then playing a little of it."""

    host = config.HOST
    concurrency = 2
    network_timeout = 60.0
    connection_timeout = 15.0
    # between editing sessions; the pauses WITHIN one burst of typing are in `type_filter`
    wait_time = between(3.0, 12.0)

    def on_start(self) -> None:
        self.profile = profiles.random_profile()
        self.view = datastar.load_page(self, self.profile.variant_query)

    @task(5)
    def type_filter(self) -> None:
        """Type a filter, previewing as you go, then usually apply it."""
        signals = self.profile.signals
        phrase = random.choice(profiles.FILTER_PHRASES)
        for prefix in profiles.typed_prefixes(phrase):
            signals.filter_text = prefix
            self.view = datastar.get_action(self, self.view, "/filter/preview", signals)
            gevent.sleep(random.uniform(*config.TYPE_PAUSE))  # NOT time.sleep: blocking the hub stops every user

        if random.random() < 0.75:
            # Enter commits: the filter changes, so the server restarts the quiz behind it
            self.view = datastar.post_action(self, self.view, "/filter/apply", signals)
        else:
            # thought better of it -- the draft is left in the box and never committed
            signals.filter_text = ""

    @task(3)
    def use_topics_picker(self) -> None:
        """Open the dialog, tick a few topics previewing each, then apply or close.

        The topic signal names are read off the page (`data-bind:topics.<slug>`) and converted the
        way datastar converts them, so the ticks select real topics. A made-up key would tick
        nothing, the preview would find nothing, and the scenario would quietly measure the cheapest
        possible call.
        """
        slugs = self.view.topic_slugs
        if not slugs:
            self.view = datastar.load_page(self, self.profile.variant_query)
            return

        signals = self.profile.signals
        signals.topics = {}
        for slug in random.sample(list(slugs), k=min(len(slugs), random.randint(1, 3))):
            signals.topics[datastar.topic_signal_key(slug)] = True
            self.view = datastar.get_action(self, self.view, "/filter/preview-topics", signals)
            gevent.sleep(random.uniform(*config.TYPE_PAUSE))  # NOT time.sleep: blocking the hub stops every user

        if random.random() < 0.6:
            self.view = datastar.post_action(self, self.view, "/filter/apply-topics", signals)
        else:
            self.view = datastar.get_action(self, self.view, "/filter/topics-reset", signals)
            signals.topics = {}

    @task(4)
    def play_a_little(self) -> None:
        """Answer one question, so the filtered corpus is actually drawn from."""
        if not self.view.can_answer():
            if self.view.awaiting_next:
                self.view = datastar.post_action(self, self.view, "/next", self.profile.signals)
            else:
                self.view = datastar.load_page(self, self.profile.variant_query)
            return
        index = random.randrange(self.view.candidates)
        self.view, stream_ms = datastar.answer(self, self.view, index, self.profile.signals)
        common.record_answer_stream(stream_ms)


@events.quitting.add_listener
def filter_threshold_checks(environment: Environment, **_kwargs: object) -> None:
    do_latency_threshold_checks(
        common.stat_entry(environment, "GET /filter/preview", method="GET"),
        {Percentile(0.95): MilliSeconds(config.PREVIEW_P95_MS)},
        environment,
    )
    do_latency_threshold_checks(
        common.stat_entry(environment, "GET /filter/preview-topics", method="GET"),
        {Percentile(0.95): MilliSeconds(config.PREVIEW_P95_MS)},
        environment,
    )
