package bidding

/*
	conditions_more_test.odin — unit tests for the ported deal-utils predicates.

	`conditions_test.odin` covers the original proof predicates; this file covers batches 1-5. To
	keep the many 13-card hands readable, hands are built with `hand_of(spades, hearts, diamonds,
	clubs)` from rank lists, and ranks have single-letter aliases. Every hand supplies exactly 13
	cards (a short hand would leave zero-valued cards that read as the club two and corrupt the
	counts).
*/

import "core:testing"
import "norn:norn"

// Rank aliases for terse hand literals.
A :: norn.Rank.Ace
K :: norn.Rank.King
Q :: norn.Rank.Queen
J :: norn.Rank.Jack
T :: norn.Rank.Ten
R9 :: norn.Rank.Nine
R8 :: norn.Rank.Eight
R7 :: norn.Rank.Seven
R6 :: norn.Rank.Six
R5 :: norn.Rank.Five
R4 :: norn.Rank.Four
R3 :: norn.Rank.Three
R2 :: norn.Rank.Two

// Build a hand from the ranks held in each suit. The four lists must total 13 cards.
@(private = "file")
hand_of :: proc(spades, hearts, diamonds, clubs: []norn.Rank) -> norn.Hand {
	hand: norn.Hand
	i := 0
	for r in spades {hand[i] = norn.make_card(.Spades, r); i += 1}
	for r in hearts {hand[i] = norn.make_card(.Hearts, r); i += 1}
	for r in diamonds {hand[i] = norn.make_card(.Diamonds, r); i += 1}
	for r in clubs {hand[i] = norn.make_card(.Clubs, r); i += 1}
	return hand
}

// --- Shared hands (named for the salient feature, with shape/hcp in the comment). ---

// 7-2-2-2, AKQJT98 spades, 10 hcp, 3 controls — a long solid major, a 3-major preempt.
solid7_spades :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, Q, J, T, R9, R8}, {R2, R3}, {R2, R3}, {R2, R3}))
}

// 7-3-2-1, solid spades plus a side ace of diamonds, 14 hcp, 5 controls — a gambling 3NT.
gambling3n :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, Q, J, T, R9, R8}, {R2, R3, R4}, {A, R2}, {R2}))
}

// 4-4-4-1, 12 hcp, 3 controls — a Marmic.
marmic12 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, R2, R3}, {Q, J, R5, R6}, {Q, R4, R5, R6}, {R2}))
}

// 6-5-1-1 majors, 19 hcp — a strong majors two-suiter.
majors_6511 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, Q, R4, R5, R6}, {A, K, Q, J, T}, {R2}, {R2}))
}

// 6-5-1-1 majors, 7 hcp — a weak/semi-positive majors two-suiter; also a Michaels hand.
weak_majors_6511 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, R3, R4, R5, R6, R7}, {K, R5, R6, R7, R8}, {R2}, {R2}))
}

// 6-3-2-2 spades, 9 hcp (A Q) — a standard weak two in spades.
weak2_spades :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, Q, R4, R5, R6, R7}, {R2, R3, R4}, {K, R3}, {R2, R3}))
}

// 5-4-2-2, five spades headed A K, 7 hcp — a 5-card-major weak two.
weak2_5card_spades :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, R4, R5, R6}, {R2, R3}, {R2, R3, R4, R5}, {R2, R3}))
}

// 6-3-2-2 diamonds, A-headed, 6 hcp — a generic weak 2D / weak red two.
weak2_diamonds :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2, R3}, {R2, R3}, {A, R3, R4, R5, R6, R7}, {Q, R3, R4}))
}

// 5-5-2-1 both minors, 10 hcp, a heart singleton — the 2S "both minors" response shape.
both_minors_5521 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2, R3}, {R2}, {A, K, R4, R5, R6}, {Q, J, R4, R5, R6}))
}

// 6-4-2-1, diamonds long, heart singleton, 13 hcp — an unbalanced minor / 2D intermediate.
unbal_diamond_6421 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2, R3}, {R2}, {A, K, Q, R5, R6, R7}, {A, R3, R4, R5}))
}

// 5-4-3-1, diamonds long, spade-headed, 12 hcp — an unbalanced 1D opener.
unbal_1d_5431 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({Q, R2, R3, R4}, {R2}, {A, K, R4, R5, R6}, {K, R3, R4}))
}

// 5-3-3-2, five hearts, 12 hcp — a 1-major opener.
major_opener_1h :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({Q, R2, R3}, {A, K, R4, R5, R6}, {K, R3, R4}, {R2, R3}))
}

// 5-3-3-2, five spades, 9 hcp — a light 1-major opener.
light_major_1s :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, R4, R5, R6}, {R2, R3, R4}, {Q, R3, R4}, {R2, R3}))
}

// 4-3-3-3, no 4-card major, 10 hcp, 3 controls — a flat no-major positive (2H/2NT-ish).
flat_no_major_10 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({K, R2, R3}, {Q, R2, R3}, {J, R2, R3}, {A, R2, R3, R4}))
}

// 6-4-2-1, clubs long, no major, 9 hcp — a non-flat no-major positive (2C/2D-ish).
unbal_no_major_9 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2, R3}, {R2}, {K, R3, R4, R5}, {A, Q, R4, R5, R6, R7}))
}

// 6-3-2-2 clubs, 12 hcp — a 2C (club one-suiter) opener.
club_2c_opener :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({Q, R2, R3}, {R2, R3}, {K, R3}, {A, K, R4, R5, R6, R7}))
}

// 4-4-1-4, 13 hcp — a 2D opener shape (also a Marmic pattern).
diamond_2d_opener :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, R3, R4}, {Q, R2, R3, R4}, {J}, {K, R3, R4, R5}))
}

// 7-2-2-2 clubs, KQ-headed (missing the ace), 5 hcp — a standard 3C 7-carder preempt.
clubs_3c_7carder :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2, R3}, {R2, R3}, {R2, R3}, {K, Q, R4, R5, R6, R7, R8}))
}

// 6-3-2-2 spades, AKQJ-solid six, 10 hcp, 3 controls — a 3NT solid-suit response.
solid6_spades :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, Q, J, R6, R7}, {R2, R3, R4}, {R2, R3}, {R2, R3}))
}

// 7-2-2-2 spades, AKQJ-solid seven, 10 hcp, 3 controls — a 4-major solid-suit response.
solid7_akqj_spades :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, Q, J, R6, R7, R8}, {R2, R3}, {R2, R3}, {R2, R3}))
}

// 8-2-2-1 spades, AQJ-headed eight (missing the king), 7 hcp — a 4-of-a-minor solid response.
eight_spades_aqj :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, Q, J, R5, R6, R7, R8, R9}, {R2, R3}, {R2}, {R2, R3}))
}

// 6-3-2-2 clubs, A-headed, 4 hcp — a weak jump-shift candidate.
wjs_clubs :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2, R3}, {R2, R3}, {R2, R3, R4}, {A, R3, R4, R5, R6, R7}))
}

// 6-3-2-2 hearts, AJ-headed, 5 hcp — a semi-positive weak two in hearts.
semipos_2h :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2, R3}, {A, J, R5, R6, R7, R8}, {R2, R3}, {R2, R3, R4}))
}

// 5-5-2-1, hearts and clubs, 13 hcp — a game-forcing hearts+minor two-suiter.
gf_hearts_minor :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2}, {A, K, R4, R5, R6}, {R2, R3}, {A, Q, R4, R5, R6}))
}

// 8-2-2-1 clubs, solid AKQJT, 10 hcp — an insane offensive preempt / shapely minor preempt.
insane_preempt :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({R2, R3}, {R2, R3}, {R2}, {A, K, Q, J, T, R9, R8, R7}))
}

// 5-3-3-2, solid AKQ(JT) across the board, 0 half-losers — a powerhouse / 4NT opener.
powerhouse :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, Q, J, T}, {A, K, Q}, {A, K, Q}, {A, K}))
}

// 4-3-3-3, 13 hcp, balanced — a weak 1C / balanced 1NT response.
balanced_13 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, R2, R3}, {K, R2, R3}, {Q, R2, R3}, {J, R2, R3}))
}

// 4-3-3-3, no 4-card major, 9 hcp — a 1D negative response to 1C.
neg_1d_response :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, R2, R3}, {Q, R2, R3}, {R2, R3, R4}, {K, R2, R3, R4}))
}

// 4-4-3-2, four spades and four hearts, 7 hcp — a 4-4 majors hand.
majors_44 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, R2, R3, R4}, {K, R2, R3, R4}, {R2, R3, R4}, {R2, R3}))
}

// 4-4-1-4, short diamonds, 14 hcp, no 5-card suit — a 1D takeout shape.
takeout_1d :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, R4, R5}, {A, K, R4, R5}, {R2}, {K, R2, R3, R4}))
}

// 4-3-3-3, balanced 20 hcp — a 2NT opener.
balanced_20 :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({A, K, R3}, {A, R3, R4}, {R2, R3, R4}, {A, K, Q, R4}))
}

// 4-3-3-3, 2 hcp — junk filler for multi-seat deals.
junk :: proc() -> norn.HandSummary {
	return norn.summarize(hand_of({Q, R2, R3, R4}, {R2, R3, R4}, {R2, R3, R4}, {R2, R3, R4}))
}

// --- Batch 1: shape and suit-quality helpers. ---

@(test)
test_suit_quality :: proc(t: ^testing.T) {
	testing.expect(t, long_semi_solid(solid7_spades(), .Spades), "AKQJT98 is long semi-solid")
	testing.expect(t, !long_semi_solid(solid6_spades(), .Spades), "a six-bagger is not long (7+)")
	testing.expect(t, good_6_plus_suit(solid6_spades(), .Spades), "AKQJ six is a good 6+ suit")
	testing.expect(t, any_good_6_plus_carder(solid7_spades()), "has a good long suit")
	testing.expect(t, !any_good_6_plus_carder(balanced_13()), "balanced hand has no good 6+ suit")
}

@(test)
test_two_suiter_shapes :: proc(t: ^testing.T) {
	testing.expect(t, two_suiter(majors_6511()), "6-5-1-1 is a two-suiter")
	testing.expect(t, !two_suiter(majors_44()), "4-4-3-2 is not a two-suiter")
	testing.expect(
		t,
		is_6_plus_other_10_card_two_suiter(unbal_diamond_6421()),
		"6-4 is a 10-card 2-suiter",
	)
	testing.expect(t, is_asymmetric_10_plus_two_suiter(majors_6511()), "6-5 is asymmetric 10+")
	testing.expect(
		t,
		is_6_plus_other_11_or_more_card_two_suiter(majors_6511()),
		"6-5 is 11+ card 2-suiter",
	)
}

@(test)
test_shape_helpers :: proc(t: ^testing.T) {
	testing.expect(t, majors_4_4(majors_44()), "4-4 majors")
	testing.expect(t, has_9_plus_majors(solid7_spades()), "7+2 majors is 9+")
	testing.expect(t, has_side_major(major_opener_1h()), "5 hearts is a side major")
	testing.expect(t, !has_side_major(insane_preempt()), "club one-suiter has no side major")
	testing.expect(t, has_n_plus_carder(solid7_spades(), 7), "has a 7-card suit")
	testing.expect(t, both_minors(both_minors_5521()), "5-5 minors")
	testing.expect(t, singleton_or_void_major(both_minors_5521()), "heart singleton")
	testing.expect(t, any_singleton_or_void(both_minors_5521()), "has a singleton")
	testing.expect(t, !any_singleton_or_void(balanced_13()), "balanced has no shortage")
	testing.expect(t, is_unbalanced_minor(unbal_diamond_6421()), "diamond-long unbalanced")
}

@(test)
test_tricky_and_side_ace :: proc(t: ^testing.T) {
	testing.expect(t, is_tricky_suit(insane_preempt(), .Clubs), "solid 8 clubs is tricky")
	testing.expect(t, side_ace(gambling3n(), .Diamonds), "bare ace of diamonds is a side ace")
	testing.expect(t, !side_ace(gambling3n(), .Spades), "AK spades is not a side ace")
	testing.expect(
		t,
		has_major_support(major_opener_1h(), neg_1d_response(), 3),
		"opener 5 hearts, responder 3 hearts",
	)
}

// --- Batch 2: openers. ---

@(test)
test_one_level_openers :: proc(t: ^testing.T) {
	testing.expect(t, is_weak_1c(balanced_13()), "balanced 13 is a weak 1C")
	testing.expect(t, is_any_1c_opener(balanced_13()), "weak 1C is a 1C opener")
	testing.expect(t, is_any_1c_opener(unbalanced_16()), "strong 1C is a 1C opener")
	testing.expect(t, is_1major_opener(major_opener_1h()), "5 hearts 12 is a 1-major opener")
	testing.expect(t, !is_1major_opener(light_major_1s()), "9 hcp is not a (full) 1-major opener")
	testing.expect(
		t,
		is_light_1major_opener(light_major_1s()),
		"9 hcp 5 spades is a light 1-major",
	)
	testing.expect(t, is_1d_unbal_opener(unbal_1d_5431()), "5-4-3-1 diamond is a 1D unbal opener")
	testing.expect(t, is_1d_opener(unbal_1d_5431()), "unbal diamond opens 1D")
}

@(test)
test_notrump_and_marmic_openers :: proc(t: ^testing.T) {
	testing.expect(t, !is_1nt_opener(unbalanced_16()), "5-5-2-1 is not a 1NT opener")
	testing.expect(t, is_2nt_opener(balanced_20()), "balanced 20 opens 2NT")
	testing.expect(t, !is_1nt_opener(balanced_20()), "20 is too strong for 1NT")
	testing.expect(t, is_marmic(marmic12()), "4-4-4-1 is Marmic")
	testing.expect(t, !is_marmic(balanced_13()), "4-3-3-3 is not Marmic")
}

@(test)
test_two_level_openers :: proc(t: ^testing.T) {
	testing.expect(t, is_2c_opener(club_2c_opener()), "6 clubs 12 opens 2C")
	testing.expect(t, is_2d_opener(diamond_2d_opener()), "4-4-1-4 opens 2D")
	testing.expect(
		t,
		is_2d_intermediate_opener(unbal_diamond_6421()),
		"6+ diamond opens 2D intermediate",
	)
	testing.expect(t, is_3n_opener(gambling3n()), "solid major + side ace opens 3NT")
	testing.expect(t, !is_3n_opener(solid7_spades()), "7-2-2-2 is excluded from 3NT")
	testing.expect(
		t,
		opens_std_1minor_prepared(unbal_diamond_6421()),
		"diamond-long opens a prepared 1m",
	)
	testing.expect(t, is_3cd_opener_1st2nd(insane_preempt()), "tricky club suit opens 3C")
	testing.expect(t, is_standard_3cd_7carder(clubs_3c_7carder()), "KQ 7-card club opens 3C")
}

// --- Batch 3: weak twos and preempts. ---

@(test)
test_weak_carders :: proc(t: ^testing.T) {
	testing.expect(t, is_any_weak_6_plus_carder(weak2_spades()), "weak 6-carder")
	testing.expect(t, is_any_weak_or_min_7_plus_carder(insane_preempt()), "weak/min 7-carder")
	testing.expect(t, !is_any_weak_6_plus_carder(powerhouse()), "29 hcp is not weak")
}

@(test)
test_weak_twos :: proc(t: ^testing.T) {
	testing.expect(t, is_generic_weak2d(weak2_diamonds()), "A-headed 6 diamonds is a weak 2D")
	testing.expect(t, is_weak_2DH(weak2_diamonds()), "6 diamonds 6 hcp is a weak red two")
	testing.expect(t, is_weak2_5card_major(weak2_5card_spades()), "5-card spade weak two")
	testing.expect(
		t,
		is_generic_5card_unbal_weak2(weak2_5card_spades()),
		"5-card unbalanced weak two",
	)
	testing.expect(t, is_weak2_major(weak2_spades()), "6-card spade weak two")
	testing.expect(t, is_weak_5_or_6_card_major(weak2_spades()), "5/6-card major weak two")
	testing.expect(t, is_weak2_major_in_range(weak2_spades(), 5, 11), "weak two in 5-11 range")
	testing.expect(
		t,
		is_semi_positive_weak_two_hearts(semipos_2h()),
		"semi-positive weak two hearts",
	)
}

@(test)
test_two_suiters_and_minor_preempts :: proc(t: ^testing.T) {
	testing.expect(
		t,
		is_semi_positive_majors_two_suiter(weak_majors_6511()),
		"weak majors 2-suiter",
	)
	testing.expect(t, is_gf_majors_two_suiter(majors_6511()), "strong majors 2-suiter")
	testing.expect(t, is_gf_hearts_minor_two_suiter(gf_hearts_minor()), "GF hearts+minor 2-suiter")
	testing.expect(t, is_minors_2n_preempt(both_minors_5521()), "5-5 minors 2NT preempt")
	testing.expect(t, is_shapely_minor_preempt(insane_preempt()), "shapely minor preempt")
}

@(test)
test_high_preempts_and_powerhouses :: proc(t: ^testing.T) {
	testing.expect(t, is_likely_3major_preempt(solid7_spades()), "7 spades is a 3-major preempt")
	testing.expect(t, any_offensive_suit(insane_preempt(), 8), "8-card solid suit is offensive")
	testing.expect(t, is_likely_4level_preempt(insane_preempt()), "8 clubs is a 4-level preempt")
	testing.expect(t, !is_likely_4level_preempt(solid7_spades()), "7-2-2-2 is barred from 4-level")
	testing.expect(t, is_insane_offensive_preempt(insane_preempt()), "8 solid clubs is insane")
	testing.expect(t, is_8_plus_tricks(powerhouse()), "powerhouse has 8+ tricks")
	testing.expect(t, is_powerhouse(powerhouse(), 4), "<=4 losers is a powerhouse")
	testing.expect(t, is_potential_4n_opener(powerhouse()), "<=3 losers is a 4NT opener")
}

// --- Batch 4: Swedish-club and 1D responses. ---

@(test)
test_swedish_club_two_level :: proc(t: ^testing.T) {
	testing.expect(t, is_1n_marmic_swedish_club_resp(marmic12()), "Marmic 12 is a 1NT response")
	testing.expect(
		t,
		is_2s_swedish_club_resp(both_minors_5521()),
		"both minors + short major is 2S",
	)
	testing.expect(t, is_2cd_swedish_club_resp(unbal_no_major_9()), "unbal no-major 9 is 2C/2D")
	testing.expect(
		t,
		is_2h_or_2n_swedish_club_resp(flat_no_major_10()),
		"flat no-major 10 is 2H/2NT",
	)
	testing.expect(
		t,
		is_minor_swedish_club_positive_response(unbal_diamond_6421()),
		"unbal minor 13 positive",
	)
}

@(test)
test_swedish_club_notrump_responses :: proc(t: ^testing.T) {
	testing.expect(
		t,
		is_old_1n_bal_swedish_club_response(balanced_13()),
		"balanced 13 is a 1NT response",
	)
	testing.expect(
		t,
		is_1n_unbal_minor_swedish_club_resp(unbal_diamond_6421()),
		"unbal minor 13 is 1NT",
	)
	testing.expect(
		t,
		is_any_1n_swedish_club_response(balanced_13()),
		"balanced is some 1NT response",
	)
	testing.expect(t, is_any_1n_swedish_club_response(marmic12()), "Marmic is some 1NT response")
	testing.expect(t, eq_3_control_points_and_max_12_hcp(solid6_spades()), "3 controls, 10 hcp")
}

@(test)
test_swedish_club_solid_suit_responses :: proc(t: ^testing.T) {
	testing.expect(t, is_akqj(solid6_spades(), .Spades), "AKQJ spades")
	testing.expect(t, is_3n_swedish_club_resp(solid6_spades()), "solid 6 is a 3NT response")
	testing.expect(
		t,
		is_4hs_swedish_club_response(solid7_akqj_spades()),
		"solid 7 major is a 4M response",
	)
	testing.expect(
		t,
		is_4cd_swedish_club_response(eight_spades_aqj()),
		"AQJ 8-bagger is a 4-minor response",
	)
	testing.expect(
		t,
		is_3x_preempt_swedish_club_response(clubs_3c_7carder()),
		"7-card 3C preempt response",
	)
}

@(test)
test_one_d_responses :: proc(t: ^testing.T) {
	testing.expect(
		t,
		is_1d_swedish_club_resp(neg_1d_response()),
		"weak no-major 9 is a 1D negative",
	)
	testing.expect(
		t,
		is_possible_inverted_diamond_raise(unbal_diamond_6421()),
		"13 + 6 diamonds raises",
	)
	testing.expect(t, is_possible_wjs_1d_response(wjs_clubs()), "sub-10 + 6 clubs jump-shifts")
	testing.expect(
		t,
		is_possible_splinter_1d_response(unbal_diamond_6421()),
		"13 + 6 diamonds + singleton splinters",
	)
	testing.expect(
		t,
		is_possible_diamond_preempt_1d_response(weak2_diamonds()),
		"6 diamonds preempts over 1D",
	)
}

// --- Batch 5: competitive (single-hand and multi-seat). ---

@(test)
test_overcalls :: proc(t: ^testing.T) {
	testing.expect(t, is_1major_overcall(major_opener_1h()), "5-card major 12 overcalls 1M")
	testing.expect(t, is_1d_takeout(takeout_1d()), "short diamonds 14 is a 1D takeout")
	testing.expect(t, has_both_majors_michaels(weak_majors_6511()), "5-5 majors is Michaels")
}

@(test)
test_multi_seat_overcalls :: proc(t: ^testing.T) {
	// South shapely (10, not flat), North invitational flat (10), E-W weak.
	may: norn.Deal_Summary
	may[.North] = flat_no_major_10()
	may[.East] = junk()
	may[.South] = insane_preempt()
	may[.West] = junk()
	testing.expect(t, north_south_may_overcall_1N(may, 15), "shapely South may overcall")
	testing.expect(
		t,
		south_may_overcall_opponents_1N_with_north_invitational(may, 15),
		"South may overcall with invitational North",
	)

	// All four hands flat and weak: neither overcall is allowed.
	all_flat: norn.Deal_Summary
	all_flat[.North] = junk()
	all_flat[.East] = junk()
	all_flat[.South] = junk()
	all_flat[.West] = junk()
	testing.expect(
		t,
		!north_south_may_overcall_1N(all_flat, 15),
		"flat-vs-flat both minimum: no overcall",
	)
	testing.expect(
		t,
		!south_may_overcall_opponents_1N_with_north_invitational(all_flat, 15),
		"flat South cannot overcall",
	)
}
