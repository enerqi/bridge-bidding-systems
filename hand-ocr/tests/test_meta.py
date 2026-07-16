"""Board metadata read from RealBridge replay info boxes (end to end).

Skipped without the vision extra (opencv), like the other vision tests. Pins the
info-box board-number OCR plus the dealer/vulnerability that follow from it, so a
regression in the metadata path fails loudly separately from the hand reads
(which the PBN sidecars in test_regression cover).
"""

from __future__ import annotations

from pathlib import Path

import pytest

cv2 = pytest.importorskip("cv2")  # skip whole module without the vision extra

from hand_ocr.pipeline import image_to_deals  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


@pytest.mark.parametrize(
    ("name", "board", "dealer", "vul", "contract", "declarer", "result"),
    [
        ("realbridge-replay-1.png", 13, "N", "All", "4CX", "W", 7),  # 4!cX-3 W -> 10-3 tricks
        ("realbridge-replay-2-nonvul.png", 1, "N", "None", "3D", "S", 9),  # 3!d = S -> made
    ],
)
def test_replay_board_metadata(name, board, dealer, vul, contract, declarer, result):
    (deal,) = image_to_deals(str(FIXTURES / name))
    assert deal.note is None
    assert deal.board == board
    assert deal.dealer == dealer
    assert deal.vul == vul
    assert deal.first == dealer  # PBN "first" seat follows the dealer
    assert deal.contract == contract
    assert deal.declarer == declarer
    assert deal.result == result
