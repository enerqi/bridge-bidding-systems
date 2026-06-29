package bidding

/*
	helpers.odin — small shared building blocks for the ported predicates.

	These mirror idioms that recur all over `deal-utils.tcl`: the `5CM_nt $hand min max` shape+range
	test, pattern-equality checks against the sorted suit lengths, and the system's custom `AQJ`/`KQJ`
	honour-combo vectors. They are package-private (`@(private)`) — implementation detail of the
	conditions, not part of the engine surface.
*/

import "norn:norn"

// `5CM_nt $hand low high`: a notrump shape (4-3-3-3 / 4-4-3-2 / 5-3-3-2) with hcp in [low, high].
// The shape test itself lives in `norn` (`is_nt5cM_shape`); pairing it with an hcp band is policy.
@(private)
nt5cM :: proc(hand: norn.Hand_Summary, low, high: int) -> bool {
	if !norn.is_nt5cM_shape(hand) {
		return false
	}
	points := norn.hcp(hand)
	return points >= low && points <= high
}

// Does the hand's pattern (the four suit lengths sorted high-to-low) equal a-b-c-d? This is the Odin
// form of deal's `[$hand pattern] == "a b c d"`.
@(private)
has_pattern :: proc(hand: norn.Hand_Summary, a, b, c, d: int) -> bool {
	return norn.pattern(hand) == [norn.SUIT_COUNT]int{a, b, c, d}
}

// The system's `defvector AQJ 1 0 1 1`: does the hand hold ace, queen AND jack of `suit` (king not
// required)? Used by `is_4cd_swedish_club_response` to spot a near-solid suit missing the king.
@(private)
has_aqj :: proc(hand: norn.Hand_Summary, suit: norn.Suit) -> bool {
	return(
		norn.holds(hand, suit, .Ace) &&
		norn.holds(hand, suit, .Queen) &&
		norn.holds(hand, suit, .Jack) \
	)
}

// The system's `defvector KQJ 0 1 1 1`: does the hand hold king, queen AND jack of `suit` (ace not
// required)? The "missing the ace" sibling of `has_aqj`.
@(private)
has_kqj :: proc(hand: norn.Hand_Summary, suit: norn.Suit) -> bool {
	return(
		norn.holds(hand, suit, .King) &&
		norn.holds(hand, suit, .Queen) &&
		norn.holds(hand, suit, .Jack) \
	)
}
