"""Section headers as auction context.

A bml section titled `**** 2C--2D--2H` means the table inside it is rooted at
2H, but the auction really begins 2C--2D. `quiz.collect_bid_table_auctions`
restores that prefix; these tests pin that behaviour down, including the
multi-suit case (`1C--1HS`) that a single-suit regex used to drop silently.

    uv run --with pytest pytest apps/quiz/tests/test_quiz_context.py
"""

import pytest

import bidfilter
import quiz


@pytest.fixture(scope="module")
def auctions():
    """Parsed auctions per corpus file, built once (parsing is slow).

    `quiz.load_bid_tables` chdirs to the `.bml` corpus itself, so the names
    below are corpus-relative regardless of where pytest was invoked.
    """
    cache = {}

    def load(bml_file):
        if bml_file not in cache:
            tables = quiz.load_bid_tables(bml_file)
            quiz.prettify_bid_table_nodes(tables)
            cache[bml_file] = quiz.collect_bid_table_auctions(tables)
        return cache[bml_file]

    return load


def test_parse_individual_bids_keeps_multi_suit():
    assert quiz.parse_individual_bids(["1H (pass) 2S", "3C"]) == ["1H", "2S", "3C"]
    # the regression: `1HS` is a real bid token, not junk to be filtered out
    assert quiz.parse_individual_bids(["1C", "1HS"]) == ["1C", "1HS"]
    assert quiz.parse_individual_bids(["4CDHS"]) == ["4CDHS"]


def test_bid_less_than_is_strict_for_multi_suit():
    assert quiz.bid_less_than("1HS", "1N")  # both 1H and 1S precede 1N
    assert not quiz.bid_less_than("1HS", "1S")  # 1S is not below itself


def test_section_auction_title_is_prepended(auctions):
    """`**** 2C--2D--2H`: every auction under it starts 2C 2D 2H."""
    under = [
        a
        for a in auctions("2club-opening.bml")
        if any("2C--2D--2H" in h.text for h in a._debug_headers_context)
    ]
    assert len(under) > 20, "expected the section to contribute many auctions"
    for a in under:
        assert a.sequence[:3] == ["2C", "2D", "2H"], a.sequence
    # and the root of the table really was just 2H before restoration
    assert any(a._initial_sequence[0] == "2H" for a in under)


def test_multi_suit_context_is_restored(auctions):
    """`1C--1HS`: opener's rebids used to record as 1C-1N, losing the response."""
    under = [
        a
        for a in auctions("bidding-system.bml")
        if a._parsed_context_bids == ["1C", "1HS"] and a._initial_sequence[:1] == ["1N"]
    ]
    assert under, "expected opener-rebid auctions under 1C--1HS"
    for a in under:
        assert a.sequence[:3] == ["1C", "1HS", "1N"], a.sequence


def test_multi_suit_context_reaches_the_filter(auctions):
    """The point of restoring it: `1C-1M-1N` can now find those auctions."""
    prepared = bidfilter.prepare_sequence_bids(a.sequence for a in auctions("bidding-system.bml"))
    pattern = [bidfilter.parse_pattern("1C-1M-1N")]
    assert sum(1 for bids in prepared if bidfilter.bids_match_any(bids, pattern)) > 0


@pytest.mark.parametrize(
    "bml_file", ["squad-system.bml", "bidding-system.bml", "2club-opening.bml"]
)
def test_no_multi_suit_context_is_dropped(bml_file, auctions):
    """Guard the whole corpus against the bug this fixed: a multi-suit context
    bid that is absent from the auction *and* ranks below its opening call has
    been dropped, and should have been restored.

    Deliberately not asserted: that the context is a strict prefix. Nested
    headers can name the same call twice (`1H--3CD` then a `3C` sub-section),
    so the context list is not always successive calls.
    """
    offenders = []
    for a in auctions(bml_file):
        if not a._initial_sequence:
            continue
        # the table's own first bid, before any context was prepended -- using
        # the restored sequence here would make the check vacuous
        first = a._initial_sequence[0].split()[0]
        for context_bid in a._parsed_context_bids:
            if len(bidfilter.parse_bid_token(context_bid).suits) < 2:
                continue  # single-suit context was never the broken case
            present = any(context_bid in element for element in a.sequence)
            if not present and quiz.bid_less_than(context_bid, first):
                offenders.append((context_bid, a._parsed_context_bids, a.sequence))
    assert not offenders, offenders[:5]
