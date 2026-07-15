"""Mode CARDS (app play view) recognition on a real BBO fixture.

Skipped without the vision extra (opencv), like the other vision tests. Run:
    uv run --extra vision python -m pytest tests/test_cards.py -q

Pins the working CARDS paths on BBO:
- horizontal N/S strips (2-hand declarer+dummy view): only N and S are face-up
  (W/E are card backs), so the deal reads those two exactly and leaves E/W
  unknown (PBN '-');
- 2D W/E card grids (4-hand view): all four hands face-up, read exact, a
  complete legal 52-card deal.
The atlas is built from `bridge-base-4-hand-large.png` (the 2-hand fixture is
the same deal at the same render scale).
"""

from __future__ import annotations

from pathlib import Path

import pytest

cv2 = pytest.importorskip("cv2")  # skip whole module without the vision extra

from hand_ocr.pipeline import image_to_deals  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


@pytest.fixture(scope="module")
def bbo_two_hand():
    deals = image_to_deals(str(FIXTURES / "bridge-base-2-hand-large.png"))
    assert len(deals) == 1, f"expected 1 deal, got {len(deals)}"
    return deals[0]


@pytest.mark.parametrize(
    ("seat", "expected"),
    [
        ("N", "432.432.Q432.KQJ"),
        ("S", "AQJ.QJ9876.5.A32"),
    ],
)
def test_bbo_declarer_dummy_exact(bbo_two_hand, seat, expected):
    # suit read per-card from the glyph (2-colour deck), rank from the BBO atlas
    assert bbo_two_hand.hands[seat] is not None, f"{seat} not read"
    assert bbo_two_hand.hands[seat].to_pbn() == expected


def test_bbo_facedown_hands_unknown(bbo_two_hand):
    # W/E are card backs -> no white blob -> unknown -> PBN '-'
    assert bbo_two_hand.hands["W"] is None
    assert bbo_two_hand.hands["E"] is None


def test_bbo_two_hand_validates(bbo_two_hand):
    bbo_two_hand.validate()  # the two known hands are legal, no card collision


@pytest.fixture(scope="module")
def bbo_four_hand():
    # all four hands face-up: N/S are horizontal strips, W/E are 2D card grids
    deals = image_to_deals(str(FIXTURES / "bridge-base-4-hand-large.png"))
    assert len(deals) == 1, f"expected 1 deal, got {len(deals)}"
    return deals[0]


@pytest.mark.parametrize(
    ("seat", "expected"),
    [
        ("N", "432.432.Q432.KQJ"),
        ("S", "AQJ.QJ9876.5.A32"),
        ("W", "765.KT5.KJT9.T98"),  # grid hand; ten read from the new "1","0" rank exemplars
        ("E", "KT98.A.A876.7654"),  # grid hand
    ],
)
def test_bbo_four_hand_exact(bbo_four_hand, seat, expected):
    assert bbo_four_hand.hands[seat] is not None, f"{seat} not read"
    assert bbo_four_hand.hands[seat].to_pbn() == expected


def test_bbo_four_hand_validates(bbo_four_hand):
    bbo_four_hand.validate()  # a complete, legal 52-card deal -- every seat read


@pytest.mark.parametrize(("seat", "expected"), [("N", "432.432.Q432.KQJ"), ("S", "AQJ.QJ9876.5.A32")])
def test_bbo_two_hand_small_strips_exact(seat, expected):
    # cross-scale guard: the small render's N/S strips read exact against the
    # large-scale atlas once it carries grid suit exemplars (fixed a ♠/♣ mix-up)
    deal = image_to_deals(str(FIXTURES / "bridge-base-2-hand-small.png"))[0]
    hand = deal.hands[seat]
    assert hand is not None, f"{seat} not read"
    assert hand.to_pbn() == expected


@pytest.mark.parametrize(
    ("seat", "expected"),
    [
        ("N", "432.432.Q432.KQJ"),
        ("S", "AQJ.QJ9876.5.A32"),
        ("W", "765.KT5.KJT9.T98"),
        ("E", "KT98.A.A876.7654"),
    ],
)
def test_bbo_four_hand_small_exact(seat, expected):
    # cross-scale: the smaller 4-hand render reads all four exact against the
    # large atlas -- whole-rank matching stopped the tens shattering at this scale
    deal = image_to_deals(str(FIXTURES / "bridge-base-4-hand-small.png"))[0]
    hand = deal.hands[seat]
    assert hand is not None, f"{seat} not read"
    assert hand.to_pbn() == expected


# --- IntoBridge: 4-colour deck (suit from colour), rotated seats (read from the
# N/E/S/W badge), gapless card grids (one merged blob split by suit glyph). ---


@pytest.fixture(scope="module")
def intobridge_four_hand():
    deals = image_to_deals(str(FIXTURES / "intobridge-4-hand-large.png"))
    assert len(deals) == 1, f"expected 1 deal, got {len(deals)}"
    return deals[0]


@pytest.mark.parametrize(
    ("seat", "expected"),
    [
        ("N", "T653.AJ8.8.87632"),  # right-side grid; seat is West by screen position -> badge says North
        ("E", "KQ74.753.KJ962.4"),  # bottom strip
        ("S", "A2.QT92.74.QJT95"),  # left-side grid
        ("W", "J98.K64.AQT53.AK"),  # top strip
    ],
)
def test_intobridge_four_hand_exact(intobridge_four_hand, seat, expected):
    assert intobridge_four_hand.hands[seat] is not None, f"{seat} not read"
    assert intobridge_four_hand.hands[seat].to_pbn() == expected


def test_intobridge_four_hand_validates(intobridge_four_hand):
    intobridge_four_hand.validate()  # complete legal deal, seats correctly de-rotated by the badges


@pytest.mark.parametrize(("seat", "expected"), [("E", "KQ74.753.KJ962.4"), ("W", "J98.K64.AQT53.AK")])
def test_intobridge_two_hand_declarer_dummy(seat, expected):
    # declarer + dummy view: only E/W face-up (badges seat them right); N/S hidden -> '-'
    deal = image_to_deals(str(FIXTURES / "intobridge-2-hand-large.png"))[0]
    hand = deal.hands[seat]
    assert hand is not None, f"{seat} not read"
    assert hand.to_pbn() == expected
    assert deal.hands["N"] is None
    assert deal.hands["S"] is None
