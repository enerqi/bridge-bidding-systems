"""Universal suit-glyph anchor: hand-count on real fixtures.

Skipped without the vision extra (opencv), like `test_rows.py`. Run with:
    uv run --extra vision python -m pytest tests/test_anchor.py -q

Pins the verified `find_hand_stacks` counts (see anchor.py's module note): the
colour-quadruple anchor finds every hand on clean-resolution renders across
three unrelated sources, and -- crucially -- does NOT over-count on BridgeWebs
(its DD-grid stray red pairs are rejected by the black-neighbour test), so it is
safe to run alongside the existing compass path.
"""

from __future__ import annotations

from pathlib import Path

import pytest

cv2 = pytest.importorskip("cv2")  # skip whole module without the vision extra

from hand_ocr.anchor import find_hand_stacks  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


def _count(name: str) -> int:
    img = cv2.imread(str(FIXTURES / name))
    assert img is not None, f"missing fixture {name}"
    return len(find_hand_stacks(img))


@pytest.mark.parametrize(
    ("name", "hands"),
    [
        ("realbridge-4-results.png", 4),  # single board, no compass at all
        ("realbridge-replay-1.png", 4),  # big-font baize cross; scale-robust anchor
        ("realbridge-replay-2-nonvul.png", 4),
        ("print-3x4-format.png", 48),  # 12-board club-print grid, compass-less
        ("bridgewebs-4.png", 4),  # compass source: must NOT over-count off the DD grid
        ("bridgewebs-4-2.png", 4),
    ],
)
def test_hand_stack_count(name, hands):
    assert _count(name) == hands


def test_stack_geometry_is_four_rows_top_to_bottom():
    stacks = find_hand_stacks(cv2.imread(str(FIXTURES / "realbridge-4-results.png")))
    assert stacks, "expected hands on realbridge-4-results"
    for s in stacks:
        assert len(s.rows_y) == 4
        assert list(s.rows_y) == sorted(s.rows_y), "S,H,D,C rows must run top-to-bottom"
        assert s.top < s.rows_y[0]
        assert s.bottom > s.rows_y[3]
