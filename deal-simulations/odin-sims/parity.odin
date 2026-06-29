package main

/*
	parity — predicate parity harness against deal.exe (a single-file `-file` program).

	Unit tests check hand-built cases; this checks the ported predicates against the ORIGINAL Tcl
	engine on a large random sample, which is the real definition-of-done (does Norn replace
	deal.exe?). It emits two files:

	  parity_candidates.txt   — every generated deal, one per line, in deal's `-l` line format
	  parity_norn_accept.txt  — the subset Norn's predicate accepts (same order)

	deal.exe then reads parity_candidates.txt via `input line` and applies the equivalent Tcl
	predicate, emitting its own accepted subset. Because both sides process the same deals in the
	same order, the two accept files must be byte-identical if the port is faithful — any diff is a
	ported-predicate bug. See the companion parity.tcl / the justfile `parity` recipe.

	The predicate here mirrors deal-simulations/1major-gf-3plus-card-support.tcl. Swap both sides to
	parity-check a different predicate.
*/

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"

import "bidding"
import "norn:cli"
import "norn:norn"

DEAL_COUNT :: #config(DEAL_COUNT, 200_000)

// Must mirror parity.tcl exactly. This union stresses the two non-obvious engine algorithms:
// `offense` (via the preempt predicates, thresholds 3/7/8/9) and `losers` (via the trick tests).
// Parity target: the registered scenarios whose ports carry hand-written helper logic (multi-reject
// / multi-accept / fit computation), unioned. Mirror parity.tcl's `verdict` to the OR of the same
// .tcl bodies. A union pass means every member matches deal.exe.
SCENARIOS :: []string {
	"1d-weak-minor-minors",
	"1major-minisplinter-or-single-suit-invite",
	"defence-vs-high-preempts",
	"defense-vs-all-preempts",
	"roman-2c-related",
	"acol-lessons-balanced",
	"1minor-(1s)",
	"1d-then-1x-interference",
}

predicate :: proc(summary: norn.Deal_Summary) -> bool {
	for name in SCENARIOS {
		s, _ := cli.lookup(bidding.registry, name)
		if s.predicate(summary) {
			return true
		}
	}
	return false
}

main :: proc() {
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 20260627)

	candidates := strings.builder_make()
	defer strings.builder_destroy(&candidates)
	verdict := strings.builder_make()
	defer strings.builder_destroy(&verdict)

	naccept := 0
	for _ in 0 ..< DEAL_COUNT {
		board := norn.deal_board()
		norn.render_deal_line(&candidates, board)
		strings.write_byte(&candidates, '\n')
		// One verdict digit per deal, same order as the candidates — diff this against deal.exe's.
		if predicate(norn.summarize_deal(board)) {
			strings.write_string(&verdict, "1\n")
			naccept += 1
		} else {
			strings.write_string(&verdict, "0\n")
		}
	}

	_ = os.write_entire_file("parity_candidates.txt", candidates.buf[:])
	_ = os.write_entire_file("parity_norn_verdict.txt", verdict.buf[:])
	fmt.eprintfln(
		"parity: %d candidates, %d norn-accepted (%.2f%%)",
		DEAL_COUNT,
		naccept,
		100.0 * f64(naccept) / f64(DEAL_COUNT),
	)
}
