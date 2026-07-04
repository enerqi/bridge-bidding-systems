package combo

/*
	combine_test.odin — tests for the objective layer + combination DP (combine.odin).

	Coverage:
	  * apply_objective(at_least) reproduces P(>= target);
	  * best_fixed_combination beats the all-top-down baseline and picks the finesse in a suit where a
	    high target needs the extra trick;
	  * the adaptive DP is never worse than the fixed combination, and EQUALS it for the linear
	    expected-tricks objective;
	  * the matchpoints objective yields a value in [0,1].
*/

import "core:testing"

import "norn:norn"

@(private = "file")
mask :: proc(ranks: ..norn.Rank) -> u16 {
	m: u16
	for r in ranks {
		m |= u16(1) << uint(r)
	}
	return m
}

// A hand whose spade suit is a finesse (AQ opposite xx) and whose other three suits are solid AKQ
// opposite a void (three certain tricks each).
@(private = "file")
finesse_hand :: proc() -> (north, south: norn.Hand_Summary) {
	north = norn.Hand_Summary {
		suits = {
			.Spades = mask(.Ace, .Queen),
			.Hearts = mask(.Ace, .King, .Queen),
			.Diamonds = mask(.Ace, .King, .Queen),
			.Clubs = mask(.Ace, .King, .Queen),
		},
	}
	south = norn.Hand_Summary {
		suits = {.Spades = mask(.Three, .Two), .Hearts = 0, .Diamonds = 0, .Clubs = 0},
	}
	return
}

// apply_objective with an at-least objective is exactly the P(>= target) tail.
@(test)
test_apply_objective_is_tail :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	north, south := finesse_hand()
	comb := best_fixed_combination(north, south, objective_at_least(10))
	testing.expectf(
		t,
		abs(apply_objective(comb.total, objective_at_least(10)) - p_at_least(comb.total, 10)) < 1e-12,
		"objective value should equal the P(>=10) tail",
	)
	sum := f64(0)
	for k in 0 ..= RANKS {
		sum += comb.total[k]
	}
	testing.expectf(t, abs(sum - 1) < 1e-9, "combined total must sum to 1, got %v", sum)
}

// The three solid suits give 9 tricks; the eleventh trick can only come from finding the spade queen,
// so at target 11 the best combination must adopt the finesse in spades (top-down never finds it).
@(test)
test_fixed_combination_picks_finesse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	north, south := finesse_hand()
	comb := best_fixed_combination(north, south, objective_at_least(11))

	testing.expectf(t, comb.lines[.Spades] == "finesse", "spades line should be the finesse, got %q", comb.lines[.Spades])
	testing.expect(t, comb.value > 0.4, "P(>=11) via the finesse should be roughly a half")
}

// The best combination is at least as good as blindly playing top-down everywhere.
@(test)
test_fixed_beats_baseline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	north, south := finesse_hand()
	obj := objective_at_least(11)
	comb := best_fixed_combination(north, south, obj)

	// All-top-down total.
	base := [RANKS + 1]f64{}
	base[0] = 1
	for suit in DISPLAY_SUITS {
		d := sd_line_distribution(north.suits[suit], south.suits[suit], line_top_down)
		base = convolve(base, d.p)
	}
	testing.expectf(t, comb.value >= apply_objective(base, obj) - 1e-12, "best combination must beat baseline")
}

// A FULL 13/13 deal (both hands 4-3-3-3, scattered honours) whose four per-suit MAX trick counts sum to
// <= 13, so the joint 13-trick cap never bites. The joint adaptive DP (`optimal_adaptive_value`) needs a
// full hand (East holds 13 of 26); this is the same "mirror" deal `joint_test` proves is cap-free, so its
// linear-objective equality (below) holds exactly by linearity of expectation. (`finesse_hand` above is a
// partial synthetic holding — fine for the independent `best_fixed_combination`, not for the joint DP.)
@(private = "file")
full_nocap_hand :: proc() -> (north, south: norn.Hand_Summary) {
	north = norn.Hand_Summary {
		suits = {
			.Spades = mask(.Ace, .Seven, .Four, .Two),
			.Hearts = mask(.Ace, .Eight, .Three),
			.Diamonds = mask(.Ace, .Nine, .Five),
			.Clubs = mask(.Ace, .Ten, .Six),
		},
	}
	south = norn.Hand_Summary {
		suits = {
			.Spades = mask(.King, .Queen, .Nine, .Five),
			.Hearts = mask(.King, .Seven, .Four),
			.Diamonds = mask(.Queen, .Jack, .Six),
			.Clubs = mask(.King, .Eight, .Four),
		},
	}
	return
}

// The JOINT adaptive DP (`optimal_adaptive_value`) is never worse than a fixed line-per-suit combination
// (adapting can only help), and for the LINEAR expected-tricks objective — when the 13-trick cap never
// bites — it equals the sum of the best-mean line per suit (no cross-suit interaction, so nothing to
// adapt). Both comparisons are made WITHIN the joint model on a full cap-free deal.
@(test)
test_adaptive_bounds_and_linear :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	north, south := full_nocap_hand()

	// A joint fixed baseline: fold the all-top-down line in every suit under the joint constraint.
	base_tables: [norn.Suit]Suit_Joint_Table
	for suit in DISPLAY_SUITS {
		base_tables[suit] = sd_line_joint_table(north.suits[suit], south.suits[suit], line_top_down)
	}
	base_total := joint_total(base_tables)

	make_obj := objective_at_least(9)
	fixed := apply_objective(base_total, make_obj)
	adaptive := optimal_adaptive_value(north, south, make_obj)
	testing.expectf(t, adaptive >= fixed - 1e-12, "adaptive %.4f must be >= the fixed top-down baseline %.4f", adaptive, fixed)

	// For E[tricks] with no cap, the joint adaptive optimum equals the sum over suits of the best line's
	// mean tricks (linearity of expectation; the joint length constraint reweights but does not shift any
	// per-suit marginal mean, and with no cap the four means simply add).
	adaptive_et := optimal_adaptive_value(north, south, objective_expected_tricks())
	best_mean_sum := f64(0)
	for suit in DISPLAY_SUITS {
		best := f64(0)
		for line in candidate_lines() {
			m := expected_tricks(sd_line_distribution(north.suits[suit], south.suits[suit], line).p)
			best = max(best, m)
		}
		best_mean_sum += best
	}
	testing.expectf(t, abs(adaptive_et - best_mean_sum) < 1e-9, "for E[tricks], adaptive %.6f should equal the sum of best-mean lines %.6f", adaptive_et, best_mean_sum)
}

// The card-page make curve (`adaptive_at_least_curve`, the joint adaptive optimum at every target) is a
// valid cumulative curve: curve[0] == 1 (you always take at least 0 tricks), monotone non-increasing, and
// every entry a probability in [0, 1].
@(test)
test_adaptive_curve_valid :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	north, south := full_nocap_hand()
	curve := adaptive_at_least_curve(north, south)

	testing.expectf(t, abs(curve[0] - 1) < 1e-9, "curve[0] must be 1, got %.6f", curve[0])
	prev := curve[0]
	for k in 1 ..= RANKS {
		testing.expectf(t, curve[k] >= -1e-12 && curve[k] <= 1 + 1e-12, "curve[%d] = %.6f out of [0,1]", k, curve[k])
		testing.expectf(t, curve[k] <= prev + 1e-12, "curve not monotone at k=%d (%.6f > %.6f)", k, curve[k], prev)
		prev = curve[k]
	}
}

// The matchpoints objective (against a field distribution) scores in [0,1].
@(test)
test_matchpoints_in_unit_range :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	north, south := finesse_hand()
	// Field = the census total of this same hand — a stand-in "what the field can do".
	field := [RANKS + 1]f64{}
	field[0] = 1
	for suit in DISPLAY_SUITS {
		field = convolve(field, suit_trick_distribution(north.suits[suit], south.suits[suit]).p)
	}
	comb := best_fixed_combination(north, south, objective_matchpoints(field))
	testing.expectf(t, comb.value >= -1e-12 && comb.value <= 1 + 1e-12, "matchpoint value %.4f must be in [0,1]", comb.value)
}
