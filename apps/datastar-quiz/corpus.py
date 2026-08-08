"""The `.bml` corpus and the bidding-tree filter, reused from the panel app.

`apps/quiz/quiz.py` and `apps/quiz/bidfilter.py` are pure domain code -- neither imports
panel -- so this port imports them rather than copying them. Nothing under `apps/quiz/` is
modified; this module only prepends that directory to `sys.path`.

`quiz.bml_docs_dir()` resolves the corpus from *its own* location (the repo root two levels
up from `apps/quiz/`), so it does not matter what directory this app is served from.
"""

from __future__ import annotations

import functools
import sys
from dataclasses import dataclass
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
PANEL_APP_DIR = APP_DIR.parent / "quiz"

if str(PANEL_APP_DIR) not in sys.path:
    # insert, not append: these are flat modules with generic names
    sys.path.insert(0, str(PANEL_APP_DIR))

import bidfilter  # noqa: E402 -- importable only after the sys.path line above
import quiz  # noqa: E402

__all__ = [
    "DEFAULT_VARIANT",
    "VARIANTS",
    "FilterCheck",
    "Variant",
    "bid_sequences",
    "bidfilter",
    "check_filter",
    "quiz",
    "requested_variant",
    "topics_for",
    "variant_for_query",
]


@dataclass(frozen=True)
class Variant:
    """A quiz flavour: which bml system it draws on, and how it is presented.

    The panel app selects this from the query string (`?swedish`) at session start
    (`quiz_app.py:79`); here it is per request, resolved once per session.
    """

    key: str
    title: str
    bml_file: str
    system_notes_url: str


VARIANTS: dict[str, Variant] = {
    "squad": Variant(
        key="squad",
        title="U16 Squad System Quiz",
        bml_file="squad-system.bml",
        system_notes_url="https://sublime.is/squad-system.html",
    ),
    "swedish": Variant(
        key="swedish",
        title="Swedish Club Quiz",
        bml_file="bidding-system.bml",
        system_notes_url="https://sublime.is/bidding-system.html",
    ),
}

DEFAULT_VARIANT = VARIANTS["squad"]


def requested_variant(query: str | None) -> Variant | None:
    """The variant a query string explicitly asks for, or None if it names none.

    Distinct from `variant_for_query` on purpose: an unrelated query (`?debug`) must not be read as
    "switch me back to the default", or a swedish session would flip to squad on the next odd link.
    """
    lowered = (query or "").lower()
    for key in ("swedish", "squad"):
        if key in lowered:
            return VARIANTS[key]
    return None


def variant_for_query(query: str | None) -> Variant:
    """`?swedish` picks the swedish club system, anything else the squad system."""
    return requested_variant(query) or DEFAULT_VARIANT


# Parsing the whole corpus takes seconds, so it is done once per process and shared by every
# session -- the same trade the panel app makes with `@pn.cache` (`quiz_app.py:102`).
@functools.cache
def bid_sequences(bml_file: str) -> list:
    tables = quiz.load_bid_tables(bml_file)
    quiz.prettify_bid_table_nodes(tables)
    return quiz.collect_bid_table_auctions(tables)


@functools.cache
def _sequence_bids(bml_file: str) -> list:
    """Canonical parsed bids per auction. Filtering is then prefix comparison, which is what
    makes validating on every keystroke cheap enough to do at all."""
    return bidfilter.prepare_sequence_bids(seq.sequence for seq in bid_sequences(bml_file))


@functools.cache
def topics_for(bml_file: str, variant_key: str) -> dict:
    """Pre-composed sidebar filters. One topics file per variant, no merging (see
    `bidfilter.topics_file_for`); topics scoped to another bml system are dropped."""
    return bidfilter.load_topics(bidfilter.topics_file_for(variant_key), system=bml_file)


@dataclass(frozen=True)
class FilterCheck:
    """What a filter string *would* select. Asking never commits it."""

    status: str  # "all" | "ok" | "error" | "too_few"
    hits: list
    parsed: bidfilter.ParsedFilter

    @property
    def usable(self) -> bool:
        return self.status == "ok"


def check_filter(bml_file: str, variant_key: str, text: str | None, min_hits: int) -> FilterCheck:
    """Port of the panel app's `check_bid_filter` (`quiz_app.py:139`) as a pure function.

    Used both to validate as the user types and to apply on commit, so the preview can never
    disagree with the result. Statuses other than "ok" mean the caller should fall back to the
    whole system -- `quiz.generate_question` needs `min_hits` distinct auctions to build the
    hardest question.
    """
    sequences = bid_sequences(bml_file)
    parsed = bidfilter.parse_filter(text, topics_for(bml_file, variant_key))
    if not parsed.patterns:
        return FilterCheck("error" if parsed.errors else "all", sequences, parsed)
    hits = [
        seq
        for seq, bids in zip(sequences, _sequence_bids(bml_file), strict=True)
        if bidfilter.bids_match_any(bids, parsed.patterns)
    ]
    if len(hits) < min_hits:
        return FilterCheck("too_few", hits, parsed)
    return FilterCheck("ok", hits, parsed)
