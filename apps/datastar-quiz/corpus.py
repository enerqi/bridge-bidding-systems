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
    "clear_filter_cache",
    "filter_cache_info",
    "prewarm",
    "quiz",
    "requested_variant",
    "topics_for",
    "variant_by_key",
    "variant_for_query",
    "variant_switch_for_query",
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


def variant_by_key(key: str | None) -> Variant | None:
    """A variant by its key, for a key that came from storage rather than from a URL.

    Tolerant of `None` and of a key this build no longer has: it is used for the store's memory of
    which system a browser was last on (`SessionStore.current_variant`), and a renamed variant should
    hand the player the default rather than a KeyError.
    """
    return VARIANTS.get(key) if key else None


def variant_switch_for_query(query: str | None) -> Variant | None:
    """What an *existing* session should switch to, or None to keep the variant it has.

    Three cases, and the middle one is the whole point:

    - names a variant (`?swedish`, `?squad`) -> that variant, as `requested_variant`;
    - **no query at all** -> the default. The bare URL is the one people share and link to, so it
      has to mean "take me home"; without this a `?swedish` session is stuck forever, because
      nothing in the UI says the way back is a query string nobody remembers;
    - a non-empty query naming no variant (`?debug`) -> None, keep what the session has. Reading
      that as "switch me to the default" would flip a swedish player to squad on the next odd link.
    """
    if not (query or ""):
        return DEFAULT_VARIANT
    return requested_variant(query)


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


FILTER_CACHE_SIZE = 256
"""How many distinct filters to remember. Each entry holds a list of REFERENCES into the shared
corpus -- 7,627 auctions at 8 bytes is 61KB for a filter that selects everything, and a filter that
selects everything is the one branch that returns the shared list rather than a new one, so the real
worst case is well under that. 256 was chosen to be comfortably larger than the topic list (18) plus
the prefixes a typist produces, and small enough that it cannot become a memory leak: the text is
user input, so an unbounded cache would be a way to grow the process without limit."""


def check_filter(bml_file: str, variant_key: str, text: str | None, min_hits: int) -> FilterCheck:
    """Port of the panel app's `check_bid_filter` (`quiz_app.py:139`) as a pure function.

    Used both to validate as the user types and to apply on commit, so the preview can never
    disagree with the result. Statuses other than "ok" mean the caller should fall back to the
    whole system -- `quiz.generate_question` needs `min_hits` distinct auctions to build the
    hardest question.

    MEMOISED, because this is the app's most expensive routine and it is called per keystroke:
    matching one filter against the corpus measures 15.8ms for `1C` and 43ms for a topic, against
    ~2ms for scoring an answer. Under load those two preview routes were the only ones to miss their
    latency targets (400 simulated users, P95 420ms and 520ms).

    The KEY is the NORMALISED text, which costs nothing extra and is exact rather than approximate:
    `parse_filter` starts by normalising (`split_entries` -> `normalize_filter_text`), so ` 1C-1D `,
    `1C  --  1D` and `1C--1D` already produce byte-identical results -- separate cache entries would
    be several names for one answer. Case is deliberately NOT folded in on top of that: `m` is the
    minors and `M` the majors (`bidfilter._upper_token` preserves exactly that letter), so a
    case-insensitive key would answer `1m` with the majors. `1c` and `1C` cost two entries and agree.

    Nothing here can go stale, and each reason is worth stating because a cache that CAN is a bug
    that shows up hours later:

    * every input it reads is already fixed for the life of the process -- `bid_sequences`,
      `_sequence_bids` and `topics_for` are all `functools.cache`d, so editing a `.bml` or a topics
      file already requires a restart (`default_topics.toml` says so itself);
    * the result is immutable in the parts that matter: `FilterCheck` and `bidfilter.ParsedFilter`
      are frozen and hold tuples;
    * `hits` is a list, and it is now shared between sessions -- but sharing a sequence list between
      sessions is what this app already did (`state.py` hands every unfiltered session the same
      global `bid_sequences` list), and nothing mutates one: `quiz.generate_question` indexes into
      it, and the only other readers take `len()`.

    `filter_cache_info` / `clear_filter_cache` exist for tests and for a REPL.
    """
    return _check_filter(bml_file, variant_key, bidfilter.normalize_filter_text(text), min_hits)


@functools.lru_cache(maxsize=FILTER_CACHE_SIZE)
def _check_filter(bml_file: str, variant_key: str, text: str, min_hits: int) -> FilterCheck:
    """`check_filter` over already-normalised text. Never call this directly -- the normalisation is
    what makes the key exact."""
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


def filter_cache_info() -> functools._CacheInfo:
    """Hits/misses/size of the `check_filter` memo."""
    return _check_filter.cache_info()


def clear_filter_cache() -> None:
    _check_filter.cache_clear()


def prewarm() -> None:
    """Parse every variant's corpus now, rather than leaving it to whoever asks first.

    All of this is `functools.cache`d and therefore happened exactly once anyway -- but it happened
    inside a REQUEST, and the yappi profile caught it doing so: `load_bid_tables` 1.31s and
    `prepare_sequence_bids` 4.25s, landing on the first visitor to open the second system. Moving it
    to startup costs the server a few seconds of boot and costs no one else anything.

    Cheap to call twice; the second call is `functools.cache` lookups.
    """
    for variant in VARIANTS.values():
        bid_sequences(variant.bml_file)
        _sequence_bids(variant.bml_file)
        topics_for(variant.bml_file, variant.key)
