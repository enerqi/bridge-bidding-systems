package bidding

/*
	competitive.odin — overcalls and multi-seat competitive judgements (deal-utils batch 5).

	Single-hand overcalls (`is_1major_overcall`, `is_1d_takeout`, `has_both_majors_michaels`) plus the
	two genuinely multi-seat predicates that read several hands of the deal at once. The latter take a
	whole `norn.Deal_Summary` (rather than a single `norn.Hand_Summary`) because they reason about both sides — they
	compose directly as a `norn.Predicate`.
*/

import "norn:norn"

// A natural 1-major overcall: 8-16 with a 5+ major as the longest suit, not a 15-18 notrump.
// (deal-utils `is_1major_overcall`.)
is_1major_overcall :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 8 || points > 16 {
		return false
	}
	hs := norn.heart_length(hand)
	ss := norn.spade_length(hand)
	if hs < 5 && ss < 5 {
		return false
	}
	cs := norn.club_length(hand)
	ds := norn.diamond_length(hand)
	if cs > hs && cs > ss {
		return false
	}
	if ds > hs && ds > ss {
		return false
	}
	if nt5cM(hand, 15, 18) {
		return false
	}
	return true
}

// A 1D takeout-style action: 11+, short diamonds, not a 1-major overcall or 15-18 notrump.
// (deal-utils `is_1d_takeout`.)
is_1d_takeout :: proc(hand: norn.Hand_Summary) -> bool {
	if norn.hcp(hand) < 11 {
		return false
	}
	if is_1major_overcall(hand) {
		return false
	}
	if nt5cM(hand, 15, 18) {
		return false
	}
	return norn.diamond_length(hand) < 3
}

// A Michaels-style both-majors hand: 5-15 with 5+ cards in each major. (deal-utils
// `has_both_majors_michaels`.)
has_both_majors_michaels :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 5 || points > 15 {
		return false
	}
	return norn.heart_length(hand) >= 5 && norn.spade_length(hand) >= 5
}

// May North-South overcall the opponents' 1NT? A multi-seat judgement (East is assumed to open):
// reject the flat-vs-flat both-minimum case, and reject when South is flat or very weak while E-W
// rate to be game-going. `top_nt_range` is the top of the relevant notrump band. (deal-utils
// `north_south_may_overcall_1N`.)
north_south_may_overcall_1N :: proc(board: norn.Deal_Summary, top_nt_range: int) -> bool {
	north := board[.North]
	east := board[.East]
	south := board[.South]
	west := board[.West]

	s_hcp := norn.hcp(south)
	if is_flattish(south) &&
	   is_flattish(north) &&
	   s_hcp < top_nt_range &&
	   norn.hcp(north) < top_nt_range {
		return false
	}

	ew_game_going := norn.hcp(east) + norn.hcp(west) >= 24
	if (is_flattish(south) || s_hcp < 8) && ew_game_going {
		return false
	}
	return true
}

// May South overcall the opponents' 1NT with North holding an invitational hand? South must be
// shapely and not too strong, E-W limited, with North in an invitational 9-13 band. (deal-utils
// `south_may_overcall_opponents_1N_with_north_invitational`.)
south_may_overcall_opponents_1N_with_north_invitational :: proc(
	board: norn.Deal_Summary,
	top_nt_range: int,
) -> bool {
	north := board[.North]
	east := board[.East]
	south := board[.South]
	west := board[.West]

	s_hcp := norn.hcp(south)
	// Ignore penalty-double or flattish South hands.
	if is_flattish(south) || s_hcp >= top_nt_range {
		return false
	}
	if norn.hcp(east) + norn.hcp(west) >= 18 {
		return false
	}
	if s_hcp < 9 {
		return false
	}
	n_hcp := norn.hcp(north)
	if n_hcp < 9 || n_hcp > 13 {
		return false
	}
	return true
}
