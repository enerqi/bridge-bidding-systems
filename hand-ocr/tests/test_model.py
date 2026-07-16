"""Model/PBN/LIN/validation tests -- the spine, no vision needed.

Run:  uv run --with pytest python -m pytest hand-ocr/tests -q
  or:  cd hand-ocr && uv run --with pytest python -m pytest -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hand_ocr.model import Deal, DealError, Hand, _normalise_suit_ranks, dealer_for_board, vul_for_board


def test_rank_normalisation_orders_and_maps_ten():
    assert _normalise_suit_ranks("4KAQ") == "AKQ4"
    assert _normalise_suit_ranks("10 8 7") == "T87"
    assert _normalise_suit_ranks("-") == ""
    assert _normalise_suit_ranks("") == ""


def test_bad_rank_rejected():
    with pytest.raises(DealError):
        _normalise_suit_ranks("AKX")


def test_dup_rank_in_suit_rejected():
    with pytest.raises(DealError):
        _normalise_suit_ranks("AA")


def test_dealer_rotation_by_board():
    assert [dealer_for_board(b) for b in (1, 2, 3, 4, 5, 13)] == ["N", "E", "S", "W", "N", "N"]


def test_vulnerability_cycle_by_board():
    # standard 16-board duplicate rotation; 13 -> All, 1 -> None, wraps at 17
    assert vul_for_board(1) == "None"
    assert vul_for_board(4) == "All"
    assert vul_for_board(13) == "All"
    assert [vul_for_board(b) for b in range(1, 5)] == [vul_for_board(b) for b in range(17, 21)]


def _full_deal() -> Deal:
    return Deal(
        first="N",
        hands={
            "N": Hand.from_rows("AKQ4", "KJ3", "AQ5", "T87"),
            "E": Hand.from_rows("T765", "T98", "JT9", "J65"),
            "S": Hand.from_rows("J932", "AQ4", "K87", "AQ2"),
            "W": Hand.from_rows("8", "765 2", "6432", "K943"),
        },
    )


def test_full_deal_validates():
    _full_deal().validate()  # no raise


def test_partial_deal_validates_and_pbn_uses_dash():
    d = Deal(
        first="N",
        hands={
            "N": Hand.from_rows("AKQ4", "KJ3", "AQ5", "T87"),
            "E": None,
            "S": Hand.from_rows("J932", "AQ4", "K87", "AQ2"),
            "W": None,
        },
    )
    d.validate()
    pbn = d.to_pbn()
    assert pbn == '[Deal "N:AKQ4.KJ3.AQ5.T87 - J932.AQ4.K87.AQ2 -"]'
    assert pbn.count(" - ") >= 1  # unknown hands present


def test_wrong_card_count_rejected():
    d = Deal(hands={"N": Hand.from_rows("AKQ", "", "", ""), "E": None, "S": None, "W": None})
    with pytest.raises(DealError, match="expected 13"):
        d.validate()


def test_duplicate_card_across_hands_rejected():
    same = Hand.from_rows("AKQ4", "KJ3", "AQ5", "T87")
    d = Deal(hands={"N": same, "E": None, "S": same, "W": None})
    with pytest.raises(DealError, match="both"):
        d.validate()


def test_lin_requires_all_four_hands():
    d = Deal(hands={"N": Hand.from_rows("AKQ4", "KJ3", "AQ5", "T87"), "E": None, "S": None, "W": None})
    with pytest.raises(DealError, match="all four"):
        d.to_lin()


def test_pbn_tags_emits_metadata_when_present():
    d = _full_deal()
    d.board, d.dealer, d.vul = 1, "N", "None"
    d.contract, d.declarer, d.result = "4CX", "W", 7
    tags = d.to_pbn_tags()
    assert '[Board "1"]' in tags
    assert '[Dealer "N"]' in tags
    assert '[Vulnerable "None"]' in tags
    assert '[Contract "4CX"]' in tags
    assert '[Declarer "W"]' in tags
    assert '[Result "7"]' in tags
    assert tags.strip().endswith(d.to_pbn())  # Deal tag stays last


def test_pbn_tags_omits_absent_metadata():
    d = _full_deal()  # no board/dealer/vul set
    assert d.to_pbn_tags() == d.to_pbn()  # just the Deal tag, no empty tags


def test_lin_full_deal_shape():
    lin = _full_deal().to_lin()
    assert lin.startswith("md|3")  # first=N -> dealer digit 3
    assert lin.endswith("|")
    assert lin.count(",") == 3  # four hands
    assert "SAKQ4" in lin  # north spades, suit-prefixed
