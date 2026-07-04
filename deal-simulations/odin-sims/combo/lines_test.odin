package combo

/*
	lines_test.odin — tests for the Phase-2 candidate-line generator (lines.odin).

	Run:  odin test combo -collection:norn=<norn> -out:target/debug/test-combo.exe

	Coverage:
	  * every candidate line yields a valid distribution;
	  * on the classic AQ-opp-xx finesse, `line_finesse` beats `line_top_down` and `best_line` picks it;
	  * the Pareto frontier is non-empty, internally non-dominated, and collapses to one line when the
	    holding is solid (all lines coincide);
	  * the compound candidates are registered; `line_finesse_other` finesses the WRONG way on a one-way
	    holding (a distinct, worse distribution); `line_duck_then_finesse` is a phased line that costs
	    nothing on a solid holding (the duck cannot be overtaken).
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

// Every candidate line produces a probability distribution (sums to 1) on a spread of holdings.
@(test)
test_candidates_are_distributions :: proc(t: ^testing.T) {
	cases := [][2]u16 {
		{mask(.Ace, .Queen), mask(.Three, .Two)},
		{mask(.Ace, .King, .Jack), mask(.Four, .Three, .Two)},
		{mask(.King, .Queen, .Ten), mask(.Six, .Five, .Four)},
		{mask(.Ace, .King, .Queen), 0},
	}
	for c in cases {
		cands := suit_candidate_lines(c[0], c[1])
		defer delete(cands)
		for lr in cands {
			sum := f64(0)
			for k in 0 ..= RANKS {
				sum += lr.dist.p[k]
			}
			testing.expectf(t, abs(sum - 1) < 1e-9, "line %s: sum = %v, want 1", lr.name, sum)
		}
	}
}

// AQ opposite xx: the finesse line takes ~2 tricks half the time; top-down never does. So the finesse
// strictly beats top-down on both P(>=2) and mean.
@(test)
test_finesse_beats_top_down :: proc(t: ^testing.T) {
	n := mask(.Ace, .Queen)
	s := mask(.Three, .Two)
	top := sd_line_distribution(n, s, line_top_down)
	fin := sd_line_distribution(n, s, line_finesse)

	testing.expectf(
		t,
		p_at_least(fin.p, 2) > p_at_least(top.p, 2) + 0.3,
		"finesse P(>=2) %.3f should beat top-down %.3f",
		p_at_least(fin.p, 2),
		p_at_least(top.p, 2),
	)
	testing.expect(t, expected_tricks(fin.p) > expected_tricks(top.p) + 0.3, "finesse mean should beat top-down")
}

// `best_line` for a 2-trick target on AQ-opp-xx should choose the finesse.
@(test)
test_best_line_picks_finesse :: proc(t: ^testing.T) {
	best := best_line(mask(.Ace, .Queen), mask(.Three, .Two), 2)
	testing.expectf(t, best.name == "finesse", "best line for target 2 was %q, want finesse", best.name)
	testing.expect(t, p_at_least(best.dist.p, 2) > 0.4, "the finesse should make >=2 roughly half the time")
}

// The Pareto frontier is non-empty and internally consistent: no member dominates another.
@(test)
test_pareto_non_dominated :: proc(t: ^testing.T) {
	cands := suit_candidate_lines(mask(.Ace, .Queen), mask(.Three, .Two))
	defer delete(cands)
	front := pareto_lines(cands)
	defer delete(front)

	testing.expect(t, len(front) >= 1, "frontier must be non-empty")
	for a, i in front {
		for b, j in front {
			if i == j {
				continue
			}
			testing.expectf(t, !line_dominates(a.dist, b.dist), "pareto member %s dominates %s", b.name, a.name)
		}
	}
}

// A solid AKQ makes three tricks under every line, so the frontier de-duplicates to a single entry.
@(test)
test_pareto_collapses_when_solid :: proc(t: ^testing.T) {
	cands := suit_candidate_lines(mask(.Ace, .King, .Queen), 0)
	defer delete(cands)
	front := pareto_lines(cands)
	defer delete(front)
	testing.expectf(t, len(front) == 1, "solid suit should collapse to one frontier line, got %d", len(front))
}

// The two compound candidates are registered (they must appear in `candidate_lines` for the DP,
// `best_line`, and the card-page emit to pick them up).
@(test)
test_compound_lines_registered :: proc(t: ^testing.T) {
	lines := candidate_lines()
	have_other, have_dtf := false, false
	for l in lines {
		if l.name == "finesse-other" {have_other = true}
		if l.name == "duck-then-finesse" {have_dtf = true}
	}
	testing.expect(t, have_other, "finesse-other should be a registered candidate")
	testing.expect(t, have_dtf, "duck-then-finesse should be a registered candidate")
}

// On the one-way AQ-opp-xx, `line_finesse` leads TOWARD the AQ tenace; `line_finesse_other` leads the
// other way (into the tenace), which is the wrong guess. So the two directions are DISTINCT and the
// correct one takes strictly more tricks — i.e. exposing both directions gives the DP a real choice.
@(test)
test_finesse_other_is_distinct :: proc(t: ^testing.T) {
	n := mask(.Ace, .Queen)
	s := mask(.Three, .Two)
	fin := sd_line_distribution(n, s, line_finesse)
	oth := sd_line_distribution(n, s, line_finesse_other)

	testing.expect(t, !dist_near_equal(fin, oth), "the two finesse directions should differ on a one-way holding")
	testing.expectf(
		t,
		expected_tricks(fin.p) > expected_tricks(oth.p) + 1e-9,
		"finessing toward the tenace (%.3f) should beat the wrong way (%.3f)",
		expected_tricks(fin.p),
		expected_tricks(oth.p),
	)
}

// `line_duck_then_finesse` ducks round one then finesses. On a solid AKQ (opposite void) the duck cannot
// be overtaken — the opponents hold nothing above the Queen — so the phased line still takes all three
// tricks: the compound line costs nothing when there is nothing to lose, and its distribution is valid.
@(test)
test_duck_then_finesse_no_cost_when_solid :: proc(t: ^testing.T) {
	d := sd_line_distribution(mask(.Ace, .King, .Queen), 0, line_duck_then_finesse)
	sum := f64(0)
	for k in 0 ..= RANKS {sum += d.p[k]}
	testing.expectf(t, abs(sum - 1) < 1e-9, "distribution must sum to 1, got %v", sum)
	testing.expectf(t, abs(expected_tricks(d.p) - 3) < 1e-9, "solid AKQ should still take 3 tricks, got %.4f", expected_tricks(d.p))
}

// The compound line EARNS its place: on AKJ7 opposite 63 (missing the queen and a fistful of spots),
// conceding the first round before running the jack-finesse strictly out-scores every single-phase line
// by mean tricks — so `best_line_by_mean` (which drives the card-page recommendation and the DP fallback)
// actually selects "duck-then-finesse". Regression guard that the phased candidate is reachable, not dead
// weight. (Holding surfaced by a random-holding sweep of all five candidates.)
@(test)
test_duck_then_finesse_selected_by_mean :: proc(t: ^testing.T) {
	n := mask(.Ace, .King, .Jack, .Seven)
	s := mask(.Six, .Three)
	best := best_line_by_mean(n, s)
	testing.expectf(t, best.name == "duck-then-finesse", "best line by mean was %q, want duck-then-finesse", best.name)

	fin := sd_line_distribution(n, s, line_finesse)
	testing.expectf(
		t,
		expected_tricks(best.dist.p) > expected_tricks(fin.p) + 1e-9,
		"duck-then-finesse mean %.4f should beat plain finesse %.4f",
		expected_tricks(best.dist.p),
		expected_tricks(fin.p),
	)
}
