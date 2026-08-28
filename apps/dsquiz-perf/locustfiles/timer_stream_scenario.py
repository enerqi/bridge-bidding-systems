"""The held-connection countdown, which is a concurrency test rather than a latency test.

Only meaningful against a server started with `DSQUIZ_TIMER=stream` (`just dsquiz serve-streamed`).
In that mode every open tab holds one SSE connection for the life of the page and the server pushes
a signal patch every 100ms per connection, whether or not the number changed -- the cost the app's
COMPARISON.md weighs against the client-side interval that is the default.

What this measures is not the response time of `GET /timer` (there isn't one -- the response never
ends) but whether the server can hold N of them while other users are playing. Run it alongside
the player scenario:

    locust -f locustfiles/timer_stream_scenario.py,locustfiles/player_scenario.py ...

Against a server in the DEFAULT client mode the route returns an empty 200 immediately, which is
harmless and roughly free; the scenario says so once rather than reporting a suspiciously fast
stream.
"""

from __future__ import annotations

import logging
import random
import sys
import time

import gclocust

sys.path.append(gclocust.abs_parent_dir(__file__))

import gevent
from locust import FastHttpUser, between, task

from common import config, datastar, profiles

logger = logging.getLogger(__name__)

_warned_about_client_mode = False
_client_mode = False
"""Set once the server answers 204: there is no stream to hold, so these users go quiet."""

PARKED_SECONDS = 30.0


class TimerStreamUser(FastHttpUser):
    """A tab left open with the countdown streaming into it."""

    host = config.HOST
    concurrency = 2
    # the point of this user is a connection held for a minute or more
    network_timeout = 300.0
    connection_timeout = 15.0
    wait_time = between(1.0, 5.0)

    def on_start(self) -> None:
        self.profile = profiles.random_profile()
        self.view = datastar.load_page(self, self.profile.variant_query)

    @task
    def hold_the_countdown(self) -> None:
        global _warned_about_client_mode, _client_mode

        if _client_mode:
            # one detection request was enough; stay alive and silent so locust does not replace us
            gevent.sleep(PARKED_SECONDS)
            return

        url = datastar.action_url(self.view, "/timer")
        hold_seconds = random.uniform(*config.TIMER_HOLD)
        deadline = time.monotonic() + hold_seconds
        frames = 0

        # `identity`, not brotli: the whole-body decoders in geventhttpclient cannot decompress a
        # stream frame by frame, and this response never ends. The compression cost of the ticks is
        # measured by the player scenario's own patches instead.
        headers = {**datastar.DS_HEADERS, "Accept-Encoding": "identity"}
        with self.client.get(
            url, name="GET /timer (held)", headers=headers, stream=True, catch_response=True
        ) as response:
            if response.status_code == datastar.NO_OP:
                # 204: the server is in the DEFAULT client timer mode, so the route answers with no
                # events at all and there is nothing to hold. A correct answer, not a failure.
                #
                # And then the user goes QUIET for the rest of the run. A held connection that is not
                # held takes a second or two of wait time and asks again, so against a client-mode
                # server these users turned into a flood of no-op 204s -- 9,550 of 33,572 requests in
                # one 400-user run, 28% of the sample, queueing on the same single core as the real
                # work and dragging the aggregate percentiles with them.
                #
                # PARKED, not stopped: `StopUser` was the first attempt and it was worse. Locust holds
                # the user count at its target, so every stopped user was replaced by a new one that
                # ran `on_start` -- a full page load -- and then stopped again. Measured: `GET /` went
                # from 585 requests at a 39ms median to 1,355 at 150ms, trading a flood of cheap 204s
                # for a respawn loop of the most expensive request in the app.
                if not _warned_about_client_mode:
                    _warned_about_client_mode = True
                    logger.warning(
                        "GET /timer answered 204 -- the server is in the default CLIENT timer mode, "
                        "where the countdown costs no requests at all. These users are stopping; "
                        "start the server with DSQUIZ_TIMER=stream (`just dsquiz serve-streamed`) "
                        "for this scenario to measure anything."
                    )
                response.request_meta["response_length"] = 0
                _client_mode = True
                return
            if response.status_code != 200:
                response.failure(f"/timer returned {response.status_code}")
                return
            try:
                for chunk in response:
                    if chunk:
                        frames += 1
                    if time.monotonic() >= deadline:
                        break
            except Exception as error:  # noqa: BLE001 -- a dropped stream is a result, not a crash
                response.failure(f"timer stream broke after {frames} frames: {error}")
                return
            finally:
                _release(response)

            if frames == 0:
                response.failure("timer stream opened with 200 but pushed no frames")
            # the connection was held for as long as it was asked to hold: that IS the success
            response.request_meta["response_length"] = frames


def _release(response: object) -> None:
    """Give the connection back after breaking out mid-stream. Best effort: an abandoned SSE
    response is exactly what closing a tab does to the server, and it is allowed to be untidy."""
    release = getattr(response, "release", None)
    if callable(release):
        try:
            release()
        except Exception:
            logger.debug("timer stream release failed", exc_info=True)
