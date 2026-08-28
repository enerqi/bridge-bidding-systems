"""Optional yappi profiling, off unless asked for, and costing nothing at all when off.

    just dsquiz serve-profiled          # DSQUIZ_YAPPI=1, plus the `profiling` extra
    curl http://127.0.0.1:5008/debug/yappi        # the report so far, as text
    curl -X POST http://127.0.0.1:5008/debug/yappi/reset   # start a fresh window

WHY yappi rather than a sampling profiler. py-spy cannot profile this server usefully: it pauses the
process to read stacks, and this app is a single asyncio loop on a single core, so pausing it *is*
the outage -- measured at 100Hz against 100 users, the P90 went from ~50ms to 18 SECONDS. Its
`--nonblocking` mode does not pause, and then loses about a third of its samples to torn reads
(measured: 108 samples, 59 errors, and zero errors in every other configuration). yappi instruments
instead of sampling, so it neither pauses the process nor guesses.

WHY IT IS FREE WHEN OFF, precisely -- "no overhead" is a claim worth being able to point at:

* `ENABLED` is read once at import from `DSQUIZ_YAPPI`. When it is false, yappi is never imported;
  the package need not even be installed.
* Nothing in this module is called from a request path. There is no middleware, no decorator, and no
  wrapper around a handler -- yappi hooks the interpreter itself when started, so profiling needs no
  cooperation from the code being profiled.
* The debug routes are only added to the app when it is on (`app.create_app`), so a production
  process has no such endpoint to reach, whatever anyone sends it.

The cost when ON is real and worth stating: an instrumenting profiler pays per function CALL, so
expect the server to run several times slower. That is fine for the question it answers -- where does
the time go, proportionally -- and useless for "how fast is it", which is what the locust runs are
for.

CLOCK. `DSQUIZ_YAPPI_CLOCK=cpu` (the default here) measures CPU time, which is the one that matters
for a single core: it excludes time a coroutine spends awaiting. `wall` includes it, which makes
`asyncio.sleep` in the answer choreography the biggest thing in the report and buries the work.
"""

from __future__ import annotations

import os
from typing import Any

ENABLED = bool(os.environ.get("DSQUIZ_YAPPI"))
CLOCK = os.environ.get("DSQUIZ_YAPPI_CLOCK", "cpu").strip().lower()

# How many rows a text report prints. The corpus code alone is thousands of functions, and the tail
# is noise -- one call to a validator that took 3 microseconds is not a finding.
ROWS = int(os.environ.get("DSQUIZ_YAPPI_ROWS", "35"))

_yappi: Any = None


def start() -> None:
    """Begin profiling. Called once at startup, and only when `ENABLED`."""
    global _yappi
    if not ENABLED:
        return
    try:
        import yappi
    except ImportError:  # asked for, but not installed -- carry on unprofiled
        return

    # NO `set_context_backend("asyncio")`: it does not exist. yappi's context backends are
    # `native_thread` and `greenlet` only (checked: `yappi.BACKEND_TYPES`), and asking for asyncio
    # raises `YappiError: Invalid backend type: ASYNCIO` -- which kills the worker at startup, since
    # this runs in a lifespan hook. Coroutine profiling needs no switch: yappi has handled coroutines
    # natively since 1.2, attributing a coroutine's time to the coroutine rather than to whichever
    # task resumed it.
    yappi.set_clock_type(CLOCK)
    # `builtins=False`: C functions are not where this app's time goes (the exception is brotli, and
    # its cost is already known from COMPARISON.md), and including them triples the report.
    yappi.start(builtins=False)
    _yappi = yappi


def stop() -> None:
    if _yappi is not None and _yappi.is_running():
        _yappi.stop()


def reset() -> None:
    """Throw away what has been collected, so the next report covers one known window."""
    if _yappi is not None:
        _yappi.clear_stats()


def report(rows: int = ROWS) -> str:
    """The profile so far as text: the functions this process spent its time inside.

    Sorted by TOTAL time (`ttot`), which for a server is the question being asked -- "what does a
    request spend itself on" -- with `tsub` (time excluding callees) beside it, because the two
    disagreeing is what tells you whether a function is expensive or merely on the path to something
    that is.
    """
    if _yappi is None:
        return "profiling is off (set DSQUIZ_YAPPI=1 and install the `profiling` extra)\n"

    stats = _yappi.get_func_stats()
    if not stats:
        return "no samples yet -- send some requests first\n"

    lines = [
        f"yappi {CLOCK} clock, {len(stats)} functions, top {rows} by total time",
        "",
        f"{'ncall':>9}  {'ttot s':>9}  {'tsub s':>9}  {'tavg ms':>9}  function",
    ]
    for stat in list(stats.sort("ttot", "desc"))[:rows]:
        where = f"{_short(stat.module)}:{stat.lineno} {stat.name}"
        lines.append(f"{stat.ncall:>9}  {stat.ttot:>9.3f}  {stat.tsub:>9.3f}  {stat.tavg * 1000:>9.3f}  {where}")
    return "\n".join(lines) + "\n"


def _short(module: str) -> str:
    """`.../site-packages/litestar/router.py` -> `litestar/router.py`, and this app's own modules to
    their bare name. Full paths make every row the same width and none of it readable."""
    parts = module.replace("\\", "/").split("/")
    for marker in ("site-packages", "datastar-quiz", "quiz"):
        if marker in parts:
            return "/".join(parts[parts.index(marker) + 1 :])
    return parts[-1]


def save(directory: str = ".reports", label: str = "yappi") -> str | None:
    """Write the text report and a callgrind file, and return the text path.

    The callgrind file is the one worth keeping: kcachegrind / qcachegrind read it, and it carries
    the call graph rather than a flat list. `yappi.convert2pstats` is the other route, for anything
    that speaks pstats.
    """
    if _yappi is None:
        return None
    import datetime as dt
    from pathlib import Path

    out_dir = Path(directory)
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(tz=dt.UTC).strftime("%Y-%m-%d %H_%M_%S")
    text_path = out_dir / f"{label} ({CLOCK}) {stamp}.txt"
    text_path.write_text(report(rows=200), encoding="utf-8")
    _yappi.get_func_stats().save(str(out_dir / f"{label} ({CLOCK}) {stamp}.callgrind"), type="callgrind")
    return str(text_path)
