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

// TWO independent blind two-way guesses compound. Spades are solid trumps (AKQJ.. opp T9.. — no guess);
// hearts AJ4/KT3 and diamonds AJ4/KT3 are each a two-way queen. At 6S (need 12) the DD ceiling is a cold
// 100% but there is NO cushion — misguessing EITHER queen drops a trick and fails, so a blind declarer makes
// only when BOTH guesses are right. The joint best-policy achievable must therefore land near ~25-30%, well
// BELOW the ~50% that each guess's marginal reports and that a single-worst-pivot view would have shown.
// (Measured seed 7, n=300: ceiling 100.0, achievable 30.0, tax 70.0.)
@(test)
test_tax_two_guesses_compound :: proc(t: ^testing.T) {
	init()
	board, err := norn.parse_pbn_deal(`[Deal "N:AKQJ4.AJ4.AJ4.A2 - T9832.KT3.KT3.43 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	c, _ := parse_contract("6S")
	res, ok := misguess_tax(board, {.North, .South}, c, 300, 7)
	testing.expect(t, ok)

	testing.expect_value(t, res.n_pivots, 2) // the two red queens, spades are solid
	testing.expect(t, res.ceiling_pct >= 95.0) // cold double-dummy
	testing.expect(t, res.achievable_pct >= 20.0 && res.achievable_pct <= 40.0) // ~both-right, not single-guess
	testing.expect(t, res.tax_pts >= 55.0) // two knife-edge guesses cost far more than one

	// Both pivots are red queens, and EACH marginal (that guess alone) is a ~50/50 that sits WELL ABOVE the
	// joint achievable — i.e. compounding strictly lowered the board number below the single worst guess.
	for i in 0 ..< res.n_pivots {
		suit := norn.card_suit(res.pivots[i].card)
		testing.expect(t, suit == .Hearts || suit == .Diamonds)
		testing.expect_value(t, norn.card_rank(res.pivots[i].card), norn.Rank.Queen)
		testing.expect(t, res.pivots[i].achievable > res.achievable_pct + 10.0)
	}
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
	// A KING is NEVER a two-way guess: it would need the Ace ABOVE it in BOTH hands, which is impossible.
	// Even AQ2 opp JT9 — the king is trapped and there are cards on both sides — is a ONE-way finesse (lead
	// toward AQ only), so it stays unflagged. This is the ceiling of the geometry, not a gap.
	{
		board, _ := norn.parse_pbn_deal(`[Deal "N:AQ2.AK2.AK2.AK32 - JT9.543.543.QJ54 -"]`)
		_, n := two_way_guess_pivots(board.deal, .North, .South)
		testing.expect_value(t, n, 0)
	}
}

// Two genuine two-way guesses in the SAME suit are BOTH flagged and are genuinely independent: spades K9
// opp AJ is missing Q AND T, and declarer's J sits BETWEEN them, so each is a separate finesse whose
// misguess costs its own trick. The tight-tenace geometry GUARANTEES a declarer card separates any two
// same-suit pivots (adjacent missing honours fail the neighbour test), so the joint model's additive
// -1-per-misguess is exact here — no same-suit interaction to special-case.
@(test)
test_tax_same_suit_double_pivot :: proc(t: ^testing.T) {
	board, err := norn.parse_pbn_deal(`[Deal "N:K9.AKQ2.AKQ2.A32 - AJ.543.543.KQJ54 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)
	pivots, n := two_way_guess_pivots(board.deal, .North, .South)
	testing.expect_value(t, n, 2)

	seen_q, seen_t := false, false
	for i in 0 ..< n {
		testing.expect_value(t, norn.card_suit(pivots[i]), norn.Suit.Spades)
		#partial switch norn.card_rank(pivots[i]) {
		case .Queen:
			seen_q = true
		case .Ten:
			seen_t = true
		}
	}
	testing.expect(t, seen_q && seen_t)
}

// Textbook single-missing-honour two-way queens are all caught: AJ opp KT and its variants (a card above
// the queen in BOTH hands, both immediate neighbours held). This pins the geometry's intended coverage.
@(test)
test_tax_pivot_catalogue :: proc(t: ^testing.T) {
	cases := []string {
		`[Deal "N:AJ2.AK2.AK2.A432 - KT3.543.543.KQJ5 -"]`, // AJ opp KT: two-way Q
		`[Deal "N:AJ9.AK2.AK2.A432 - KT3.543.543.KQJ5 -"]`, // AJ9 opp KT3: two-way Q
		`[Deal "N:KJ2.AK2.AK2.A432 - AT3.543.543.KQJ5 -"]`, // KJ opp AT: two-way Q (roles swapped)
	}
	for pbn in cases {
		board, err := norn.parse_pbn_deal(pbn)
		testing.expect_value(t, err, norn.Pbn_Parse_Error.None)
		pivots, n := two_way_guess_pivots(board.deal, .North, .South)
		testing.expect_value(t, n, 1)
		testing.expect_value(t, pivots[0], norn.make_card(.Spades, .Queen))
	}
}
