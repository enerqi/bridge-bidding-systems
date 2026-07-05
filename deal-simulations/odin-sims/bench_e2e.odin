package main

/*
	bench_e2e.odin — end-to-end, single-scenario pipeline benchmark.

	Where `bench.odin` micro-benchmarks the combo procs in isolation, this times the WHOLE realistic
	export of ONE scenario the way the sim actually runs it: reject-sample deals until `COUNT` pass the
	scenario predicate AND the double-dummy filter, then render each to Html_Cards WITH the dd par
	caption + the combo table (`dd.annotate` + `combo.annotate`). Exactly the work behind

	    sim.exe -S slam-makes-dd --count 48 --format html-cards --dd

	minus the file write — it renders into a builder and discards it, so the number is pure pipeline
	compute (generation + DDS filtering + DDS par + combo threading + rendering).

	It links DDS (like sim), so build/run with the dds collection:
	    odin run bench_e2e.odin -file -collection:norn=<...> -collection:dds=<...> -o:speed -microarch:native
	    (or: just bench-e2e)

	Knobs (compile-time -define):
	    SCENARIO (default "slam-makes-dd"), COUNT (48), ITERS (3), SEED (42, fixed → identical work per
	    iteration for stable timing), COMBO_THREADS (true; -define:COMBO_THREADS=false times the serial
	    combo path for comparison).
*/

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:sys/windows"
import "core:time"

import "bidding"
import "combo"
import "dd"
import "norn:norn"

E2E_SCENARIO :: #config(E2E_SCENARIO, "slam-makes-dd")
E2E_COUNT :: #config(E2E_COUNT, 48)
E2E_ITERS :: #config(E2E_ITERS, 3)
E2E_SEED :: #config(E2E_SEED, 42)
E2E_MAX_ATTEMPTS :: 20_000_000 // matches cli's HTML_EXPORT_MAX_ATTEMPTS; a rare filter under-fills instead of hanging

// The dd par caption followed by the combo table — the same annotator sim registers for this scenario.
e2e_annotate :: proc(b: ^strings.Builder, board: norn.Deal, format: norn.Output_Format) {
	dd.annotate(b, board, format)
	combo.annotate(b, board, format)
}

// DDS-solve counting. The real cost is double-dummy solves, NOT raw attempts: `generate_accepted` calls
// the deal_filter (a DDS solve) ONLY on boards that already passed the cheap summary predicate (the `&&`
// short-circuits), and the par annotator adds one DDS solve per ACCEPTED deal. So attempts/accept% tell
// you nothing about cost; the solve count does. `filter_solves` = boards that reached the DDS filter =
// cheap-predicate survivors; par solves = accepted. Single-threaded generation here, so a plain global is
// safe (combo's own worker threads never touch this).
g_filter_solves: int

// Wraps the scenario's DDS filter to tally how often it actually runs (i.e. how many boards the cheap
// predicate let through to a solve).
counting_slam_filter :: proc(board: norn.Deal) -> bool {
	g_filter_solves += 1
	return dd.ns_makes_slam(board)
}

main :: proc() {
	windows.SetConsoleOutputCP(.UTF8) // suit glyphs in the rendered output

	// Resolve the scenario predicate from this bidding system's registry.
	predicate: norn.Predicate
	found: bool
	for s in bidding.registry {
		if s.name == E2E_SCENARIO {
			predicate = s.predicate
			found = true
			break
		}
	}
	if !found {
		fmt.eprintfln("bench_e2e: scenario %q not in registry", E2E_SCENARIO)
		return
	}

	// The double-dummy second-stage filter this scenario runs under --dd (wrapped to count its solves).
	// Keep it in step with sim.odin's dd_filters binding; a mismatch would benchmark a different
	// acceptance rate than the real export.
	deal_filter: norn.Deal_Filter = counting_slam_filter
	if E2E_SCENARIO != "slam-makes-dd" {
		fmt.eprintfln(
			"bench_e2e: note — the DD filter is hard-wired to ns_makes_slam; override the source for %q",
			E2E_SCENARIO,
		)
	}

	dd.init()
	defer dd.shutdown()

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.printfln(
		"end-to-end: scenario=%q  count=%d  iters=%d  seed=%d  threads=%v",
		E2E_SCENARIO,
		E2E_COUNT,
		E2E_ITERS,
		E2E_SEED,
		combo.COMBO_THREADS,
	)

	best_ms := max(f64)
	sum_ms := f64(0)
	for iter in 0 ..< E2E_ITERS {
		// Re-seed to the SAME value each iteration so every run deals the identical sequence and does the
		// identical work — the timing variance is then the machine's, not the RNG's.
		state: rand.Xoshiro256_Random_State
		context.random_generator = norn.seeded_xoshiro(&state, E2E_SEED)
		strings.builder_reset(&b)
		g_filter_solves = 0

		start := time.tick_now()
		accepted, attempts := norn.generate_accepted(
			&b,
			E2E_COUNT,
			.Html_Cards,
			predicate,
			E2E_MAX_ATTEMPTS,
			false, // randomize_table
			nil, // predeal
			nil, // smartstack
			deal_filter,
			e2e_annotate,
			E2E_SCENARIO, // page_title
		)
		el := time.tick_diff(start, time.tick_now())

		ms := f64(time.duration_nanoseconds(el)) / 1e6
		sum_ms += ms
		best_ms = min(best_ms, ms)
		// DDS solves = filter solves (cheap-predicate survivors) + one par solve per accepted deal. This,
		// not attempts/accept%, is what the time tracks.
		dds_solves := g_filter_solves + accepted
		fmt.printfln(
			"  iter %d: %8.1f ms | %d attempts, %d accepted (%.3f%%) | DDS solves: %d filter + %d par = %d | %5.2f ms/solve | %d bytes",
			iter,
			ms,
			attempts,
			accepted,
			100.0 * f64(accepted) / f64(max(attempts, 1)),
			g_filter_solves,
			accepted,
			dds_solves,
			ms / f64(max(dds_solves, 1)),
			strings.builder_len(b),
		)
	}

	mean_ms := sum_ms / f64(max(E2E_ITERS, 1))
	fmt.printfln(
		"summary: best %.1f ms   mean %.1f ms   (%.2f ms/deal at count=%d)",
		best_ms,
		mean_ms,
		best_ms / f64(max(E2E_COUNT, 1)),
		E2E_COUNT,
	)
}
