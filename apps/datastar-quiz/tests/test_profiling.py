"""The yappi profiler is optional, and OFF has to mean nothing at all.

"No overhead when turned off" is a claim, so it is asserted rather than described: with
`DSQUIZ_YAPPI` unset, yappi is never imported, the debug routes do not exist, and no startup hook
runs. Everything here is about the OFF state -- the on state is exercised by hand
(`just serve-profiled`), because starting a profiler inside the test process would profile pytest.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from litestar.testing import TestClient

import app as app_module
import profiling

APP_DIR = Path(app_module.__file__).resolve().parent


def test_off_by_default():
    assert profiling.ENABLED is False


def test_yappi_is_not_imported_when_off():
    """A subprocess, because pytest's own environment may have imported yappi for another reason.

    This is the whole of the zero-overhead claim: an unprofiled process does not even load the
    profiler, so the `profiling` extra need not be installed on the box.
    """
    code = "import sys; import app; print('yappi' in sys.modules, app.profiling.ENABLED)"
    result = subprocess.run(
        [sys.executable, "-c", code],
        capture_output=True,
        text=True,
        cwd=APP_DIR,
        check=True,
    )
    assert result.stdout.strip() == "False False"


def test_the_debug_routes_do_not_exist_when_off():
    """Not "return 403" -- absent. A production process has no such endpoint to reach."""
    with TestClient(app=app_module.app) as client:
        for path in ("/debug/yappi", "/debug/yappi/reset", "/debug/yappi/save"):
            method = client.get if path.endswith("yappi") else client.post
            assert method(path).status_code == 404, path


def test_no_profiling_hook_when_off():
    """`on_startup` is not empty -- it pre-warms the corpora (see `create_app`) -- so this asserts the
    profiler's own hooks are absent rather than that the list is."""
    assert app_module.app.on_shutdown == []
    assert len(app_module.app.on_startup) == (1 if app_module.PREWARM else 0)


def test_report_says_so_rather_than_failing_when_off():
    assert "profiling is off" in profiling.report()
    assert profiling.save() is None
    profiling.reset()  # a no-op, not an error
    profiling.stop()
