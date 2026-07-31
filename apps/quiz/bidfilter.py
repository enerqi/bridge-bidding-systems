"""Canonical bid model + bidding-tree prefix filtering for the quiz.

Turns the quiz's messy `Node.get_sequence()` strings (e.g. ['1C (Pass) 1H',
'2D', '2S'], with opponents in parens, `!x` suit shorthand, and multi-suit
bids like '2DHS') into a canonical list of `Bid`, and matches an auction prefix
against a user pattern like `1D-1M-1N`, where suit-class shortcuts expand:

    M -> majors  {H, S}      N -> notrump {N}
    m -> minors  {C, D}

So `1D-1M-1N` matches both `1D-1H-1N` and `1D-1S-1N`. Opponent bids are
written in parens in a pattern too, e.g. `1H-(X)-2H`.

Calls are separated by a single dash (bml's `--` and plain spaces are accepted
too, and all normalise to one `-`). User input is further normalised before
parsing: leading/trailing and superfluous interior whitespace is dropped, and
case is folded — *except* for a lowercase `m`, which is the "minors" class
shortcut and would otherwise collapse into `M` ("majors"). So `1d-1M-1n` ==
`1D-1M-1N`, while `1D-1m` still means minors.

A filter string may hold several comma-separated entries, matched as an OR.
Each entry is either a bid pattern or the name of a *topic* — a pre-composed
collection of patterns loaded from `quiz_topics.toml` (see `load_topics`).

Not (yet) supported: `oM`/`om` "other major/minor" relative to an earlier bid.
"""

from __future__ import annotations

import os
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

# The bid model itself belongs with the bml tools, so the parser and every
# consumer agree on what a call is (same bootstrap as quiz.py).
sys.path.append(os.environ.get("BML_TOOLS_DIRECTORY", os.path.join(os.path.expanduser("~"), "dev/bml")))

import bmlbids  # noqa: E402
from bmlbids import MAJORS, MINORS, Bid  # noqa: E402

# Auctions are parsed by the shared model; this module only adds the *pattern*
# language the quiz filters with.
parse_bid_token = bmlbids.parse_call
parse_sequence = bmlbids.parse_calls
_strip_parens = bmlbids.strip_brackets
_expand_shorthand = bmlbids.expand_suit_shorthand

_WS_RE = re.compile(r"\s+")
# One dash is enough to separate calls here — bml's `--` is accepted too, and
# both normalise to a single `-`.
_DASH_RE = re.compile(r"\s*-+\s*")
_SPLIT_RE = re.compile(r"-+|\s+")


@dataclass(frozen=True)
class BidPattern:
    level: Optional[int]  # None = any level
    suit_class: frozenset  # allowed suits; empty = any suit
    kind: str  # 'bid' | 'pass' | 'double' | 'redouble' | '*' (any call)
    by_opponent: Optional[bool]  # None = don't care


@dataclass(frozen=True)
class CallPattern:
    """One position in an auction: the alternatives allowed there.

    Usually one. `/` writes more than one -- `2D/2H`, `3S/4C` -- which is a
    single call the author wrote as a choice, *not* two consecutive calls.
    Alternatives differing only in suit could equally be written `2DH`; ones
    spanning levels (`3S/4C`) have no single-token form, which is why a
    position is a set of patterns rather than one widened pattern.
    """

    alternatives: tuple[BidPattern, ...]

    def _single(self) -> BidPattern:
        if len(self.alternatives) != 1:
            raise ValueError(
                f"{len(self.alternatives)} alternatives at this position; "
                "read .alternatives instead"
            )
        return self.alternatives[0]

    # Delegation for the ordinary one-alternative case, so callers (and the
    # tests) can keep asking a position about its level or suits directly.
    @property
    def level(self) -> Optional[int]:
        return self._single().level

    @property
    def suit_class(self) -> frozenset:
        return self._single().suit_class

    @property
    def kind(self) -> str:
        return self._single().kind

    @property
    def by_opponent(self) -> Optional[bool]:
        return self._single().by_opponent


def _fold_token_case(tok: str) -> str:
    """Uppercase a token, keeping a lowercase `m` (minors) distinct from `M`
    (majors). Every other character is a suit letter or a keyword, for which
    case carries no meaning."""
    return "".join(ch if ch == "m" else ch.upper() for ch in tok)


def normalize_filter_text(text: Optional[str]) -> str:
    """Tidy raw user input: strip ends, collapse whitespace runs, and remove
    whitespace that is decorative rather than a token separator (inside
    brackets, around `--` and around the comma entry separator)."""
    s = _WS_RE.sub(" ", (text or "").strip())
    s = _DASH_RE.sub("-", s)
    s = re.sub(r"\(\s+", "(", s)
    s = re.sub(r"\s+\)", ")", s)
    # rebuild from the entries so empty ones (`,,` or a trailing `,`) vanish
    return ", ".join(e for e in (part.strip() for part in s.split(",")) if e)


def _parse_pattern_token(tok: str) -> CallPattern:
    """Parse one position, which may be an alternation (`2D/2H`, `3S/4C`).

    Brackets may wrap the whole alternation -- `(2D/2H)` is the opponents
    making either call -- or an individual branch.
    """
    inner, opp = _strip_parens(tok)
    parts = [p for p in inner.split(bmlbids.ALT_SEP) if p.strip()]
    if not parts:
        raise ValueError(f"cannot parse pattern token: {tok!r}")
    return CallPattern(tuple(_parse_alternative(p, opp) for p in parts))


def _parse_alternative(tok: str, outer_opp: bool = False) -> BidPattern:
    inner, opp = _strip_parens(tok)
    opp = opp or outer_opp
    # brackets are the notation for "the opponents did this", so a token
    # without them is one of our calls. (The bare `*` wildcard below opts back
    # out to "either side" — that is what makes it useful for counting depth.)
    by_opp: Optional[bool] = opp
    inner = _fold_token_case(_expand_shorthand(inner))
    u = inner.upper()
    if u in ("P", "PASS"):
        return BidPattern(None, frozenset(), "pass", by_opp)
    if u in ("X", "DBL"):
        return BidPattern(None, frozenset(), "double", by_opp)
    if u in ("XX", "RDBL", "R"):
        return BidPattern(None, frozenset(), "redouble", by_opp)
    if u in ("*", "ANY"):
        # wildcard: any call at this position, by either side unless bracketed.
        # `(*)` means "the opponents did something here", since their passes
        # are dropped by `significant_bids`.
        return BidPattern(None, frozenset(), "*", True if opp else None)
    m = re.match(r"^([1-7])\*$", u)
    if m:
        # `1*` — any suit at that level (an empty suit class means "any")
        return BidPattern(int(m.group(1)), frozenset(), "bid", by_opp)
    # level + suit-class chars (case-sensitive: M/m are class shortcuts)
    m = re.match(r"^([1-7])?([CDHSNMm]+)$", inner)
    if not m:
        raise ValueError(f"cannot parse pattern token: {tok!r}")
    level = int(m.group(1)) if m.group(1) else None
    suit_class: set = set()
    for ch in m.group(2):
        if ch == "M":
            suit_class |= MAJORS
        elif ch == "m":
            suit_class |= MINORS
        else:
            suit_class.add(ch)
    return BidPattern(level, frozenset(suit_class), "bid", by_opp)


def parse_pattern(pattern_str: str) -> list[CallPattern]:
    """Parse `1D-1M-1N` (dashes or spaces; bml's `--` also accepted).

    A position may offer alternatives with `/`: `1M-3S/4C`.
    """
    parts = [p for p in _SPLIT_RE.split(normalize_filter_text(pattern_str)) if p]
    if not parts:
        raise ValueError("empty pattern")
    return [_parse_pattern_token(p) for p in parts]


def bid_matches(bid: Bid, pat: BidPattern | CallPattern) -> bool:
    """Does one call satisfy one position?

    Both sides can name a *set* of calls — the auction may record `1HS` or
    `2D/2H`, the pattern may ask for `1M` or `3S/4C` — so this is a test for
    overlap, not equality: the position matches if any alternative it allows
    shares a denomination with any the call allows.
    """
    if isinstance(pat, CallPattern):
        return any(bid_matches(bid, alt) for alt in pat.alternatives)
    if pat.kind != "*" and pat.kind != bid.kind:
        return False
    if pat.by_opponent is not None and pat.by_opponent != bid.by_opponent:
        return False
    if pat.kind == "bid":
        if pat.level is not None and pat.level != bid.level:
            return False
        if pat.suit_class and not (bid.suits & pat.suit_class):
            return False
    return True


def position_matches(position: tuple[Bid, ...], pat: CallPattern) -> bool:
    """As `bid_matches`, when the *auction* position is itself a set of calls.

    `1HS--3S/4C` records a position no single Bid can express, so an auction
    position is a tuple of alternatives. It matches when any of them does —
    the recorded auction is one of these calls, and the filter is asking
    whether it could be the one wanted.
    """
    return any(bid_matches(bid, pat) for bid in position)


def matches_prefix(seq_bids: list, pattern: list[CallPattern]) -> bool:
    """True if the auction begins with the pattern.

    A pattern describes *our* auction. The opponents can slip a call in at any
    point, so opponent calls the pattern does not ask about are stepped over
    rather than failing the match: `1D-1H` matches 1D (Pass) 1H, 1D (1S) 1H
    and 1D (X) 1H alike.

    Three kinds of token opt out of that skipping and line up with whatever
    call comes next:
      - the *first* token, because this is a prefix match: it anchors to the
        opening call, so `2C` means we opened 2C, not that we bid 2C at some
        point after an opponent's opening;
      - a bracketed token — `(X)`, `(2H)`, `(*)` — which is *about* the
        opponents, so it must match the very next call;
      - the bare wildcard `*`, meaning "any call at all" including an
        opponent's, which is what makes `*-*-*-*-*-*` mean "six calls deep"
        rather than "six calls by us".
    """
    positions = _as_positions(seq_bids)
    i = 0
    for n, pat in enumerate(pattern):
        if n and not _anchored(pat):
            while i < len(positions) and all(b.by_opponent for b in positions[i]):
                i += 1
        if i >= len(positions) or not position_matches(positions[i], pat):
            return False
        i += 1
    return True


def _anchored(pat: CallPattern | BidPattern) -> bool:
    """Must this position line up with the very next call rather than skipping
    over opponent calls? True for anything bracketed and for the bare `*`."""
    alts = pat.alternatives if isinstance(pat, CallPattern) else (pat,)
    return any(a.by_opponent is True or a.kind == "*" for a in alts)


def _as_positions(seq: list) -> list[tuple[Bid, ...]]:
    """Accept either a plain list of calls or a list of position alternatives,
    so callers holding pre-parsed `list[Bid]` keep working."""
    return [p if isinstance(p, tuple) else (p,) for p in seq]


def significant_bids(bids: list[Bid]) -> list[Bid]:
    """Drop opponent passes. They are noise for filtering — the auction
    notation omits them anyway — and dropping them is what lets `(*)` mean
    "the opponents actually did something". Active opponent calls like (X) or
    (1S) are kept, and `matches_prefix` decides whether to step over them."""
    return [b for b in bids if not (b.by_opponent and b.kind == "pass")]


def parse_sequence_positions(sequence: Iterable[str]) -> list[tuple[Bid, ...]]:
    """Parse an auction into one entry per position, each the calls it allows.

    Unlike `parse_sequence` this keeps `3S/4C` — an alternation spanning
    levels, which has no single-Bid form — instead of degrading it to 'other'.
    """
    positions: list[tuple[Bid, ...]] = []
    for element in sequence:
        for token in str(element).split():
            calls = bmlbids.parse_call_alternatives(token)
            if calls:
                positions.append(tuple(calls))
    return positions


def significant_positions(positions: list[tuple[Bid, ...]]) -> list[tuple[Bid, ...]]:
    """`significant_bids` for position tuples: drop opponent passes."""
    return [
        p for p in positions if not all(b.by_opponent and b.kind == "pass" for b in p)
    ]


def sequence_matches(sequence: list[str], pattern: list[CallPattern]) -> bool:
    """Convenience: parse a raw get_sequence() result and prefix-match it,
    ignoring implicit opponent passes."""
    return matches_prefix(significant_positions(parse_sequence_positions(sequence)), pattern)


# --- topics: pre-composed collections of patterns ---------------------------

DEFAULT_TOPICS_FILE = Path(__file__).with_name("quiz_topics.toml")


@dataclass(frozen=True)
class Topic:
    """A named bundle of patterns; an auction matches the topic if it matches
    any one of them."""

    name: str
    patterns: tuple[str, ...]
    description: str = ""
    systems: tuple[str, ...] = ()  # empty = applies to every bml system


def _norm_name(name: str) -> str:
    """Fold a topic name for comparison the same way user input is normalised,
    so a name containing a dash still matches what the user typed."""
    return normalize_filter_text(name).casefold()


def load_topics(
    path: Path | str = DEFAULT_TOPICS_FILE, system: Optional[str] = None
) -> dict[str, Topic]:
    """Read `quiz_topics.toml`, keyed by topic name in file order.

    Schema:

        [topics."Opening 1C"]
        patterns = ["1C", "1C-(X)"]
        description = "optional"
        systems = ["squad-system.bml"]   # optional; omit for all systems

    A missing file is not an error — topics are optional, the app just has
    none to offer. Topics whose patterns do not parse are skipped rather than
    breaking the whole file.
    """
    path = Path(path)
    if not path.is_file():
        return {}
    with path.open("rb") as f:
        data = tomllib.load(f)
    topics: dict[str, Topic] = {}
    for name, spec in (data.get("topics") or {}).items():
        patterns = tuple(str(p) for p in (spec.get("patterns") or []))
        if not patterns:
            continue
        systems = tuple(str(s) for s in (spec.get("systems") or []))
        if system is not None and systems and system not in systems:
            continue
        try:
            for p in patterns:
                parse_pattern(p)
        except ValueError:
            continue
        topics[name] = Topic(
            name=name,
            patterns=patterns,
            description=str(spec.get("description", "")),
            systems=systems,
        )
    return topics


def match_topic_name(text: str, names: Iterable[str], fuzzy: bool = True) -> Optional[str]:
    """Resolve free-form text to a single topic name, or None.

    Tried in order, each ignoring case and superfluous whitespace: exact name,
    then (unless `fuzzy` is off) unique prefix, then unique substring.
    Ambiguous input resolves to None so the caller can fall back to treating
    it as a bid pattern.
    """
    target = _norm_name(text)
    if not target:
        return None
    by_norm = {_norm_name(n): n for n in names}
    if target in by_norm:
        return by_norm[target]
    if not fuzzy:
        return None
    for test in (str.startswith, str.__contains__):
        hits = [orig for norm, orig in by_norm.items() if test(norm, target)]
        if len(hits) == 1:
            return hits[0]
    return None


# --- whole-filter parsing (comma-separated entries, OR'd) -------------------


@dataclass(frozen=True)
class ParsedFilter:
    """The result of interpreting a filter string.

    `patterns` is the flat OR list actually matched against; `entries` records
    what each comma-separated entry resolved to, and `canonical_text` is the
    input rewritten with resolved topic names (what the input box should show
    after the user commits).
    """

    patterns: tuple[tuple[CallPattern, ...], ...] = ()
    entries: tuple[str, ...] = ()
    topic_names: tuple[str, ...] = ()
    canonical_text: str = ""
    errors: tuple[str, ...] = ()

    def __bool__(self) -> bool:
        return bool(self.patterns)


def split_entries(text: Optional[str]) -> list[str]:
    """Split normalised filter text on commas into non-empty entries."""
    return [e.strip() for e in normalize_filter_text(text).split(",") if e.strip()]


def canonical_pattern_text(pattern_str: str) -> str:
    """Rewrite a pattern the way it was understood: `-`-joined, whitespace
    tidied, case folded (`1d -- 1M 1n` -> `1D-1M-1N`)."""
    parts = [p for p in _SPLIT_RE.split(normalize_filter_text(pattern_str)) if p]
    out = []
    for part in parts:
        inner, opp = _strip_parens(part)
        inner = _fold_token_case(_expand_shorthand(inner))
        out.append(f"({inner})" if opp else inner)
    return "-".join(out)


def parse_filter(text: Optional[str], topics: Optional[dict[str, Topic]] = None) -> ParsedFilter:
    """Interpret a whole filter string: `topic name, 1D-1M, 1H-(X)`.

    Each entry is resolved in this order: an exact topic name, then a bid
    pattern, then a fuzzy topic name (unique prefix or substring — this is
    what makes typing part of a topic and pressing Enter select it). Patterns
    are tried before the fuzzy step so a valid pattern is never hijacked by a
    topic that happens to contain it in its name.

    Unresolvable entries land in `.errors` and are skipped; the remaining
    entries still filter, so one typo does not discard the rest.
    """
    topics = topics or {}
    entries = split_entries(text)
    patterns: list[tuple[CallPattern, ...]] = []
    canonical: list[str] = []
    topic_names: list[str] = []
    errors: list[str] = []
    for entry in entries:
        topic_name = match_topic_name(entry, topics, fuzzy=False)
        if topic_name is None:
            try:
                patterns.append(tuple(parse_pattern(entry)))
            except ValueError:
                topic_name = match_topic_name(entry, topics)  # fuzzy fallback
            else:
                canonical.append(canonical_pattern_text(entry))
                continue
        if topic_name is None:
            errors.append(entry)
            continue
        topic = topics[topic_name]
        patterns.extend(tuple(parse_pattern(p)) for p in topic.patterns)
        canonical.append(topic_name)
        topic_names.append(topic_name)
    return ParsedFilter(
        patterns=tuple(patterns),
        entries=tuple(entries),
        topic_names=tuple(topic_names),
        canonical_text=", ".join(canonical),
        errors=tuple(errors),
    )


def bids_match_any(bids: list, patterns: Iterable[Iterable[CallPattern]]) -> bool:
    """True if pre-parsed auction bids match *any* of the patterns (comma = OR)."""
    return any(matches_prefix(bids, list(p)) for p in patterns)


def prepare_sequence_bids(sequences: Iterable[list[str]]) -> list[list[tuple[Bid, ...]]]:
    """Pre-parse a corpus of auctions once, so that repeatedly re-filtering it
    (e.g. validating on every keystroke) is only prefix comparisons.

    Each auction becomes a list of positions, and each position the calls it
    allows — one for an ordinary call, several for `2D/2H`."""
    return [significant_positions(parse_sequence_positions(s)) for s in sequences]


def sequence_matches_any(
    sequence: list[str], patterns: Iterable[Iterable[CallPattern]]
) -> bool:
    """True if the auction matches *any* of the patterns (comma = OR).

    Parses the sequence once, unlike calling `sequence_matches` per pattern.
    """
    return bids_match_any(significant_positions(parse_sequence_positions(sequence)), patterns)
