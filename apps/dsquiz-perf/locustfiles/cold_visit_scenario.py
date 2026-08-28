"""First loads: someone opening the quiz for the first time, and taking the assets with them.

The cheapest scenario to overlook and the most visible to a real visitor. A cold visit is one
session created, one whole document rendered (shell, app body, the drawer, the topics dialog and
the bid-table status line), and then ~250KB of static files -- the datastar bundle alone is 71KB.
A returning visitor revalidates instead (`no-cache`, so a 304), which is why this user drops its
cookies and its connection between visits: it is measuring the expensive half on purpose.

    GET / (cold)      the document, with no session to resume
    GET /static/...   one entry per file, so a slow one cannot hide in an average
    GET /sfx/<name>   the synthesised WAVs, but only for the share of visitors who turn sound on
"""

from __future__ import annotations

import random
import sys

import gclocust

sys.path.append(gclocust.abs_parent_dir(__file__))

from gclocust import MilliSeconds, Percentile, do_latency_threshold_checks
from locust import FastHttpUser, between, events, task
from locust.env import Environment

import common
from common import config, datastar, profiles

SFX_NAMES = ("correct", "wrong", "skip", "final", "tick")
"""What `sfx.py` synthesises. A wrong name here is a 404, which shows up as a failure rather than
silently measuring nothing -- so the list is allowed to be slightly wrong and still be honest."""


class ColdVisitorUser(FastHttpUser):
    """Arrives with an empty cache and an empty cookie jar, looks around, leaves."""

    host = config.HOST
    # a browser opens several connections for the assets on a first load
    concurrency = 6
    network_timeout = 60.0
    connection_timeout = 15.0
    wait_time = between(5.0, 30.0)

    def on_start(self) -> None:
        self.profile = profiles.random_profile()

    @task
    def cold_visit(self) -> None:
        self.client.cookiejar.clear()
        self.profile = profiles.random_profile()
        view = datastar.load_page(self, self.profile.variant_query, name="GET / (cold)")

        if config.CHECK_STATIC:
            # the page's own <link>/<script> URLs, so a renamed or added stylesheet is picked up
            # here without this file knowing about it
            for asset in view.assets:
                self.client.get(asset, name=asset, headers=datastar.PAGE_HEADERS)

        # sound starts OFF, and nothing is fetched until it is ticked -- so only a minority of
        # visits pay for the WAVs
        if random.random() < 0.2:
            for name in SFX_NAMES:
                self.client.get(
                    f"{datastar.prefix_of(view)}/sfx/{name}", name="GET /sfx/<name>", headers=datastar.PAGE_HEADERS
                )

        # one interaction, so the visit is not purely static: this is also the cheapest check that
        # a freshly created session can actually be played
        if view.can_answer():
            _, stream_ms = datastar.answer(self, view, random.randrange(view.candidates), self.profile.signals)
            common.record_answer_stream(stream_ms)


@events.quitting.add_listener
def cold_visit_threshold_checks(environment: Environment, **_kwargs: object) -> None:
    do_latency_threshold_checks(
        common.stat_entry(environment, "GET / (cold)", method="GET"),
        {Percentile(0.95): MilliSeconds(config.PAGE_P95_MS)},
        environment,
    )
