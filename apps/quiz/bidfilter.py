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
collection of patterns loaded from a topics toml (see `topics_file_for` /
`load_topics`).

`oM`/`om` ("the other major/minor") and repeated class shortcuts are resolved
against the auction itself: `1HS--2M` means one major named twice, and
`1H--2oM` means spades. See `expand_correlated`.
"""

from __future__ import annotations

import os
import itertools
import re
import sys
import tomllib
from dataclasses import dataclass, replace
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
    m = re.match(r"^([1-7])[X*]$", u)
    if m:
        # `1*` / `1x` — any suit at that level (empty suit class means "any").
        # Bid tables spell this `x`, section headers `*`; a bare `X` was caught
        # above as a double, so the level makes them unambiguous.
        return BidPattern(int(m.group(1)), frozenset(), "bid", by_opp)
    m = re.match(r"^([1-7])?O([Mm])$", inner)
    if m:
        # `oM` in a *pattern* has no earlier call to be "other" than, so it
        # asks for the class: an auction whose oM resolved either way matches.
        level = int(m.group(1)) if m.group(1) else None
        return BidPattern(
            level, MAJORS if m.group(2) == "M" else MINORS, "bid", by_opp
        )
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
    if bid.kind in ("any", "anybid", "anycall"):
        # a catch-all row — "whatever is called here" — so it answers to any
        # pattern, subject to whose call it was and to how much the word
        # promised: `(overcall)` is a bid, `(bid)` is anything but a pass,
        # `any`/`other(s)` is anything at all
        if pat.by_opponent is not None and pat.by_opponent != bid.by_opponent:
            return False
        if bid.kind == "anybid":
            return pat.kind in ("bid", "*")
        if bid.kind == "anycall":
            return pat.kind in ("bid", "double", "redouble", "*")
        return True
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
            calls = []
            for call in bmlbids.parse_call_alternatives(token):
                # `2N+` names its own floor, so it needs no auction: expand it
                # here into the calls it allows
                if call.kind == "at_least":
                    calls.extend(bmlbids.calls_at_or_above(call))
                elif call.kind == "game":
                    # a game contract: 3N, 4H, 4S, 5C or 5D
                    calls.extend(bmlbids.game_calls(call.by_opponent))
                else:
                    calls.append(call)
            if calls:
                positions.append(tuple(calls))
    return positions


def significant_positions(positions: list[tuple[Bid, ...]]) -> list[tuple[Bid, ...]]:
    """`significant_bids` for position tuples: drop opponent passes."""
    return [
        p for p in positions if not all(b.by_opponent and b.kind == "pass" for b in p)
    ]


# --- correlated suit classes ------------------------------------------------
#
# `1HS--2M` is "1H then 2H, or 1S then 2S" -- one major, named twice. Matching
# each position independently also accepts 1H then 2S, an auction the section
# never described. The corpus proves the intent: it writes `oM` when it means
# *the other* major, which would be pointless if a repeated `M` did not mean
# the same one.
#
# Rather than binding variables inside the matcher (which would make it
# stateful and need backtracking), an auction is expanded into the concrete
# auctions it stands for, and matches if any of them does. For a single
# set-valued position this is identical to the old overlap test; it only
# tightens where two positions share a class.

# A suit class is a proper subset of the denominations: {H,S} and {C,D} bind,
# the five-denomination wildcard (`3*`) does not — two wildcards in an auction
# are unrelated, not "the same unknown suit".
_BINDABLE = (MAJORS, MINORS)


def _binding_class(bid: Bid) -> Optional[frozenset]:
    """The class this call's suit is drawn from, if it is one that binds.

    A concrete call counts: `1H` is a use of the majors class, which is what
    lets a later `2oM` mean spades.
    """
    if not bid.is_bid or not bid.suits:
        return None
    if bid.suit_class:
        return bid.class_suits if bid.class_suits in _BINDABLE else None
    for klass in _BINDABLE:
        if bid.suits <= klass:
            return klass
    return None


def _bound_classes(positions: list[tuple[Bid, ...]]) -> list[frozenset]:
    """Which classes this auction uses as a variable.

    A class binds when the auction leaves it open more than once (`1HS ... 2M`),
    or names "the other" one alongside any call of that class (`1H ... 2oM` --
    the concrete 1H is what fixes it).
    """
    open_uses: dict[frozenset, int] = {}
    any_uses: dict[frozenset, int] = {}
    other: set[frozenset] = set()
    for position in positions:
        for bid in position:
            klass = _binding_class(bid)
            if klass is None:
                continue
            any_uses[klass] = any_uses.get(klass, 0) + 1
            if bid.is_other_class:
                other.add(klass)
            elif len(bid.suits) > 1:
                open_uses[klass] = open_uses.get(klass, 0) + 1
    return [
        k
        for k in any_uses
        if open_uses.get(k, 0) > 1 or (k in other and any_uses[k] > 1)
    ]


def _fixed_suit(positions: list[tuple[Bid, ...]], klass: frozenset) -> Optional[str]:
    """The one denomination of `klass` the auction states outright, if any.

    Two different concrete calls of the same class (`1H` then `1S`) leave the
    variable genuinely ambiguous; returning None makes the caller fall back to
    the untightened auction rather than guess.
    """
    concrete = {
        next(iter(bid.suits))
        for position in positions
        for bid in position
        if _binding_class(bid) == klass and len(bid.suits) == 1
    }
    return concrete.pop() if len(concrete) == 1 else None


def _resolve(bid: Bid, assignment: dict[frozenset, str]) -> Bid:
    klass = _binding_class(bid)
    if klass is None or klass not in assignment or len(bid.suits) == 1:
        return bid
    chosen = assignment[klass]
    suits = klass - {chosen} if bid.is_other_class else {chosen}
    return replace(bid, suits=frozenset(suits))


def resolve_relative(
    positions: list[tuple[Bid, ...]],
) -> list[list[tuple[Bid, ...]]]:
    """Replace `next` with the call it stands for: the cheapest bid above the
    position before it (`4HS = splinter` then `next = RKB` is 4S over 4H).

    Returns the auctions that produces. A parent naming several calls gives one
    auction per call, *with the parent pinned* — 4H then 4S, or 4S then 4N, and
    never 4H then 4N, which no line of the table describes. A `next` whose
    parent is not a bid at all (`any`, prose) stays unresolved and so matches
    nothing: the auction never said which call it was.

    Run *after* `expand_correlated`, so a parent whose suit class was bound is
    already concrete.
    """
    auctions: list[list[tuple[Bid, ...]]] = [[]]
    for position in positions:
        relatives = [b for b in position if b.kind in RELATIVE_KINDS]
        if relatives and auctions[0]:
            grown = []
            for auction in auctions:
                # `!c/!d` is two relative tokens at one position, so every one
                # of them contributes its resolutions
                resolved = [
                    (parent, call, relative)
                    for relative in relatives
                    for parent, call in _resolutions_of(relative, auction)
                ]
                for parent, call, relative in resolved:
                    resolved_call = (
                        replace(call, by_opponent=relative.by_opponent),
                    )
                    if parent is None:
                        # the call we measured from is further back than the
                        # previous position, so there is nothing to pin here
                        grown.append(auction + [resolved_call])
                    else:
                        grown.append(auction[:-1] + [(parent,), resolved_call])
                if not resolved:
                    grown.append(auction + [position])  # unresolvable, keep as is
            auctions = grown
        else:
            auctions = [auction + [position] for auction in auctions]
    return auctions


# Token kinds whose call has to be worked out from the auction so far.
RELATIVE_KINDS = frozenset(
    {
        "next",
        "jump",
        "cue",
        "cueover",
        "cuelow",
        "cuehigh",
        "new",
        "step",
        "raise",
        "strain",
        "strainany",
        "slam",
        "nextsuit",
        "fourthsuit",
    }
)


def _last_bid_position(auction: list[tuple[Bid, ...]]) -> int:
    """Index of the last position holding an actual bid.

    Everything here measures "cheapest above" from a *bid*: a raise or a cue
    over partner's double is still legal, it just has to clear the last bid.
    -1 when the auction holds no bid at all.
    """
    for i in range(len(auction) - 1, -1, -1):
        if any(bid.is_bid and bid.suits for bid in auction[i]):
            return i
    return -1


def _resolutions_of(
    relative: Bid, auction: list[tuple[Bid, ...]]
) -> list[tuple[Optional[Bid], Bid]]:
    """(pinned previous call, the call the token resolves to) for each call the
    previous position could have been.

    The pinned call is None when the bid being measured from is not the call
    immediately before us — it is only pinned when it is, since that is the
    position `resolve_relative` rewrites.
    """
    source = _last_bid_position(auction)
    if source < 0:
        return []
    pin = source == len(auction) - 1
    pairs = []
    for previous in auction[source]:
        for suit in sorted(previous.suits):
            parent = replace(previous, suits=frozenset({suit}), suit_class="")
            if relative.kind == "next":
                call = bmlbids.next_call(parent)
                if call is not None:
                    pairs.append((parent if pin else None, call))
                continue
            if relative.kind == "jump":
                calls = _jumps_from(parent, relative.jump_levels, auction)
            elif relative.kind == "new":
                calls = _in_suits(parent, _unbid_suits(auction), relative.level)
            elif relative.kind == "strain":
                # a denomination with no level: the simple (non-jump) bid in it
                calls = _in_suits(parent, relative.suits, None)
            elif relative.kind == "strainany":
                # `!c+`: that strain at whatever level it takes, so every legal
                # bid in it from the cheapest upward
                calls = [
                    replace(cheapest, level=level)
                    for cheapest in _in_suits(parent, relative.suits, None)
                    for level in range(cheapest.level, 8)
                ]
            elif relative.kind == "raise":
                calls = _raises_from(parent, auction, relative)
            elif relative.kind == "slam":
                calls = _slams_from(parent, auction, relative)
            elif relative.kind == "nextsuit":
                calls = _next_suit_from(parent)
            elif relative.kind == "fourthsuit":
                calls = _fourth_suit_from(parent, auction)
            elif relative.kind == "step":
                calls = _steps_from(parent, relative.level)
            elif relative.kind == "cueover":
                calls = _in_suits(parent, _rho_suits(parent, auction), relative.level)
            elif relative.kind in ("cuelow", "cuehigh"):
                calls = _picked_cue(parent, auction, relative)
            else:  # cue
                calls = _cues_from(parent, auction, relative.level)
            pairs.extend((parent if pin else None, call) for call in calls)
    return pairs


def _spoken_suits(auction: list[tuple[Bid, ...]], by_opponent: Optional[bool] = None):
    """Denominations the auction pinned down to one suit, optionally only the
    opponents'. An unresolved `2M` names no single suit, so it neither counts
    as bid nor rules a suit out."""
    return {
        suit
        for position in auction
        for bid in position
        if bid.is_bid
        and len(bid.suits) == 1
        and (by_opponent is None or bid.by_opponent == by_opponent)
        for suit in bid.suits
    }


def _unbid_suits(auction: list[tuple[Bid, ...]]) -> set:
    """Suits nobody has bid — neither side. Notrump is not a suit."""
    return set("CDHS") - _spoken_suits(auction)


def _in_suits(parent: Bid, suits, level: Optional[int]) -> list[Bid]:
    """The call in each of `suits`: at `level` when the token named one
    (`3new`), otherwise the cheapest available (a simple bid, not a jump)."""
    calls = []
    for suit in sorted(suits):
        if level is None:
            call = bmlbids.cheapest_call(parent, suit)
        else:
            call = replace(
                parent, level=level, suits=frozenset({suit}), suit_class="",
                jump_levels=0,
            )
        if call is not None:
            calls.append(call)
    return calls


def _raises_from(
    parent: Bid, auction: list[tuple[Bid, ...]], token: Bid
) -> list[Bid]:
    """Support for the last suit partner bid.

    Partner's suit is the last bid on our own side of the table — usually the
    call right before ours, but an opponent may have come in between
    (`2D--(P)--2N--(any)--raise`). `jumpRaise` is one level above the simple
    raise, and `3raise` names the level outright.

    Caveat: when partner's bid was itself several calls (`2HS`) *and* it is not
    the call immediately before ours, both raises are offered rather than one
    per pinned variant — only the previous position is pinned.
    """
    suits = _partner_suits(auction, token.by_opponent, parent)
    if not suits:
        return []
    calls = _in_suits(parent, suits, token.level)
    if token.jump_levels:
        calls = [
            replace(c, level=c.level + token.jump_levels)
            for c in calls
            if c.level + token.jump_levels <= 7
        ]
    return calls


def _slams_from(parent: Bid, auction: list[tuple[Bid, ...]], token: Bid) -> list[Bid]:
    """`slam`: the agreed suit — the last one our side named — at the slam
    level, 6 or 7. `6slam` says which."""
    suits = _partner_suits(auction, token.by_opponent, parent)
    levels = [token.level] if token.level else bmlbids.SLAM_LEVELS
    calls = []
    for suit in sorted(suits):
        cheapest = bmlbids.cheapest_call(parent, suit)
        if cheapest is None:
            continue
        calls.extend(
            replace(cheapest, level=level)
            for level in levels
            if level >= cheapest.level
        )
    return calls


def _next_suit_from(parent: Bid) -> list[Bid]:
    """`nextSuit`: the next bid up that is a suit — the cheapest call above,
    skipping notrump (a `next` that lands on 3N is not one)."""
    candidates = [
        call
        for suit in "CDHS"
        if (call := bmlbids.cheapest_call(parent, suit)) is not None
    ]
    if not candidates:
        return []
    return [
        min(
            candidates,
            key=lambda c: (c.level, bmlbids.SUIT_RANK[next(iter(c.suits))]),
        )
    ]


def _fourth_suit_from(parent: Bid, auction: list[tuple[Bid, ...]]) -> list[Bid]:
    """`4thSuit`: fourth-suit-forcing — the one suit still unbid.

    Only resolvable when exactly one is left; with two or more the token is
    not describing anything the auction has pinned down.
    """
    unbid = _unbid_suits(auction)
    if len(unbid) != 1:
        return []
    return _in_suits(parent, unbid, None)


def _partner_suits(
    auction: list[tuple[Bid, ...]], by_opponent: bool, parent: Optional[Bid] = None
) -> set:
    """The suits of the last bid on the given side — partner's, for our own
    tokens.

    When that bid is the one we are measuring from it has already been pinned
    to a single suit, so use it: `4HS` then `slam` is 6H over 4H or 6S over 4S,
    never 6S over 4H.
    """
    for index in range(len(auction) - 1, -1, -1):
        found = {
            suit
            for bid in auction[index]
            if bid.is_bid and bid.by_opponent == by_opponent
            for suit in bid.suits
        }
        if not found:
            continue
        if (
            parent is not None
            and parent.by_opponent == by_opponent
            and index == _last_bid_position(auction)
        ):
            return parent.suits & set("CDHSN")
        return found & set("CDHSN")
    return set()


def _steps_from(parent: Bid, step: Optional[int]) -> list[Bid]:
    """The step response(s) to an artificial ask.

    `1step` is one rung up the ladder, `2step` two. `xstep` is "a step
    response, however many the scheme has" — the author's reading — so it
    stands for the first `bmlbids.STEP_LIMIT` of them rather than for one
    known call. Beyond that the schemes leave the ladder (the EKB rows say so
    themselves: "5th step = 2 KC + a void", then `6x`).
    """
    wanted = [step] if step is not None else range(1, bmlbids.STEP_LIMIT + 1)
    calls = [bmlbids.step_call(parent, n) for n in wanted]
    return [c for c in calls if c is not None]


def _rho_suits(parent: Bid, auction: list[tuple[Bid, ...]]) -> set:
    """The suit of the last call by the player on our immediate right, the one
    `CueOver` cues — as opposed to `cue`, which is any of their suits.

    It is their *last call* that matters, not their last bid: if they doubled,
    there is nothing to cue over and the token stays unresolved, even though an
    earlier opponent bid is sitting there (cueing that one is the "sitting
    under" bid, which the tables write out separately). Notrump is dropped,
    there being no such thing as cueing notrump. When their call is the one
    right before ours it has already been pinned, so the cue follows what they
    actually bid rather than the union of what their token allowed.
    """
    last = _last_opponent_position(auction)
    if last < 0:
        return set()
    if parent.by_opponent and last == _last_bid_position(auction):
        # their last call *is* the bid we are measuring from, already pinned
        return parent.suits & set("CDHS")
    return {suit for bid in auction[last] if bid.is_bid for suit in bid.suits} & set(
        "CDHS"
    )


def _last_opponent_position(auction: list[tuple[Bid, ...]]) -> int:
    """Index of the opponents' most recent *call*, of any kind."""
    for i in range(len(auction) - 1, -1, -1):
        if any(bid.by_opponent for bid in auction[i]):
            return i
    return -1


def _picked_cue(parent: Bid, auction: list[tuple[Bid, ...]], token: Bid) -> list[Bid]:
    """`cueLow` / `cueHi`: a cue of the lower- or higher-ranking of *their two
    suits*.

    Only resolvable when the auction shows two opponent suits. Where the corpus
    uses these words the opponents have made a conventional two-suited bid
    (`1C--(2!c) = two suiter, two known (e.g. majors)`) — which two suits is
    system knowledge the calls do not record, so the token stays unresolved
    rather than guessing at the pair.
    """
    theirs = _spoken_suits(auction, by_opponent=True)
    if len(theirs) < 2:
        return []
    pick = min if token.kind == "cuelow" else max
    suit = pick(theirs, key=lambda s: bmlbids.SUIT_RANK[s])
    return _in_suits(parent, {suit}, token.level)


def _cues_from(
    parent: Bid, auction: list[tuple[Bid, ...]], level: Optional[int]
) -> list[Bid]:
    """A cue bid: their suit. Unqualified it is the *lowest* cue available, so
    with two opponent suits shown only the cheaper one counts."""
    theirs = _spoken_suits(auction, by_opponent=True)
    calls = _in_suits(parent, theirs, level)
    if level is None and calls:
        calls = [min(calls, key=lambda c: (c.level, bmlbids.SUIT_RANK[next(iter(c.suits))]))]
    return calls


def _jumps_from(
    parent: Bid, levels: int, auction: list[tuple[Bid, ...]]
) -> list[Bid]:
    """Every call `jump` could be over `parent`: a jump in a *new suit*.

    A jump is `levels` above the cheapest bid available in that suit, never in
    notrump (a jump to 3N is a different animal, not what these tables mean by
    `jump`), and never in a suit already bid. "Already bid" counts only calls
    the auction pinned down to one denomination, so an unresolved `2M` does not
    silently rule both majors out.
    """
    spoken = {
        suit
        for position in auction
        for bid in position
        if bid.is_bid and len(bid.suits) == 1
        for suit in bid.suits
    }
    spoken |= parent.suits
    calls = []
    for suit in sorted(set("CDHS") - spoken):
        cheapest = bmlbids.cheapest_call(parent, suit)
        if cheapest is None or cheapest.level + levels > 7:
            continue
        calls.append(replace(cheapest, level=cheapest.level + levels))
    return calls


def expand_correlated(positions: list[tuple[Bid, ...]]) -> list[list[tuple[Bid, ...]]]:
    """The concrete auctions an auction with correlated suit classes stands for.

    Returns `[positions]` unchanged when nothing binds, which is the common
    case; otherwise one auction per assignment of the bound classes.
    """
    classes = _bound_classes(positions)
    if not classes:
        return [positions]
    domains = []
    for klass in classes:
        fixed = _fixed_suit(positions, klass)
        if fixed is not None and any(
            bid.is_other_class
            for position in positions
            for bid in position
            if _binding_class(bid) == klass
        ):
            domains.append([fixed])  # a spelled-out call pins the variable
        else:
            domains.append(sorted(klass))
    variants = []
    for choice in itertools.product(*domains):
        assignment = dict(zip(classes, choice))
        variants.append(
            [
                tuple(_resolve(bid, assignment) for bid in position)
                for position in positions
            ]
        )
    return variants or [positions]


def prepare_auction(sequence: Iterable[str]) -> list[list[tuple[Bid, ...]]]:
    """One auction as the concrete auctions it stands for: parsed into
    positions, opponent passes dropped, suit classes bound, `next` resolved."""
    positions = significant_positions(parse_sequence_positions(sequence))
    return [
        auction
        for variant in expand_correlated(positions)
        for auction in resolve_relative(variant)
    ]


def sequence_matches(sequence: list[str], pattern: list[CallPattern]) -> bool:
    """Convenience: parse a raw get_sequence() result and prefix-match it,
    ignoring implicit opponent passes."""
    return bids_match_any(prepare_auction(sequence), [pattern])


# --- topics: pre-composed collections of patterns ---------------------------

TOPICS_DIR = Path(__file__).parent
DEFAULT_TOPICS_FILE = TOPICS_DIR / "default_topics.toml"


def topics_file_for(variant: Optional[str] = None, directory: Path | str = TOPICS_DIR) -> Path:
    """Pick the topics file for a quiz variant: `<variant>_topics.toml` if that
    file exists, otherwise `default_topics.toml`.

    One file per variant, chosen whole -- there is deliberately no merging or
    inheritance between them, so a variant file is a full replacement and the
    default is the catch-all. `load_topics` treats a missing file as "no
    topics", so a variant with neither file simply offers none.
    """
    directory = Path(directory)
    if variant:
        candidate = directory / f"{variant}_topics.toml"
        if candidate.is_file():
            return candidate
    return directory / "default_topics.toml"


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
    """Read a topics toml (see `topics_file_for`), keyed by topic name in file
    order.

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
    """True if a pre-parsed auction matches *any* of the patterns (comma = OR).

    Accepts what `prepare_sequence_bids` produces (an auction as its correlated
    variants) as well as a plain list of calls or positions.
    """
    variants = bids if bids and isinstance(bids[0], list) else [bids]
    return any(matches_prefix(v, list(p)) for v in variants for p in patterns)


def prepare_sequence_bids(sequences: Iterable[list[str]]) -> list[list[tuple[Bid, ...]]]:
    """Pre-parse a corpus of auctions once, so that repeatedly re-filtering it
    (e.g. validating on every keystroke) is only prefix comparisons.

    Each auction becomes a list of *variants* (one unless correlated suit
    classes bind — see `expand_correlated`), each a list of positions, each
    position the calls it allows: one for an ordinary call, several for
    `2D/2H`."""
    return [prepare_auction(s) for s in sequences]


def sequence_matches_any(
    sequence: list[str], patterns: Iterable[Iterable[CallPattern]]
) -> bool:
    """True if the auction matches *any* of the patterns (comma = OR).

    Parses the sequence once, unlike calling `sequence_matches` per pattern.
    """
    return bids_match_any(prepare_auction(sequence), patterns)
