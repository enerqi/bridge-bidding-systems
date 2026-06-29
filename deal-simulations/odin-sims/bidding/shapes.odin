package bidding

/*
	shapes.odin — shape and suit-quality helpers (deal-utils batch 1).

	These are the low-level predicates the openers / preempts / responses are built from: suit
	quality (`long_semi_solid`, `good_6_plus_suit`), two-suited shape sets (`two_suiter` and friends),
	minor/major shape tests, and the trick-based `is_tricky_suit`. They are still system policy (which
	is why they live here, not in `norn`), but they carry no bidding meaning on their own.
*/

import "norn:norn"

// A long, near-solid suit: 7+ cards with a Top5Q of 6+ (e.g. two of the top three honours plus
// length, or AKQ). (deal-utils `long_semi_solid`.)
long_semi_solid :: proc(hand: norn.Hand_Summary, suit: norn.Suit) -> bool {
	return norn.top5q(hand, suit) >= 6 && norn.suit_length(hand, suit) >= 7
}

// A good six-bagger: 6+ cards with a Top5Q of 4+ (roughly two of the top three honours).
// (deal-utils `good_6_plus_suit`.)
good_6_plus_suit :: proc(hand: norn.Hand_Summary, suit: norn.Suit) -> bool {
	return norn.top5q(hand, suit) >= 4 && norn.suit_length(hand, suit) >= 6
}

// Does the hand hold a good 6+ suit in any of the four suits? (deal-utils `any_good_6_plus_carder`.)
any_good_6_plus_carder :: proc(hand: norn.Hand_Summary) -> bool {
	return(
		good_6_plus_suit(hand, .Spades) ||
		good_6_plus_suit(hand, .Hearts) ||
		good_6_plus_suit(hand, .Diamonds) ||
		good_6_plus_suit(hand, .Clubs) \
	)
}

// A classic two-suited shape: one of the 5-5, 6-4, 6-5, 7-4 or 7-5 patterns. (deal-utils
// `two_suiter`.)
two_suiter :: proc(hand: norn.Hand_Summary) -> bool {
	return(
		has_pattern(hand, 5, 5, 2, 1) ||
		has_pattern(hand, 5, 5, 3, 0) ||
		has_pattern(hand, 6, 4, 2, 1) ||
		has_pattern(hand, 6, 4, 3, 0) ||
		has_pattern(hand, 6, 5, 2, 0) ||
		has_pattern(hand, 6, 5, 1, 1) ||
		has_pattern(hand, 7, 4, 1, 1) ||
		has_pattern(hand, 7, 4, 2, 0) ||
		has_pattern(hand, 7, 5, 1, 0) \
	)
}

// A 6-4 or 7-3 shape (a six- or seven-card suit with exactly ten cards in the two longest suits).
// (deal-utils `is_6_plus_other_10_card_two_suiter`.)
is_6_plus_other_10_card_two_suiter :: proc(hand: norn.Hand_Summary) -> bool {
	return(
		has_pattern(hand, 6, 4, 2, 1) ||
		has_pattern(hand, 6, 4, 3, 0) ||
		has_pattern(hand, 7, 3, 2, 1) ||
		has_pattern(hand, 7, 3, 3, 0) \
	)
}

// A wide-ranging "asymmetric" two-suiter set: 6-4, 6-5, 7-4, 7-5 or 8-4. (deal-utils
// `is_asymmetric_10_plus_two_suiter`.)
is_asymmetric_10_plus_two_suiter :: proc(hand: norn.Hand_Summary) -> bool {
	return(
		has_pattern(hand, 6, 4, 2, 1) ||
		has_pattern(hand, 6, 4, 3, 0) ||
		has_pattern(hand, 6, 5, 2, 0) ||
		has_pattern(hand, 6, 5, 1, 1) ||
		has_pattern(hand, 7, 4, 1, 1) ||
		has_pattern(hand, 7, 4, 2, 0) ||
		has_pattern(hand, 7, 5, 1, 0) ||
		has_pattern(hand, 8, 4, 1, 0) \
	)
}

// Eleven+ cards in the two longest suits: 6-5, 6-6, 7-4, 7-5 or 8-4. (deal-utils
// `is_6_plus_other_11_or_more_card_two_suiter`.)
is_6_plus_other_11_or_more_card_two_suiter :: proc(hand: norn.Hand_Summary) -> bool {
	return(
		has_pattern(hand, 6, 5, 2, 0) ||
		has_pattern(hand, 6, 5, 1, 1) ||
		has_pattern(hand, 6, 6, 1, 0) ||
		has_pattern(hand, 7, 4, 1, 1) ||
		has_pattern(hand, 7, 4, 2, 0) ||
		has_pattern(hand, 7, 5, 1, 0) ||
		has_pattern(hand, 8, 4, 1, 0) \
	)
}

// Exactly four spades and four hearts. (deal-utils `majors_4_4`.)
majors_4_4 :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.spade_length(hand) == 4 && norn.heart_length(hand) == 4
}

// An unbalanced hand whose longest suit is a minor: not flattish, with a minor strictly longer than
// both majors. (deal-utils `is_unbalanced_minor`.)
is_unbalanced_minor :: proc(hand: norn.Hand_Summary) -> bool {
	ss := norn.spade_length(hand)
	hs := norn.heart_length(hand)
	ds := norn.diamond_length(hand)
	cs := norn.club_length(hand)
	if is_flattish(hand) {
		return false
	}
	return (ds > hs && ds > ss) || (cs > hs && cs > ss)
}

// Nine+ cards in the two majors combined. (deal-utils `has_9_plus_majors`.)
has_9_plus_majors :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.spade_length(hand) + norn.heart_length(hand) >= 9
}

// A four-card-or-longer major on the side. (deal-utils `has_side_major`.)
has_side_major :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.spade_length(hand) >= 4 || norn.heart_length(hand) >= 4
}

// Does the hand hold an n-card-or-longer suit anywhere? (deal-utils `has_n_plus_carder`.)
has_n_plus_carder :: proc(hand: norn.Hand_Summary, n: int) -> bool {
	return(
		norn.spade_length(hand) >= n ||
		norn.heart_length(hand) >= n ||
		norn.diamond_length(hand) >= n ||
		norn.club_length(hand) >= n \
	)
}

// Both minors: 9+ cards combined with at least four of each. (deal-utils `both_minors`.)
both_minors :: proc(hand: norn.Hand_Summary) -> bool {
	cs := norn.club_length(hand)
	ds := norn.diamond_length(hand)
	return cs + ds >= 9 && cs >= 4 && ds >= 4
}

// Shortness (singleton or void) in at least one major. (deal-utils `singleton_or_void_major`.)
singleton_or_void_major :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.spade_length(hand) <= 1 || norn.heart_length(hand) <= 1
}

// Shortness in any suit at all. (deal-utils `any_singleton_or_void`.)
any_singleton_or_void :: proc(hand: norn.Hand_Summary) -> bool {
	return(
		norn.spade_length(hand) <= 1 ||
		norn.heart_length(hand) <= 1 ||
		norn.diamond_length(hand) <= 1 ||
		norn.club_length(hand) <= 1 \
	)
}

// A suit with real offensive potential: more than three estimated offensive tricks. (deal-utils
// `is_tricky_suit`.)
is_tricky_suit :: proc(hand: norn.Hand_Summary, suit: norn.Suit) -> bool {
	return norn.offense(hand, suit) > 3
}

// An ace held WITHOUT the king in `suit` — a "side ace". (deal-utils `side_ace`: `Ace==1 &&
// AceKing==1`, i.e. exactly one of the top two and it's the ace.)
side_ace :: proc(hand: norn.Hand_Summary, suit: norn.Suit) -> bool {
	return norn.holds(hand, suit, .Ace) && norn.top_count(hand, suit, 2) == 1
}

// Does the responder hold `support_length`+ cards in a 5+ card major the opener has? A two-hand
// test (opener and responder), so it takes both hands explicitly. (deal-utils `has_major_support`.)
has_major_support :: proc(opener, responder: norn.Hand_Summary, support_length: int) -> bool {
	opener_s := norn.spade_length(opener)
	opener_h := norn.heart_length(opener)
	resp_s := norn.spade_length(responder)
	resp_h := norn.heart_length(responder)
	return(
		(opener_s >= 5 && resp_s >= support_length) ||
		(opener_h >= 5 && resp_h >= support_length) \
	)
}
