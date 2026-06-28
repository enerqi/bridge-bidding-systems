package main

/*
	sim — the bidding-system deal generator (consumer program).

	A single-file (`-file`) program: the thin `main` that wires THIS bidding system's scenario
	registry into norn's reusable CLI driver. The hand-generation engine (`norn:norn`) and the
	scenario framework / argument parsing (`norn:cli`) come from the norn library via
	`-collection:norn=...`; everything system-specific — the predicates and the scenario registry —
	lives in the local `bidding` package.

	Build/run (from the odin-sims dir): see the justfile, e.g. `just run --scenario 1c-any -n 12`.
	The raw form is:
	  odin run sim.odin -file -collection:norn=C:/Users/Enerqi/dev/norn -- --scenario 1c-any -n 12
*/

import "core:os"

import "bidding"
import "norn:cli"

main :: proc() {
	os.exit(cli.main_program(bidding.registry))
}
