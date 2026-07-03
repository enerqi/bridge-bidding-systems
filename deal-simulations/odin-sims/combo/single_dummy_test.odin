package combo

/*
	single_dummy_test.odin — tests for the Phase-2 fixed-line evaluator (single_dummy.odin).

	Run:  odin test combo -collection:norn=<norn> -out:target/debug/test-combo.exe

	Coverage:
	  * evaluator mechanics on hand-computable holdings (solid, two-tops, drop) with `line_top_down`;
	  * the defining Phase-2 property: a fixed line's mean tricks <= the Phase-1 census mean (the
	    double-dummy tax is non-negative);
	  * a worked finesse: `line_top_down` (never finesses) leaves ~half a trick on AQ-opp-xx, and a
	    bespoke finesse line recovers exactly the census optimum there — showing both that the
	    evaluator scores lines correctly and that line choice matters.
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

// AKQ opposite a void, played top-down: three solid winners in every layout.
@(test)
test_sd_solid_certain :: proc(t: ^testing.T) {
	d := sd_line_distribution(mask(.Ace, .King, .Queen), 0, line_top_down)
	testing.expectf(t, abs(d.p[3] - 1) < 1e-9, "P(3 tricks) = %v, want 1", d.p[3])
}

// AK opposite two small: cashing the tops takes exactly two tricks, whatever the split — the
// opponents hold every other rank and win once the tops are gone. Pins multi-trick play + scoring.
@(test)
test_sd_two_tops_exact :: proc(t: ^testing.T) {
	d := sd_line_distribution(mask(.Ace, .King), mask(.Three, .Two), line_top_down)
	testing.expectf(t, abs(d.p[2] - 1) < 1e-9, "P(2 tricks) = %v, want 1", d.p[2])
}

// A fixed line's distribution is still a probability distribution.
@(test)
test_sd_distribution_sums_to_one :: proc(t: ^testing.T) {
	cases := [][2]u16 {
		{mask(.Ace, .Queen), mask(.Three, .Two)},
		{mask(.Ace, .King, .Jack), mask(.Four, .Three, .Two)},
		{mask(.King, .Queen), mask(.Five, .Four)},
	}
	for c in cases {
		d := sd_line_distribution(c[0], c[1], line_top_down)
		sum := f64(0)
		for k in 0 ..= RANKS {
			sum += d.p[k]
		}
		testing.expectf(t, abs(sum - 1) < 1e-9, "distribution sum = %v, want 1", sum)
	}
}

// The defining Phase-2 property: a blind line never beats the double-dummy census (which sees every
// layout). So sd_mean <= census_mean for every holding — the gap is the double-dummy tax.
@(test)
test_sd_never_beats_census :: proc(t: ^testing.T) {
	cases := [][2]u16 {
		{mask(.Ace, .Queen), mask(.Three, .Two)},
		{mask(.Ace, .King, .Jack), mask(.Four, .Three, .Two)},
		{mask(.King, .Queen, .Ten), mask(.Five, .Four, .Three)},
		{mask(.Ace, .Jack, .Ten), mask(.Nine, .Three, .Two)},
	}
	for c in cases {
		sd_mean, census_mean, gap := sd_census_gap(c[0], c[1], line_top_down)
		testing.expectf(
			t,
			gap >= -1e-9,
			"sd_mean %.3f must be <= census_mean %.3f (gap %.3f)",
			sd_mean,
			census_mean,
			gap,
		)
	}
}

// AQ opposite xx: `line_top_down` cashes the ace then leads the queen into the king, so it NEVER
// finesses — it takes ~one trick in every layout (the tiny excess over 1.0 is the rare layout where
// the king is singleton and falls under the cashed ace), while the double-dummy census (finesse
// right per layout) averages ~1.5. The gap is the cost of the un-taken finesse.
@(test)
test_sd_top_down_leaves_finesse :: proc(t: ^testing.T) {
	sd_mean, census_mean, gap := sd_census_gap(mask(.Ace, .Queen), mask(.Three, .Two), line_top_down)
	testing.expectf(t, sd_mean >= 1 && sd_mean < 1.05, "top-down should take ~1 trick, got %.3f", sd_mean)
	testing.expectf(t, census_mean > 1.4, "census should average > 1.4, got %.3f", census_mean)
	testing.expectf(t, gap > 0.35, "the un-taken finesse should cost > 0.35 tricks, got %.3f", gap)
}

// A bespoke finesse line for AQ-opp-xx: lead low from the hand WITHOUT the queen, finesse the queen,
// but cover with the ace if the king appears on the left. This blind line captures essentially all
// of the double-dummy census (it beats top-down by the ~half-trick the finesse is worth). It is not
// PERFECTLY optimal — because it leads low first it forgoes the tiny gain of cashing the ace to drop
// a singleton king offside — so a hair of tax remains. That residue is exactly the kind of line
// imperfection the optimal-line search (next increment) will squeeze out.
@(test)
test_sd_finesse_line_recovers_census :: proc(t: ^testing.T) {
	QUEEN :: 10

	finesse := Sd_Line {
		name = "finesse-queen",
		lead = proc(north, south, played: u16) -> (seat: int, rank: int) {
			// Lead low from the hand that does NOT hold the queen (toward the tenace).
			if south != 0 && south & (u16(1) << QUEEN) == 0 {
				return SEAT_S, lowest_rank(south)
			}
			if north != 0 {
				return SEAT_N, lowest_rank(north)
			}
			return SEAT_S, lowest_rank(south)
		},
		partner = proc(v: Sd_View) -> int {
			// King (or higher) showed on the left: cover with our top card. Otherwise finesse the
			// queen if we hold it; else our lowest.
			if v.win_rank > QUEEN && !v.win_ns {
				return highest_rank(v.own)
			}
			if v.own & (u16(1) << QUEEN) != 0 {
				return QUEEN
			}
			return lowest_rank(v.own)
		},
	}

	fin_mean, census_mean, gap := sd_census_gap(mask(.Ace, .Queen), mask(.Three, .Two), finesse)
	top_mean := expected_tricks(sd_line_distribution(mask(.Ace, .Queen), mask(.Three, .Two), line_top_down).p)

	testing.expectf(t, gap >= -1e-9 && gap < 0.01, "finesse should capture ~all the census optimum, gap = %.4f", gap)
	testing.expectf(t, fin_mean > top_mean + 0.3, "finesse (%.3f) should beat top-down (%.3f)", fin_mean, top_mean)
	testing.expectf(t, abs(fin_mean - census_mean) < 0.01, "finesse %.3f should ~equal census %.3f", fin_mean, census_mean)
}
