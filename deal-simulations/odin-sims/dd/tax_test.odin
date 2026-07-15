package dd

/*
	tax_test.odin — validation for the misguess-tax estimator (tax.odin).

	The estimator is the DECIDED cheap achievable single-dummy number (COMBO_ANALYSER.md "NEXT SESSION").
	These tests pin its two headline behaviours against the PIMC spike's boards:
	  * a board with a genuine blind TWO-WAY guess -> achievable meaningfully BELOW the DD ceiling (a real
	    tax), but not absurdly low (it stays above PIMC's pessimistic procrastination floor);
	  * a board with NO real guess (a cold slam; a cold 3NT with solid tops) -> achievable ≈ ceiling, i.e.
	    NO spurious tax. This is exactly where naive PIMC UNDERSHOOTS (the cold slam reads ~80% there), so
	    it is the estimator's key advantage — the geometric guess filter keeps a cold contract cold.
	Run single-threaded (the `test-dd` recipe forces THREADS=1: DDS is not reentrant).
*/

import "core:testing"

import "norn:norn"

// A board built AROUND a two-way queen finesse. Spades AJ54 opp KT32 miss Q9876 — a genuine two-way guess
// (finesse toward AJ or toward KT), and it decides the 9th trick of 3NT. Double-dummy catches the queen
// whenever the layout allows, so 3NT is a high CEILING (~70-82% here — not stone cold, since some Q-with-
// length layouts beat even the two-way finesse). A blind declarer must pick a side and is right only
// ~half the time, so the achievable is FAR lower (~35%). Asserts a real tax, the spade queen as the
// identified pivot, and a sane (non-blow-up) achievable band. (Measured seed 7, n=300: ceiling 71.3,
// achievable 36.0, tax 35.3.)
@(test)
test_tax_two_way_guess_is_docked :: proc(t: ^testing.T) {
	init()
	board, err := norn.parse_pbn_deal(`[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	c, _ := parse_contract("3NT")
	res, ok := misguess_tax(board, {.North, .South}, c, 300, 7)
	testing.expect(t, ok)
	testing.expect_value(t, res.n, 300)

	testing.expect(t, res.ceiling_pct >= 60.0 && res.ceiling_pct <= 90.0) // high but not cold
	testing.expect(t, res.achievable_pct <= res.ceiling_pct) // a blind commit can never beat peeking
	testing.expect(t, res.tax_pts >= 20.0) // the blind two-way guess costs a real chunk
	testing.expect(t, res.achievable_pct >= 25.0 && res.achievable_pct <= 50.0) // right ~half the time, no blow-up

	// The queen of spades is the identified guess.
	testing.expect(t, res.n_pivots >= 1)
	q_spades := norn.make_card(.Spades, .Queen)
	found := false
	for i in 0 ..< res.n_pivots {
		if res.pivots[i].card == q_spades {
			found = true
		}
	}
	testing.expect(t, found)
	// pivots are dominant-first: pivots[0] is the guess that set the achievable.
	testing.expect(t, res.pivots[0].achievable == res.achievable_pct)
}

// A COLD slam with solid tops and NO two-way guess (the PIMC spike's near-cold board). Naive PIMC
// UNDERSHOOTS this to ~80%; the misguess-tax estimator must NOT — its geometric filter finds no guess, so
// the achievable equals the ceiling. This is the estimator's whole point over PIMC.
@(test)
test_tax_cold_slam_untaxed :: proc(t: ^testing.T) {
	init()
	board, err := norn.parse_pbn_deal(`[Deal "N:AKQJ2.AK3.A32.A2 - 543.QJ2.KQ4.KQ43 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	c, _ := parse_contract("6S")
	res, ok := misguess_tax(board, {.North, .South}, c, 200, 3)
	testing.expect(t, ok)
	testing.expect_value(t, res.n_pivots, 0) // AKQ-solid suits: no two-way tenace to guess
	testing.expect(t, res.ceiling_pct >= 95.0) // a cold slam
	testing.expect_value(t, res.achievable_pct, res.ceiling_pct) // no guess -> no tax
	testing.expect_value(t, res.tax_pts, 0.0)
}

// A cold 3NT with 11 top tricks split as AKQ/AK across the pair (the PIMC spike's `test_pimc_measure`
// board). It has no TIGHT two-way tenace — AK missing Q with low cards is not a finesse — so again no
// spurious tax, where naive PIMC read ~94% (its procrastination undershoot on an actually-cold hand).
@(test)
test_tax_cold_3nt_untaxed :: proc(t: ^testing.T) {
	init()
	board, err := norn.parse_pbn_deal(`[Deal "N:AK32.AK2.A432.A2 - QJ54.Q43.K5.K543 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	c, _ := parse_contract("3NT")
	res, ok := misguess_tax(board, {.North, .South}, c, 200, 5)
	testing.expect(t, ok)
	testing.expect_value(t, res.n_pivots, 0)
	testing.expect(t, res.ceiling_pct >= 99.0)
	testing.expect_value(t, res.tax_pts, 0.0)
}

// The ceiling the tax estimator computes must MATCH sample_contract's make-% exactly (same board, seed,
// n): they share the sampling loop, so this guards against the tax pass drifting from the census ceiling.
@(test)
test_tax_ceiling_matches_sample :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_pbn_deal(`[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`)
	c, _ := parse_contract("3NT")
	tax, tok := misguess_tax(board, {.North, .South}, c, 150, 9)
	samp, sok := sample_contract(board, {.North, .South}, c, 150, 9)
	testing.expect(t, tok && sok)
	testing.expect_value(t, tax.ceiling_pct, samp.make_pct)
	testing.expect_value(t, tax.mean_tricks, samp.mean_tricks)
}

// Reproducibility: same seed -> identical numbers.
@(test)
test_tax_seed_reproducible :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_pbn_deal(`[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`)
	c, _ := parse_contract("3NT")
	r1, ok1 := misguess_tax(board, {.North, .South}, c, 120, 4)
	r2, ok2 := misguess_tax(board, {.North, .South}, c, 120, 4)
	testing.expect(t, ok1 && ok2)
	testing.expect_value(t, r1.achievable_pct, r2.achievable_pct)
	testing.expect_value(t, r1.tax_pts, r2.tax_pts)
}

// The pivot geometry alone (no sampling): two-way guesses are flagged, one-way (forced) finesses and
// solid-top holdings are NOT — the filter that keeps cold contracts cold.
@(test)
test_tax_pivot_geometry :: proc(t: ^testing.T) {
	// Two-way queen (AJ54 / KT32): flagged.
	{
		board, _ := norn.parse_pbn_deal(`[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`)
		pivots, n := two_way_guess_pivots(board.deal, .North, .South)
		testing.expect_value(t, n, 1)
		testing.expect_value(t, pivots[0], norn.make_card(.Spades, .Queen))
	}
	// One-way king finesse (AQ2 opp 543): the king is trapped but only from one side -> NOT a two-way
	// guess (declarer just takes the finesse), so untaxed.
	{
		board, _ := norn.parse_pbn_deal(`[Deal "N:AQ2.AK32.AK32.A2 - 543.QJ4.QJ4.KQ43 -"]`)
		_, n := two_way_guess_pivots(board.deal, .North, .South)
		testing.expect_value(t, n, 0)
	}
	// Solid tops (AKQ missing J): J's lower neighbour is a defender card -> not a tenace, not flagged.
	{
		board, _ := norn.parse_pbn_deal(`[Deal "N:AKQ2.AK3.A32.A32 - 543.QJ2.KQ4.KQ54 -"]`)
		_, n := two_way_guess_pivots(board.deal, .North, .South)
		testing.expect_value(t, n, 0)
	}
}
