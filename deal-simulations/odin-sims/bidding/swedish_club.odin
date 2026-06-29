package bidding

/*
	swedish_club.odin — responses to the artificial 1C and 1D openings (deal-utils batch 4).

	The "Swedish club" response structure: the 1D negative, the various 1NT rebuilds, the 2-level
	positives, and the solid-suit slam-try responses (3NT / 4-of-a-major). Plus the 1D-opening
	response family (inverted raise, weak jump shift, splinter, diamond preempt). These lean on the
	batch 1-3 helpers and on the system's `AQJ`/`KQJ` honour combos.
*/

import "norn:norn"

// A 1NT response to 1C showing a Marmic (4-4-4-1) 12+. (deal-utils `is_1n_marmic_swedish_club_resp`.)
is_1n_marmic_swedish_club_resp :: proc(hand: norn.HandSummary) -> bool {
	return is_marmic(hand) && norn.hcp(hand) >= 12
}

// The 2S "both minors" positive response: both minors with a major shortage, 9-11. (deal-utils
// `is_2s_swedish_club_resp`.)
is_2s_swedish_club_resp :: proc(hand: norn.HandSummary) -> bool {
	points := norn.hcp(hand)
	return both_minors(hand) && singleton_or_void_major(hand) && points >= 9 && points <= 11
}

// The 2C/2D positive: no side major, not flattish, 7-10. (deal-utils `is_2cd_swedish_club_resp`.)
is_2cd_swedish_club_resp :: proc(hand: norn.HandSummary) -> bool {
	points := norn.hcp(hand)
	return !has_side_major(hand) && !is_flattish(hand) && points >= 7 && points <= 10
}

// The 2H/2NT positive: no side major, flattish, 9-12. (deal-utils `is_2h_or_2n_swedish_club_resp`.)
is_2h_or_2n_swedish_club_resp :: proc(hand: norn.HandSummary) -> bool {
	points := norn.hcp(hand)
	return !has_side_major(hand) && is_flattish(hand) && points >= 9 && points <= 12
}

// The 1D negative-ish response to 1C: 0-9, not strong enough (or wrong-shaped) for the 1M / minor /
// 2S / preempt / weak-two responses. (deal-utils `is_1d_swedish_club_resp`.)
is_1d_swedish_club_resp :: proc(hand: norn.HandSummary) -> bool {
	points := norn.hcp(hand)
	if points > 9 {
		return false
	}
	// Not if worth a multi / weak-two response.
	if is_weak2_major_in_range(hand, 5, 7) {
		return false
	}
	// Not if worth a 1M response.
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	if (ss >= 4 || hs >= 4) && points >= 8 {
		return false
	}
	// Not if worth a minor response.
	cs := norn.club_length(hand)
	ds := norn.diamond_length(hand)
	if (cs >= 6 || ds >= 6) && points >= 8 {
		return false
	}
	// Not a 2S response.
	if is_2s_swedish_club_resp(hand) {
		return false
	}
	// Not a 3C/3D 6-carder positive (7 with all top honours).
	if (cs >= 6 || ds >= 6) &&
	   points == 7 &&
	   (norn.top_count(hand, .Clubs, 4) == 3 || norn.top_count(hand, .Diamonds, 4) == 3) {
		return false
	}
	// Not a preempt response.
	if is_3x_preempt_swedish_club_response(hand) {
		return false
	}
	return true
}

// A minor-suit positive response to 1C: a 2S hand, or an 11+ unbalanced-minor / both-minors hand.
// (deal-utils `is_minor_swedish_club_positive_response`.)
is_minor_swedish_club_positive_response :: proc(hand: norn.HandSummary) -> bool {
	if is_2s_swedish_club_resp(hand) {
		return true
	}
	if !(is_unbalanced_minor(hand) || both_minors(hand)) {
		return false
	}
	return norn.hcp(hand) >= 11
}

// A 1NT response showing an unbalanced minor 12+ (no side major, not a 2S hand, not balanced).
// (deal-utils `is_1n_unbal_minor_swedish_club_resp`.)
is_1n_unbal_minor_swedish_club_resp :: proc(hand: norn.HandSummary) -> bool {
	if norn.hcp(hand) < 12 {
		return false
	}
	if has_side_major(hand) || is_2s_swedish_club_resp(hand) || norn.is_balanced(hand) {
		return false
	}
	return true
}

// The older balanced 1NT response: balanced 12+. (deal-utils `is_old_1n_bal_swedish_club_response`.)
is_old_1n_bal_swedish_club_response :: proc(hand: norn.HandSummary) -> bool {
	if norn.hcp(hand) < 12 {
		return false
	}
	return norn.is_balanced(hand)
}

// Any of the 1NT responses (balanced, unbalanced-minor, or Marmic). (deal-utils
// `is_any_1n_swedish_club_response`.)
is_any_1n_swedish_club_response :: proc(hand: norn.HandSummary) -> bool {
	return(
		is_old_1n_bal_swedish_club_response(hand) ||
		is_1n_unbal_minor_swedish_club_resp(hand) ||
		is_1n_marmic_swedish_club_resp(hand) \
	)
}

// Exactly 3 control points and at most 12 hcp — the controlled, solid-suit profile the 3NT/4M
// responses share. (deal-utils `eq_3_control_points_and_max_12_hcp`.)
eq_3_control_points_and_max_12_hcp :: proc(hand: norn.HandSummary) -> bool {
	if norn.controls(hand) != 3 {
		return false
	}
	return norn.hcp(hand) <= 12
}

// A solid AKQJ holding in `suit`. (deal-utils `AKQJ`: `Top4 == 4`.)
is_akqj :: proc(hand: norn.HandSummary, suit: norn.Suit) -> bool {
	return norn.top_count(hand, suit, 4) == 4
}

// A 3NT response showing a totally solid (AKQJ) 6-card suit and no outside A/K. (deal-utils
// `is_3n_swedish_club_resp`.)
is_3n_swedish_club_resp :: proc(hand: norn.HandSummary) -> bool {
	if !eq_3_control_points_and_max_12_hcp(hand) {
		return false
	}
	return(
		(is_akqj(hand, .Spades) && norn.spade_length(hand) == 6) ||
		(is_akqj(hand, .Hearts) && norn.heart_length(hand) == 6) ||
		(is_akqj(hand, .Diamonds) && norn.diamond_length(hand) == 6) ||
		(is_akqj(hand, .Clubs) && norn.club_length(hand) == 6) \
	)
}

// A 4-of-a-minor response showing a solid-but-for-one-top-honour 8-card major and no outside top
// honours. (deal-utils `is_4cd_swedish_club_response`.)
//
// NOTE: the original's leading `if {![hcp $hand]>10}` guard is a no-op in Tcl (it parses as
// `(!hcp) > 10`, never true), so it is intentionally omitted here — the 8-card-suit body is the
// whole of the real test.
is_4cd_swedish_club_response :: proc(hand: norn.HandSummary) -> bool {
	// A spade 8-bagger headed by AQJ or KQJ (missing one top honour), nothing else of note.
	if norn.top_count(hand, .Spades, 4) != 4 &&
	   (has_aqj(hand, .Spades) || has_kqj(hand, .Spades)) &&
	   norn.spade_length(hand) == 8 &&
	   norn.top_count(hand, .Hearts, 2) == 0 &&
	   norn.top_count(hand, .Diamonds, 2) == 0 &&
	   norn.top_count(hand, .Clubs, 2) == 0 {
		return true
	}
	if norn.top_count(hand, .Hearts, 4) != 4 &&
	   (has_aqj(hand, .Hearts) || has_kqj(hand, .Hearts)) &&
	   norn.heart_length(hand) == 8 &&
	   norn.top_count(hand, .Spades, 2) == 0 &&
	   norn.top_count(hand, .Diamonds, 2) == 0 &&
	   norn.top_count(hand, .Clubs, 2) == 0 {
		return true
	}
	return false
}

// A 4-of-a-major response showing a totally solid (AKQJ) 7-card major. (deal-utils
// `is_4hs_swedish_club_response`.)
is_4hs_swedish_club_response :: proc(hand: norn.HandSummary) -> bool {
	if !eq_3_control_points_and_max_12_hcp(hand) {
		return false
	}
	return(
		(is_akqj(hand, .Spades) && norn.spade_length(hand) == 7) ||
		(is_akqj(hand, .Hearts) && norn.heart_length(hand) == 7) \
	)
}

// A 3-level preempt response to 1C: at most 7 hcp and one of the preempt shapes. (deal-utils
// `is_3x_preempt_swedish_club_response`.)
is_3x_preempt_swedish_club_response :: proc(hand: norn.HandSummary) -> bool {
	if norn.hcp(hand) > 7 {
		return false
	}
	return(
		is_shapely_minor_preempt(hand) ||
		is_standard_3cd_7carder(hand) ||
		is_likely_3major_preempt(hand) ||
		is_likely_4level_preempt(hand) \
	)
}

// --- Responses to a 1D opening ---

// A possible inverted diamond raise: 10+, no side major, 4+ diamonds. (deal-utils
// `is_possible_inverted_diamond_raise`.)
is_possible_inverted_diamond_raise :: proc(hand: norn.HandSummary) -> bool {
	if norn.hcp(hand) < 10 {
		return false
	}
	if has_side_major(hand) {
		return false
	}
	return norn.diamond_length(hand) >= 4
}

// A possible weak jump-shift response to 1D: sub-10 with a 6+ heart, spade or club suit. (deal-utils
// `is_possible_wjs_1d_response`.)
is_possible_wjs_1d_response :: proc(hand: norn.HandSummary) -> bool {
	if norn.hcp(hand) >= 10 {
		return false
	}
	return(
		norn.heart_length(hand) >= 6 ||
		norn.spade_length(hand) >= 6 ||
		norn.club_length(hand) >= 6 \
	)
}

// A possible splinter response to 1D: 13+, 6+ diamonds with a side singleton. (deal-utils
// `is_possible_splinter_1d_response`.)
is_possible_splinter_1d_response :: proc(hand: norn.HandSummary) -> bool {
	if norn.hcp(hand) < 13 {
		return false
	}
	if norn.diamond_length(hand) < 6 {
		return false
	}
	return(
		norn.club_length(hand) == 1 ||
		norn.heart_length(hand) == 1 ||
		norn.spade_length(hand) == 1 \
	)
}

// A possible diamond-preempt response to 1D: at most 10 hcp with 6+ diamonds. (deal-utils
// `is_possible_diamond_preempt_1d_response`.)
is_possible_diamond_preempt_1d_response :: proc(hand: norn.HandSummary) -> bool {
	if norn.hcp(hand) > 10 {
		return false
	}
	return norn.diamond_length(hand) >= 6
}
