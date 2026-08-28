"""Shared setup for every dsquiz locustfile.

Importing this package is what arms the run: the reporting options and the aggregate threshold
checks are registered here as locust event listeners, so a scenario file gets them by saying
`import common` and nothing else. That is the arrangement the Confluence guide describes under
"Global Aggregate Threshold Checks" -- per-scenario checks live in the scenario files.

Module-level code here runs once per locust PROCESS, master and worker alike; the gclocust helpers
know which of the two they are on and only act where it makes sense (stats are collected on the
master, so that is where a threshold can be judged).
"""

from __future__ import annotations

import logging
from collections import Counter

from gclocust import (
    MilliSeconds,
    Percentile,
    do_check_rate_counter_against_threshold,
    do_fail_ratio_threshold_check,
    do_increase_live_charting_latency_details,
    do_latency_threshold_checks,
    do_set_output_report_name_if_missing,
)
from locust import events, stats
from locust.env import Environment

from common import config

PROJECT_NAME = "DSQuiz"

logger = logging.getLogger(__name__)

slow_sse_stream_rate: Counter[bool] = Counter({True: 0, False: 0})
"""A K6-style `Rate` over whole `/answer` SSE streams: True = the stream outran its budget.

Kept out of the normal statistics deliberately. The stream is mostly the server sleeping between
toasts, so firing it as a request would drag the aggregate percentiles to ~3s and make every latency
threshold meaningless. As a rate it answers the question that actually matters -- how often does the
choreography fail to keep to its own pace -- and `do_check_rate_counter_against_threshold` turns
that into an exit code.
"""

answer_stream_ms: list[float] = []
"""Every whole-stream duration, for the one-line summary at the end of a run."""


@events.init.add_listener
def set_reporting_options(environment: Environment, **_kwargs: object) -> None:
    do_increase_live_charting_latency_details(environment)
    do_set_output_report_name_if_missing(environment, PROJECT_NAME, output_dir_prefix=".reports")


@events.quitting.add_listener
def aggregate_threshold_checks(environment: Environment, **_kwargs: object) -> None:
    """The whole-run pass/fail, in the order the exit code needs.

    `do_fail_ratio_threshold_check` goes LAST: it is the one that clears locust's default
    "any error at all fails the run" policy, and it only does so while nothing else has already
    failed the run.
    """
    if answer_stream_ms:
        mean_ms = sum(answer_stream_ms) / len(answer_stream_ms)
        over = slow_sse_stream_rate[True]
        logger.info(
            "answer SSE streams: %s sampled, mean %.0f ms, %s over the %.0f ms budget",
            len(answer_stream_ms),
            mean_ms,
            over,
            config.SSE_BUDGET_MS,
        )

    do_latency_threshold_checks(
        environment.stats.total,
        {
            Percentile(0.50): MilliSeconds(config.P50_MS),
            Percentile(0.95): MilliSeconds(config.P95_MS),
            Percentile(0.99): MilliSeconds(config.P99_MS),
        },
        environment,
    )
    do_check_rate_counter_against_threshold(
        slow_sse_stream_rate,
        Percentile(config.SLOW_SSE_RATE),
        "answer SSE streams over budget",
        environment,
    )
    do_fail_ratio_threshold_check(environment.stats.total, Percentile(config.FAIL_RATIO), environment)


def record_answer_stream(stream_ms: float) -> None:
    """Book one whole-stream duration against the budget. Called by the player scenario."""
    if stream_ms <= 0:
        return
    answer_stream_ms.append(stream_ms)
    slow_sse_stream_rate[stream_ms > config.SSE_BUDGET_MS] += 1


def stat_entry(environment: Environment, name: str, method: str = "POST") -> stats.StatsEntry | None:
    """One named request's statistics, or None if the run never made that request.

    `stats.get` would CREATE an empty entry, which then reports a P95 of zero and passes every
    threshold silently. The gclocust checks log a warning when handed None, which is the honest
    outcome for "that scenario did not run".
    """
    return environment.stats.entries.get((name, method))
