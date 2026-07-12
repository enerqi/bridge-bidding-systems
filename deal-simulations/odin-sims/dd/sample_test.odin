package dd

/*
	sample_test.odin — unit tests for the DDS-sampling whole-hand make-% engine (sample.odin).

	Run (from odin-sims):
	  odin test dd -collection:norn=<norn> -collection:dds=<dds> -out:target/debug/test-dd.exe
	(the `test-dd` justfile recipe wires the collections.)

	DDS is statically linked with no auto-init, so every test that solves must call `init()` first (it
	is idempotent — just sizes the transposition tables). The tests pin the parse layer, the aggregate
	invariants (histogram sums to n, make_count is the >= need tail), and the two obvious extremes: a
	cold slam samples 100%, a hopeless contract samples low.
*/

import "core:math"
import "core:math/rand"
import "core:testing"

import dds "dds:."
import "norn:norn"

@(test)
test_parse_contract :: proc(t: ^testing.T) {
	c, ok := parse_contract("4H")
	testing.expect(t, ok)
	testing.expect_value(t, c.level, 4)
	testing.expect_value(t, c.strain, dds.Strain.Hearts)

	c, ok = parse_contract("3NT")
	testing.expect(t, ok)
	testing.expect_value(t, c.level, 3)
	testing.expect_value(t, c.strain, dds.Strain.NT)

	c, ok = parse_contract("6c")
	testing.expect(t, ok)
	testing.expect_value(t, c.strain, dds.Strain.Clubs)

	_, ok = parse_contract("8S") // level out of range
	testing.expect(t, !ok)
	_, ok = parse_contract("4X") // bad strain
	testing.expect(t, !ok)
	_, ok = parse_contract("4") // no strain
	testing.expect(t, !ok)
}

// A cold small slam (the strong-hand pair holds every top): every sampled layout makes, so the
// verdict is 100% and the histogram is entirely at 12+ tricks.
@(test)
test_sample_cold_slam :: proc(t: ^testing.T) {
	init()
	board, err := norn.parse_pbn_deal(`[Deal "N:AKQJ2.AK3.A32.A2 - 543.QJ2.KQ4.KQ43 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	c, _ := parse_contract("6S")
	res, ok := sample_contract(board, {.North, .South}, c, 100, 7)
	testing.expect(t, ok)
	testing.expect_value(t, res.n, 100)

	// Histogram accounts for every sample.
	total := 0
	for h in res.hist {
		total += h
	}
	testing.expect_value(t, total, 100)

	// make_count is exactly the >= need (= level + 6 = 12) tail of the histogram.
	tail := 0
	for k in res.need ..< 14 {
		tail += res.hist[k]
	}
	testing.expect_value(t, tail, res.make_count)

	// A cold slam makes every time.
	testing.expect(t, res.make_pct > 99.9)
	testing.expect(t, res.stderr_pct < 0.01)
}

// A hopeless contract for a weak pair: the whole-hand make-% is low, well under the DD-census ceiling
// (which the SAME two hands drive) — a sanity check that sampling discriminates and is not stuck high.
@(test)
test_sample_hopeless_is_low :: proc(t: ^testing.T) {
	init()
	board, err := norn.parse_pbn_deal(`[Deal "N:AKJ32.K32.Q32.32 - Q54.A54.K54.QJ54 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	c, _ := parse_contract("4S")
	res, ok := sample_contract(board, {.North, .South}, c, 300, 5)
	testing.expect(t, ok)
	testing.expect(t, res.make_pct < 25.0) // ~20 HCP: 4S is against the odds
	testing.expect(t, res.mean_tricks < f64(res.need)) // averages fewer than the 10 it needs
}

// Reproducibility: the same seed yields the identical aggregate.
@(test)
test_sample_seed_reproducible :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_pbn_deal(`[Deal "N:AKJ32.K32.Q32.32 - Q54.A54.K54.QJ54 -"]`)
	c, _ := parse_contract("4S")
	r1, ok1 := sample_contract(board, {.North, .South}, c, 200, 42)
	r2, ok2 := sample_contract(board, {.North, .South}, c, 200, 42)
	testing.expect(t, ok1 && ok2)
	testing.expect_value(t, r1.make_count, r2.make_count)
	testing.expect_value(t, r1.mean_tricks, r2.mean_tricks)
}

// Auto-contract: on a cold-slam pair, the best-expected-score pick is a high, making contract (a game
// or slam), not a trivial part-score — a sanity check that best_contract prefers value, not just a lock.
@(test)
test_best_contract_prefers_value :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_pbn_deal(`[Deal "N:AKQJ2.AK3.A32.A2 - 543.QJ2.KQ4.KQ43 -"]`)
	grid, ok := sample_grid(board, {.North, .South}, 100, 7)
	testing.expect(t, ok)
	c, c_ok := best_contract(grid)
	testing.expect(t, c_ok)
	testing.expect(t, c.level >= 4) // this strong pair should be steered to at least a game

	// The picked contract must actually make often (best_contract weights P(make) × score).
	r := result_for(grid, c)
	testing.expect(t, r.make_pct > 60.0)

	// Empty grid -> no pick.
	empty: Grid_Result
	_, e_ok := best_contract(empty)
	testing.expect(t, !e_ok)
}

// SAMPLING VARIETY (the documented claim): the constrained deal `sample_grid` draws from puts the
// defenders' suit splits in proportion to their a-priori (hypergeometric) probability — it does not
// hand-pick splits. We replicate the engine's exact sampling step here (build the predeal from the two
// known hands, deal M times) and check the empirical distribution of East's holding in a suit with a
// KNOWN number of missing cards against the exact C(m,k)C(26-m,13-k)/C(26,13). Passing this is what
// makes the make-% an honest probability rather than a flat average over split types.
@(test)
test_sample_split_distribution_matches_apriori :: proc(t: ^testing.T) {
	// North + South hold 9 spades between them (AKQJ8 + T732), so 4 spades are missing — split between
	// the two defenders across samples.
	board, err := norn.parse_pbn_deal(`[Deal "N:AKQJ8.A2.A32.A32 - T732.KQ3.K54.K54 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	MISSING :: 4 // 13 - 9 spades held by NS

	// Build the predeal exactly as sample_grid does.
	pd: norn.Predeal
	for seat in ([2]norn.Seat{.North, .South}) {
		for k in 0 ..< norn.HAND_SIZE {
			norn.predeal_add(&pd, seat, board.deal[seat][k])
		}
	}

	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 99)

	M :: 4000
	counts: [MISSING + 1]int // counts[k] = samples where East held k of the missing spades
	for _ in 0 ..< M {
		b := norn.deal_board_predealt(pd)
		e := 0
		for c in b[.East] {
			if norn.card_suit(c) == .Spades {
				e += 1
			}
		}
		counts[e] += 1
	}

	// Exact hypergeometric P(East holds k of MISSING) and empirical fraction; each must agree closely.
	for k in 0 ..= MISSING {
		analytic := hypergeom(MISSING, k)
		empirical := f64(counts[k]) / f64(M)
		testing.expectf(
			t,
			math.abs(empirical - analytic) < 0.03,
			"East holds %d/%d spades: empirical %.3f vs a-priori %.3f (should match — sampling weights splits by probability)",
			k,
			MISSING,
			empirical,
			analytic,
		)
	}
	// And the mean East length in the suit is the vacant-space expectation MISSING * 13/26 = MISSING/2.
	mean := 0.0
	for k in 0 ..= MISSING {
		mean += f64(k) * f64(counts[k]) / f64(M)
	}
	testing.expectf(t, math.abs(mean - f64(MISSING) / 2) < 0.05, "mean East length %.3f", mean)
}

// Exact probability East holds `k` of `m` missing cards when 26 unknown cards split 13-13:
// C(m,k)·C(26-m,13-k)/C(26,13).
@(private = "file")
hypergeom :: proc(m, k: int) -> f64 {
	return choose(m, k) * choose(26 - m, 13 - k) / choose(26, 13)
}

@(private = "file")
choose :: proc(n, r: int) -> f64 {
	if r < 0 || r > n {
		return 0
	}
	res := 1.0
	rr := min(r, n - r)
	for i in 0 ..< rr {
		res = res * f64(n - i) / f64(i + 1)
	}
	return res
}

// A 4-hand board (both partnerships known) is not a valid 2-hand advisor input for one call, but
// sampling `side` is still well-defined; the guard we DO enforce is that `side` must be fully known.
// Passing a side with an unknown seat must fail.
@(test)
test_sample_rejects_unknown_side :: proc(t: ^testing.T) {
	init()
	// Only North + South specified; ask for the E/W side -> not known -> reject.
	board, _ := norn.parse_pbn_deal(`[Deal "N:AKQJ2.AK3.A32.A2 - 543.QJ2.KQ4.KQ43 -"]`)
	c, _ := parse_contract("4S")
	_, ok := sample_contract(board, {.East, .West}, c, 50, 1)
	testing.expect(t, !ok)
}
