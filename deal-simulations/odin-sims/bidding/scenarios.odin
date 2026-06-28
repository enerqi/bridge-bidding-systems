package bidding

/*
	scenarios.odin — the named-simulation registry (part of package `bidding`; see bidding.odin).

	Each entry is the Odin port of one `deal-simulations/tcl-sims` script: a `name` (the script's
	base filename), a one-line `description`, and a `predicate` over a whole `norn.Deal`. The
	predicate is the `main { ... accept/reject ... }` body, re-expressed as a `norn.Predicate` — it
	composes the parity-verified predicates in this package over the named seats (North opens, South
	responds, East/West compete).

	The `Scenario` type and `lookup` live in the generic `norn:cli` framework, so this file supplies
	only the concrete definitions; the `cli` driver looks a scenario up by name and feeds its
	predicate to `norn.generate_accepted`.

	Adding a scenario = adding one `cli.Scenario` literal to `registry`. No driver change needed.
*/

import "norn:cli"
import "norn:norn"

// All registered scenarios, ordered roughly as the bidding develops (opener, then responses, then
// competition). The `name` mirrors the source `.tcl` basename so the two corpora stay diff-able.
registry := []cli.Scenario {
	// --- 1C opening, any strength ---
	{
		"1c-any",
		"North opens 1C (any strength)",
		proc(b: norn.Deal) -> bool {return is_any_1c_opener(b[.North])},
	},
	{"1c-any-1n", "1C opener; South makes any 1NT response", proc(b: norn.Deal) -> bool {
			return(
				is_any_1c_opener(b[.North]) &&
				is_any_1n_swedish_club_response(b[.South]) \
			)
		}},
	{
		"1c-any-1n-unbal",
		"1C opener; South responds 1NT on an unbalanced-minor or Marmic hand",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			return(
				is_any_1c_opener(b[.North]) &&
				(is_1n_unbal_minor_swedish_club_resp(south) ||
						is_1n_marmic_swedish_club_resp(south)) \
			)
		},
	},
	{"1c-any-2cd", "1C opener; South responds 2C/2D", proc(b: norn.Deal) -> bool {
			return(
				is_any_1c_opener(b[.North]) &&
				is_2cd_swedish_club_resp(b[.South]) \
			)
		}},
	{"1c-any-2h-or-2n", "1C opener; South responds 2H/2NT", proc(b: norn.Deal) -> bool {
			return(
				is_any_1c_opener(b[.North]) &&
				is_2h_or_2n_swedish_club_resp(b[.South]) \
			)
		}},
	{
		"1c-any-2h-candidates",
		"1C opener; South holds one of the 2H-zone positive shapes",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			return(
				is_any_1c_opener(b[.North]) &&
				(is_semi_positive_weak_two_hearts(south) ||
						is_semi_positive_majors_two_suiter(south) ||
						is_gf_hearts_minor_two_suiter(south) ||
						is_gf_majors_two_suiter(south)) \
			)
		},
	},
	{"1c-any-2s", "1C opener; South responds 2S (both minors)", proc(b: norn.Deal) -> bool {
			return(
				is_any_1c_opener(b[.North]) &&
				is_2s_swedish_club_resp(b[.South]) \
			)
		}},
	{
		"1c-any-3n-plus",
		"1C opener; South makes a solid-suit 3NT / 4-of-a-suit slam-try response",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			return(
				is_any_1c_opener(b[.North]) &&
				(is_3n_swedish_club_resp(south) ||
						is_4cd_swedish_club_response(south) ||
						is_4hs_swedish_club_response(south)) \
			)
		},
	},
	{
		"1c-any-3x-response",
		"1C opener; South makes a 3-level preempt response",
		proc(b: norn.Deal) -> bool {
			return(
				is_any_1c_opener(b[.North]) &&
				is_3x_preempt_swedish_club_response(b[.South]) \
			)
		},
	},
	{
		"1c-any-preempted",
		"1C opener; East preempts (any weak 6+ or weak/min 7+ suit); South has 4+ hcp",
		proc(b: norn.Deal) -> bool {
			east := b[.East]
			return(
				is_any_1c_opener(b[.North]) &&
				(is_any_weak_6_plus_carder(east) ||
						is_any_weak_or_min_7_plus_carder(east)) &&
				norn.hcp(b[.South]) >= 4 \
			)
		},
	},
	{
		"1c-any-long-suit-preempted",
		"1C opener; East preempts a long (weak/min 7+) suit; South has 4+ hcp",
		proc(b: norn.Deal) -> bool {
			return(
				is_any_1c_opener(b[.North]) &&
				is_any_weak_or_min_7_plus_carder(b[.East]) &&
				norn.hcp(b[.South]) >= 4 \
			)
		},
	},

	// --- 1C strong (the 16+ artificial opening) ---
	{
		"1c-strong",
		"North opens a strong 1C",
		proc(b: norn.Deal) -> bool {return is_strong_1c(b[.North])},
	},
	{
		"1c-19plus-or-marmic",
		"Strong 1C that is either Marmic or 19+ hcp",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_strong_1c(north) &&
				(is_marmic(north) || norn.hcp(north) >= 19) \
			)
		},
	},
	{"1c-strong-19plus-unbal", "Strong 1C, 19+ and unbalanced", proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_strong_1c(north) &&
				norn.hcp(north) >= 19 &&
				!is_flattish(north) \
			)
		}},
	{
		"1c-strong-19plus-asymmetric-10plus-card-two-suiter",
		"Strong 1C, 19+ with an asymmetric 10+ card two-suiter",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_strong_1c(north) &&
				norn.hcp(north) >= 19 &&
				is_asymmetric_10_plus_two_suiter(north) \
			)
		},
	},
	{"1c-strong-21plus-unbal", "Strong 1C, 21+ and unbalanced", proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_strong_1c(north) &&
				norn.hcp(north) >= 21 &&
				!is_flattish(north) \
			)
		}},
	{
		"1c-strong-(overcall)",
		"Strong 1C with East able to overcall (8+ hcp, not flat)",
		proc(b: norn.Deal) -> bool {
			east := b[.East]
			return(
				is_strong_1c(b[.North]) &&
				norn.hcp(east) >= 8 &&
				!is_flattish(east) \
			)
		},
	},
	{
		"1c-strong-preempted",
		"Strong 1C; East preempts (weak/min 7+ or weak 6+); South has 4+ hcp",
		proc(b: norn.Deal) -> bool {
			east := b[.East]
			return(
				is_strong_1c(b[.North]) &&
				(is_any_weak_or_min_7_plus_carder(east) ||
						is_any_weak_6_plus_carder(east)) &&
				norn.hcp(b[.South]) >= 4 \
			)
		},
	},
	{
		"1c-strong-minor-opening-positive",
		"Strong 1C, 18+ unbalanced minor; South has a 8+ hcp positive",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_strong_1c(north) &&
				norn.hcp(north) >= 18 &&
				is_unbalanced_minor(north) &&
				norn.hcp(b[.South]) >= 8 \
			)
		},
	},
	{"1c-strong-1d", "Strong 1C; South gives the 1D negative", proc(b: norn.Deal) -> bool {
			return(
				is_strong_1c(b[.North]) &&
				is_1d_swedish_club_resp(b[.South]) \
			)
		}},
	{
		"1c-strong-1d-1h-1s-likely",
		"Strong 1C; South 1D negative with both sides holding a likely major fit",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			south := b[.South]
			return(
				norn.heart_length(south) >= 4 &&
				norn.spade_length(north) >= 4 &&
				is_strong_1c(north) &&
				is_1d_swedish_club_resp(south) \
			)
		},
	},
	{"1c-strong-1n", "Strong 1C; South makes any 1NT response", proc(b: norn.Deal) -> bool {
			return(
				is_strong_1c(b[.North]) &&
				is_any_1n_swedish_club_response(b[.South]) \
			)
		}},
	{
		"1c-strong-1n-unbal",
		"Strong 1C; South 1NT on an unbalanced-minor or Marmic hand",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			return(
				is_strong_1c(b[.North]) &&
				(is_1n_unbal_minor_swedish_club_resp(south) ||
						is_1n_marmic_swedish_club_resp(south)) \
			)
		},
	},
	{
		"1c-strong-1n-2c-2s-minor-response",
		"Strong 1C; South makes a minor-suit positive (2S or 11+ minor)",
		proc(b: norn.Deal) -> bool {
			return(
				is_strong_1c(b[.North]) &&
				is_minor_swedish_club_positive_response(b[.South]) \
			)
		},
	},
	{"1c-strong-2cd", "Strong 1C; South responds 2C/2D", proc(b: norn.Deal) -> bool {
			return(
				is_strong_1c(b[.North]) &&
				is_2cd_swedish_club_resp(b[.South]) \
			)
		}},
	{"1c-strong-extras-2cd", "Strong 1C, 20+; South responds 2C/2D", proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_strong_1c(north) &&
				norn.hcp(north) >= 20 &&
				is_2cd_swedish_club_resp(b[.South]) \
			)
		}},
	{"1c-strong-2h-or-2n", "Strong 1C; South responds 2H/2NT", proc(b: norn.Deal) -> bool {
			return(
				is_strong_1c(b[.North]) &&
				is_2h_or_2n_swedish_club_resp(b[.South]) \
			)
		}},
	{"1c-strong-2s", "Strong 1C; South responds 2S (both minors)", proc(b: norn.Deal) -> bool {
			return(
				is_strong_1c(b[.North]) &&
				is_2s_swedish_club_resp(b[.South]) \
			)
		}},
	{
		"1c-strong-responder-bal-gf",
		"Strong 1C; South gives the old balanced 12+ 1NT response",
		proc(b: norn.Deal) -> bool {
			return(
				is_strong_1c(b[.North]) &&
				is_old_1n_bal_swedish_club_response(b[.South]) \
			)
		},
	},
	{
		"1c-strong-responder-14plus-bal-gf",
		"Strong 1C; South balanced 1NT response with 14+ hcp",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			return(
				is_strong_1c(b[.North]) &&
				is_old_1n_bal_swedish_club_response(south) &&
				norn.hcp(south) >= 14 \
			)
		},
	},
	{
		"1c-strong-1hs-support",
		"Strong 1C; South has 8+ with a side major and a likely major fit (not NT/solid-suit)",
		proc(b: norn.Deal) -> bool {return is_1hs_support(b, false)},
	},
	{
		"1c-strong-1hs-support-unbal",
		"As 1c-strong-1hs-support but South is also non-flat",
		proc(b: norn.Deal) -> bool {return is_1hs_support(b, true)},
	},

	// --- 1D openings ---
	{
		"1d-unbalanced-opener",
		"North opens an unbalanced 1D",
		proc(b: norn.Deal) -> bool {return is_1d_unbal_opener(b[.North])},
	},
	{
		"1d-unbalanced-opener-gf-two-suiter",
		"Unbalanced 1D; South a 13+ two-suiter (game force)",
		proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_1d_unbal_opener(b[.North]) &&
				two_suiter(s) &&
				norn.hcp(s) >= 13 \
			)
		},
	},
	{
		"1d-unbalanced-opener-slam-try-two-suiter",
		"Unbalanced 1D; South an 18+ two-suiter (slam try)",
		proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_1d_unbal_opener(b[.North]) &&
				two_suiter(s) &&
				norn.hcp(s) >= 18 \
			)
		},
	},
	{
		"1d-any-invitish-no-major-or-inverted",
		"1D opener (11+); South flat invitational or a possible inverted raise",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			south := b[.South]
			s_hcp := norn.hcp(south)
			return(
				is_1d_opener(north) &&
				norn.hcp(north) >= 11 &&
				is_flattish(south) &&
				((s_hcp >= 10 && s_hcp < 13) ||
						is_possible_inverted_diamond_raise(south)) \
			)
		},
	},
	{
		"1d-any-splinter-preempt-wjs",
		"1D opener; South makes a WJS, splinter, or diamond-preempt response",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			return(
				is_1d_opener(b[.North]) &&
				(is_possible_wjs_1d_response(south) ||
						is_possible_splinter_1d_response(south) ||
						is_possible_diamond_preempt_1d_response(south)) \
			)
		},
	},
	{
		"1d-weak-minor-minors",
		"1D opener; South a weak (5-9) no-major non-flat hand, East not a real opener",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			east := b[.East]
			s_hcp := norn.hcp(south)
			return(
				is_1d_opener(b[.North]) &&
				s_hcp < 10 &&
				s_hcp > 4 &&
				!has_side_major(south) &&
				!is_flattish(south) &&
				(norn.hcp(east) < 8 ||
						(norn.heart_length(east) < 5 && norn.spade_length(east) < 5)) \
			)
		},
	},
	{
		"1d-then-1x-interference",
		"1D opener; East overcalls; South has 6+ hcp with a major and the side has a major fit",
		proc(b: norn.Deal) -> bool {return is_1d_interference(b, false)},
	},
	{
		"1d-then-1x-interference-6major",
		"As 1d-then-1x-interference but South also holds a 6-card major",
		proc(b: norn.Deal) -> bool {return is_1d_interference(b, true)},
	},

	// --- 1-of-a-minor with competition ---
	{
		"1minor-(1s)",
		"1C/1D opener; East overcalls 1S (5+ spades); South has 5+ hcp",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			east := b[.East]
			return(
				(is_1d_opener(north) || is_any_1c_opener(north)) &&
				norn.spade_length(east) >= 5 &&
				is_1major_overcall(east) &&
				norn.hcp(b[.South]) >= 5 \
			)
		},
	},
	{
		"1minor-(overcall)",
		"1C/1D opener; East able to overcall (8+ hcp, not flat)",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			east := b[.East]
			return(
				(is_1d_opener(north) || is_any_1c_opener(north)) &&
				norn.hcp(east) >= 8 &&
				!is_flattish(east) \
			)
		},
	},

	// --- 1-of-a-major openings ---
	{
		"1major-any",
		"North opens 1 of a major",
		proc(b: norn.Deal) -> bool {return is_1major_opener(b[.North])},
	},
	{
		"1major-light-any",
		"North opens a light 1 of a major",
		proc(b: norn.Deal) -> bool {return is_light_1major_opener(b[.North])},
	},
	{"1major-inviteish", "1 major opener; South invitational (9-12)", proc(b: norn.Deal) -> bool {
			s_hcp := norn.hcp(b[.South])
			return is_1major_opener(b[.North]) && s_hcp >= 9 && s_hcp < 13
		}},
	{"1major-game-force", "1 major opener; South 13+ (game force)", proc(b: norn.Deal) -> bool {
			return is_1major_opener(b[.North]) && norn.hcp(b[.South]) >= 13
		}},
	{
		"1major-gf-3plus-card-support",
		"1 major opener; South 13+ with 3+ card support",
		proc(b: norn.Deal) -> bool {
			return(
				is_1major_opener(b[.North]) &&
				norn.hcp(b[.South]) >= 13 &&
				has_major_support(b[.North], b[.South], 3) \
			)
		},
	},
	{
		"1major-invite-4plus-card-support",
		"1 major opener; South 10+ with 4+ card support",
		proc(b: norn.Deal) -> bool {
			return(
				is_1major_opener(b[.North]) &&
				norn.hcp(b[.South]) >= 10 &&
				has_major_support(b[.North], b[.South], 4) \
			)
		},
	},
	{
		"1major-10plus-splinterable",
		"1 major opener; South 10+ with 4+ support and a shortage (splinter)",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			return(
				is_1major_opener(b[.North]) &&
				norn.hcp(south) >= 10 &&
				has_major_support(b[.North], south, 4) &&
				any_singleton_or_void(south) \
			)
		},
	},
	{
		"1major-minisplinter-or-single-suit-invite",
		"1 major opener; South a 7-11 4-card-support splinter or a 9-12 good-suit invite",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			south := b[.South]
			s_hcp := norn.hcp(south)
			if !is_1major_opener(north) {
				return false
			}
			splinter :=
				s_hcp >= 7 &&
				s_hcp <= 11 &&
				has_major_support(north, south, 4) &&
				any_singleton_or_void(south)
			invite := s_hcp >= 9 && s_hcp <= 12 && any_good_6_plus_carder(south)
			return splinter || invite
		},
	},
	{"1major-slam-try", "1 major opener; South 18+ (slam try)", proc(b: norn.Deal) -> bool {
			return is_1major_opener(b[.North]) && norn.hcp(b[.South]) >= 18
		}},
	{
		"1major-max-6-carder-maybe-1nt",
		"Maximum (14+) 1 major opener on a 6-bagger opposite a South hand that might pass 1NT",
		proc(b: norn.Deal) -> bool {return is_1major_max_6carder(b)},
	},

	// --- 1NT opening ---
	{
		"1n-opener",
		"North opens 1NT",
		proc(b: norn.Deal) -> bool {return is_1nt_opener(b[.North])},
	},
	{"1n-slam-try", "1NT opener; South 13+ (slam try)", proc(b: norn.Deal) -> bool {
			return is_1nt_opener(b[.North]) && norn.hcp(b[.South]) >= 13
		}},
	{"1n-two-suiter", "1NT opener; South a two-suiter", proc(b: norn.Deal) -> bool {
			return is_1nt_opener(b[.North]) && two_suiter(b[.South])
		}},
	{"1n-unbalanced", "1NT opener; South unbalanced", proc(b: norn.Deal) -> bool {
			return is_1nt_opener(b[.North]) && !is_flattish(b[.South])
		}},

	// --- 2C opening (strong / artificial) ---
	{
		"2c-opener",
		"North opens 2C",
		proc(b: norn.Deal) -> bool {return is_2c_opener(b[.North])},
	},
	{"2c-any-slam-try", "2C opener; South 18+ (slam try)", proc(b: norn.Deal) -> bool {
			return is_2c_opener(b[.North]) && norn.hcp(b[.South]) >= 18
		}},
	{
		"2c-any-two-suiter-slam-try",
		"2C opener; South a 17+ two-suiter",
		proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_2c_opener(b[.North]) &&
				two_suiter(s) &&
				norn.hcp(s) >= 17 \
			)
		},
	},
	{"2c-any-unbalanced", "2C opener; South unbalanced", proc(b: norn.Deal) -> bool {
			return is_2c_opener(b[.North]) && !is_flattish(b[.South])
		}},
	{
		"2c-positive-nine-plus-major-cards",
		"2C opener; South 8+ with 9+ cards in the majors",
		proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_2c_opener(b[.North]) &&
				has_9_plus_majors(s) &&
				norn.hcp(s) >= 8 \
			)
		},
	},
	{"2c-positive-two-suiter", "2C opener; South an 8+ two-suiter", proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_2c_opener(b[.North]) &&
				two_suiter(s) &&
				norn.hcp(s) >= 8 \
			)
		}},
	{"2c-positive-unbalanced", "2C opener; South 8+ unbalanced", proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_2c_opener(b[.North]) &&
				!is_flattish(s) &&
				norn.hcp(s) >= 8 \
			)
		}},
	{
		"2c-unbal-slam-try",
		"2C opener; South 16+ unbalanced (slam try)",
		proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_2c_opener(b[.North]) &&
				norn.hcp(s) >= 16 &&
				!is_flattish(s) \
			)
		},
	},

	// --- 2D openings (Precision-style and intermediate) ---
	{
		"2d-precision-any",
		"North opens a Precision 2D",
		proc(b: norn.Deal) -> bool {return is_2d_opener(b[.North])},
	},
	{"2d-precision-any-10-plus", "Precision 2D; South 10+", proc(b: norn.Deal) -> bool {
			return is_2d_opener(b[.North]) && norn.hcp(b[.South]) >= 10
		}},
	{"2d-precision-any-18-plus", "Precision 2D; South 18+", proc(b: norn.Deal) -> bool {
			return is_2d_opener(b[.North]) && norn.hcp(b[.South]) >= 18
		}},
	{
		"2d-intermediate-any",
		"North opens an intermediate 2D",
		proc(b: norn.Deal) -> bool {return is_2d_intermediate_opener(b[.North])},
	},
	{
		"2d-intermediate-under-invite",
		"Intermediate 2D; South sub-invitational (<=9)",
		proc(b: norn.Deal) -> bool {
			return is_2d_intermediate_opener(b[.North]) && norn.hcp(b[.South]) <= 9
		},
	},
	{
		"2d-intermediate-with-4cM",
		"Intermediate 2D with a side 4-card major; South 6+",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_2d_intermediate_opener(north) &&
				(norn.heart_length(north) == 4 || norn.spade_length(north) == 4) &&
				norn.hcp(b[.South]) >= 6 \
			)
		},
	},
	{"2d-intermediate-strong", "Intermediate 2D; South 16+", proc(b: norn.Deal) -> bool {
			return is_2d_intermediate_opener(b[.North]) && norn.hcp(b[.South]) >= 16
		}},
	{
		"2d-intermediate-good-6carder-GF",
		"Intermediate 2D; South 13+ with a good 6+ suit (game force)",
		proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_2d_intermediate_opener(b[.North]) &&
				norn.hcp(s) >= 13 &&
				any_good_6_plus_carder(s) \
			)
		},
	},
	{
		"2d-intermediate-twoish-suiters-GF",
		"Intermediate 2D; South 13+ with a 6-plus-other two-suiter (game force)",
		proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_2d_intermediate_opener(b[.North]) &&
				norn.hcp(s) >= 13 &&
				(is_6_plus_other_10_card_two_suiter(s) ||
						is_6_plus_other_11_or_more_card_two_suiter(s)) \
			)
		},
	},
	{
		"2d-intermediate-unbal-slam-try",
		"Intermediate 2D; South 16+ unbalanced (slam try)",
		proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_2d_intermediate_opener(b[.North]) &&
				norn.hcp(s) >= 16 &&
				!is_flattish(s) \
			)
		},
	},

	// --- Weak two-bids in the majors ---
	{
		"2hs-opener",
		"North opens a weak 2 in a major",
		proc(b: norn.Deal) -> bool {return is_weak2_major(b[.North])},
	},
	{
		"2hs-5card-opener",
		"North opens a 5-card weak two in a major",
		proc(b: norn.Deal) -> bool {return is_weak2_5card_major(b[.North])},
	},
	{
		"2hs-5-or-6-card-opener",
		"North opens a weak 5-or-6-card major",
		proc(b: norn.Deal) -> bool {return is_weak_5_or_6_card_major(b[.North])},
	},
	{"2hs-any-12-plus", "Weak 2 major; South 12+", proc(b: norn.Deal) -> bool {
			return is_weak2_major(b[.North]) && norn.hcp(b[.South]) >= 12
		}},
	{"2hs-any-20-plus", "Weak 2 major; South 20+", proc(b: norn.Deal) -> bool {
			return is_weak2_major(b[.North]) && norn.hcp(b[.South]) >= 20
		}},
	{"2hs-unbalanced-16-plus", "Weak 2 major; South 16+ unbalanced", proc(b: norn.Deal) -> bool {
			s := b[.South]
			return(
				is_weak2_major(b[.North]) &&
				norn.hcp(s) >= 16 &&
				!is_flattish(s) \
			)
		}},

	// --- 2NT opening ---
	{
		"2n-opener",
		"North opens 2NT",
		proc(b: norn.Deal) -> bool {return is_2nt_opener(b[.North])},
	},
	{"2n-slam-try", "2NT opener; South 11+ (slam try)", proc(b: norn.Deal) -> bool {
			return is_2nt_opener(b[.North]) && norn.hcp(b[.South]) >= 11
		}},
	{"2n-two-suiter", "2NT opener; South a two-suiter", proc(b: norn.Deal) -> bool {
			return is_2nt_opener(b[.North]) && two_suiter(b[.South])
		}},
	{"2n-unbalanced", "2NT opener; South unbalanced", proc(b: norn.Deal) -> bool {
			return is_2nt_opener(b[.North]) && !is_flattish(b[.South])
		}},

	// --- High openings and preempts ---
	{
		"3n-opener",
		"North opens a gambling 3NT",
		proc(b: norn.Deal) -> bool {return is_3n_opener(b[.North])},
	},
	{
		"3x-preempt",
		"North opens a 3-level preempt (minor 7-bagger or likely 3-major)",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_3cd_opener_1st2nd(north) ||
				is_likely_3major_preempt(north) \
			)
		},
	},
	{
		"4x-preempt",
		"North opens a 4-level preempt",
		proc(b: norn.Deal) -> bool {return is_likely_4level_preempt(b[.North])},
	},
	{
		"4n-opener",
		"North opens a potential 4NT (two-suited slam invitation)",
		proc(b: norn.Deal) -> bool {return is_potential_4n_opener(b[.North])},
	},
	{
		"5m-opener",
		"North opens an insane offensive preempt with a 7+ minor",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				is_insane_offensive_preempt(north) &&
				(norn.diamond_length(north) >= 7 || norn.club_length(north) >= 7) \
			)
		},
	},
	{
		"extreme-offensive-opener",
		"North holds an insane offensive preempt",
		proc(b: norn.Deal) -> bool {return is_insane_offensive_preempt(b[.North])},
	},
	{
		"8plus-pt-mixed",
		"North holds 8+ playing tricks",
		proc(b: norn.Deal) -> bool {return is_8_plus_tricks(b[.North])},
	},

	// --- Slam-zone and balanced study hands ---
	{
		"slam-hands-32-plus-hcp",
		"North-South hold a combined 32+ hcp",
		proc(b: norn.Deal) -> bool {return norn.hcp(b[.North]) + norn.hcp(b[.South]) >= 32},
	},
	{
		"slam-hands-35-plus-hcp",
		"North-South hold a combined 35+ hcp",
		proc(b: norn.Deal) -> bool {return norn.hcp(b[.North]) + norn.hcp(b[.South]) >= 35},
	},
	{
		"acol-lessons-balanced",
		"Both N and S flat; North 11+, South 5+ (balanced teaching hands)",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			south := b[.South]
			return(
				is_flattish(north) &&
				is_flattish(south) &&
				norn.hcp(north) >= 11 &&
				norn.hcp(south) >= 5 \
			)
		},
	},
	{
		"roman-2c-related",
		"North opens 2C / intermediate 2D / 1D but is NOT an 11-13 balanced hand",
		proc(b: norn.Deal) -> bool {
			north := b[.North]
			return(
				!nt5cM(north, 11, 13) &&
				(is_2c_opener(north) ||
						is_2d_intermediate_opener(north) ||
						is_1d_opener(north)) \
			)
		},
	},

	// --- Defending opponents' preempts (East/West are the preemptors) ---
	{
		"defence-vs-3s-or-4s-preempt",
		"E or W holds a 7+ spade preempt, limited combined E/W hcp",
		proc(b: norn.Deal) -> bool {return is_defence_vs_3s4s(b)},
	},
	{
		"defence-vs-high-preempts",
		"E or W opens any high (2NT-minors / 3-level) preempt",
		proc(b: norn.Deal) -> bool {
			return any_high_preempt(b[.West]) || any_high_preempt(b[.East])
		},
	},
	{
		"defense-vs-all-preempts",
		"E or W opens any preempt (weak twos through 4-level)",
		proc(b: norn.Deal) -> bool {return any_preempt(b[.West]) || any_preempt(b[.East])},
	},

	// --- Defending opponents' notrump openings (East opens the NT) ---
	{"defence-vs-mini-nt", "East opens a 10-12 NT; N-S may overcall", proc(b: norn.Deal) -> bool {
			return north_south_may_overcall_1N(b, 12) && nt5cM(b[.East], 10, 12)
		}},
	{"defence-vs-weak-nt", "East opens a 12-14 NT; N-S may overcall", proc(b: norn.Deal) -> bool {
			return north_south_may_overcall_1N(b, 14) && nt5cM(b[.East], 12, 14)
		}},
	{
		"defence-vs-weak-nt-invitational",
		"East opens a 12-14 NT; South may overcall opposite an invitational North",
		proc(b: norn.Deal) -> bool {
			return(
				nt5cM(b[.East], 12, 14) &&
				south_may_overcall_opponents_1N_with_north_invitational(b, 14) \
			)
		},
	},
	{
		"defence-vs-intermediate-nt",
		"East opens a 14-16 NT; N-S may overcall",
		proc(b: norn.Deal) -> bool {
			return north_south_may_overcall_1N(b, 15) && nt5cM(b[.East], 14, 16)
		},
	},
	{
		"defence-vs-strong-nt",
		"East opens a 15-17 NT; N-S may overcall",
		proc(b: norn.Deal) -> bool {
			return north_south_may_overcall_1N(b, 16) && nt5cM(b[.East], 15, 17)
		},
	},

	// --- Defending opponents' prepared-minor / strong-club openings ---
	{
		"defence-vs-prepared-minor",
		"East opens a prepared minor; South has both majors or a red weak-two shape",
		proc(b: norn.Deal) -> bool {
			south := b[.South]
			return(
				opens_std_1minor_prepared(b[.East]) &&
				(has_both_majors_michaels(south) || is_weak_2DH(south)) \
			)
		},
	},
	{
		"defence-vs-prepared-minor-with-majors",
		"East opens a prepared minor; South has both majors (Michaels)",
		proc(b: norn.Deal) -> bool {
			return(
				opens_std_1minor_prepared(b[.East]) &&
				has_both_majors_michaels(b[.South]) \
			)
		},
	},
	{
		"defence-vs-strong-club-unbal-or-major",
		"East opens a strong club / 17-19 NT; South has a shapely takeout",
		proc(b: norn.Deal) -> bool {return is_defence_vs_strong_club(b)},
	},

	// --- Overcalling an unbalanced 12-19 East opening ---
	{
		"unbalanced-overcalls",
		"East opens 12-19 unbalanced; South 7+ and not flat",
		proc(b: norn.Deal) -> bool {
			if !east_opens_unbalanced(b) {
				return false
			}
			s := b[.South]
			return norn.hcp(s) >= 7 && !is_flattish(s)
		},
	},
	{
		"unbalanced-two-suiter-overcalls",
		"East opens 12-19 unbalanced; South 7+, not flat, two-suiter",
		proc(b: norn.Deal) -> bool {
			if !east_opens_unbalanced(b) {
				return false
			}
			s := b[.South]
			return norn.hcp(s) >= 7 && !is_flattish(s) && two_suiter(s)
		},
	},
	{
		"unbalanced-intermediate-two-suiter-overcall",
		"East opens 12-19 unbalanced; South 11-15 two-suiter",
		proc(b: norn.Deal) -> bool {
			if !east_opens_unbalanced(b) {
				return false
			}
			s := b[.South]
			points := norn.hcp(s)
			return points >= 11 && points <= 15 && two_suiter(s)
		},
	},
}

// Shared body of the two `1c-strong-1hs-support*` scenarios: strong 1C opposite a South hand worth
// showing a major fit. `exclude_flat` adds the unbalanced variant's extra "South not flat" filter.
@(private)
is_1hs_support :: proc(b: norn.Deal, exclude_flat: bool) -> bool {
	north := b[.North]
	south := b[.South]
	if !is_strong_1c(north) {
		return false
	}
	if norn.hcp(south) < 8 || !has_side_major(south) {
		return false
	}
	// Need a fitting major: 3+ support opposite a 4+ holding in spades or hearts.
	spade_fit := norn.spade_length(north) >= 3 && norn.spade_length(south) >= 4
	heart_fit := norn.heart_length(north) >= 3 && norn.heart_length(south) >= 4
	if !spade_fit && !heart_fit {
		return false
	}
	if exclude_flat && is_flattish(south) {
		return false
	}
	// Exclude hands better described by a 1NT or solid-suit response.
	if is_any_1n_swedish_club_response(south) ||
	   is_4cd_swedish_club_response(south) ||
	   is_4hs_swedish_club_response(south) {
		return false
	}
	return true
}

// Shared body of the two `1d-then-1x-interference*` scenarios: 1D opener, East overcalls, and South
// has a 6+ hcp hand with a major while the E/W side also has a major fit worth competing over.
// `require_6major` adds the `-6major` variant's "South holds a 6-card major" filter.
@(private)
is_1d_interference :: proc(b: norn.Deal, require_6major: bool) -> bool {
	north := b[.North]
	south := b[.South]
	hs := norn.heart_length(south)
	ss := norn.spade_length(south)
	h_fit := norn.heart_length(b[.East]) + norn.heart_length(b[.West])
	s_fit := norn.spade_length(b[.East]) + norn.spade_length(b[.West])

	if require_6major && !(hs >= 6 || ss >= 6) {
		return false
	}
	if !(s_fit >= 8 || h_fit >= 8) {
		return false
	}
	if norn.hcp(south) < 6 {
		return false
	}
	if !(hs > 3 || ss > 3) {
		return false
	}
	if !is_1d_opener(north) {
		return false
	}
	return is_1major_overcall(b[.East]) || is_1d_takeout(b[.East])
}

// `1major-max-6-carder-maybe-1nt`: a maximum (14+) 1-major opener on a 6-card suit, opposite a South
// hand weak/shapeless enough that it might pass a 1NT rebid — i.e. NOT worth a 4-card raise, a 3-card
// limit raise, a 2S weak jump, or an invitational+ new suit. Ported statement-for-statement.
@(private)
is_1major_max_6carder :: proc(b: norn.Deal) -> bool {
	north := b[.North]
	south := b[.South]
	hs := norn.heart_length(north)
	ss := norn.spade_length(north)
	if norn.hcp(north) < 14 || (hs != 6 && ss != 6) || !is_1major_opener(north) {
		return false
	}
	s_hcp := norn.hcp(south)
	sh := norn.heart_length(south)
	sp := norn.spade_length(south)
	// A heart opener: reject any South worth a real heart action.
	if hs == 6 && (sh > 3 || (sh == 3 && s_hcp >= 10 && s_hcp <= 12) || (s_hcp < 9 && sp >= 7)) {
		return false
	}
	// A spade opener: same for spades.
	if ss == 6 && (sp > 3 || (sp == 3 && s_hcp >= 10 && s_hcp <= 12)) {
		return false
	}
	// No invitational-or-better jump shift in a 6-card side suit.
	if norn.club_length(south) >= 6 && s_hcp >= 10 {
		return false
	}
	if norn.diamond_length(south) >= 6 && s_hcp >= 10 {
		return false
	}
	if norn.heart_length(south) >= 6 && s_hcp >= 10 {
		return false
	}
	return true
}

// `defence-vs-3s-or-4s-preempt`: one of E/W has a 7+ spade preempt, the partnership is not strong
// enough to be in game on its own (E+W < 15), and the long hand is a recognised 3-major or 4-level
// preempt.
@(private)
is_defence_vs_3s4s :: proc(b: norn.Deal) -> bool {
	east := b[.East]
	west := b[.West]
	if norn.spade_length(west) < 7 && norn.spade_length(east) < 7 {
		return false
	}
	if norn.hcp(east) + norn.hcp(west) >= 15 {
		return false
	}
	return(
		is_likely_3major_preempt(west) ||
		is_likely_3major_preempt(east) ||
		is_likely_4level_preempt(west) ||
		is_likely_4level_preempt(east) \
	)
}

// The high-preempt family for a single hand (used by `defence-vs-high-preempts` over E and W).
@(private)
any_high_preempt :: proc(h: norn.Hand) -> bool {
	return(
		is_minors_2n_preempt(h) ||
		is_shapely_minor_preempt(h) ||
		is_standard_3cd_7carder(h) ||
		is_likely_3major_preempt(h) ||
		is_likely_4level_preempt(h) \
	)
}

// The full preempt family for a single hand (used by `defense-vs-all-preempts` over E and W): the
// high-preempt set plus the weak-two shapes.
@(private)
any_preempt :: proc(h: norn.Hand) -> bool {
	return(
		is_minors_2n_preempt(h) ||
		is_shapely_minor_preempt(h) ||
		is_standard_3cd_7carder(h) ||
		is_weak2_major(h) ||
		is_generic_5card_unbal_weak2(h) ||
		is_generic_weak2d(h) ||
		is_likely_3major_preempt(h) ||
		is_likely_4level_preempt(h) \
	)
}

// `defence-vs-strong-club-unbal-or-major`: East shows a strong club or 17-19 NT, and South holds a
// shapely takeout worth competing — 4-4 majors (10+), an 8+ non-flat or 9+-major hand, or a 5+ two-
// suiter (6+).
@(private)
is_defence_vs_strong_club :: proc(b: norn.Deal) -> bool {
	east := b[.East]
	if !nt5cM(east, 17, 19) && !is_strong_1c(east) {
		return false
	}
	south := b[.South]
	s := norn.hcp(south)
	if s >= 10 && majors_4_4(south) {
		return true
	}
	if s > 8 && !is_flattish(south) {
		return true
	}
	if s > 8 && has_9_plus_majors(south) {
		return true
	}
	if s > 5 && two_suiter(south) {
		return true
	}
	return false
}

// The shared East guard for the three `unbalanced-*-overcall(s)` scenarios: East has opened a
// 12-19 hcp unbalanced (non-flat) hand.
@(private)
east_opens_unbalanced :: proc(b: norn.Deal) -> bool {
	east := b[.East]
	e := norn.hcp(east)
	return !is_flattish(east) && e >= 12 && e <= 19
}
