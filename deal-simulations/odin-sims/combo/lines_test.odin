package combo

/*
	lines_test.odin — tests for the Phase-2 candidate-line generator (lines.odin).

	Run:  odin test combo -collection:norn=<norn> -out:target/debug/test-combo.exe

	Coverage:
	  * every candidate line yields a valid distribution;
	  * on the classic AQ-opp-xx finesse, `line_finesse` beats `line_top_down` and `best_line` picks it;
	  * the Pareto frontier is non-empty, internally non-dominated, and collapses to one line when the
	    holding is solid (all lines coincide).
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
