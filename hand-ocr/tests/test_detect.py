"""Mode routing: detect_mode on real fixtures.

Skipped without the vision extra (opencv), like the other vision tests.

Pins the CARDS/ROWS decision at the tricky boundaries the green-fraction test
alone gets wrong: a RealBridge *replay* diagram sits on a green baize yet is ROWS
(caught by a full board of suit-row anchor stacks + no white card faces), while a
*cropped* IntoBridge card grid shows no baize yet is CARDS (no anchor stacks).
"""

from __future__ import annotations

from pathlib import Path

import pytest

cv2 = pytest.importorskip("cv2")  # skip whole module without the vision extra

from hand_ocr.detect import Mode, Tile, detect_mode  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


def _mode(name: str) -> Mode:
    img = cv2.imread(str(FIXTURES / name))
    assert img is not None, f"missing fixture {name}"
    return detect_mode(Tile(image=img, origin=(0, 0)))


@pytest.mark.parametrize(
    ("name", "mode"),
    [
        # ROWS suit-row diagrams
        ("bridgewebs-4.png", Mode.ROWS),  # compass baize is small
        ("realbridge-4-results.png", Mode.ROWS),  # no baize
        ("realbridge-replay-1.png", Mode.ROWS),  # baize + big-font board (vul badges)
        ("realbridge-replay-2-nonvul.png", Mode.ROWS),  # baize + big-font board
        ("print-3x4-format.png", Mode.ROWS),
        # CARDS play views
        ("bridge-base-4-hand-large.png", Mode.CARDS),  # BBO baize + white cards
        ("intobridge-2-hand-large.png", Mode.CARDS),  # IntoBridge baize + white cards
        ("intobridge-4-hand-cramped.png", Mode.CARDS),  # cropped grid, no baize, no stacks
        ("intobridge-4-hand-small.png", Mode.CARDS),
    ],
)
def test_mode_routing(name, mode):
    assert _mode(name) == mode
