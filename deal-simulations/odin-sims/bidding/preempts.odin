package bidding

/*
	preempts.odin — weak twos, preempts, and offensive-strength predicates (deal-utils batch 3).

	Weak/semi-positive two-bids in the majors, the various minor preempts, the offensive-trick tests
	the high preempts lean on (`any_offensive_suit` / `is_likely_4level_preempt` / …), and the
	loser-based powerhouse tests. Ports of the matching `deal-utils.tcl` procs.
*/

import "norn:norn"

// A weak hand (5-11) with any 6+ suit. (deal-utils `is_any_weak_6_plus_carder`.)
is_any_weak_6_plus_carder :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 5 || points > 11 {
		return false
	}
	return has_n_plus_carder(hand, 6)
}

// A weak-to-minimum hand (5-14) with any 7+ suit. (deal-utils `is_any_weak_or_min_7_plus_carder`.)
is_any_weak_or_min_7_plus_carder :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 5 || points > 14 {
		return false
	}
	return has_n_plus_carder(hand, 7)
}

// A generic weak 2D: 6-10, a 6-card diamond suit with an honour, no 4-card major, at most five
// clubs. (deal-utils `is_generic_weak2d`.)
is_generic_weak2d :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 6 || points > 10 {
		return false
	}
	if norn.spade_length(hand) >= 4 || norn.heart_length(hand) >= 4 {
		return false
	}
	if norn.diamond_length(hand) == 6 &&
	   norn.club_length(hand) <= 5 &&
	   norn.top_count(hand, .Diamonds, 4) >= 1 {
		return true
	}
	return false
}

// A generic 5-card unbalanced weak two: 6-10 with a 5-4-2-2 / 5-4-3-1 / 5-5-3-0 / 5-5-2-1 shape and
// a 5-card spade, heart or diamond suit (not both majors). (deal-utils `is_generic_5card_unbal_weak2`.)
is_generic_5card_unbal_weak2 :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 6 || points > 10 {
		return false
	}
	if has_pattern(hand, 5, 3, 3, 2) {
		return false
	}
	if !(has_pattern(hand, 5, 4, 2, 2) ||
		   has_pattern(hand, 5, 4, 3, 1) ||
		   has_pattern(hand, 5, 5, 3, 0) ||
		   has_pattern(hand, 5, 5, 2, 1)) {
		return false
	}
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	ds := norn.diamond_length(hand)
	if ss >= 4 && hs >= 4 {
		return false
	}
	return ss == 5 || hs == 5 || ds == 5
}

// A weak two on a 5-card major: 6-11 (weaker hands need 5-5 shape), an unbalanced 5-card-major
// shape, no 6-card minor, no second 4-card major, and 2+ honours in the major. (deal-utils
// `is_weak2_5card_major`.)
is_weak2_5card_major :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 6 || points > 11 {
		return false
	}
	if has_pattern(hand, 5, 3, 3, 2) {
		return false
	}
	if points < 7 && !has_pattern(hand, 5, 5, 3, 0) && !has_pattern(hand, 5, 5, 2, 1) {
		return false
	}
	if !(has_pattern(hand, 5, 4, 2, 2) ||
		   has_pattern(hand, 5, 4, 3, 1) ||
		   has_pattern(hand, 5, 5, 3, 0) ||
		   has_pattern(hand, 5, 5, 2, 1)) {
		return false
	}
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	if ss >= 4 && hs >= 4 {
		return false
	}
	if norn.diamond_length(hand) > 5 || norn.club_length(hand) > 5 {
		return false
	}
	return(
		(ss == 5 && norn.top_count(hand, .Spades, 4) >= 2) ||
		(hs == 5 && norn.top_count(hand, .Hearts, 4) >= 2) \
	)
}

// A standard weak two on a 6-card major: 6-11 (weaker hands need 6-4 shape; 6-5 hands cap at 9), no
// second 4-card major, no 6-card minor, 1+ honour in the major. (deal-utils `is_weak2_major`.)
is_weak2_major :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 6 || points > 11 {
		return false
	}
	if points < 7 && !has_pattern(hand, 6, 4, 2, 1) && !has_pattern(hand, 6, 4, 3, 0) {
		return false
	}
	if points > 9 && (has_pattern(hand, 6, 5, 1, 1) || has_pattern(hand, 6, 5, 2, 0)) {
		return false
	}
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	if ss >= 4 && hs >= 4 {
		return false
	}
	if norn.diamond_length(hand) > 5 || norn.club_length(hand) > 5 {
		return false
	}
	return(
		(ss == 6 && norn.top_count(hand, .Spades, 4) >= 1) ||
		(hs == 6 && norn.top_count(hand, .Hearts, 4) >= 1) \
	)
}

// Either flavour of weak major two-bid (5- or 6-card). (deal-utils `is_weak_5_or_6_card_major`.)
is_weak_5_or_6_card_major :: proc(hand: norn.Hand_Summary) -> bool {
	return is_weak2_major(hand) || is_weak2_5card_major(hand)
}

// A "semi-positive" weak two in hearts: a notch weaker (4-7) than a standard weak two but the same
// shape rules, on a 6-card heart suit with an honour. (deal-utils `is_semi_positive_weak_two_hearts`.)
is_semi_positive_weak_two_hearts :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 4 || points > 7 {
		return false
	}
	if points < 5 && !has_pattern(hand, 6, 4, 2, 1) && !has_pattern(hand, 6, 4, 3, 0) {
		return false
	}
	if points > 6 && (has_pattern(hand, 6, 5, 1, 1) || has_pattern(hand, 6, 5, 2, 0)) {
		return false
	}
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	if ss >= 4 && hs >= 4 {
		return false
	}
	if norn.diamond_length(hand) > 5 || norn.club_length(hand) > 5 {
		return false
	}
	return hs == 6 && norn.top_count(hand, .Hearts, 4) >= 1
}

// A semi-positive majors two-suiter: a 5-5+ two-suiter in the majors, 3-7 points (weak hands need
// 6-5 shape). (deal-utils `is_semi_positive_majors_two_suiter`.)
is_semi_positive_majors_two_suiter :: proc(hand: norn.Hand_Summary) -> bool {
	if !two_suiter(hand) {
		return false
	}
	if norn.heart_length(hand) < 5 || norn.spade_length(hand) < 5 {
		return false
	}
	points := norn.hcp(hand)
	if points < 3 || points > 7 {
		return false
	}
	if points < 5 && !has_pattern(hand, 6, 5, 1, 1) && !has_pattern(hand, 6, 5, 2, 0) {
		return false
	}
	return true
}

// A game-forcing majors two-suiter: 5-5+ in the majors, 6+ points (weak hands need 6-5 shape).
// (deal-utils `is_gf_majors_two_suiter`.)
is_gf_majors_two_suiter :: proc(hand: norn.Hand_Summary) -> bool {
	if !two_suiter(hand) {
		return false
	}
	if norn.heart_length(hand) < 5 || norn.spade_length(hand) < 5 {
		return false
	}
	points := norn.hcp(hand)
	if points < 6 {
		return false
	}
	if points < 7 && !has_pattern(hand, 6, 5, 1, 1) && !has_pattern(hand, 6, 5, 2, 0) {
		return false
	}
	return true
}

// A game-forcing hearts-and-a-minor two-suiter: 5+ hearts and a 5+ minor, 7+ points (weaker hands
// need 6-5 shape). (deal-utils `is_gf_hearts_minor_two_suiter`.)
is_gf_hearts_minor_two_suiter :: proc(hand: norn.Hand_Summary) -> bool {
	if !two_suiter(hand) {
		return false
	}
	hs := norn.heart_length(hand)
	cs := norn.club_length(hand)
	ds := norn.diamond_length(hand)
	if hs < 5 || (cs < 5 && ds < 5) {
		return false
	}
	points := norn.hcp(hand)
	if points < 7 {
		return false
	}
	if points < 9 && !has_pattern(hand, 6, 5, 1, 1) && !has_pattern(hand, 6, 5, 2, 0) {
		return false
	}
	return true
}

// A minors 2NT preempt: 6-11 with a 6-5 / 5-5 both-minors shape. (deal-utils `is_minors_2n_preempt`.)
is_minors_2n_preempt :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 6 || points > 11 {
		return false
	}
	if !(has_pattern(hand, 6, 5, 1, 1) ||
		   has_pattern(hand, 6, 5, 2, 0) ||
		   has_pattern(hand, 5, 5, 3, 0) ||
		   has_pattern(hand, 5, 5, 2, 1)) {
		return false
	}
	return norn.club_length(hand) >= 5 && norn.diamond_length(hand) >= 5
}

// A shapely minor preempt: sub-opening, no side major, limited controls, a 7+ minor with a side
// shortage. (deal-utils `is_shapely_minor_preempt`.)
is_shapely_minor_preempt :: proc(hand: norn.Hand_Summary) -> bool {
	if norn.hcp(hand) > 10 {
		return false
	}
	if has_side_major(hand) {
		return false
	}
	if norn.controls(hand) > 4 {
		return false
	}
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	ds := norn.diamond_length(hand)
	cs := norn.club_length(hand)
	if cs >= 7 && (ss <= 1 || hs <= 1 || ds <= 1) {
		return true
	}
	if ds >= 7 && (ss <= 1 || hs <= 1 || cs <= 1) {
		return true
	}
	return false
}

// A likely 3-major preempt: sub-opening with a 7+ major and no four cards in the other major.
// (deal-utils `is_likely_3major_preempt`.)
is_likely_3major_preempt :: proc(hand: norn.Hand_Summary) -> bool {
	if norn.hcp(hand) > 10 {
		return false
	}
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	return (ss >= 7 && hs < 4) || (hs >= 7 && ss < 4)
}

// Does any suit reach `offense_tricks` estimated offensive tricks? (deal-utils `any_offensive_suit`.)
any_offensive_suit :: proc(hand: norn.Hand_Summary, offense_tricks: int) -> bool {
	return(
		norn.offense(hand, .Clubs) >= offense_tricks ||
		norn.offense(hand, .Diamonds) >= offense_tricks ||
		norn.offense(hand, .Hearts) >= offense_tricks ||
		norn.offense(hand, .Spades) >= offense_tricks \
	)
}

// A likely 4-level preempt: at most 12 hcp, not a 7-2-2-2, with a suit worth ~7 offensive tricks.
// (deal-utils `is_likely_4level_preempt`.)
is_likely_4level_preempt :: proc(hand: norn.Hand_Summary) -> bool {
	if norn.hcp(hand) > 12 {
		return false
	}
	if has_pattern(hand, 7, 2, 2, 2) {
		return false
	}
	return any_offensive_suit(hand, 7)
}

// An "insane" offensive preempt: at most 13 hcp with a suit worth 8-9 offensive tricks. (deal-utils
// `is_insane_offensive_preempt`.)
is_insane_offensive_preempt :: proc(hand: norn.Hand_Summary) -> bool {
	if norn.hcp(hand) > 13 {
		return false
	}
	return any_offensive_suit(hand, 8) || any_offensive_suit(hand, 9)
}

// 8+ playing tricks: 14+ hcp and at most five losers. (deal-utils `is_8_plus_tricks`.)
is_8_plus_tricks :: proc(hand: norn.Hand_Summary) -> bool {
	if norn.hcp(hand) < 14 {
		return false
	}
	return norn.losers(hand) <= 5
}

// A powerhouse: at most `maxlosers` losing tricks. (deal-utils `is_powerhouse`.)
is_powerhouse :: proc(hand: norn.Hand_Summary, maxlosers: int) -> bool {
	return norn.losers(hand) <= maxlosers
}

// A potential 4NT (Blackwood/quantitative) opener: at most three losers. (deal-utils
// `is_potential_4n_opener`.)
is_potential_4n_opener :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.losers(hand) <= 3
}

// A weak two-bid in either red suit: 5-11 with 6+ hearts or 6+ diamonds. (deal-utils `is_weak_2DH`.)
is_weak_2DH :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 5 || points > 11 {
		return false
	}
	return norn.heart_length(hand) >= 6 || norn.diamond_length(hand) >= 6
}

// A weak major two-bid within an explicit point range, requiring 2+ honours in the 6-card major.
// (deal-utils `is_weak2_major_in_range`.)
is_weak2_major_in_range :: proc(hand: norn.Hand_Summary, low, high: int) -> bool {
	points := norn.hcp(hand)
	if points < low || points > high {
		return false
	}
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	if ss >= 4 && hs >= 4 {
		return false
	}
	if norn.diamond_length(hand) > 5 || norn.club_length(hand) > 5 {
		return false
	}
	return(
		(ss == 6 && norn.top_count(hand, .Spades, 4) >= 2) ||
		(hs == 6 && norn.top_count(hand, .Hearts, 4) >= 2) \
	)
}
