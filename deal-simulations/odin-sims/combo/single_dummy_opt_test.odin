package combo

/*
	single_dummy_opt_test.odin — tests for the optimal single-dummy search (single_dummy_opt.odin).

	Exact search is only tractable when NS holds most of the suit (few missing cards), so the exact
	tests use LONG holdings (small m). Coverage:
	  * bounds that must always hold: best fixed candidate <= optimal <= double-dummy census;
	  * a no-guess holding where optimal == census exactly;
	  * a genuine TWO-WAY guess (finesse either opponent for a queen) where the blind optimum is
	    STRICTLY below the census — proof the search actually confronts a guess rather than peeking;
	  * a short holding that blows the budget falls back to a valid distribution (exact = false).
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

@(private = "file")
best_candidate_mean :: proc(north, south: u16) -> f64 {
	lines := candidate_lines()
	best := f64(-1)
	for line in lines {
		d := sd_line_distribution(north, south, line)
		mn := expected_tricks(d.p)
		if mn > best {
			best = mn
		}
	}
	return best
}

// A running suit — North AKQJT9 (6), South 87654 (5), opponents hold only the two lowest cards. Both
// NS hands follow every trick (two cards spent per trick), so the suit is worth max(6, 5) = 6 tricks,
// not 11 — and the optimal search confirms it exactly, matching the (now-fixed) census.
@(test)
test_opt_no_guess_equals_census :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := mask(.Ace, .King, .Queen, .Jack, .Ten, .Nine)
	s := mask(.Eight, .Seven, .Six, .Five, .Four)
	dist, exact := sd_optimal_distribution(n, s)
	census := suit_trick_distribution(n, s)

	testing.expect(t, exact, "a running holding with few missing cards should solve exactly")
	testing.expectf(t, abs(dist.p[6] - 1) < 1e-9, "should take exactly 6 tricks, P(6) = %v", dist.p[6])
	testing.expectf(
		t,
		abs(expected_tricks(dist.p) - expected_tricks(census.p)) < 1e-9,
		"optimal %.3f should equal census %.3f",
		expected_tricks(dist.p),
		expected_tricks(census.p),
	)
}

// The core invariant, on an exactly-solvable holding: best fixed candidate <= optimal <= census.
@(test)
test_opt_within_bounds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Two-way-queen holding (see the strict test below) — 10 cards, only 3 missing, so exact.
	n := mask(.Ace, .Jack, .Nine, .Seven, .Five)
	s := mask(.King, .Ten, .Eight, .Six, .Four)

	opt, exact := sd_optimal_expected_tricks(n, s)
	testing.expect(t, exact, "10-card holding (3 missing) should solve exactly")

	cand := best_candidate_mean(n, s)
	census := expected_tricks(suit_trick_distribution(n, s).p)

	testing.expectf(t, opt >= cand - 1e-9, "optimal %.3f must be >= best candidate %.3f", opt, cand)
	testing.expectf(t, opt <= census + 1e-9, "optimal %.3f must be <= census %.3f", opt, census)
}

// A genuine two-way finesse for the queen (North A J …, South K T …, queen missing and guarded). The
// double-dummy census always guesses right; a BLIND declarer cannot, so the optimum is strictly below
// the census. This proves the search models declarer's guess rather than peeking at the split.
@(test)
test_opt_two_way_guess_below_census :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := mask(.Ace, .Jack, .Nine, .Seven, .Five)
	s := mask(.King, .Ten, .Eight, .Six, .Four)

	opt, exact := sd_optimal_expected_tricks(n, s)
	census := expected_tricks(suit_trick_distribution(n, s).p)

	testing.expect(t, exact, "should solve exactly")
	testing.expectf(t, census - opt > 0.02, "blind optimum %.3f should trail census %.3f by a real guess", opt, census)
}

// A short holding (AQ opposite xx) has too many missing cards for the exact search; it must fall back
// to a valid distribution (flagged non-exact) rather than crashing or returning garbage.
@(test)
test_opt_falls_back_on_short_holding :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dist, exact := sd_optimal_distribution(mask(.Ace, .Queen), mask(.Three, .Two))
	sum := f64(0)
	for k in 0 ..= RANKS {
		sum += dist.p[k]
	}
	testing.expectf(t, abs(sum - 1) < 1e-9, "fallback distribution must still sum to 1, got %v", sum)
	testing.expect(t, !exact, "a 9-missing holding should exceed the budget and fall back")
	// Whatever the path, the mean cannot exceed the double-dummy census.
	census := expected_tricks(suit_trick_distribution(mask(.Ace, .Queen), mask(.Three, .Two)).p)
	testing.expectf(t, expected_tricks(dist.p) <= census + 1e-9, "fallback mean %.3f must be <= census %.3f", expected_tricks(dist.p), census)
}
