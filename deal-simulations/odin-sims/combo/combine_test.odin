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

// The adaptive DP never underperforms the fixed combination, and matches it exactly for the linear
// expected-tricks objective (no cross-suit interaction).
@(test)
test_adaptive_bounds_and_linear :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	north, south := finesse_hand()

	make_obj := objective_at_least(11)
	fixed := best_fixed_combination(north, south, make_obj).value
	adaptive := optimal_adaptive_value(north, south, make_obj)
	testing.expectf(t, adaptive >= fixed - 1e-12, "adaptive %.4f must be >= fixed %.4f", adaptive, fixed)

	et := objective_expected_tricks()
	fixed_et := best_fixed_combination(north, south, et).value
	adaptive_et := optimal_adaptive_value(north, south, et)
	testing.expectf(t, abs(adaptive_et - fixed_et) < 1e-9, "for E[tricks], adaptive %.4f should equal fixed %.4f", adaptive_et, fixed_et)
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
