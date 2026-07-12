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

// Lead sub-grids (live lead picker): one pass produces the base grid AND per-(defender,card) sub-grids.
// The base must match a plain sample_grid on the same seed; a card sub-grid must condition like the
// equivalent Held_Card run — here West holds the spade K (onside) vs East (offside) flips 7NT.
@(test)
test_lead_grids :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_pbn_deal(`[Deal "N:AQJ2.AKQ.AKQ.J32 - 543.432.432.AKQ4 -"]`)
	lg := new(Lead_Grids)
	defer free(lg)
	ok := sample_lead_grids(board, {.North, .South}, 200, lg, 9)
	testing.expect(t, ok)
	testing.expect_value(t, lg.n, 200)

	// Base equals the standalone grid (same seed, same sampling).
	base, _ := sample_grid(board, {.North, .South}, 200, 9)
	for strain in dds.Strain {
		for k in 0 ..< 14 {
			testing.expect_value(t, lg.base.hist[strain][k], base.hist[strain][k])
		}
	}

	ks := int(norn.make_card(.Spades, .King))
	west := lg.seat[norn.Seat.West][ks]
	east := lg.seat[norn.Seat.East][ks]
	testing.expect(t, west.n > 0 && east.n > 0)
	testing.expect_value(t, west.n + east.n, 200) // the K sits with exactly one defender each deal

	// 7NT (13 tricks): onside with West -> mostly makes; offside with East -> mostly not.
	tail :: proc(h: [14]int, need: int) -> int {
		s := 0
		for k in need ..< 14 {
			s += h[k]
		}
		return s
	}
	w_pct := f64(tail(west.hist[.NT], 13)) / f64(west.n)
	e_pct := f64(tail(east.hist[.NT], 13)) / f64(east.n)
	// The spade-K location swings the grand slam hard one way (which defender is favourable depends on
	// declarer/leader geometry); the point is the large conditioning swing.
	testing.expectf(t, abs(w_pct - e_pct) > 0.4, "K location should swing 7NT: West %.2f vs East %.2f", w_pct, e_pct)
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

// Constrained sampling: a void constraint keeps only layouts where the named defender is void, so the
// make-% conditions on that inference. We force East void in spades (4 missing spades → all with West)
// and check (a) it still samples, and (b) the spade make-% differs from the unconstrained run — the
// finesse math changes when the missing honours are known to sit with one defender.
@(test)
test_constrained_sampling_conditions :: proc(t: ^testing.T) {
	init()
	// NS hold 9 spades (AKQJ8 + T732), 4 missing incl. the spade tricks that a finesse decides.
	board, _ := norn.parse_pbn_deal(`[Deal "N:AKQJ8.A2.A32.A32 - T732.KQ3.K54.K54 -"]`)

	free_grid, ok1 := sample_grid(board, {.North, .South}, 300, 3)
	testing.expect(t, ok1)

	cons := Sample_Constraints{shape = {{seat = .East, suit = .Spades, min = 0, max = 0}}}
	con_grid, ok2 := sample_grid(board, {.North, .South}, 300, 3, cons)
	testing.expect(t, ok2)
	testing.expect_value(t, con_grid.n, 300)

	// The two spade distributions should not be identical — conditioning on the void shifts them.
	same := true
	for k in 0 ..< 14 {
		if free_grid.hist[.Spades][k] != con_grid.hist[.Spades][k] {
			same = false
			break
		}
	}
	testing.expect(t, !same)
}

// An impossible constraint (a defender needs more of a suit than exists) fails cleanly, not hangs.
@(test)
test_constrained_impossible_fails :: proc(t: ^testing.T) {
	init()
	// 4 spades are missing; asking one defender to hold 5 is impossible.
	board, _ := norn.parse_pbn_deal(`[Deal "N:AKQJ8.A2.A32.A32 - T732.KQ3.K54.K54 -"]`)
	cons := Sample_Constraints{shape = {{seat = .West, suit = .Spades, min = 5, max = 13}}}
	_, ok := sample_grid(board, {.North, .South}, 10, 1, cons)
	testing.expect(t, !ok)
}

// Held-card (opening lead) constraint: conditioning on a defender holding a specific missing honour must
// (a) keep only layouts where that seat has it, and (b) move the make-% vs unconstrained — the classic
// "the finesse works iff the king is onside" swing. North holds AQJ2 and leads are toward it, so the
// spade king is onside when WEST holds it (West plays before North's tenace) and offside with East;
// forcing it to one defender vs the other flips a grand slam's chance.
@(test)
test_held_card_conditions :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_pbn_deal(`[Deal "N:AQJ2.AKQ.AKQ.J32 - 543.432.432.AKQ4 -"]`)
	ks := norn.make_card(.Spades, .King)

	// West holds the K -> onside -> grand slam cold.
	west_k := Sample_Constraints{held = {{seat = .West, card = ks}}}
	gw, okw := sample_grid(board, {.North, .South}, 150, 3, west_k)
	testing.expect(t, okw)
	rw := result_for(gw, Contract{level = 7, strain = .NT})

	// East holds the K -> offside -> grand slam off.
	east_k := Sample_Constraints{held = {{seat = .East, card = ks}}}
	ge, oke := sample_grid(board, {.North, .South}, 150, 3, east_k)
	testing.expect(t, oke)
	re := result_for(ge, Contract{level = 7, strain = .NT})

	testing.expectf(
		t,
		rw.make_pct > re.make_pct + 40,
		"K onside/West (%.0f%%) should dwarf K offside/East (%.0f%%) for 7NT",
		rw.make_pct,
		re.make_pct,
	)
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
