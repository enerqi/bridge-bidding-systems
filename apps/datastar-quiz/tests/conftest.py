"""Put the app directory on `sys.path` -- these are flat modules, as in `apps/quiz/`."""

import sys
from pathlib import Path

import pytest

APP_DIR = Path(__file__).resolve().parents[1]

if str(APP_DIR) not in sys.path:
    sys.path.insert(0, str(APP_DIR))


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "real_pacing: this test needs the app's real `asyncio.sleep` (the timer stream's tick loop)",
    )


@pytest.fixture(autouse=True)
def _skip_toast_pacing(request, monkeypatch):
    """The answer stream's toast pauses are ~3 REAL seconds a question, and they were the suite.

    `_answer_stream` awaits `asyncio.sleep(toast.pause)` between beats, which is the point in
    production and pure waiting in a test: 38 of the 58 seconds this suite took were spent sleeping,
    and a test that walks a quiz to its finale (`test_show_the_finale_restarts_a_finished_quiz_first`)
    took 11s on its own. Two files already patched it out per-fixture; doing it once here is the same
    trick applied everywhere, and it makes the pacing opt-IN rather than something each new test file
    forgets.

    Opt out with `@pytest.mark.real_pacing`. Exactly one file needs to: `test_timer_modes.py`, whose
    held SSE stream ticks on `asyncio.sleep(TIMER_TICK_SECONDS)` and would spin against a wall-clock
    deadline without it.
    """
    if "real_pacing" in request.keywords:
        return

    import app as app_module

    async def _no_sleep(_seconds: float) -> None:
        return None

    monkeypatch.setattr(app_module.asyncio, "sleep", _no_sleep)
