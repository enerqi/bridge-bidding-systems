"""Section headers as auction context.

A bml section titled `**** 2C--2D--2H` means the table inside it is rooted at
2H, but the auction really begins 2C--2D. `quiz.collect_bid_table_auctions`
restores that prefix; these tests pin that behaviour down, including the
multi-suit case (`1C--1HS`) that a single-suit regex used to drop silently.

    uv run --with pytest pytest apps/quiz/tests/test_quiz_context.py
"""

import pytest

import bidfilter
import bml
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


def header_bids(title):
    return quiz.parse_bids_from_headers([quiz.Header(bml.ContentType.H1, title)])


@pytest.mark.parametrize(
    "title,expected",
    [
        # multi-suit in either position. `1HS--2M` used to yield [] outright:
        # the gate regex allowed one suit letter, so neither `-2M` nor `1HS-`
        # matched and the whole section lost its context
        ("1C--1HS", ["1C", "1HS"]),
        ("1HS--2M", ["1HS", "2M"]),
        ("1C--1D--1HS", ["1C", "1D", "1HS"]),
        # `x` and `*` are the same wildcard: tables spell it `x`, headers `*`.
        # Header tokens come back case-folded, hence `3X/4X`.
        ("1HS--3x/4x", ["1HS", "3X/4X"]),
        ("1HS--3*/4*", ["1HS", "3*/4*"]),
        # major/minor shorthand
        ("1M--3D", ["1M", "3D"]),
        ("2M--2N", ["2M", "2N"]),
        ("1m--2m", ["1m", "2m"]),
        ("1M--(2C)--2D", ["1M", "(2C)", "2D"]),
        # prose around the auction; `/` is OR *within* one position
        ("Transfers after 1M--(X) or 1M overcall--(X)", ["1M"]),
        ("1N--2D/2H", ["1N", "2D/2H"]),
        # not auctions
        ("Good-Bad", []),
        ("1HS", []),  # no separator: a section name, not a sequence
    ],
)
def test_header_bids(title, expected):
    assert header_bids(title) == expected


def test_minor_shorthand_survives_case_folding():
    """`(1m)` is the opponents opening a *minor*. A plain .upper() folded it to
    `(1M)`, silently turning the section into a major-opening context."""
    assert header_bids("After (1m)--P--(1N)") == ["(1m)", "(1N)"]
    assert bidfilter.parse_bid_token("(1m)").suits == bidfilter.MINORS
    assert bidfilter.parse_bid_token("(1M)").suits == bidfilter.MAJORS


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


def test_alternation_in_a_header_is_one_position():
    """`/` is OR at a single position, not a call separator.

    `** 1C--1N/2C` means 1C, then 1D (from the enclosing section), then *either*
    1N or 2C. Splitting the slash recorded four context calls and pushed every
    auction under the section one call to the right.
    """
    assert header_bids("1C--1N/2C") == ["1C", "1N/2C"]
    assert header_bids("1N--2S/2N") == ["1N", "2S/2N"]
    assert header_bids("(1N)--P--(2D/2H)") == ["(1N)", "(2D/2H)"]
    assert header_bids("1HS--3*/4*") == ["1HS", "3*/4*"]


def test_alternation_section_does_not_invent_a_call(auctions):
    """The regression: auctions under `1C--1N/2C` were recorded as
    `1C 1D 1N 2C 2D...`, a five-call auction that was never bid."""
    under = [
        a
        for a in auctions("alternatives.bml")
        if any("1C--1N/2C" in h.text for h in a._debug_headers_context)
    ]
    assert under, "expected auctions under the 1C--1N/2C section"
    for a in under:
        assert a.sequence[:3] == ["1C", "1D", "1N/2C"], a.sequence
        assert "2C" not in a.sequence[:3]


def test_alternation_auction_matches_either_branch(auctions):
    under = [
        a
        for a in auctions("alternatives.bml")
        if a.sequence[:3] == ["1C", "1D", "1N/2C"]
    ]
    assert under
    prepared = bidfilter.prepare_sequence_bids(a.sequence for a in under)
    for pattern_text in ("1C-1D-1N", "1C-1D-2C"):
        pattern = [bidfilter.parse_pattern(pattern_text)]
        assert any(bidfilter.bids_match_any(b, pattern) for b in prepared), pattern_text
    absent = [bidfilter.parse_pattern("1C-1D-1H")]
    assert not any(bidfilter.bids_match_any(b, absent) for b in prepared)
