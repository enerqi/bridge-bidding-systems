package dd

/*
	pimc_test.odin — spike measurement + sanity for pimc.odin (the achievable single-dummy PIMC play-out).

	The point of the spike is the two numbers logged by `test_pimc_measure`: wall-time PER BOARD and the
	GAP between sample.odin's double-dummy CEILING and the PIMC achievable make-%. Those decide whether the
	production engine is worth building as-is, cheaper (misguess-tax), or at all. Run with THREADS=1 (DDS is
	not reentrant): the `test-dd` recipe forces it. The measurement prints to stderr so it shows in a run.
*/

import "core:fmt"
import "core:testing"
import "core:time"

import "norn:norn"

// A cold slam (ceiling 100%): the naive PIMC baseline UNDERSHOOTS it — with no play heuristic to break
// DD-value ties the blind declarer procrastinates and bleeds tricks (measured ~80%, mean ~11.7). The
// honest invariants are only that it stays BELOW the ceiling and still makes the slam most of the time.
// (A production engine would add the tie-break heuristic to close this gap — see COMBO_ANALYSER.md.)
@(test)
test_pimc_cold_slam_undershoots :: proc(t: ^testing.T) {
	init()
	board, err := norn.parse_pbn_deal(`[Deal "N:AKQJ2.AK3.A32.A2 - 543.QJ2.KQ4.KQ43 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	c, _ := parse_contract("6S")
	ceil, cok := sample_contract(board, {.North, .South}, c, 50, 10)
	res, ok := pimc_make(board, {.North, .South}, c, 50, 10, 1)
	testing.expect(t, ok && cok)
	testing.expect_value(t, res.n, 50)
	fmt.eprintfln("[NEAR-COLD] 6S ceiling %.1f%% achievable %.1f%% mean %.2f", ceil.make_pct, res.make_pct, res.mean_tricks)
	testing.expect(t, res.make_pct <= ceil.make_pct + 2.0) // never exceeds the double-dummy ceiling
	testing.expect(t, res.make_pct >= 60.0) // still makes a cold slam most of the time, even naive
}

// The achievable (blind declarer, double-dummy defenders) must not EXCEED the double-dummy ceiling that
// the SAME two hands drive — declarer seeing less can never do better. Allow a little Monte-Carlo slack.
@(test)
test_pimc_at_most_ceiling :: proc(t: ^testing.T) {
	init()
	board, err := norn.parse_pbn_deal(`[Deal "N:AKJ32.K32.Q32.32 - Q54.A54.K54.QJ54 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	c, _ := parse_contract("4S")
	ceil, cok := sample_contract(board, {.North, .South}, c, 200, 11)
	pim, pok := pimc_make(board, {.North, .South}, c, 40, 6, 11)
	testing.expect(t, cok && pok)
	testing.expect(t, pim.make_pct <= ceil.make_pct + 6.0) // achievable <= ceiling (within noise)
}

// Reproducibility: same seed -> identical make count (deterministic given the seeded stream).
@(test)
test_pimc_seed_reproducible :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_pbn_deal(`[Deal "N:AKJ32.K32.Q32.32 - Q54.A54.K54.QJ54 -"]`)
	c, _ := parse_contract("4S")
	r1, ok1 := pimc_make(board, {.North, .South}, c, 20, 5, 7)
	r2, ok2 := pimc_make(board, {.North, .South}, c, 20, 5, 7)
	testing.expect(t, ok1 && ok2)
	testing.expect_value(t, r1.make_count, r2.make_count)
	testing.expect_value(t, r1.mean_tricks, r2.mean_tricks)
}

// THE SPIKE MEASUREMENT. On a board with a genuine blind guess (a two-way queen finesse the double-dummy
// solver always gets right but a blind declarer cannot), log: ceiling make-% vs PIMC make-%, the gap, the
// wall-time and total solves per board. Not an assertion of a specific gap — the NUMBERS are the output.
@(test)
test_pimc_measure :: proc(t: ^testing.T) {
	init()
	// 3NT: eight fast tricks (AKQ in three suits split across the pair) plus a two-way guess for the last.
	// Double-dummy always guesses the queen right; a blind declarer must actually pick a side.
	board, err := norn.parse_pbn_deal(`[Deal "N:AK32.AK2.A432.A2 - QJ54.Q43.K5.K543 -"]`)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)

	// Captured headline (n_outer=100, k_inner=12): ceiling 100.0% vs achievable 94.0% (gap 6.0), 26,690
	// solves in 55.9s/board (~2.1 ms/solve single-thread). Trimmed here so the suite is not minutes long.
	c, _ := parse_contract("3NT")
	n_outer := 60
	k_inner := 8

	ceil, cok := sample_contract(board, {.North, .South}, c, n_outer, 11)
	testing.expect(t, cok)

	t0 := time.now()
	pim, pok := pimc_make(board, {.North, .South}, c, n_outer, k_inner, 11)
	dt := time.since(t0)
	testing.expect(t, pok)
	testing.expect_value(t, pim.n, n_outer)

	secs := time.duration_seconds(dt)
	fmt.eprintfln(
		"\n[PIMC SPIKE] 3NT  ceiling %.1f%%  achievable %.1f%% (±%.1f)  gap %.1f pts\n" +
		"             n_outer=%d k_inner=%d  solves=%d  time=%.2fs  => %.3fs/board  %.1f solves/board",
		ceil.make_pct,
		pim.make_pct,
		pim.stderr_pct,
		ceil.make_pct - pim.make_pct,
		n_outer,
		k_inner,
		pim.solves,
		secs,
		secs, // one board here; s/board == total time
		f64(pim.solves),
	)
}
