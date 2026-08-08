"""Optional OpenTelemetry, off unless asked for.

Same deal as the panel app's `quiz_telemetry.py`: the instrumentation calls in the routes stay
unconditional, and everything here degrades to a no-op when the packages are absent or
`DSQUIZ_OTEL` is unset. Nothing in this app requires a collector to run.

    just dsquiz serve-traced      # with a local jaeger (apps/quiz/run-jaeger-tracing.cmd)
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

ENABLED = bool(os.environ.get("DSQUIZ_OTEL"))

_tracer: Any = None

if ENABLED:
    try:
        from opentelemetry import trace  # ty: ignore[unresolved-import] -- the optional `telemetry` extra

        _tracer = trace.get_tracer("datastar-quiz")
    except ImportError:  # asked for, but not installed -- carry on untraced
        _tracer = None


@contextmanager
def span(name: str) -> Iterator[Any]:
    """Trace a block when tracing is on; otherwise cost nothing worth measuring."""
    if _tracer is None:
        yield None
        return
    with _tracer.start_as_current_span(name) as active:
        yield active


def plugins() -> list:
    """Litestar's ASGI-level tracing, when available.

    The import moved between litestar versions (`litestar.plugins.opentelemetry` in newer
    releases, `litestar.contrib.opentelemetry` before), so both are tried and neither is
    required.
    """
    if not ENABLED:
        return []
    for module_name in ("litestar.plugins.opentelemetry", "litestar.contrib.opentelemetry"):
        try:
            module = __import__(module_name, fromlist=["OpenTelemetryConfig", "OpenTelemetryPlugin"])
            return [module.OpenTelemetryPlugin(module.OpenTelemetryConfig())]
        except ImportError, AttributeError:
            continue
    return []
