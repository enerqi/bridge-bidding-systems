package bidding

/*
	openers.odin — opening-bid predicates (deal-utils batch 2).

	The system's opening structure: the artificial 1C (weak or strong), the prepared/limited 1D, the
	limited 1-major, the various notrump openers, the club-based 2C and diamond-based 2D, the gambling
	3NT, and the 3-level club/diamond preempts. Each is a near-mechanical port of the matching
	`deal-utils.tcl` proc and is written in terms of the `norn` primitives plus the batch-1 helpers.
*/

import "norn:norn"

// A weak (13-15) balanced 1C opening — the limited natural side of the artificial 1C. (deal-utils
// `is_weak_1c`.)
is_weak_1c :: proc(hand: norn.Hand_Summary) -> bool {
	return nt5cM(hand, 13, 15)
}

// Any artificial 1C opening: the weak balanced one or the strong one. (deal-utils
// `is_any_1c_opener`.)
is_any_1c_opener :: proc(hand: norn.Hand_Summary) -> bool {
	return is_weak_1c(hand) || is_strong_1c(hand)
}

// An unbalanced, limited (11-15) diamond opening: 4+ diamonds as the (co-)longest suit, not a hand
// that belongs in 2C or the intermediate 2D. (deal-utils `is_1d_unbal_opener`.)
is_1d_unbal_opener :: proc(hand: norn.Hand_Summary) -> bool {
	if is_flattish(hand) {
		return false
	}
	points := norn.hcp(hand)
	if points < 11 || points > 15 {
		return false
	}
	if is_2c_opener(hand) || is_2d_intermediate_opener(hand) {
		return false
	}
	ds := norn.diamond_length(hand)
	if ds < 4 || norn.spade_length(hand) >= ds || norn.heart_length(hand) >= ds {
		return false
	}
	return true
}

// A 1D opening: the unbalanced diamond hand, OR a balanced 11-13 that is not a 1-major hand.
// (deal-utils `is_1d_opener`.)
is_1d_opener :: proc(hand: norn.Hand_Summary) -> bool {
	if is_1d_unbal_opener(hand) {
		return true
	}
	if is_1major_opener(hand) {
		return false
	}
	return nt5cM(hand, 11, 13)
}

// A limited (11-15) 1-major opening: a 5+ card major as longest suit, not a 13-15 balanced (1C)
// hand and not a gambling 3NT. (deal-utils `is_1major_opener`.)
is_1major_opener :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 11 || points > 15 {
		return false
	}
	hs := norn.heart_length(hand)
	ss := norn.spade_length(hand)
	if hs < 5 && ss < 5 {
		return false
	}
	if nt5cM(hand, 13, 15) {
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
	if is_3n_opener(hand) {
		return false
	}
	return true
}

// A light (9-11) 1-major opening — same shape rules as `is_1major_opener`, lower point band.
// (deal-utils `is_light_1major_opener`.)
is_light_1major_opener :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 9 || points > 11 {
		return false
	}
	hs := norn.heart_length(hand)
	ss := norn.spade_length(hand)
	if hs < 5 && ss < 5 {
		return false
	}
	if nt5cM(hand, 13, 15) {
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
	if is_3n_opener(hand) {
		return false
	}
	return true
}

// A 16-18 balanced 1NT opening. (deal-utils `is_1nt_opener`.)
is_1nt_opener :: proc(hand: norn.Hand_Summary) -> bool {
	return nt5cM(hand, 16, 18)
}

// A 19-20 balanced 2NT opening. (deal-utils `is_2nt_opener`.)
is_2nt_opener :: proc(hand: norn.Hand_Summary) -> bool {
	return nt5cM(hand, 19, 20)
}

// The "Marmic" 4-4-4-1 shape. (deal-utils `is_marmic`.)
is_marmic :: proc(hand: norn.Hand_Summary) -> bool {
	return has_pattern(hand, 4, 4, 4, 1)
}

// A club-based 2C opening: a 6+ club one-suiter, 11-15 (or a 10-point 7-card club suit), with no
// other 6+ suit. (deal-utils `is_2c_opener`.)
is_2c_opener :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	clublen := norn.club_length(hand)
	min_7carder := points == 10 && clublen == 7
	long_other :=
		norn.spade_length(hand) > 5 || norn.heart_length(hand) > 5 || norn.diamond_length(hand) > 5
	if !long_other && (min_7carder || (clublen >= 6 && points >= 11)) && points <= 15 {
		return true
	}
	return false
}

// A diamond-based 2D opening: a 4-4-1-4 12-16, or a 4-4-0-5 / 4-3-1-5 / 3-4-1-5 11-15. (deal-utils
// `is_2d_opener`.) `norn.shape` is in S-H-D-C order, matching deal's `[$hand shape]`.
is_2d_opener :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	shdc := norn.shape(hand)
	if shdc == ([norn.SUIT_COUNT]int{4, 4, 1, 4}) && points >= 12 && points <= 16 {
		return true
	}
	if (shdc == ([norn.SUIT_COUNT]int{4, 4, 0, 5}) ||
		   shdc == ([norn.SUIT_COUNT]int{4, 3, 1, 5}) ||
		   shdc == ([norn.SUIT_COUNT]int{3, 4, 1, 5})) &&
	   points >= 11 &&
	   points <= 15 {
		return true
	}
	return false
}

// The intermediate (9-15) 2D opening: 6+ diamonds as the longest suit, no 5+ major, weaker hands
// needing extra two-suited shape. (deal-utils `is_2d_intermediate_opener`.)
is_2d_intermediate_opener :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 9 || points > 15 {
		return false
	}
	cs := norn.club_length(hand)
	ds := norn.diamond_length(hand)
	hs := norn.heart_length(hand)
	ss := norn.spade_length(hand)
	if ds < 6 || ds < cs || hs > 4 || ss > 4 {
		return false
	}
	// 9/10 counts need extra shape.
	if points == 9 && !is_6_plus_other_11_or_more_card_two_suiter(hand) {
		return false
	}
	if points == 10 &&
	   !is_6_plus_other_10_card_two_suiter(hand) &&
	   !is_6_plus_other_11_or_more_card_two_suiter(hand) {
		return false
	}
	return true
}

// A gambling-3NT opening: a long near-solid major (AK-headed plus a side ace, or AK twice over) in
// an 8-14 hand with limited controls and not a 7-2-2-2. (deal-utils `is_3n_opener`.)
is_3n_opener :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 8 || points > 14 {
		return false
	}
	if norn.controls(hand) > 5 {
		return false
	}
	if has_pattern(hand, 7, 2, 2, 2) {
		return false
	}
	if long_semi_solid(hand, .Spades) &&
	   ((norn.top_count(hand, .Spades, 2) == 1 &&
				   (side_ace(hand, .Hearts) ||
						   side_ace(hand, .Diamonds) ||
						   side_ace(hand, .Clubs))) ||
			   (norn.top_count(hand, .Spades, 2) == 2)) {
		return true
	}
	if long_semi_solid(hand, .Hearts) &&
	   ((norn.top_count(hand, .Hearts, 2) == 1 &&
				   (side_ace(hand, .Spades) ||
						   side_ace(hand, .Diamonds) ||
						   side_ace(hand, .Clubs))) ||
			   (norn.top_count(hand, .Hearts, 2) == 2)) {
		return true
	}
	return false
}

// A standard prepared 1-minor opening (natural systems): 11-21, longest suit a minor (or balanced
// without a 5-card major), excluding the 15-17 notrump and a flat 20+. (deal-utils
// `opens_std_1minor_prepared`.)
opens_std_1minor_prepared :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 11 || points > 21 {
		return false
	}
	cs := norn.club_length(hand)
	ds := norn.diamond_length(hand)
	hs := norn.heart_length(hand)
	ss := norn.spade_length(hand)
	if nt5cM(hand, 15, 17) {
		return false
	}
	if is_flattish(hand) && points >= 20 {
		return false
	}
	if (cs > hs && cs > ss) || (ds > hs && ds > ss) {
		return true
	}
	if hs >= 5 || ss >= 5 {
		return false
	}
	return true
}

// A 3C/3D preempt in 1st/2nd seat: sub-opening, no side major, limited controls, with a tricky
// (offensive) minor. (deal-utils `is_3cd_opener_1st2nd`.)
is_3cd_opener_1st2nd :: proc(hand: norn.Hand_Summary) -> bool {
	if norn.hcp(hand) > 11 {
		return false
	}
	if has_side_major(hand) {
		return false
	}
	if norn.controls(hand) > 4 {
		return false
	}
	return is_tricky_suit(hand, .Clubs) || is_tricky_suit(hand, .Diamonds)
}

// A standard 3C/3D preempt on a 7-card minor: sub-opening, no side major, very limited controls, a
// 7-card minor missing top honours with no other long minor. (deal-utils `is_standard_3cd_7carder`.)
is_standard_3cd_7carder :: proc(hand: norn.Hand_Summary) -> bool {
	if norn.hcp(hand) > 11 {
		return false
	}
	if has_side_major(hand) {
		return false
	}
	if norn.controls(hand) > 3 {
		return false
	}
	cs := norn.club_length(hand)
	ds := norn.diamond_length(hand)
	// Tcl precedence (&& over ||): a club 7-bagger with short diamonds, OR a diamond 7-bagger AND
	// short clubs. The asymmetry is faithfully ported from the original.
	if (cs == 7 && norn.top_count(hand, .Clubs, 4) <= 2 && ds < 4) ||
	   (ds == 7 && norn.top_count(hand, .Diamonds, 4) <= 2) && cs < 4 {
		return true
	}
	return false
}
