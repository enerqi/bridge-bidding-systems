"""Everything tunable, read from the environment once.

Locust itself owns user count, spawn rate and duration (`-u`, `-r`, `-t`); this module owns what
those users *do* and what counts as a pass. Every value has a default that works against a local
`just dsquiz serve`, so a first run needs no configuration at all.
"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)


def _float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, "").strip() or default)
    except ValueError:
        logger.exception("%s is not a number, using %s", name, default)
        return default


def _int(name: str, default: int) -> int:
    return int(_float(name, default))


def _bool(name: str, *, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


HOST = os.environ.get("DSQUIZ_PERF_HOST", "http://127.0.0.1:5008").rstrip("/")
"""Where the app is. `--host` on the CLI overrides this."""

PREFIX = "/" + os.environ.get("DSQUIZ_PREFIX", "").strip("/") if os.environ.get("DSQUIZ_PREFIX") else ""
"""Mount point, matching the app's own `DSQUIZ_PREFIX`. Only a fallback: the real prefix is read
out of the page's action URLs, so a mounted deployment is handled without setting anything."""

ACCEPT_ENCODING = os.environ.get("DSQUIZ_PERF_ENCODING", "br, gzip")
"""What the simulated browser asks for. The app compresses at brotli q5 (see `create_app`), and
that CPU is part of what we are measuring, so the default is realistic rather than convenient --
geventhttpclient decodes both br and gzip. Set `identity` to take the client's decode cost out of
the injector when the injector is the bottleneck."""

SWEDISH_SHARE = _float("DSQUIZ_PERF_SWEDISH_SHARE", 0.3)
"""Share of players on `?swedish` rather than the default squad system. Both are separate corpora
and separate session keys, so the mix decides how many bid tables the server holds hot."""

THINK_FAST = (0.8, 2.5)
THINK_TYPICAL = (2.0, 7.0)
THINK_SLOW = (5.0, 14.0)
"""Per-user think-time ranges. A question allows 4-8 seconds (`engine._SECONDS_PER_LEVEL`), so a
typical player answers inside the clock and a slow one usually does not -- which is a real load
difference: a timed-out answer still scores, it just wins no time bonus."""

FAST_SHARE = _float("DSQUIZ_PERF_FAST_SHARE", 0.25)
SLOW_SHARE = _float("DSQUIZ_PERF_SLOW_SHARE", 0.25)

SKIP_CHANCE = _float("DSQUIZ_PERF_SKIP_CHANCE", 0.08)
"""How often a player with a skip in hand spends it instead of answering."""

ABANDON_CHANCE = _float("DSQUIZ_PERF_ABANDON_CHANCE", 0.15)
"""Share of `start_over` beats that drop the cookie and arrive as a brand new visitor instead of
pressing Restart. This is the one that grows `state.SessionStore`: the abandoned session stays
resident for its six-hour TTL, so a long run at scale is also a session-memory test."""

TYPE_PAUSE = (0.3, 0.8)
"""Gap between filter-box previews. The box debounces at 300ms (`data-on:input__debounce.300ms`),
so this is the rate at which a *typist* produces server round trips, not the keystroke rate."""

TIMER_HOLD = (_float("DSQUIZ_PERF_TIMER_HOLD_MIN", 20.0), _float("DSQUIZ_PERF_TIMER_HOLD_MAX", 90.0))
"""How long a held-countdown connection stays open before the tab is 'closed'. Shorten both ends
when checking the scenario itself works -- a run shorter than the hold measures one connection."""

# --- pass/fail ---------------------------------------------------------------
#
# Starting values, not measurements. Take a baseline run against an idle machine first, then set
# these from it -- a threshold nobody derived from a real run only fails at inconvenient moments.

P50_MS = _float("DSQUIZ_PERF_P50_MS", 150.0)
P95_MS = _float("DSQUIZ_PERF_P95_MS", 600.0)
P99_MS = _float("DSQUIZ_PERF_P99_MS", 1500.0)
FAIL_RATIO = _float("DSQUIZ_PERF_FAIL_RATIO", 0.01)

ANSWER_P95_MS = _float("DSQUIZ_PERF_ANSWER_P95_MS", 400.0)
PAGE_P95_MS = _float("DSQUIZ_PERF_PAGE_P95_MS", 900.0)
PREVIEW_P95_MS = _float("DSQUIZ_PERF_PREVIEW_P95_MS", 400.0)

SSE_BUDGET_MS = _float("DSQUIZ_PERF_SSE_BUDGET_MS", 6000.0)
"""How long a whole `/answer` SSE stream may take, end to end.

This is NOT a latency threshold on server work: the stream is paced by the server's own
`asyncio.sleep` between toasts (0.6s for a wrong answer, up to ~4s for a correct one that pays a
milestone). The budget catches the stream taking *materially longer than its own choreography*,
which is what a saturated event loop looks like from the player's chair. See README, "what the
answer route measures"."""

SLOW_SSE_RATE = _float("DSQUIZ_PERF_SLOW_SSE_RATE", 0.02)
"""Share of answer streams allowed to exceed `SSE_BUDGET_MS` before the run fails."""

CHECK_STATIC = _bool("DSQUIZ_PERF_CHECK_STATIC", default=True)
"""Whether the cold-visit scenario also fetches the stylesheets and the datastar bundle."""
