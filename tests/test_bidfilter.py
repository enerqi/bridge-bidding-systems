"""Tests for bidfilter: the quiz's bidding-tree filter language.

    uv run --with pytest pytest tests/test_bidfilter.py
"""

from bidfilter import (
    MAJORS,
    MINORS,
    Bid,
    Topic,
    bids_match_any,
    canonical_pattern_text,
    load_topics,
    match_topic_name,
    normalize_filter_text,
    parse_bid_token,
    parse_filter,
    parse_pattern,
    parse_sequence,
    prepare_sequence_bids,
    sequence_matches,
    sequence_matches_any,
)
from pathlib import Path


def test_parse_bid_token():
    assert parse_bid_token("1D") == Bid(1, frozenset("D"), "bid", False)
    assert parse_bid_token("(1!h)") == Bid(1, frozenset("H"), "bid", True)
    assert parse_bid_token("2DHS") == Bid(2, frozenset("DHS"), "bid", False)
    assert parse_bid_token("(3CDHS)") == Bid(3, frozenset("CDHS"), "bid", True)
    assert parse_bid_token("Pass").kind == "pass"
    assert parse_bid_token("(X)") == Bid(None, frozenset(), "double", True)
    assert parse_bid_token("any").kind == "other"


def test_parse_sequence():
    seq = ["1C (Pass) 1H", "2D", "2S"]
    bids = parse_sequence(seq)
    assert [b.kind for b in bids] == ["bid", "pass", "bid", "bid", "bid"]
    assert bids[0] == Bid(1, frozenset("C"), "bid", False)
    assert bids[1] == Bid(None, frozenset(), "pass", True)


def test_major_shortcut_matches_both():
    pat = parse_pattern("1D--1M--1N")
    assert sequence_matches(["1D (Pass) 1H", "1N"], pat)
    assert sequence_matches(["1D (Pass) 1S", "1N"], pat)
    # wrong level in the middle
    assert not sequence_matches(["1D (Pass) 2H", "1N"], pat)
    # minor where a major is required
    assert not sequence_matches(["1D (Pass) 1C", "1N"], pat)


def test_prefix_shorter_than_sequence():
    pat = parse_pattern("1D--1H")
    assert sequence_matches(["1D (Pass) 1H", "1N", "2C"], pat)
    # pattern longer than auction cannot match
    assert not sequence_matches(["1D"], parse_pattern("1D--1H--1N"))


def test_multi_suit_and_opponents():
    # multi-suit bid 2DHS ({D,H,S}) intersects a major-class pattern 2M ({H,S})
    assert sequence_matches(["1H (Pass) 2DHS"], parse_pattern("1H--2M"))
    # ...but not a pattern demanding clubs
    assert not sequence_matches(["1H (Pass) 2DHS"], parse_pattern("1H--2C"))
    # opponent double in pattern
    pat = parse_pattern("1H--(X)--2H")
    assert sequence_matches(["1H (X)", "2H"], pat)
    assert not sequence_matches(["1H (Pass)", "2H"], pat)


def test_wildcard_token():
    # `(*)` = opponents did something (implicit opponent passes are dropped)
    pat = parse_pattern("1M--(*)")
    assert sequence_matches(["1H (X)"], pat)
    assert sequence_matches(["1S (2D)"], pat)
    assert not sequence_matches(["1H (Pass)", "2H"], pat)
    assert not sequence_matches(["1C (X)"], pat)  # 1C is not a major
    # bare `*` / `any` matches any call by either side
    assert sequence_matches(["1C (Pass) 1H"], parse_pattern("*--*"))
    assert sequence_matches(["1C (X)"], parse_pattern("1C--any"))
    # `1*` — any suit, but that level and an actual bid
    assert sequence_matches(["1C (Pass) 1S"], parse_pattern("1C--1*"))
    assert not sequence_matches(["1C (Pass) 2S"], parse_pattern("1C--1*"))
    assert not sequence_matches(["1C (X)"], parse_pattern("1C--1*"))


def test_normalize_filter_text():
    assert normalize_filter_text("  1D-1M-1N  ") == "1D-1M-1N"
    assert normalize_filter_text("1D  --  1M") == "1D-1M"
    assert normalize_filter_text("1H -- ( X ) - 2H") == "1H-(X)-2H"
    assert normalize_filter_text("1C ,, 1D ,") == "1C, 1D"
    assert normalize_filter_text(None) == ""


def test_opponent_calls_can_be_slipped_in_anywhere():
    # a pattern describes our auction; whatever the opponents do in between
    # should not stop it matching
    pat = parse_pattern("1D-1H")
    assert sequence_matches(["1D (Pass) 1H"], pat)
    assert sequence_matches(["1D (1S) 1H"], pat)
    assert sequence_matches(["1D (X) 1H"], pat)
    assert sequence_matches(["1D (2C)", "1H"], pat)
    # ...but our own calls still have to be in the right order
    assert not sequence_matches(["1D (1S) 2C", "1H"], pat)

    # naming the opponents pins them down: it must be the very next call
    pinned = parse_pattern("1D-(X)-1H")
    assert sequence_matches(["1D (X) 1H"], pinned)
    assert not sequence_matches(["1D (1S) 1H"], pinned)
    assert not sequence_matches(["1D (Pass) 1H"], pinned)

    # a bare `*` is any call at all, opponents included, so it counts depth
    assert sequence_matches(["1D (1S) 1H"], parse_pattern("*-*-*"))
    assert not sequence_matches(["1D (Pass) 1H"], parse_pattern("*-*-*"))


def test_unbracketed_tokens_are_our_calls():
    # brackets mean "the opponents" -- so a bare 1C is our 1C opening, and
    # their 1C opening belongs to a different filter
    assert sequence_matches(["1C (Pass) 1H"], parse_pattern("1C"))
    assert not sequence_matches(["(1C) X"], parse_pattern("1C"))
    assert sequence_matches(["(1C) X"], parse_pattern("(1C)"))
    # the bare wildcard is the exception: either side, so it counts depth
    assert sequence_matches(["(1C) X"], parse_pattern("*"))


def test_first_token_anchors_to_the_opening_call():
    # `2C` means we opened 2C, not that we bid 2C later over their opening --
    # otherwise every overcall would be counted as an opening
    assert sequence_matches(["2C (Pass) 2D"], parse_pattern("2C"))
    assert not sequence_matches(["(1H) 2C"], parse_pattern("2C"))
    # say so explicitly and it matches again
    assert sequence_matches(["(1H) 2C"], parse_pattern("(1H)-2C"))
    assert sequence_matches(["(1H) 2C"], parse_pattern("(*)-2C"))


def test_separators_are_interchangeable():
    # one dash, bml's two dashes, a plain space, or any mix — all the same
    expected = parse_pattern("1D-1H-1N")
    for text in ("1D--1H--1N", "1D 1H 1N", "1D - 1H -- 1N", "1D-1H 1N", "1D  --1H-  1N"):
        assert parse_pattern(text) == expected, text
        assert canonical_pattern_text(text) == "1D-1H-1N", text
    # ...including inside a comma-separated entry
    pf = parse_filter("1D 1H, 2C-2D")
    assert pf.canonical_text == "1D-1H, 2C-2D"
    assert not pf.errors


def test_case_insensitive_except_minors():
    # suit letters and keywords fold case
    assert parse_pattern("1d--1h--1n") == parse_pattern("1D--1H--1N")
    assert parse_pattern("1h--(x)--2h") == parse_pattern("1H--(X)--2H")
    assert parse_pattern("1d--pass") == parse_pattern("1D--PASS")
    assert parse_pattern("1d--(1!H)") == parse_pattern("1D--(1!h)")
    # ...but M (majors) and m (minors) stay distinct
    assert parse_pattern("1d--1M")[1].suit_class == MAJORS
    assert parse_pattern("1D--1m")[1].suit_class == MINORS
    assert parse_pattern("1D--1M") != parse_pattern("1D--1m")


def test_whitespace_and_case_do_not_change_matching():
    pat = parse_pattern("  1d  --  1M  --  1n ")
    assert sequence_matches(["1D (Pass) 1S", "1N"], pat)


def test_parse_filter_comma_is_or():
    pf = parse_filter("1C, 1D--1M")
    assert len(pf.patterns) == 2
    assert not pf.errors
    assert sequence_matches_any(["1C (Pass) 1H"], pf.patterns)
    assert sequence_matches_any(["1D (Pass) 1S"], pf.patterns)
    assert not sequence_matches_any(["1H (Pass) 2H"], pf.patterns)


def test_parse_filter_reports_bad_entry_but_keeps_the_rest():
    pf = parse_filter("1C, nonsense!!, 1D")
    assert pf.errors == ("nonsense!!",)
    assert len(pf.patterns) == 2
    assert pf.canonical_text == "1C, 1D"


def test_topics_resolution():
    topics = {
        "Opening 1C": Topic("Opening 1C", ("1C",)),
        "Major raises": Topic("Major raises", ("1M--2M", "1M--3M")),
        "Minor raises": Topic("Minor raises", ("1m--2m",)),
    }
    # exact, case- and whitespace-insensitive
    assert match_topic_name("  opening   1c ", topics) == "Opening 1C"
    # unique prefix, then unique substring
    assert match_topic_name("major", topics) == "Major raises"
    assert match_topic_name("1c", topics) == "Opening 1C"
    # ambiguous / unknown -> None (caller falls back to pattern parsing)
    assert match_topic_name("raises", topics) is None  # major and minor both
    assert match_topic_name("m", topics) is None  # prefix hits two topics
    assert match_topic_name("slam", topics) is None


def test_parse_filter_expands_topics():
    topics = {"Major raises": Topic("Major raises", ("1M--2M", "1M--3M"))}
    pf = parse_filter("major", topics)
    assert pf.topic_names == ("Major raises",)
    assert pf.canonical_text == "Major raises"  # what the input box should show
    assert len(pf.patterns) == 2
    assert sequence_matches_any(["1H (Pass) 3H"], pf.patterns)
    assert not sequence_matches_any(["1H (Pass) 4H"], pf.patterns)


def test_parse_filter_mixes_topics_and_patterns():
    topics = {"Opening 1C": Topic("Opening 1C", ("1C",))}
    pf = parse_filter("opening 1c, 1d -- 1M", topics)
    assert pf.topic_names == ("Opening 1C",)
    # topic name resolved, pattern case-folded and re-joined on a single dash
    assert pf.canonical_text == "Opening 1C, 1D-1M"
    assert sequence_matches_any(["1C (Pass) 1H"], pf.patterns)
    assert sequence_matches_any(["1D (Pass) 1H"], pf.patterns)


def test_valid_pattern_beats_fuzzy_topic_name():
    # "1C" is a unique substring of the topic name, but it is also a valid
    # pattern — the pattern must win, or `1C` could never mean just `1C`
    topics = {"Opening 1C strong": Topic("Opening 1C strong", ("1C--2N",))}
    pf = parse_filter("1C", topics)
    assert pf.topic_names == ()
    assert pf.canonical_text == "1C"
    assert sequence_matches_any(["1C (Pass) 1H"], pf.patterns)
    # ...while a non-pattern prefix still resolves to the topic
    assert parse_filter("strong", topics).topic_names == ("Opening 1C strong",)


def test_prepared_bids_match_the_unprepared_path():
    seqs = [["1C (Pass) 1H", "2D"], ["1D (X)", "2H"], ["1H (Pass) 2H"]]
    pats = [parse_pattern("1C"), parse_pattern("1D--(X)")]
    prepared = prepare_sequence_bids(seqs)
    assert [bids_match_any(b, pats) for b in prepared] == [
        sequence_matches_any(s, pats) for s in seqs
    ]
    assert [bids_match_any(b, pats) for b in prepared] == [True, True, False]


def test_empty_filter_is_falsey():
    pf = parse_filter("   ")
    assert not pf
    assert pf.patterns == ()
    assert not pf.errors


def test_load_topics_filters_by_system():
    import tempfile

    body = """
[topics."Everywhere"]
patterns = ["1C"]

[topics."Squad only"]
patterns = ["1D--1M"]
systems = ["squad-system.bml"]

[topics."Broken"]
patterns = ["not a bid"]
"""
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "quiz_topics.toml"
        p.write_text(body, encoding="utf-8")
        assert set(load_topics(p)) == {"Everywhere", "Squad only"}  # "Broken" skipped
        assert set(load_topics(p, system="squad-system.bml")) == {"Everywhere", "Squad only"}
        assert set(load_topics(p, system="bidding-system.bml")) == {"Everywhere"}
    assert load_topics(Path(d) / "gone.toml") == {}  # missing file is not an error
