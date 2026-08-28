"""The corpus and filter wiring -- that the panel app's domain code is reachable unchanged."""

from __future__ import annotations

import corpus
import engine

BML = corpus.DEFAULT_VARIANT.bml_file
VARIANT = corpus.DEFAULT_VARIANT.key


def test_corpus_loads_auctions():
    sequences = corpus.bid_sequences(BML)
    assert len(sequences) > 100
    assert all(seq.sequence for seq in sequences[:10])


def test_variant_selection_from_query():
    assert corpus.variant_for_query("?swedish").key == "swedish"
    assert corpus.variant_for_query("swedish=1").key == "swedish"
    assert corpus.variant_for_query("").key == "squad"
    assert corpus.variant_for_query(None).key == "squad"


def test_empty_filter_selects_everything():
    check = corpus.check_filter(BML, VARIANT, "", engine.MAX_DIFFICULTY)
    assert check.status == "all"
    assert check.hits is corpus.bid_sequences(BML)


def test_pattern_filter_narrows_the_working_set():
    everything = corpus.check_filter(BML, VARIANT, "", engine.MAX_DIFFICULTY)
    check = corpus.check_filter(BML, VARIANT, "1C", engine.MAX_DIFFICULTY)
    assert check.status in {"ok", "too_few"}
    assert len(check.hits) < len(everything.hits)


def test_unparseable_filter_reports_error_and_falls_back():
    check = corpus.check_filter(BML, VARIANT, "not-a-bid", engine.MAX_DIFFICULTY)
    assert check.status == "error"
    assert check.parsed.errors
    assert not check.usable  # callers fall back to the whole system


def test_too_few_matches_is_distinguished_from_error():
    # a deep, specific auction: parseable, but unlikely to have MAX_DIFFICULTY distinct hits
    check = corpus.check_filter(BML, VARIANT, "1C-1D-1H-1S-2C-2D-2H", engine.MAX_DIFFICULTY)
    assert check.status in {"too_few", "ok"}
    if check.status == "too_few":
        assert len(check.hits) < engine.MAX_DIFFICULTY


# --- the check_filter memo ---------------------------------------------------
#
# Cheap to get wrong in a way nobody notices for hours, so the properties it rests on are asserted
# rather than assumed: the key is the NORMALISED text, and a repeat is the same object.


def test_repeat_filter_check_is_the_same_object():
    corpus.clear_filter_cache()
    first = corpus.check_filter(BML, VARIANT, "1C", engine.MAX_DIFFICULTY)
    second = corpus.check_filter(BML, VARIANT, "1C", engine.MAX_DIFFICULTY)
    assert first is second
    assert corpus.filter_cache_info().hits == 1


def test_equivalent_spellings_share_one_entry():
    """`parse_filter` normalises before it does anything, so these were always the same answer --
    caching them separately would be several names for one result."""
    corpus.clear_filter_cache()
    canonical = corpus.check_filter(BML, VARIANT, "1C-1D", engine.MAX_DIFFICULTY)
    for spelling in (" 1C-1D ", "1C  --  1D", "1C--1D"):
        assert corpus.check_filter(BML, VARIANT, spelling, engine.MAX_DIFFICULTY) is canonical
    assert corpus.filter_cache_info().currsize == 1


def test_case_is_not_folded_into_the_key():
    """Deliberately NOT case-insensitive: `m` is the minors and `M` is the majors (`_upper_token`
    in bidfilter keeps that one letter), so folding case in the cache key would answer `1m` with
    the majors. `1c` and `1C` therefore cost two entries and agree, which is the safe way round."""
    corpus.clear_filter_cache()
    lower = corpus.check_filter(BML, VARIANT, "1c-1d", engine.MAX_DIFFICULTY)
    upper = corpus.check_filter(BML, VARIANT, "1C-1D", engine.MAX_DIFFICULTY)
    assert lower is not upper
    assert [seq.sequence for seq in lower.hits] == [seq.sequence for seq in upper.hits]

    minors = corpus.check_filter(BML, VARIANT, "1m", engine.MAX_DIFFICULTY)
    majors = corpus.check_filter(BML, VARIANT, "1M", engine.MAX_DIFFICULTY)
    assert [seq.sequence for seq in minors.hits] != [seq.sequence for seq in majors.hits]


def test_the_memo_does_not_change_the_answer():
    corpus.clear_filter_cache()
    fresh = corpus.check_filter(BML, VARIANT, "1D", engine.MAX_DIFFICULTY)
    hits, status, canonical = list(fresh.hits), fresh.status, fresh.parsed.canonical_text
    corpus.clear_filter_cache()
    recomputed = corpus.check_filter(BML, VARIANT, "1D", engine.MAX_DIFFICULTY)
    assert recomputed is not fresh  # the cache really was cleared
    assert [seq.sequence for seq in recomputed.hits] == [seq.sequence for seq in hits]
    assert (recomputed.status, recomputed.parsed.canonical_text) == (status, canonical)


def test_variants_do_not_share_filter_results():
    """The variant key is in the key because it picks the topics file: a topic name means different
    things in the two systems, and the bml file decides the corpus."""
    corpus.clear_filter_cache()
    squad = corpus.check_filter(BML, VARIANT, "1C", engine.MAX_DIFFICULTY)
    other = corpus.VARIANTS["swedish"]
    swedish = corpus.check_filter(other.bml_file, other.key, "1C", engine.MAX_DIFFICULTY)
    assert squad is not swedish
    assert corpus.filter_cache_info().currsize == 2
