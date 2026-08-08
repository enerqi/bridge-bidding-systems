"""Each module must be importable on its own.

`apps/quiz/` reaches sys.path only when `corpus` is imported, so any module that needs `quiz`
has to get there through `corpus`. A plain `import quiz` looks fine until an import-sorter moves
it above `import corpus` -- these tests import each module first in a fresh interpreter, which
is the only way that regression shows up.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

APP_DIR = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("module", ["corpus", "engine", "state", "render", "app", "telemetry"])
def test_module_imports_standalone(module):
    result = subprocess.run(
        [sys.executable, "-c", f"import {module}"],
        cwd=APP_DIR,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
