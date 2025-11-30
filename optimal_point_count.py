import io
from dataclasses import dataclass
from enum import Enum
from pprint import pprint as pp
from typing import NewType

SmallCardCount = NewType("SmallCardCount", int)


class Honour(Enum):
    Ace = "Ace"
    King = "King"
    Queen = "Queen"
    Jack = "Jack"
    Ten = "Ten"

_RANKS = {Honour.Ace: 1, Honour.King: 2, Honour.Queen: 3, Honour.Jack: 4, Honour.Ten: 5}
_TEXT = {Honour.Ace: "A", Honour.King: "K", Honour.Queen: "Q", Honour.Jack: "J", Honour.Ten: "T"}

def honour_rank(hon: Honour) -> int:
    return _RANKS[hon]


def show_honour(hon: Honour) -> str:
    return _TEXT[hon]


@dataclass
class SuitHolding:
    honours: list[Honour]
    xs: SmallCardCount

    def __str__(self) -> str:
        if suit_length(self) == 0:
            return "-"

        hons = sorted(self.honours, key=honour_rank)
        prefix = "".join(show_honour(hon) for hon in hons)
        return prefix + "x" * self.xs


@dataclass
class Hand:
    suits: list[SuitHolding]


def parse_rough_suit(s: str) -> SuitHolding:
    """
    Parse some letters as suit honours, including T as 10, otherwise treat any character as an "x" (small card)
    """
    s = s.upper().strip()
    honours: list[Honour] = []
    small_card_count = 0

    if "10" in s:
        s = s.replace("10", "")
        honours.append(Honour.Ten)

    mapping = {
        "A": Honour.Ace,
        "K": Honour.King,
        "Q": Honour.Queen,
        "J": Honour.Jack,
        "T": Honour.Ten,
    }

    for ch in s:
        honour = mapping.get(ch)
        if honour is not None:
            honours.append(honour)
        else:
            small_card_count += 1

    return SuitHolding(honours=honours, xs=SmallCardCount(small_card_count))


def validate_hand(hand: Hand) -> str | None:
    if not len(hand.suits) == 4:
        return "required: 4 suits for a hand"

    card_count = sum(len(suit.honours) + suit.xs for suit in hand.suits)
    if card_count != 13:
        return "required: 13 cards for a hand"

    for suit in hand.suits:
        if len(suit.honours) != len(set(suit.honours)):
            return "duplicate honours in one or more suits"

    return None


@dataclass
class Honour_Points:
    total_opening: float
    total_non_opening: float
    tallies: list[tuple[float, str]]
    opening_only: list[tuple[float, str]]


def is_accompanied_by_picture_honour(hon: Honour, holding: SuitHolding) -> bool:
    assert hon in holding.honours
    return any(
        other_hon in holding.honours
        for other_hon in [Honour.Ace, Honour.King, Honour.Queen, Honour.Jack]
        if other_hon != hon
    )


def in_any_suit(hon: Honour, hand: Hand) -> bool:
    for suit in hand.suits:
        if hon in suit.honours:
            return True

    return False


def count_honour(hon: Honour, hand: Hand) -> int:
    return sum(1 for suit in hand.suits if hon in suit.honours)


def is_singleton_picture_honour_suit(holding: SuitHolding) -> bool:
    return len(holding.honours) == 1 and holding.honours[0] != Honour.Ten and holding.xs == 0


def is_honour_x_doubleton(hon: Honour, suit: SuitHolding) -> bool:
    return hon in suit.honours and len(suit.honours) == 1 and suit.xs == 1


def is_aq_ak_kq_qj_doubleton_honour(suit: SuitHolding) -> bool:
    if not suit.xs == 0:
        return False

    if not len(suit.honours) == 2:
        return False

    return (
        (Honour.Ace in suit.honours and Honour.Queen in suit.honours)
        or (Honour.Ace in suit.honours and Honour.King in suit.honours)
        or (Honour.King in suit.honours and Honour.Queen in suit.honours)
        or (Honour.Queen in suit.honours and Honour.Jack in suit.honours)
    )


def is_kx_qx_jx_j10_doubleton(suit: SuitHolding) -> bool:
    if suit.xs == 1 and len(suit.honours) == 1:
        one_honour = suit.honours[0]
        return any(hon == one_honour for hon in [Honour.King, Honour.Queen, Honour.Jack])
    if len(suit.honours) == 2 and suit.xs == 0:
        return Honour.Jack in suit.honours and Honour.Ten in suit.honours

    return False


def suit_length(suit: SuitHolding) -> int:
    return len(suit.honours) + suit.xs


def picture_honours_count(suit: SuitHolding) -> int:
    return sum(1 for hon in suit.honours if hon != Honour.Ten)


def milton_hcp(suit: SuitHolding) -> int:
    hcp = {
        Honour.Ace: 4,
        Honour.King: 3,
        Honour.Queen: 2,
        Honour.Jack: 1,
        Honour.Ten: 0,
    }

    return sum(hcp[hon] for hon in suit.honours)


def has_all_honours(suit: SuitHolding, honours: set[Honour]) -> bool:
    return all(hon in suit.honours for hon in honours)


def count_6_carders(hand: Hand) -> int:
    return sum(1 for suit in hand.suits if suit_length(suit) == 6)


def count_5_carders(hand: Hand) -> int:
    return sum(1 for suit in hand.suits if suit_length(suit) == 5)


def count_4_carders(hand: Hand) -> int:
    return sum(1 for suit in hand.suits if suit_length(suit) == 4)


def count_tripleton(hand: Hand) -> int:
    return sum(1 for suit in hand.suits if suit_length(suit) == 3)


def count_doubleton(hand: Hand) -> int:
    return sum(1 for suit in hand.suits if suit_length(suit) == 2)


def count_singleton(hand: Hand) -> int:
    return sum(1 for suit in hand.suits if suit_length(suit) == 1)


def count_void(hand: Hand) -> int:
    return sum(1 for suit in hand.suits if suit_length(suit) == 0)


def is_4333_shape(hand: Hand) -> bool:
    return count_tripleton(hand) == 3


def honour_points(hand: Hand) -> Honour_Points:
    total = 0.0
    tallies = []
    opening_only = []

    # per suit
    for suit in hand.suits:
        if Honour.Ace in suit.honours:
            total += 4.5
            tallies.append((4.5, "Ace"))

        if Honour.King in suit.honours:
            total += 3.0
            tallies.append((3.0, "King"))

        if Honour.Queen in suit.honours:
            if is_accompanied_by_picture_honour(Honour.Queen, suit):
                total += 2.0
                tallies.append((2.0, "Queen accompanied by picture honour"))
            else:
                total += 1.5
                tallies.append((1.5, "Queen isolated, no picture honours"))

        if Honour.Jack in suit.honours:
            if is_accompanied_by_picture_honour(Honour.Jack, suit):
                total += 1.0
                tallies.append((1.0, "Jack accompanied by picture honour"))
            else:
                total += 0.5
                tallies.append((0.5, "Jack isolated, no picture honours"))

        if Honour.Ten in suit.honours:
            # 10 valued once depending on how close the nearest honour is
            if Honour.Jack in suit.honours and picture_honours_count(suit) == 1 and suit.xs > 0:
                total += 1.5
                tallies.append((1.5, "Ten + Jack combination upvalues J and 10 with small cards"))
            elif Honour.Jack in suit.honours and picture_honours_count(suit) == 1 and suit.xs == 0:
                total += 1.0
                tallies.append((1.0, "Ten + Jack Doubleton"))
            elif Honour.Jack in suit.honours:
                total += 1.0
                tallies.append((1.0, "Ten + Jack and other honour(s)"))
            elif Honour.Queen in suit.honours:
                if picture_honours_count(suit) == 1 and suit.xs == 0:
                    total += 0.5
                    tallies.append((0.5, "Ten + Queen Doubleton"))
                else:
                    total += 1.0
                    tallies.append((1.0, "Ten + Queen combo"))
            elif Honour.King in suit.honours:
                total += 0.5
                tallies.append((0.5, "Ten + King combo, no Q|J"))

        if is_singleton_picture_honour_suit(suit) and Honour.Jack not in suit.honours:
            total -= 1.0
            tallies.append((-1.0, "singleton honour, A|K|Q"))

        if is_honour_x_doubleton(Honour.Queen, suit):
            total -= 0.5
            tallies.append((-0.5, "Qx doubleton"))

        if is_honour_x_doubleton(Honour.Jack, suit):
            total -= 0.5
            tallies.append((-0.5, "Jx doubleton"))

        if is_aq_ak_kq_qj_doubleton_honour(suit):
            total -= 1.0
            tallies.append((-1.0, "AQ or AK or KQ or QJ doubleton honour"))

        if picture_honours_count(suit) >= 3:
            if suit_length(suit) == 5:
                total += 1.0
                tallies.append((1.0, f"3+ picture honours in 5 card suit ({suit})"))
            elif suit_length(suit) >= 6:
                total += 2.0
                tallies.append((2.0, f"3+ picture honours in 6+ card suit ({suit})"))

    # global
    no_kings = False
    no_queens = False

    if not in_any_suit(Honour.Queen, hand):
        total -= 1
        tallies.append((-1.0, "Zero Queens"))
        no_queens = True

    kings = count_honour(Honour.King, hand)
    if kings == 0:
        total -= 1
        tallies.append((-1.0, "Zero Kings"))
        no_kings = True
    if kings == 3:
        total += 1.0
        tallies.append((1.0, "3 Kings"))
    if kings == 4:
        total += 2.0
        tallies.append((2.0, "4 Kings"))

    if count_honour(Honour.Queen, hand) == 4:
        total += 1.0
        tallies.append((1.0, "4 Queens"))

    if not in_any_suit(Honour.Ace, hand):
        if not (no_kings and no_queens):
            opening_only.append((-1.0, "Zero Aces"))
        else:
            opening_only.append((0.0, "Zero Aces, ignored as already No Queens and Kings"))

    total_non_opening = total
    total_opening = total_non_opening + sum(x for (x, _) in opening_only)

    return Honour_Points(
        total_non_opening=total_non_opening, total_opening=total_opening, tallies=tallies, opening_only=opening_only
    )


@dataclass
class Length_Points:
    total: float
    tallies: list[tuple[float, str]]


def length_points(hand: Hand) -> Length_Points:
    total = 0.0
    tallies = []

    for suit in hand.suits:
        good_suit = milton_hcp(suit) >= 3
        if suit_length(suit) == 5 and good_suit:
            total += 1.0
            tallies.append((1.0, f"5 card length with QJ+|K+ ({suit})"))
        if suit_length(suit) >= 6 and good_suit:
            total += 2.0
            tallies.append((2.0, f"6+ card length with QJ+|K+ ({suit})"))
        if suit_length(suit) >= 6 and not good_suit:
            total += 1.0
            tallies.append((1.0, f"6+ card length poor honours ({suit})"))
        if suit_length(suit) >= 7:
            total += 2.0
            tallies.append((2.0, "7th card extra length"))
        if suit_length(suit) >= 8:
            total += 2.0
            tallies.append((2.0, "8th card extra length"))
        if suit_length(suit) >= 9:
            total += 2.0
            tallies.append((2.0, "9th card extra length"))
        if suit_length(suit) >= 10:
            total += 2.0
            tallies.append((2.0, "10th card extra length"))
        if suit_length(suit) >= 11:
            total += 2.0
            tallies.append((2.0, "11th card extra length"))
        if suit_length(suit) >= 12:
            total += 2.0
            tallies.append((2.0, "12th card extra length"))
        if suit_length(suit) == 13:
            total += 2.0
            tallies.append((2.0, "13th card extra length"))

    return Length_Points(total=total, tallies=tallies)


@dataclass
class Distribution_Points:
    total_suit: float
    total_nt: float
    tallies: list[tuple[float, str]]
    nt_only: list[tuple[float, str]]


def distribution_points(hand: Hand) -> Distribution_Points:
    total = 0.0
    tallies = []
    nt_only = []

    if is_4333_shape(hand):
        total -= 1.0
        tallies.append((-1.0, "4333 shape"))

    if count_doubleton(hand) == 2:
        total += 1.0
        tallies.append((1.0, "2 doubletons"))

    singletons = count_singleton(hand)
    if singletons:
        singleton_total = singletons * 2.0
        total += singleton_total

        tallies.append((singleton_total, f"{singletons} singleton(s)"))

        nt_only.append((-1.0 * singletons, "singletons at NT"))
        nt_only.append((-1.0, "declaring NT penalty with a singleton"))

    voids = count_void(hand)
    if voids:
        voids_total = 4.0 * voids
        total += voids_total
        tallies.append((voids_total, f"{voids} void(s)"))
        nt_only.append((-2.0, "voids at NT"))
        nt_only.append((-1.0, "declaring NT penalty with a void"))

    total_suit = total
    total_nt = total_suit + sum(x for (x, _) in nt_only)

    return Distribution_Points(total_suit=total_suit, total_nt=total_nt, tallies=tallies, nt_only=nt_only)


@dataclass
class Starting_Points:
    total_opening_suit: float
    total_opening_nt: float
    total_non_opening_suit: float
    total_non_opening_nt: float
    H: Honour_Points
    L: Length_Points
    D: Distribution_Points


def hld(h_points: Honour_Points, l_points: Length_Points, d_points: Distribution_Points) -> Starting_Points:
    total_opening_suit = l_points.total + h_points.total_opening + d_points.total_suit
    total_opening_nt = l_points.total + h_points.total_opening + d_points.total_nt
    total_non_opening_suit = l_points.total + h_points.total_non_opening + d_points.total_suit
    total_non_opening_nt = l_points.total + h_points.total_non_opening + d_points.total_nt

    return Starting_Points(
        H=h_points,
        L=l_points,
        D=d_points,
        total_opening_suit=total_opening_suit,
        total_opening_nt=total_opening_nt,
        total_non_opening_suit=total_non_opening_suit,
        total_non_opening_nt=total_non_opening_nt,
    )


@dataclass
class With_Partners_Long_Suit:
    potential_adjustments: list[tuple[float, str]]


def with_partners_long_suit(hand: Hand) -> With_Partners_Long_Suit:
    potential_adjustments = []
    for suit in hand.suits:
        if suit_length(suit) == 0:
            potential_adjustments.append((-3.0, "misfit: void opposite long suit"))
        if suit_length(suit) == 1:
            potential_adjustments.append((-2.0, f"misfit ({suit}): singleton opposite long suit"))
        if suit_length(suit) == 2 and suit.xs == 2:
            potential_adjustments.append((-1.0, "misfit: xx opposite long suit"))

        if is_kx_qx_jx_j10_doubleton(suit):
            potential_adjustments.append((1.0, f"semi-fit ({suit}): Kx/Qx/Jx/J10 opposite long suit"))

    potential_adjustments.append((-1.0, "misfit: per mirror suit when partner has a long suit"))
    potential_adjustments.append((-2.0, "misfit: mirror hand when partner has a long suit"))

    return With_Partners_Long_Suit(potential_adjustments=potential_adjustments)


@dataclass
class With_Partners_Shortage:
    potential_adjustments: list[tuple[float, str]]


def with_partners_shortage(hand: Hand) -> With_Partners_Shortage:
    potential_adjustments = []
    for suit in hand.suits:
        if any(hon in suit.honours for hon in [Honour.King, Honour.Queen, Honour.Jack]):
            potential_adjustments.append((-2.0, f"wasted honours ({suit}): honour except Ace opposite singleton"))
            potential_adjustments.append((-3.0, f"wasted honours ({suit}): honour except Ace opposite void"))

        if not any(hon in suit.honours for hon in [Honour.King, Honour.Queen, Honour.Jack]):
            if Honour.Ace not in suit.honours:
                potential_adjustments.append((2.0, f"(no) wasted honours ({suit}): opposite singleton"))
                potential_adjustments.append((3.0, f"(no) wasted honours ({suit}): opposite void"))
            else:
                potential_adjustments.append((1.0, f"(no) wasted honours ({suit}): isolated Ace opposite singleton"))

    return With_Partners_Shortage(potential_adjustments=potential_adjustments)


@dataclass
class Fitting_Weak_Honours:
    potential_adjustments: list[tuple[float, str]]


def fitting_weak_honours(hand: Hand) -> Fitting_Weak_Honours:
    potential_adjustments = []

    for suit in hand.suits:
        # Must be < 4 optimal points. QJ10 would be 4 points in OPC
        if milton_hcp(suit) < 4 and not has_all_honours(suit, {Honour.Queen, Honour.Jack, Honour.Ten}):
            if picture_honours_count(suit) >= 1:
                potential_adjustments.append((1.0, f"upgrade weak honour(s) < 4 points ({suit}): with 8+ fit"))

    return Fitting_Weak_Honours(potential_adjustments=potential_adjustments)


@dataclass
class OPC_Summary:
    hand: Hand
    hand_validation: str
    hand_text_summary: str
    hld: Starting_Points
    with_long: With_Partners_Long_Suit
    with_short: With_Partners_Shortage
    weak_fit: Fitting_Weak_Honours


def opc_calculation(suit_args: list[str], verbose: bool = False) -> OPC_Summary:
    suits = [parse_rough_suit(suit_arg) for suit_arg in suit_args]
    # fill in missing / implicit voids
    voids = 4 - len(suits)
    for _ in range(voids):
        suits.append(SuitHolding(honours=[], xs=0))

    hand_text_summary = " ".join(str(s) for s in suits)

    hand = Hand(suits)
    if verbose:
        pp(hand)

    invalid_msg = validate_hand(hand)
    if invalid_msg is not None:
        hand_validation = f'"{hand_text_summary}" is not a valid hand "{invalid_msg}"'
    else:
        hand_validation = hand_text_summary

    H_values = honour_points(hand)
    L_values = length_points(hand)
    D_values = distribution_points(hand)
    hld_values = hld(H_values, L_values, D_values)
    single_long_suit_adjustment = with_partners_long_suit(hand)
    weak_honour_fits = fitting_weak_honours(hand)
    single_short_suit_adjustment = with_partners_shortage(hand)

    return OPC_Summary(
        hand=hand,
        hand_text_summary=hand_text_summary,
        hand_validation=hand_validation,
        hld=hld_values,
        with_long=single_long_suit_adjustment,
        with_short=single_short_suit_adjustment,
        weak_fit=weak_honour_fits,
    )


TRICK_CONVERSIONS = """
    2 level
    NT:   22 23 24  (~40-45%, ~50-55%, ~60%+ success)
    Suit: 20 21 22

    3 level
    NT:   25 26 27  (~40-45%, ~50-55%, ~60%+ success)
    Suit: 23 24 25

    4 level
    NT:   28 29 30  (~40-45%, ~50-55%, ~60%+ success)
    Suit: 26 27 28

    5 level
    NT:   31 32 33  (~40-45%, ~50-55%, ~60%+ success)
    Suit: 29 30 31

    6 level
    NT:   33 34 35  (~50%, ~55-60%, ~65%+ success)
    Suit: 32 33 34

    7 level
    NT:   36 37 +  (~70%, ~70-75%, ~75%+ success)
    Suit: 35 36 +
    """

TRICK_CONVERSIONS_MD = """
## 2 level
__NT__:   22 __23__ 24  (~40-45%, ~50-55%, ~60%+ success)

__Suit__: 20 __21__ 22

## 3 level
__NT__:   25 __26__ 27  (~40-45%, ~50-55%, ~60%+ success)

__Suit__: 23 __24__ 25

## 4 level
__NT__:   28 __29__ 30  (~40-45%, ~50-55%, ~60%+ success)

__Suit__: 26 __27__ 28


## 5 level
__NT__:   31 __32__ 33  (~40-45%, ~50-55%, ~60%+ success)

__Suit__: 29 __30__ 31


## 6 level
__NT__:   33 __34__ 35  (~50%, ~55-60%, ~65%+ success)

__Suit__: 32 __33__ 34

## 7 level
__NT__:   36 __37__ +  (~70%, ~70-75%, ~75%+ success)

__Suit__: 35 __36__ +
"""


def render_summary(summary: OPC_Summary, include_trick_conversion: bool = True) -> str:
    buffer = io.StringIO()
    import pprint

    printer = pprint.PrettyPrinter(stream=buffer, width=120)

    print(f"{summary.hand_validation}", file=buffer)

    print("\n------------------------------------------------", file=buffer)
    print("* Our hand in isolation\n", file=buffer)
    printer.pprint(summary.hld)

    print("\n! Responder/Advancer only includes max 2 (L)ength points and the -1 4333 (D)istribution points, UNLESS opener/overcaller bids NT\n", file=buffer)

    print("\n------------------------------------------------", file=buffer)
    print("* Overcalling Adjustments\n", file=buffer)

    print("""Suit overcall Length changes
    -1 for 3 cards in their suit
    -2 for 4 cards in their suit
    -3 for 5 cards in their suit
    +1 for singleton/void (in additional to existing (D)istribution points)
    """, file=buffer)

    print("""Suit overcall Honour changes
    -0.5 side or opponent's suit: isolated Jack
    -1 side or opponent's suit: isolated Kxx/Kxxx (3 or 4 card suit) ANY position
    -1 opponent's suit KQ sat UNDER
    +1 opponent's suit KQ sat OVER
    """, file=buffer)

    print("""NT overcall Length downgrades
    -1 for 4 cards in their suit
    -2 for 5 cards in their suit
    """, file=buffer)

    print("""NT overcall Honour downgrades
    -1 isolated Kxx/Kxxx  (3 or 4 card suit)
    -0.5 isolated Jack
    """, file=buffer)

    print("\n------------------------------------------------", file=buffer)
    print("* Calculations that depend on partner's hand\n", file=buffer)

    print("Opposite any 5+ card suit:", file=buffer)
    printer.pprint(summary.with_long)

    print(file=buffer)
    print("Opposite any shortage:", file=buffer)
    printer.pprint(summary.with_short)

    print(file=buffer)
    print("Weak honour improvements for any fit:", file=buffer)
    printer.pprint(summary.weak_fit)

    print(file=buffer)
    print(
        """Fit points (both suit and NT contracts):
    +1 per 8 card fit
    +2 per 9 card fit
    +3 per 10+ card fit
    """,
        file=buffer,
    )

    print(
        """Distribution-Fit points (suit contracts, max 4 trump support only):
    * With 2 to 4 card support: for the *SHORTEST* suit only add the support hand's trump length minus that shortage length (e.g. 4 trumps and a singleton +3 points)
    * With 5(+) card support: only treat as a long suit, add (D)istribution points for shortages as an opening hand would
    """,
        file=buffer,
    )

    if include_trick_conversion:
        print("\n------------------------------------------------", file=buffer)
        print("* Trick conversions", file=buffer)

        print(TRICK_CONVERSIONS, file=buffer)

    return buffer.getvalue()


def main():
    import sys

    args = sys.argv[1:]

    def is_verbose_arg(s: str) -> bool:
        return s.lower() == "-v" or s == "--verbose"

    suit_args = []
    verbose = False
    for arg in args:
        if is_verbose_arg(arg):
            verbose = True
        else:
            suit_args.append(arg)

    summary = opc_calculation(suit_args, verbose=verbose)
    text_report = render_summary(summary, False)
    print(text_report)


if __name__ == "__main__":
    main()
