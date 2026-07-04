package main

/*
	bench.odin — combo package benchmarks.

	Four cost layers:
	  Phase 1                  suit_trick_distribution — DD minimax with memo, per suit.
	  Phase 2 / single line    sd_line_distribution — fixed-line evaluator, per suit.
	  Phase 2 / 5 candidates   suit_candidate_lines — all 5 lines, per suit.
	  Phase 2 / optimal        sd_optimal_distribution — partial-observability minimax, per suit.
	  Deal level               adaptive_at_least_curve + annotate(.Html_Cards) end-to-end.

	Per-suit benches use two fixed holdings for reproducibility:
	  6-missing: 7-card combined (AK32 / Q54), 64 splits — typical.
	  8-missing: 5-card combined (AKQ / JT), 256 splits — heavier.

	Deal-level benches cycle a pre-dealt pool so holding variety is covered.

	Build:  odin run bench.odin -file -collection:norn=<norn_home> -o:speed -microarch:native
	Or:     just bench

	Override iteration counts:
	    odin run bench.odin -file ... -define:COUNT_SUIT=5000 -define:COUNT_OPT=200 -define:COUNT_DEAL=500
*/

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:time"

import "combo"
import "norn:norn"

COUNT_SUIT :: #config(COUNT_SUIT, 2_000) // per-suit Phase 1 and Phase 2 line benches
COUNT_OPT  :: #config(COUNT_OPT,    100) // per-suit optimal-search bench (heavier)
COUNT_DEAL :: #config(COUNT_DEAL,    200) // per-deal benches (annotate, adaptive curve)

POOL      :: 1 << 11 // 2048 pre-dealt boards — enough variety to avoid cache-hot bias
POOL_MASK :: POOL - 1

deals:     [POOL]norn.Deal
summaries: [POOL]norn.Deal_Summary

// Sinks: stop the optimiser removing work under test.
sink:   int
sink_f: f64

// Fixed holdings — bit r = rank r (Two=0 .. Ace=12).
//
// 6-missing (64 splits) — typical 7-card combined suit:
//   North = A K 3 2  (A=12→0x1000, K=11→0x800, 3=1→0x002, 2=0→0x001 → 0x1803)
//   South = Q 5 4    (Q=10→0x400,  5=3→0x008,  4=2→0x004             → 0x040C)
//   combined=0x1C0F  missing = J T 9 8 7 6 (0x03F0)
NORTH_6M :: u16(0x1803)
SOUTH_6M :: u16(0x040C)

// 8-missing (256 splits) — thin 5-card combined suit:
//   North = A K Q  (0x1C00)
//   South = J T    (J=9→0x200, T=8→0x100 → 0x0300)
//   combined=0x1F00  missing = 9 8 7 6 5 4 3 2 (0x00FF)
NORTH_8M :: u16(0x1C00)
SOUTH_8M :: u16(0x0300)

// --- Phase 1: suit_trick_distribution ---

bench_p1_6m :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for _ in 0 ..< COUNT_SUIT {
		d := combo.suit_trick_distribution(NORTH_6M, SOUTH_6M)
		local += d.p[0]
	}
	sink_f += local
	options.count = COUNT_SUIT
	return .Okay
}

bench_p1_8m :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for _ in 0 ..< COUNT_SUIT {
		d := combo.suit_trick_distribution(NORTH_8M, SOUTH_8M)
		local += d.p[0]
	}
	sink_f += local
	options.count = COUNT_SUIT
	return .Okay
}

// --- Phase 2 / single line: sd_line_distribution ---

bench_p2_sd_6m :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for _ in 0 ..< COUNT_SUIT {
		d := combo.sd_line_distribution(NORTH_6M, SOUTH_6M, combo.line_finesse)
		local += d.p[0]
	}
	sink_f += local
	options.count = COUNT_SUIT
	return .Okay
}

bench_p2_sd_8m :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for _ in 0 ..< COUNT_SUIT {
		d := combo.sd_line_distribution(NORTH_8M, SOUTH_8M, combo.line_finesse)
		local += d.p[0]
	}
	sink_f += local
	options.count = COUNT_SUIT
	return .Okay
}

// --- Phase 2 / 5 candidates: suit_candidate_lines ---

bench_p2_cands_6m :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for _ in 0 ..< COUNT_SUIT {
		results := combo.suit_candidate_lines(NORTH_6M, SOUTH_6M, context.temp_allocator)
		local += results[0].dist.p[0]
		free_all(context.temp_allocator)
	}
	sink_f += local
	options.count = COUNT_SUIT
	return .Okay
}

bench_p2_cands_8m :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for _ in 0 ..< COUNT_SUIT {
		results := combo.suit_candidate_lines(NORTH_8M, SOUTH_8M, context.temp_allocator)
		local += results[0].dist.p[0]
		free_all(context.temp_allocator)
	}
	sink_f += local
	options.count = COUNT_SUIT
	return .Okay
}

// --- Phase 2 / optimal: sd_optimal_distribution ---
// 6m may complete exactly; 8m will likely hit the budget and fall back to best_line_by_mean.

bench_p2_opt_6m :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for _ in 0 ..< COUNT_OPT {
		d, exact := combo.sd_optimal_distribution(NORTH_6M, SOUTH_6M)
		local += d.p[0]
		if !exact {local += 1}
		free_all(context.temp_allocator)
	}
	sink_f += local
	options.count = COUNT_OPT
	return .Okay
}

bench_p2_opt_8m :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for _ in 0 ..< COUNT_OPT {
		d, exact := combo.sd_optimal_distribution(NORTH_8M, SOUTH_8M)
		local += d.p[0]
		if !exact {local += 1}
		free_all(context.temp_allocator)
	}
	sink_f += local
	options.count = COUNT_OPT
	return .Okay
}

// --- Deal level: adaptive_at_least_curve (gather candidates + 14 DP passes) ---
// gather_candidates is private; this is the nearest public entry point that exercises it.

bench_adaptive_curve :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	local := f64(0)
	for i in 0 ..< COUNT_DEAL {
		ds := summaries[i & POOL_MASK]
		curve := combo.adaptive_at_least_curve(ds[.North], ds[.South])
		local += curve[0]
		free_all(context.temp_allocator)
	}
	sink_f += local
	options.count = COUNT_DEAL
	return .Okay
}

// --- Deal level: annotate end-to-end (both partnerships, Html_Cards format) ---
// This is the real-world hot path: Phase 1 × 8 suits + Phase 2 best-line × 24 calls +
// adaptive_at_least_curve × 2. The single most useful number for comparing changes.

bench_annotate :: proc(options: ^time.Benchmark_Options, _ := context.allocator) -> time.Benchmark_Error {
	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	local := 0
	for i in 0 ..< COUNT_DEAL {
		strings.builder_reset(&b)
		combo.annotate(&b, deals[i & POOL_MASK], .Html_Cards)
		local += strings.builder_len(b)
	}
	sink += local
	options.count = COUNT_DEAL
	return .Okay
}

// --- reporting ---

report :: proc(name: string, options: ^time.Benchmark_Options, unit: string, scale: f64) {
	per_call := f64(time.duration_nanoseconds(options.duration)) / f64(options.count) / scale
	fmt.printfln("%-28s %8.2f %s   %9.0f /s", name, per_call, unit, options.rounds_per_second)
}

main :: proc() {
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 42)
	for i in 0 ..< POOL {
		deals[i] = norn.deal_board()
		summaries[i] = norn.summarize_deal(deals[i])
	}

	// Sanity: Phase 2 mean must not exceed Phase 1 mean (single-dummy <= double-dummy ceiling).
	p1 := combo.suit_trick_distribution(NORTH_6M, SOUTH_6M)
	p2 := combo.sd_line_distribution(NORTH_6M, SOUTH_6M, combo.line_finesse)
	p1_mean := combo.expected_tricks(p1.p)
	p2_mean := combo.expected_tricks(p2.p)
	_, opt_exact := combo.sd_optimal_distribution(NORTH_6M, SOUTH_6M)
	free_all(context.temp_allocator)

	fmt.printfln(
		"Sanity (6m AK32/Q54): P1 mean=%.3f  P2(finesse) mean=%.3f  gap=%.3f  opt-exact=%v",
		p1_mean, p2_mean, p1_mean - p2_mean, opt_exact,
	)
	if p2_mean > p1_mean + 1e-9 {
		fmt.println("FAIL — Phase2 mean exceeds Phase1 ceiling.")
		return
	}
	fmt.printfln(
		"Pool: %d deals.  Iterations: suit=%d  opt=%d  deal=%d\n",
		POOL, COUNT_SUIT, COUNT_OPT, COUNT_DEAL,
	)

	opt_p1_6m          := &time.Benchmark_Options{bench = bench_p1_6m}
	opt_p1_8m          := &time.Benchmark_Options{bench = bench_p1_8m}
	opt_p2_sd_6m       := &time.Benchmark_Options{bench = bench_p2_sd_6m}
	opt_p2_sd_8m       := &time.Benchmark_Options{bench = bench_p2_sd_8m}
	opt_p2_cands_6m    := &time.Benchmark_Options{bench = bench_p2_cands_6m}
	opt_p2_cands_8m    := &time.Benchmark_Options{bench = bench_p2_cands_8m}
	opt_p2_opt_6m      := &time.Benchmark_Options{bench = bench_p2_opt_6m}
	opt_p2_opt_8m      := &time.Benchmark_Options{bench = bench_p2_opt_8m}
	opt_adaptive_curve := &time.Benchmark_Options{bench = bench_adaptive_curve}
	opt_annotate       := &time.Benchmark_Options{bench = bench_annotate}

	time.benchmark(opt_p1_6m)
	time.benchmark(opt_p1_8m)
	time.benchmark(opt_p2_sd_6m)
	time.benchmark(opt_p2_sd_8m)
	time.benchmark(opt_p2_cands_6m)
	time.benchmark(opt_p2_cands_8m)
	time.benchmark(opt_p2_opt_6m)
	time.benchmark(opt_p2_opt_8m)
	time.benchmark(opt_adaptive_curve)
	time.benchmark(opt_annotate)

	NS :: f64(1e0)  // ns/op scale factor (nanoseconds, no division)
	US :: f64(1e3)  // µs/op
	MS :: f64(1e6)  // ms/op

	fmt.println("--- Phase 1: suit_trick_distribution ---")
	report("p1 / 6-missing (64 splits)",  opt_p1_6m,       "µs/call", US)
	report("p1 / 8-missing (256 splits)", opt_p1_8m,       "µs/call", US)

	fmt.println("--- Phase 2 / single line: sd_line_distribution (finesse) ---")
	report("p2 sd / 6-missing",           opt_p2_sd_6m,    "µs/call", US)
	report("p2 sd / 8-missing",           opt_p2_sd_8m,    "µs/call", US)

	fmt.println("--- Phase 2 / 5 candidates: suit_candidate_lines ---")
	report("p2 cands / 6-missing",        opt_p2_cands_6m, "µs/call", US)
	report("p2 cands / 8-missing",        opt_p2_cands_8m, "µs/call", US)

	fmt.println("--- Phase 2 / optimal: sd_optimal_distribution ---")
	report("p2 opt / 6-missing",          opt_p2_opt_6m,   "µs/call", US)
	report("p2 opt / 8-missing",          opt_p2_opt_8m,   "µs/call", US)

	fmt.println("--- Deal level ---")
	report("adaptive-curve (NS only)",    opt_adaptive_curve, "ms/deal", MS)
	report("annotate / Html_Cards",       opt_annotate,       "ms/deal", MS)

	// Derived ratios that motivate the §2 redundancy fix in PERFORMANCE.md.
	p2_sd_us  := f64(time.duration_nanoseconds(opt_p2_sd_6m.duration))   / f64(COUNT_SUIT) / 1e3
	p2_5l_us  := f64(time.duration_nanoseconds(opt_p2_cands_6m.duration)) / f64(COUNT_SUIT) / 1e3
	p1_us     := f64(time.duration_nanoseconds(opt_p1_6m.duration))       / f64(COUNT_SUIT) / 1e3
	ann_ms    := f64(time.duration_nanoseconds(opt_annotate.duration))     / f64(COUNT_DEAL) / 1e6
	adp_ms    := f64(time.duration_nanoseconds(opt_adaptive_curve.duration)) / f64(COUNT_DEAL) / 1e6

	fmt.println()
	fmt.printfln("P2-single-line vs P1 ratio (6m):     %.1fx  (no-memo overhead vs memoised)",
		p2_sd_us / p1_us)
	fmt.printfln("P2-5-lines vs P1 ratio (6m):         %.1fx  (expected ~5× single-line)",
		p2_5l_us / p1_us)
	fmt.printfln("annotate vs adaptive-curve (NS only): %.1fx  (annotate does 2 partnerships + extra writers)",
		ann_ms / adp_ms)

	fmt.printfln("\n(sinks: %d  %.6g)", sink, sink_f)
}
