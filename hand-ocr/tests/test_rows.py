"""End-to-end Mode-ROWS recognition on a real fixture.

Skipped automatically when the vision extra (opencv) is not installed, so the
light spine test run stays dependency-free. Run the full thing with:
    uv run --extra vision python -m pytest tests/test_rows.py -q

These tests pin the verified behaviour on `bridgewebs-4-2.png`: all four hands
are read exactly and the assembled deal validates as a legal 52-card deal.
"""

from __future__ import annotations

from pathlib import Path

import pytest

cv2 = pytest.importorskip("cv2")  # skip whole module without the vision extra

from hand_ocr.detect import split_tiles  # noqa: E402
from hand_ocr.model import DealError  # noqa: E402
from hand_ocr.rows import read_rows  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
FIXTURE = FIXTURES / "bridgewebs-4-2.png"


def _read(name: str):
    img = cv2.imread(str(FIXTURES / name))
    assert img is not None, f"missing fixture {name}"
    return read_rows(img)


def _valid_boards(name: str) -> tuple[int, int]:
    img = cv2.imread(str(FIXTURES / name))
    assert img is not None, f"missing fixture {name}"
    tiles = split_tiles(img)
    ok = 0
    for t in tiles:
        try:
            read_rows(t.image).validate()
            ok += 1
        except DealError:
            pass
    return ok, len(tiles)


@pytest.fixture(scope="module")
def deal():
    img = cv2.imread(str(FIXTURE))
    assert img is not None, f"missing fixture {FIXTURE}"
    return read_rows(img)


@pytest.mark.parametrize(
    ("seat", "expected"),
    [
        ("N", "AT5.A64.K92.A953"),
        ("E", "8763.KQ.A8764.QJ"),
        ("S", "Q2.JT83.53.K8742"),
        ("W", "KJ94.9752.QJT.T6"),
    ],
)
def test_hand_read_exactly(deal, seat, expected):
    assert deal.hands[seat].to_pbn() == expected


def test_full_deal_validates(deal):
    deal.validate()  # all four hands legal, 52 distinct cards


# Multi-board grids: the `_maybe_split` merge-splitting fix lifted these counts
# (touching black ♠/♣ + first rank used to be dropped as one blob). Pin the floor
# so a regression that re-merges glyphs fails loudly; exact counts may rise later.
@pytest.mark.parametrize(
    ("name", "min_valid", "total"),
    [
        ("bridgewebs-4-3x3-multi.png", 6, 9),
        ("bridgewebs-4-3x3-multi-part2.png", 3, 9),
        ("bridgewebs-4-multi-table.png", 5, 6),
    ],
)
def test_grid_valid_board_floor(name, min_valid, total):
    ok, n = _valid_boards(name)
    assert n == total, f"{name}: split into {n} tiles, expected {total}"
    assert ok >= min_valid, f"{name}: only {ok}/{n} boards valid, expected >= {min_valid}"


# ---- compass-less path (suit-quadruple anchor) ----------------------------


@pytest.fixture(scope="module")
def realbridge():
    return _read("realbridge-4-results.png")


@pytest.mark.parametrize(
    ("seat", "expected"),
    [
        ("N", "872.QT863.J53.T4"),
        ("E", "QT95.AK75.AQ4.AJ"),
        ("S", "AJ.J2.KT976.9875"),
        ("W", "K643.94.82.KQ632"),
    ],
)
def test_realbridge_hand_read_exactly(realbridge, seat, expected):
    # no compass at all: hands are found by the colour-quadruple anchor, ranks
    # by the RealBridge atlas (ten "10" -> "T"). All four hands exact.
    assert realbridge.hands[seat].to_pbn() == expected


def test_realbridge_deal_validates(realbridge):
    realbridge.validate()


def test_print_grid_frame_tiles():
    # club-print grid has no compass; it is tiled by its ruled board frames.
    img = cv2.imread(str(FIXTURES / "print-3x4-format.png"))
    tiles = split_tiles(img)
    assert len(tiles) == 12, f"expected 12 framed boards, got {len(tiles)}"
    assert all(t.atlas == "print" for t in tiles), "frame tiles must carry the print atlas hint"
