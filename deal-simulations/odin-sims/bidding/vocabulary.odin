package bidding

/*
	vocabulary.odin — WHICH OF THIS SYSTEM'S PREDICATES A USER MAY NAME in a `.scenario` file.

	The bridge between the compiled bidding system and `scenario_dsl`. A text scenario can say
	`north: is_strong_1c` because this table exists; without it the language would offer nothing but hcp
	and suit lengths, which is the ceiling a form of ranges has and the reason a DSL is worth having at
	all — the auctions are the part that cannot be expressed as numbers.

	IT LIVES HERE, NOT IN `scenario_dsl`, and the direction of the dependency is the point. The language
	knows nothing about this bidding system; this bidding system decides what of itself to expose. Same
	seam as `combo.set_suit_book(suit_book.provider())` — generic engine, local content.

	EVERY ENTRY IS HAND-LEVEL, taking one seat's `Hand_Summary`, because that is the shape a seat line in
	the grammar evaluates (`south: is_2cd_swedish_club_resp`). Predicates over a whole DEAL are not here:
	they have no seat to belong to, and the grammar has no place to put one yet.

	The descriptions are empty for now. They are what a completion list or a `--list-vocabulary` would
	show, so they are worth filling in as the language gets a UI — but an empty string is honest, and
	inventing 58 one-line glosses without checking each predicate's actual boundaries would not be.
*/

import "../scenario_dsl"

// Handed to `scenario_dsl.set_vocabulary` once at startup by whichever program is wiring things up
// (`sim`, the workbench). Not installed here: a package should not have opinions about global state it
// does not own.
vocabulary := []scenario_dsl.Vocabulary_Entry {
	{name = "is_1d_opener", description = "", call = is_1d_opener},
	{name = "is_1d_swedish_club_resp", description = "", call = is_1d_swedish_club_resp},
	{name = "is_1d_takeout", description = "", call = is_1d_takeout},
	{name = "is_1d_unbal_opener", description = "", call = is_1d_unbal_opener},
	{name = "is_1major_opener", description = "", call = is_1major_opener},
	{name = "is_1major_overcall", description = "", call = is_1major_overcall},
	{name = "is_1n_marmic_swedish_club_resp", description = "", call = is_1n_marmic_swedish_club_resp},
	{name = "is_1n_unbal_minor_swedish_club_resp", description = "", call = is_1n_unbal_minor_swedish_club_resp},
	{name = "is_1nt_opener", description = "", call = is_1nt_opener},
	{name = "is_2c_opener", description = "", call = is_2c_opener},
	{name = "is_2cd_swedish_club_resp", description = "", call = is_2cd_swedish_club_resp},
	{name = "is_2d_intermediate_opener", description = "", call = is_2d_intermediate_opener},
	{name = "is_2d_opener", description = "", call = is_2d_opener},
	{name = "is_2h_or_2n_swedish_club_resp", description = "", call = is_2h_or_2n_swedish_club_resp},
	{name = "is_2nt_opener", description = "", call = is_2nt_opener},
	{name = "is_2s_swedish_club_resp", description = "", call = is_2s_swedish_club_resp},
	{name = "is_3cd_opener_1st2nd", description = "", call = is_3cd_opener_1st2nd},
	{name = "is_3n_opener", description = "", call = is_3n_opener},
	{name = "is_3n_swedish_club_resp", description = "", call = is_3n_swedish_club_resp},
	{name = "is_3x_preempt_swedish_club_response", description = "", call = is_3x_preempt_swedish_club_response},
	{name = "is_4cd_swedish_club_response", description = "", call = is_4cd_swedish_club_response},
	{name = "is_4hs_swedish_club_response", description = "", call = is_4hs_swedish_club_response},
	{name = "is_6_plus_other_10_card_two_suiter", description = "", call = is_6_plus_other_10_card_two_suiter},
	{
		name = "is_6_plus_other_11_or_more_card_two_suiter",
		description = "",
		call = is_6_plus_other_11_or_more_card_two_suiter,
	},
	{name = "is_8_plus_tricks", description = "", call = is_8_plus_tricks},
	{name = "is_any_1c_opener", description = "", call = is_any_1c_opener},
	{name = "is_any_1n_swedish_club_response", description = "", call = is_any_1n_swedish_club_response},
	{name = "is_any_weak_6_plus_carder", description = "", call = is_any_weak_6_plus_carder},
	{name = "is_any_weak_or_min_7_plus_carder", description = "", call = is_any_weak_or_min_7_plus_carder},
	{name = "is_asymmetric_10_plus_two_suiter", description = "", call = is_asymmetric_10_plus_two_suiter},
	{name = "is_flattish", description = "", call = is_flattish},
	{name = "is_generic_5card_unbal_weak2", description = "", call = is_generic_5card_unbal_weak2},
	{name = "is_generic_weak2d", description = "", call = is_generic_weak2d},
	{name = "is_gf_hearts_minor_two_suiter", description = "", call = is_gf_hearts_minor_two_suiter},
	{name = "is_gf_majors_two_suiter", description = "", call = is_gf_majors_two_suiter},
	{name = "is_insane_offensive_preempt", description = "", call = is_insane_offensive_preempt},
	{name = "is_light_1major_opener", description = "", call = is_light_1major_opener},
	{name = "is_likely_3major_preempt", description = "", call = is_likely_3major_preempt},
	{name = "is_likely_4level_preempt", description = "", call = is_likely_4level_preempt},
	{name = "is_marmic", description = "", call = is_marmic},
	{
		name = "is_minor_swedish_club_positive_response",
		description = "",
		call = is_minor_swedish_club_positive_response,
	},
	{name = "is_minors_2n_preempt", description = "", call = is_minors_2n_preempt},
	{name = "is_old_1n_bal_swedish_club_response", description = "", call = is_old_1n_bal_swedish_club_response},
	{
		name = "is_possible_diamond_preempt_1d_response",
		description = "",
		call = is_possible_diamond_preempt_1d_response,
	},
	{name = "is_possible_inverted_diamond_raise", description = "", call = is_possible_inverted_diamond_raise},
	{name = "is_possible_splinter_1d_response", description = "", call = is_possible_splinter_1d_response},
	{name = "is_possible_wjs_1d_response", description = "", call = is_possible_wjs_1d_response},
	{name = "is_potential_4n_opener", description = "", call = is_potential_4n_opener},
	{name = "is_semi_positive_majors_two_suiter", description = "", call = is_semi_positive_majors_two_suiter},
	{name = "is_semi_positive_weak_two_hearts", description = "", call = is_semi_positive_weak_two_hearts},
	{name = "is_shapely_minor_preempt", description = "", call = is_shapely_minor_preempt},
	{name = "is_standard_3cd_7carder", description = "", call = is_standard_3cd_7carder},
	{name = "is_strong_1c", description = "", call = is_strong_1c},
	{name = "is_unbalanced_minor", description = "", call = is_unbalanced_minor},
	{name = "is_weak2_5card_major", description = "", call = is_weak2_5card_major},
	{name = "is_weak2_major", description = "", call = is_weak2_major},
	{name = "is_weak_1c", description = "", call = is_weak_1c},
	{name = "is_weak_5_or_6_card_major", description = "", call = is_weak_5_or_6_card_major},
}
