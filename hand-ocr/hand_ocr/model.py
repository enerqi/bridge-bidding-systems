"""Deal model + PBN/LIN serialisation + validation.

This is the source-of-truth layer, independent of any vision code. A parsed
image becomes a `Deal`; everything downstream (PBN text, LIN view, validation)
works off that. No heavy deps here so it is trivially testable.

Formats:
- PBN `Deal` tag is the canonical output: it can mark a hand *unknown* with
  `-`, which is exactly the declarer+dummy case (E/W unknown).
- LIN `md|` cannot mark a hand unknown -- omitted hands are auto-filled from
  the remaining cards -- so LIN is emitted only as a *view* when enough hands
  are known and never as the primary artifact. See `to_lin`.
"""

from __future__ import annotations

from dataclasses import dataclass

RANKS = "AKQJT98765432"  # high -> low; canonical ordering
SUITS = "SHDC"  # PBN within-hand order: spades, hearts, diamonds, clubs
SEATS = "NESW"  # clockwise

# rank spellings we normalise on input
_RANK_ALIASES = {"10": "T", "t": "T"}


class DealError(ValueError):
    """Structural problem in a parsed deal (bad card, dup, wrong count)."""


def normalise_rank(token: str) -> str:
    token = _RANK_ALIASES.get(token, token.upper())
    if token not in RANKS:
        raise DealError(f"bad rank {token!r}")
    return token


def _normalise_suit_ranks(raw: str) -> str:
    """Take a per-suit rank string (e.g. '10 8 7' or 'AKQ4' or '-'), return
    canonical high->low with no separators. Empty / '-' => void ''."""
    raw = raw.strip()
    if raw in ("", "-", "—"):
        return ""
    # split '10' out first, then treat rest as single chars
    tokens: list[str] = []
    i = 0
    compact = raw.replace(" ", "")
    while i < len(compact):
        if compact[i : i + 2] == "10":
            tokens.append("T")
            i += 2
        else:
            tokens.append(compact[i])
            i += 1
    ranks = [normalise_rank(t) for t in tokens]
    # canonical order, dedupe check
    if len(set(ranks)) != len(ranks):
        raise DealError(f"duplicate rank in suit {raw!r}")
    return "".join(sorted(ranks, key=RANKS.index))


@dataclass
class Hand:
    """One player's 13 cards (or fewer while a deal is being assembled)."""

    suits: dict[str, str]  # suit char -> canonical rank string, e.g. {"S": "AKQ4", ...}

    @classmethod
    def from_rows(cls, spades: str, hearts: str, diamonds: str, clubs: str) -> Hand:
        return cls(
            {
                "S": _normalise_suit_ranks(spades),
                "H": _normalise_suit_ranks(hearts),
                "D": _normalise_suit_ranks(diamonds),
                "C": _normalise_suit_ranks(clubs),
            }
        )

    def card_count(self) -> int:
        return sum(len(self.suits[s]) for s in SUITS)

    def cards(self) -> set[str]:
        return {s + r for s in SUITS for r in self.suits[s]}

    def to_pbn(self) -> str:
        return ".".join(self.suits[s] for s in SUITS)


@dataclass
class Deal:
    """Up to four hands keyed by seat. `None` means the hand is unknown."""

    hands: dict[str, Hand | None]  # seat char -> Hand | None
    first: str = "N"  # PBN "first" seat; hands listed clockwise from here
    # optional metadata read for free from Mode-B diagrams (BridgeWebs/RealBridge);
    # all None for Mode-A play views. Emitted as PBN tags only when present.
    board: int | None = None
    dealer: str | None = None  # seat char
    vul: str | None = None  # PBN vulnerability: None | NS | EW | All
    # set by the pipeline when a reader stage failed on this tile: the deal is
    # returned all-unknown (rather than raising and sinking the whole page) and
    # this records which stage broke so the CLI can flag it for manual fix.
    note: str | None = None

    def known(self) -> dict[str, Hand]:
        return {seat: h for seat, h in self.hands.items() if h is not None}

    def validate(self) -> None:
        """Raise DealError on any structural impossibility. Partial deals are
        allowed (unknown hands) but every *known* hand must be legal and the
        known cards must not collide or overflow a suit."""
        seen: dict[str, str] = {}  # card -> seat, for dup detection
        for seat, hand in self.known().items():
            if seat not in SEATS:
                raise DealError(f"bad seat {seat!r}")
            n = hand.card_count()
            if n != 13:
                raise DealError(f"seat {seat} has {n} cards, expected 13")
            for card in hand.cards():
                if card in seen:
                    raise DealError(f"card {card} in both {seen[card]} and {seat}")
                seen[card] = seat

    def to_pbn(self) -> str:
        """The `[Deal "..."]` tag alone. Unknown hands render as `-`."""
        order = [SEATS[(SEATS.index(self.first) + i) % 4] for i in range(4)]
        parts = []
        for seat in order:
            h = self.hands.get(seat)
            parts.append(h.to_pbn() if h is not None else "-")
        return f'[Deal "{self.first}:{" ".join(parts)}"]'

    def to_pbn_tags(self) -> str:
        """A PBN tag block: Board/Dealer/Vulnerable (when known) plus Deal.
        Use this for Mode-B diagrams that carry the metadata; `to_pbn` remains
        the bare Deal tag."""
        lines = []
        if self.board is not None:
            lines.append(f'[Board "{self.board}"]')
        if self.dealer is not None:
            lines.append(f'[Dealer "{self.dealer}"]')
        if self.vul is not None:
            lines.append(f'[Vulnerable "{self.vul}"]')
        lines.append(self.to_pbn())
        return "\n".join(lines)

    def to_lin(self) -> str:
        """BBO handviewer `md|` string. Requires all four hands known --
        raises otherwise, because LIN cannot represent an unknown hand
        (omitted hands are silently auto-filled, which would fabricate cards).
        Use PBN for partial deals."""
        if len(self.known()) != 4:
            raise DealError("LIN needs all four hands; use to_pbn for partial deals")
        # LIN dealer digit: 1=S 2=W 3=N 4=E; hands listed S,W,N,E
        dealer_digit = {"S": 1, "W": 2, "N": 3, "E": 4}[self.first]
        lin_order = "SWNE"
        hand_strs = []
        for seat in lin_order:
            h = self.hands[seat]
            assert h is not None
            hand_strs.append("".join(s + h.suits[s] for s in SUITS))
        return f"md|{dealer_digit}{','.join(hand_strs)}|"
