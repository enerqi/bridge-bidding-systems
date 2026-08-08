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
