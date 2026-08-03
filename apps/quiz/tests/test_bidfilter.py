"""Tests for bidfilter: the quiz's bidding-tree filter language.

    uv run --with pytest pytest apps/quiz/tests/test_bidfilter.py
"""

from bidfilter import (
    DEFAULT_TOPICS_FILE,
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
    topics_file_for,
)
from pathlib import Path


def test_parse_bid_token():
    assert parse_bid_token("1D") == Bid(1, frozenset("D"), "bid", False)
    assert parse_bid_token("(1!h)") == Bid(1, frozenset("H"), "bid", True)
    assert parse_bid_token("2DHS") == Bid(2, frozenset("DHS"), "bid", False)
    assert parse_bid_token("(3CDHS)") == Bid(3, frozenset("CDHS"), "bid", True)
    assert parse_bid_token("Pass").kind == "pass"
    assert parse_bid_token("(X)") == Bid(None, frozenset(), "double", True)
    assert parse_bid_token("any").kind == "any"  # the catch-all row
    assert parse_bid_token("cue").kind == "cue"  # resolved against the auction
    assert parse_bid_token("others").kind == "any"  # a catch-all row
    assert parse_bid_token("enquiry").kind == "other"  # prose, still unresolved


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
        p = Path(d) / "default_topics.toml"
        p.write_text(body, encoding="utf-8")
        assert set(load_topics(p)) == {"Everywhere", "Squad only"}  # "Broken" skipped
        assert set(load_topics(p, system="squad-system.bml")) == {"Everywhere", "Squad only"}
        assert set(load_topics(p, system="bidding-system.bml")) == {"Everywhere"}
    assert load_topics(Path(d) / "gone.toml") == {}  # missing file is not an error


def test_topics_file_for_variant():
    """A variant file wins when present; everything else falls back to default."""
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        directory = Path(d)
        default = directory / "default_topics.toml"
        swedish = directory / "swedish_topics.toml"
        default.write_text('[topics."D"]\npatterns = ["1C"]\n', encoding="utf-8")

        # no variant file yet -- both variants get the catch-all
        assert topics_file_for("swedish", directory) == default
        assert topics_file_for("squad", directory) == default
        assert topics_file_for(None, directory) == default

        swedish.write_text('[topics."S"]\npatterns = ["1D"]\n', encoding="utf-8")
        assert topics_file_for("swedish", directory) == swedish
        assert topics_file_for("squad", directory) == default  # unaffected by a sibling
        assert set(load_topics(topics_file_for("swedish", directory))) == {"S"}
        assert set(load_topics(topics_file_for("squad", directory))) == {"D"}


def test_topics_file_for_defaults_to_app_dir():
    """The shipped default file is what the app gets with no variant file."""
    assert topics_file_for() == DEFAULT_TOPICS_FILE
    assert DEFAULT_TOPICS_FILE.is_file()
    assert load_topics(topics_file_for("squad"))  # non-empty: the real file parses


# --- alternation (`/`) and the `*` wildcard ---------------------------------


def test_pattern_alternation_same_level():
    """`2D/2H` in a pattern is one position offering two calls."""
    pat = parse_pattern("1N--2D/2H")
    assert sequence_matches(["1N (Pass) 2D"], pat)
    assert sequence_matches(["1N (Pass) 2H"], pat)
    assert not sequence_matches(["1N (Pass) 2S"], pat)
    # ...and it is not two positions: 1N-2D-2H must not be what it means
    assert sequence_matches(["1N (Pass) 2D", "3C"], pat)


def test_pattern_alternation_across_levels():
    """`3S/4C` spans levels, so it cannot collapse to one multi-suit bid."""
    pat = parse_pattern("1M--3S/4C")
    assert sequence_matches(["1H (Pass) 3S"], pat)
    assert sequence_matches(["1S (Pass) 4C"], pat)
    assert not sequence_matches(["1H (Pass) 4S"], pat)  # no cross-pairing
    assert not sequence_matches(["1H (Pass) 3C"], pat)


def test_pattern_alternation_brackets_apply_to_every_branch():
    pat = parse_pattern("1C--(2D/2H)")
    assert sequence_matches(["1C (2D)"], pat)
    assert sequence_matches(["1C (2H)"], pat)
    assert not sequence_matches(["1C (Pass) 2D"], pat)  # ours, not theirs


def test_wildcard_denomination_pattern():
    pat = parse_pattern("1M--3*")
    assert sequence_matches(["1H (Pass) 3D"], pat)
    assert sequence_matches(["1S (Pass) 3N"], pat)
    assert not sequence_matches(["1H (Pass) 4D"], pat)  # level still binds
    # `3*` and the older `3*`-as-any-suit spelling agree
    assert sequence_matches(["1H (Pass) 3D"], parse_pattern("1M--3*"))


def test_alternation_in_the_recorded_auction():
    """The auction itself can hold an alternation — a section titled
    `1C--1N/2C` records a call the author wrote as a choice. It should answer
    to a filter naming either branch, and to neither of the others."""
    seq = ["1C", "1D", "1N/2C", "2D"]
    assert sequence_matches(seq, parse_pattern("1C-1D-1N-2D"))
    assert sequence_matches(seq, parse_pattern("1C-1D-2C-2D"))
    assert not sequence_matches(seq, parse_pattern("1C-1D-1H-2D"))
    # and it stays ONE position: 2D follows it, nothing was inserted
    assert not sequence_matches(seq, parse_pattern("1C-1D-1N-2C"))


def test_canonical_text_keeps_alternation():
    assert canonical_pattern_text("1n -- 2d/2h") == "1N-2D/2H"
    assert canonical_pattern_text("1m--3*") == "1m-3*"


def test_call_pattern_single_alternative_delegates():
    """One-alternative positions still answer level/suit questions directly."""
    pat = parse_pattern("1D--1M")
    assert pat[1].suit_class == MAJORS
    assert pat[1].level == 1
    assert len(parse_pattern("1D--3S/4C")[1].alternatives) == 2


# --- suit-class variables ---------------------------------------------------


def test_repeated_class_means_the_same_suit():
    """`1HS--2M` is one major named twice: 1H-2H or 1S-2S, never 1H-2S."""
    seq = ["1HS", "2M"]
    assert sequence_matches(seq, parse_pattern("1H-2H"))
    assert sequence_matches(seq, parse_pattern("1S-2S"))
    assert not sequence_matches(seq, parse_pattern("1H-2S"))
    assert not sequence_matches(seq, parse_pattern("1S-2H"))
    # the class-level question still answers yes
    assert sequence_matches(seq, parse_pattern("1M-2M"))
    # three positions stay consistent with each other
    assert sequence_matches(["1HS", "2M", "3M"], parse_pattern("1S-2S-3S"))
    assert not sequence_matches(["1HS", "2M", "3M"], parse_pattern("1S-2S-3H"))
    # minors bind the same way
    assert sequence_matches(["2CD", "3m"], parse_pattern("2C-3C"))
    assert not sequence_matches(["2CD", "3m"], parse_pattern("2C-3D"))


def test_other_major_resolves_against_the_auction():
    """`oM` is the major that is not the one already shown."""
    assert sequence_matches(["1H", "2oM"], parse_pattern("1H-2S"))
    assert not sequence_matches(["1H", "2oM"], parse_pattern("1H-2H"))
    long_auction = ["1C", "1HS", "2C", "2D", "2oM"]
    assert sequence_matches(long_auction, parse_pattern("1C-1H-2C-2D-2S"))
    assert sequence_matches(long_auction, parse_pattern("1C-1S-2C-2D-2H"))
    assert not sequence_matches(long_auction, parse_pattern("1C-1H-2C-2D-2H"))


def test_what_does_not_bind():
    """Only proper suit classes correlate."""
    # different classes are unrelated
    assert sequence_matches(["1HS", "3CD"], parse_pattern("1H-3D"))
    # two wildcards are two unknown suits, not the same unknown suit
    assert sequence_matches(["3x", "4x"], parse_pattern("3H-4S"))
    # a lone class is as permissive as before
    assert sequence_matches(["2M"], parse_pattern("2S"))
    assert sequence_matches(["2M"], parse_pattern("2H"))
    # two concrete majors are just themselves
    assert sequence_matches(["1H", "1S"], parse_pattern("1H-1S"))


def test_x_and_om_in_patterns():
    assert sequence_matches(["1H (Pass) 3D"], parse_pattern("1M-3x"))
    assert parse_pattern("1M-3x") == parse_pattern("1M-3*")
    # `oM` typed as a pattern has nothing to be other than, so it asks the class
    assert sequence_matches(["1C (Pass) 2H"], parse_pattern("1C-2oM"))
    assert not sequence_matches(["1C (Pass) 2D"], parse_pattern("1C-2oM"))


def test_link_bids_in_an_auction():
    """The opening-summary tables write their bids as links to the section."""
    assert sequence_matches(["1C", "[1HS](#1C--1HS)"], parse_pattern("1C-1H"))
    assert not sequence_matches(["1C", "[1HS](#1C--1HS)"], parse_pattern("1C-2H"))


def test_any_row_answers_to_any_pattern():
    """`(any)` is the interference catch-all row: whatever the opponents call
    here. A filter naming a specific interference should find it."""
    assert sequence_matches(["1C", "(any)"], parse_pattern("1C-(X)"))
    assert sequence_matches(["1C", "(any)"], parse_pattern("1C-(2H)"))
    assert sequence_matches(["1C", "(any)"], parse_pattern("1C-(*)"))
    # ...but whose call it was still matters
    assert not sequence_matches(["1C", "(any)"], parse_pattern("1C-2H"))
    # our own `any` row likewise
    assert sequence_matches(["1C", "any"], parse_pattern("1C-2H"))
    assert not sequence_matches(["1C", "any"], parse_pattern("1C-(2H)"))
    # and it does not swallow the rest of the auction
    assert sequence_matches(["1C", "(any)", "2D"], parse_pattern("1C-(X)-2D"))
    assert not sequence_matches(["1C", "(any)", "2D"], parse_pattern("1C-(X)-3D"))


def test_next_resolves_to_the_step_above_its_parent():
    """`4HS = splinter` / `next = RKB` means 4S over 4H, or 4N over 4S."""
    seq = ["1C", "3C", "4HS", "next"]
    assert sequence_matches(seq, parse_pattern("1C-3C-4H-4S"))
    assert sequence_matches(seq, parse_pattern("1C-3C-4S-4N"))
    # ...and never the cross pairing, which no line of the table describes
    assert not sequence_matches(seq, parse_pattern("1C-3C-4H-4N"))
    assert not sequence_matches(seq, parse_pattern("1C-3C-4S-4S"))
    # a concrete parent has one step; notrump rolls to the next level
    assert sequence_matches(["4H", "next"], parse_pattern("4H-4S"))
    assert not sequence_matches(["4H", "next"], parse_pattern("4H-5C"))
    assert sequence_matches(["4N", "next"], parse_pattern("4N-5C"))
    # the auction continues normally after it
    assert sequence_matches(["4HS", "next", "5C"], parse_pattern("4S-4N-5C"))
    assert not sequence_matches(["4HS", "next", "5C"], parse_pattern("4H-4N-5C"))


def test_next_stays_unresolved_without_a_parent_bid():
    """Unresolvable means unmatched, never a wildcard."""
    assert not sequence_matches(["1C", "any", "next"], parse_pattern("1C-2H-2S"))
    assert not sequence_matches(["next"], parse_pattern("2C"))
    assert not sequence_matches(["1C", "Pass", "next"], parse_pattern("1C-P-2C"))


def test_next_after_a_bound_class():
    """When the class was already pinned by the auction, so is the step."""
    seq = ["1HS", "2M", "next"]
    assert sequence_matches(seq, parse_pattern("1S-2S-2N"))
    assert sequence_matches(seq, parse_pattern("1H-2H-2S"))
    assert not sequence_matches(seq, parse_pattern("1H-2S-2N"))
    assert not sequence_matches(seq, parse_pattern("1S-2S-3C"))


def test_jump_is_a_jump_in_a_new_suit():
    """`2H = weak two` / `2S = forcing` / `jump = splinter`: over 2S the
    cheapest new suit is 3C or 3D, so the jump is 4C or 4D."""
    seq = ["2H", "2S", "jump"]
    assert sequence_matches(seq, parse_pattern("2H-2S-4C"))
    assert sequence_matches(seq, parse_pattern("2H-2S-4D"))
    assert not sequence_matches(seq, parse_pattern("2H-2S-3C"))  # that is no jump
    assert not sequence_matches(seq, parse_pattern("2H-2S-4H"))  # hearts were bid
    assert not sequence_matches(seq, parse_pattern("2H-2S-4N"))  # never notrump
    assert not sequence_matches(seq, parse_pattern("2H-2S-3N"))


def test_jump_skips_suits_already_bid():
    seq = ["1D", "1S", "jump"]
    assert sequence_matches(seq, parse_pattern("1D-1S-3C"))
    assert sequence_matches(seq, parse_pattern("1D-1S-3H"))
    assert not sequence_matches(seq, parse_pattern("1D-1S-3D"))
    assert not sequence_matches(seq, parse_pattern("1D-1S-3S"))
    assert not sequence_matches(seq, parse_pattern("1D-1S-2C"))  # the cheapest bid


def test_double_jump_is_one_higher():
    seq = ["1D", "1S", "doubleJump"]
    assert sequence_matches(seq, parse_pattern("1D-1S-4C"))
    assert sequence_matches(seq, parse_pattern("1D-1S-4H"))
    assert not sequence_matches(seq, parse_pattern("1D-1S-3C"))


def test_jump_without_a_resolvable_parent():
    assert not sequence_matches(["1C", "any", "jump"], parse_pattern("1C-2H-3S"))
    assert not sequence_matches(["jump"], parse_pattern("3S"))


def test_cue_is_the_lowest_available_bid_in_their_suit():
    seq = ["(1H)", "1S", "cue"]
    assert sequence_matches(seq, parse_pattern("(1H)-1S-2H"))
    assert not sequence_matches(seq, parse_pattern("(1H)-1S-3H"))  # not the lowest
    assert not sequence_matches(seq, parse_pattern("(1H)-1S-2C"))  # not their suit
    # with two of their suits shown, only the cheaper cue counts
    two = ["(1H)", "(2D)", "2S", "cue"]
    assert sequence_matches(two, parse_pattern("(1H)-(2D)-2S-3D"))
    assert not sequence_matches(two, parse_pattern("(1H)-(2D)-2S-3H"))
    # a level named on the token overrides "lowest"
    assert sequence_matches(["(1H)", "1S", "3cue"], parse_pattern("(1H)-1S-3H"))
    assert not sequence_matches(["(1H)", "1S", "3cue"], parse_pattern("(1H)-1S-2H"))
    # nothing to cue: unresolved, so unmatched
    assert not sequence_matches(["1C", "1H", "cue"], parse_pattern("1C-1H-2H"))


def test_new_is_a_suit_neither_side_has_bid():
    seq = ["1D", "1S", "new"]
    assert sequence_matches(seq, parse_pattern("1D-1S-2C"))
    assert sequence_matches(seq, parse_pattern("1D-1S-2H"))
    assert not sequence_matches(seq, parse_pattern("1D-1S-2D"))  # ours
    assert not sequence_matches(seq, parse_pattern("1D-1S-2S"))  # ours
    assert not sequence_matches(seq, parse_pattern("1D-1S-2N"))  # not a suit
    assert not sequence_matches(seq, parse_pattern("1D-1S-3C"))  # that is a jump
    # the opponents' suit is not new either
    assert not sequence_matches(
        ["1D", "(1H)", "1S", "new"], parse_pattern("1D-(1H)-1S-2H")
    )
    # a level named on the token pins it
    assert sequence_matches(["1D", "1S", "3new"], parse_pattern("1D-1S-3C"))
    assert not sequence_matches(["1D", "1S", "3new"], parse_pattern("1D-1S-2C"))


def test_at_least_token_covers_everything_above():
    assert sequence_matches(["1C", "(2N+)"], parse_pattern("1C-(2N)"))
    assert sequence_matches(["1C", "(2N+)"], parse_pattern("1C-(3C)"))
    assert sequence_matches(["1C", "(2N+)"], parse_pattern("1C-(7N)"))
    assert not sequence_matches(["1C", "(2N+)"], parse_pattern("1C-(2S)"))
    assert not sequence_matches(["1C", "(2N+)"], parse_pattern("1C-(1N)"))
    # `2x+` starts at the bottom of the level
    assert sequence_matches(["1C", "(2x+)"], parse_pattern("1C-(2C)"))
    assert not sequence_matches(["1C", "(2x+)"], parse_pattern("1C-(1S)"))


def test_catch_all_rows_promise_different_amounts():
    """`(overcall)` is a bid; `(bid)` is anything but a pass; `any` and
    `other(s)` are anything at all."""
    over = ["1C", "1N", "(overcall)"]
    assert sequence_matches(over, parse_pattern("1C-1N-(2H)"))
    assert not sequence_matches(over, parse_pattern("1C-1N-(X)"))
    assert not sequence_matches(over, parse_pattern("1C-1N-2H"))  # theirs, not ours

    anything_but_pass = ["1C", "1N", "(bid)"]
    assert sequence_matches(anything_but_pass, parse_pattern("1C-1N-(2H)"))
    assert sequence_matches(anything_but_pass, parse_pattern("1C-1N-(X)"))
    assert sequence_matches(anything_but_pass, parse_pattern("1C-1N-(XX)"))

    # `other` is the same catch-all as `any`, not a statement about siblings
    assert sequence_matches(["1C", "1D", "other"], parse_pattern("1C-1D-2D"))
    assert sequence_matches(["1C", "1D", "other"], parse_pattern("1C-1D-P"))


def test_game_is_a_game_contract():
    for call in ("3N", "4H", "4S", "5C", "5D"):
        assert sequence_matches(["1C", "game"], parse_pattern(f"1C-{call}")), call
    assert not sequence_matches(["1C", "game"], parse_pattern("1C-4N"))
    assert not sequence_matches(["1C", "game"], parse_pattern("1C-3S"))


def test_suit_is_a_simple_new_suit():
    seq = ["1D", "1S", "suit"]
    assert sequence_matches(seq, parse_pattern("1D-1S-2C"))
    assert sequence_matches(seq, parse_pattern("1D-1S-2H"))
    assert not sequence_matches(seq, parse_pattern("1D-1S-2N"))  # never notrump
    assert not sequence_matches(seq, parse_pattern("1D-1S-3C"))  # that is a jump
    assert not sequence_matches(seq, parse_pattern("1D-1S-2D"))  # already bid


def test_level_y_is_a_new_suit():
    """`1x (Pass) 1y`: any suit at the 1 level, then a *new* suit at the
    1 level — `1y` is `1new`."""
    seq = ["1D", "1S", "2Y"]
    assert sequence_matches(seq, parse_pattern("1D-1S-2C"))
    assert sequence_matches(seq, parse_pattern("1D-1S-2H"))
    assert not sequence_matches(seq, parse_pattern("1D-1S-2D"))  # already bid
    assert not sequence_matches(seq, parse_pattern("1D-1S-2N"))  # not a suit
    assert not sequence_matches(seq, parse_pattern("1D-1S-3C"))  # wrong level


def test_cue_over_cues_the_player_on_our_right():
    """`(1C)--P--(1x)`: cueing the 1C is "sitting under", cueing what our RHO
    just bid is `CueOver`, "sitting over"."""
    seq = ["(1C)", "P", "(1HS)", "CueOver"]
    assert sequence_matches(seq, parse_pattern("(1C)-P-(1H)-2H"))
    assert sequence_matches(seq, parse_pattern("(1C)-P-(1S)-2S"))
    # their suit is what *they* bid, not either of the two the token allowed
    assert not sequence_matches(seq, parse_pattern("(1C)-P-(1H)-1S"))
    # ...and not the first opponent's suit, which is the plain `cue`
    assert not sequence_matches(seq, parse_pattern("(1C)-P-(1H)-2C"))
    assert sequence_matches(
        ["(1C)", "P", "(1HS)", "cue"], parse_pattern("(1C)-P-(1H)-2C")
    )
    # a wildcard opponent bid: whatever they bid is the suit to cue
    assert sequence_matches(
        ["(1C)", "P", "(1x)", "CueOver"], parse_pattern("(1C)-P-(1D)-2D")
    )
    # nothing to cue over
    assert not sequence_matches(
        ["(1C)", "P", "(X)", "CueOver"], parse_pattern("(1C)-P-(X)-2C")
    )


def test_step_responses_to_an_artificial_ask():
    """`4x/5x EKB` then `xstep`: the keycard responses, 5C through 5N."""
    for call in ("5C", "5D", "5H", "5S", "5N"):
        assert sequence_matches(["4N", "xstep"], parse_pattern(f"4N-{call}")), call
    assert not sequence_matches(["4N", "xstep"], parse_pattern("4N-6C"))  # off the ladder
    # a numbered step is one rung, not the whole ladder
    assert sequence_matches(["4N", "1step"], parse_pattern("4N-5C"))
    assert not sequence_matches(["4N", "1step"], parse_pattern("4N-5D"))
    # the queen ask sits one step above whichever response was made
    nested = ["4N", "xstep", "1step"]
    assert sequence_matches(nested, parse_pattern("4N-5C-5D"))
    assert sequence_matches(nested, parse_pattern("4N-5H-5S"))
    assert not sequence_matches(nested, parse_pattern("4N-5C-5H"))
    # nothing to answer, and nowhere left to go
    assert not sequence_matches(["any", "xstep"], parse_pattern("*-2C"))
    assert not sequence_matches(["7N", "xstep"], parse_pattern("7N-7N"))


def test_raise_supports_partners_last_suit():
    """`raise` is support for the last suit *our side* bid — which, since our
    calls alternate, is partner's."""
    # partner opened a weak two, we raise it
    assert sequence_matches(["2HS", "raise"], parse_pattern("2H-3H"))
    assert sequence_matches(["2HS", "raise"], parse_pattern("2S-3S"))
    assert not sequence_matches(["2HS", "raise"], parse_pattern("2H-3S"))
    # an opponent in between does not make their suit ours
    assert sequence_matches(["1H", "(2C)", "raise"], parse_pattern("1H-(2C)-2H"))
    assert not sequence_matches(["1H", "(2C)", "raise"], parse_pattern("1H-(2C)-3C"))
    # opener raising responder's suit: partner's last is the 2C, not the 1H
    assert sequence_matches(["1H", "2C", "raise"], parse_pattern("1H-2C-3C"))
    assert not sequence_matches(["1H", "2C", "raise"], parse_pattern("1H-2C-2H"))
    # bracketed, it is *their* partner's suit
    assert sequence_matches(["(1H)", "X", "(raise)"], parse_pattern("(1H)-X-(2H)"))
    assert not sequence_matches(["(1H)", "X", "(raise)"], parse_pattern("(1H)-X-(2S)"))
    # nobody on our side has bid
    assert not sequence_matches(["(1H)", "raise"], parse_pattern("(1H)-2H"))


def test_jump_raise_and_levelled_raise():
    assert sequence_matches(["1H", "(2C)", "jumpRaise"], parse_pattern("1H-(2C)-3H"))
    assert not sequence_matches(["1H", "(2C)", "jumpRaise"], parse_pattern("1H-(2C)-2H"))
    assert sequence_matches(["1H", "2C", "3raise"], parse_pattern("1H-2C-3C"))


def test_resolution_measures_from_the_last_bid_not_the_last_call():
    """A raise or a new suit over partner's double still has to clear the last
    *bid*; the double itself sets no level."""
    assert sequence_matches(["1H", "X", "new"], parse_pattern("1H-X-2C"))
    assert sequence_matches(["(1H)", "X", "(raise)"], parse_pattern("(1H)-X-(2H)"))


def test_cue_low_and_cue_high_pick_between_their_suits():
    """`cueLow` / `cueHi` cue the lower- or higher-ranking of their two suits —
    when the auction actually shows two."""
    low = ["(1H)", "P", "(2S)", "cueLow"]
    assert sequence_matches(low, parse_pattern("(1H)-P-(2S)-3H"))
    assert not sequence_matches(low, parse_pattern("(1H)-P-(2S)-3S"))
    high = ["(1H)", "P", "(2S)", "cueHi"]
    assert sequence_matches(high, parse_pattern("(1H)-P-(2S)-3S"))
    assert not sequence_matches(high, parse_pattern("(1H)-P-(2S)-3H"))
    # over a *conventional* two-suiter only one call is on the table, and which
    # two suits it shows is system knowledge — so nothing is resolved
    assert not sequence_matches(["1C", "(2C)", "cueLow"], parse_pattern("1C-(2C)-3C"))


def test_higher_is_a_catch_all_bid():
    """`(higher)` reads as "they bid something" — the calls worth naming have
    their own sections, including `(X)`."""
    seq = ["(1C)", "1HS", "(higher)"]
    assert sequence_matches(seq, parse_pattern("(1C)-1H-(2C)"))
    assert sequence_matches(seq, parse_pattern("(1C)-1H-(1N)"))
    assert not sequence_matches(seq, parse_pattern("(1C)-1H-(X)"))  # a bid, not a double
    assert not sequence_matches(seq, parse_pattern("(1C)-1H-(P)"))


def test_denomination_without_a_level_is_a_simple_bid():
    """`NT`, `m`, `major`, `!c/!d` name a strain but no level: the simple
    (non-jump) bid in it, at whatever level the auction has reached."""
    assert sequence_matches(["1C", "2C", "(2S)", "NT"], parse_pattern("1C-2C-(2S)-2N"))
    assert not sequence_matches(
        ["1C", "2C", "(2S)", "NT"], parse_pattern("1C-2C-(2S)-3N")
    )
    for call, want in (("1H", True), ("1S", True), ("2H", False), ("1N", False)):
        assert sequence_matches(["1C", "1D", "major"], parse_pattern(f"1C-1D-{call}")) is want, call
    for call, want in (("3C", True), ("3D", True), ("3H", False), ("2N", False)):
        assert sequence_matches(["2S", "m"], parse_pattern(f"2S-{call}")) is want, call
    # both halves of an alternation of strains resolve
    for call, want in (("3C", True), ("3D", True), ("3H", False)):
        assert sequence_matches(["1N", "(2H)", "!c/!d"], parse_pattern(f"1N-(2H)-{call}")) is want, call


def test_other_suit_is_the_new_suit_rule():
    """`(otherSuit)`: a new suit, not the one their partner bid, never NT."""
    seq = ["(1H)", "1S", "(otherSuit)"]
    assert sequence_matches(seq, parse_pattern("(1H)-1S-(2C)"))
    assert sequence_matches(seq, parse_pattern("(1H)-1S-(2D)"))
    assert not sequence_matches(seq, parse_pattern("(1H)-1S-(2H)"))  # partner's
    assert not sequence_matches(seq, parse_pattern("(1H)-1S-(1N)"))  # not a suit


def test_strain_plus_is_any_level_in_that_strain():
    """`!c+` is "clubs, at whatever level it takes" — the pass/correct sense —
    where a bare `!c` is the simple bid."""
    seq = ["1N", "(2H)", "!c+/!d+"]
    for call in ("3C", "3D", "4C", "5D", "7C"):
        assert sequence_matches(seq, parse_pattern(f"1N-(2H)-{call}")), call
    assert not sequence_matches(seq, parse_pattern("1N-(2H)-3H"))  # wrong strain
    assert not sequence_matches(seq, parse_pattern("1N-(2H)-2C"))  # not legal
    # the bare form stays the simple bid
    assert sequence_matches(["1N", "(2H)", "!c/!d"], parse_pattern("1N-(2H)-3C"))
    assert not sequence_matches(["1N", "(2H)", "!c/!d"], parse_pattern("1N-(2H)-4C"))


def test_slam_bids_the_agreed_suit_at_the_slam_level():
    """`slam = to play` under a preempt: that suit at the 6 or 7 level."""
    assert sequence_matches(["4HS", "slam"], parse_pattern("4H-6H"))
    assert sequence_matches(["4HS", "slam"], parse_pattern("4S-6S"))
    assert sequence_matches(["4HS", "slam"], parse_pattern("4H-7H"))
    assert not sequence_matches(["4HS", "slam"], parse_pattern("4H-6S"))  # pinned
    assert not sequence_matches(["4HS", "slam"], parse_pattern("4H-5H"))
    # `6slam` says which level
    assert sequence_matches(["1H", "2C", "6slam"], parse_pattern("1H-2C-6C"))
    assert not sequence_matches(["1H", "2C", "6slam"], parse_pattern("1H-2C-7C"))


def test_next_suit_skips_notrump():
    """`nextSuit` — herbert negative, the queen ask for grand — is the next bid
    up that is a suit."""
    assert sequence_matches(["1C", "2H", "nextSuit"], parse_pattern("1C-2H-2S"))
    assert not sequence_matches(["1C", "2H", "nextSuit"], parse_pattern("1C-2H-2N"))
    # over spades the next suit is a level up, notrump skipped
    assert sequence_matches(["1C", "2S", "nextSuit"], parse_pattern("1C-2S-3C"))
    assert not sequence_matches(["1C", "2S", "nextSuit"], parse_pattern("1C-2S-2N"))


def test_fourth_suit_is_the_one_left():
    assert sequence_matches(["1C", "1D", "1H", "4thSuit"], parse_pattern("1C-1D-1H-1S"))
    assert not sequence_matches(["1C", "1D", "1H", "4thSuit"], parse_pattern("1C-1D-1H-2C"))
    # with two suits still unbid it is not describing one call
    assert not sequence_matches(["1C", "1D", "4thSuit"], parse_pattern("1C-1D-1H"))
