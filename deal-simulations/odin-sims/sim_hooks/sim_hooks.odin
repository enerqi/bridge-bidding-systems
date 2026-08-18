package sim_hooks

/*
	sim_hooks — this bidding system's double-dummy generation hooks, as data.

	`norn:cli` stays solver-agnostic: `--dd` only sets a flag, and the hooks themselves are function
	values a consumer supplies (`cli.Gen_Hooks`). This package is that supply — the name -> filter and
	name -> annotator bindings for THIS system's scenarios.

	It exists as a package rather than as a block inside `sim.odin` because there are now two programs
	that generate deals — `sim.odin` (the CLI) and `workbench.odin` (the desktop app) — and a hook table
	copied into both is one a new scenario gets added to in one place only. The failure mode is silent:
	`--dd` on a scenario missing from the map costs the same as a run without it and produces a page with
	no filter and no caption, which reads as a bug in the annotator rather than a missing entry.

	Kept out of `bidding` deliberately: these reference `deal_solve`, which links DDS, and `bidding` is
	lint-checked WITHOUT the `dds` collection (see the justfile's `lint`).
*/

import "core:strings"

import "../deal_solve"
import "norn:cli"
import "norn:combo"
import "norn:norn"

// The hook maps plus the `cli.Gen_Hooks` view of them. The maps are owned here — `cli` borrows them for
// the length of a run — so a caller pairs `make_hooks` with `free_hooks`.
Hooks :: struct {
	filters:    map[string]norn.Deal_Filter,
	annotators: map[string]norn.Deal_Annotator,
}

// The double-dummy par caption (deal_solve) followed by the naive combined-holding trick table (combo). Both
// are `norn.Deal_Annotator`s writing to the same builder; combo needs no DDS, so the combo half still
// renders when a deal reaches here. Registered for scenarios that want both (see `make_hooks`).
dd_and_combo_annotate :: proc(builder: ^strings.Builder, deal: norn.Deal, format: norn.Output_Format) {
	deal_solve.annotate(builder, deal, format)
	combo.annotate(builder, deal, format)
}

// Build this system's hook tables.
//
// Per-scenario double-dummy FILTERS (policy: which DD condition each scenario's survivors must also
// pass). Only scenarios listed here get a second stage under --dd; the rest are unfiltered. The filter
// *implementations* live in the `deal_solve` package; this is just the name -> filter binding.
//
// Per-scenario double-dummy ANNOTATORS (policy: which scenarios get the DD caption in their HTML).
// Per-scenario, not global, so under --dd the batch export still pools every scenario NOT listed here
// (annotators, like filters, make the scenario call DDS -> serial). List every scenario name to caption
// them all — they then serialise, each still parallel inside DDS. `deal_solve.annotate` is the single
// uniform caption; a scenario could instead be given a bespoke annotator.
make_hooks :: proc(allocator := context.allocator) -> Hooks {
	h := Hooks {
		filters    = make(map[string]norn.Deal_Filter, allocator),
		annotators = make(map[string]norn.Deal_Annotator, allocator),
	}

	h.filters["1major-game-force"] = deal_solve.ns_makes_game
	h.filters["slam-makes-dd"] = deal_solve.ns_makes_slam
	// h.filters["1major-gf-3plus-card-support"] = deal_solve.ns_makes_game
	// h.filters["1n-slam-try"] = deal_solve.ns_makes_slam
	// h.filters["2c-any-slam-try"] = deal_solve.ns_makes_slam
	// h.filters["slam-hands-32-plus-hcp"] = deal_solve.ns_makes_slam

	h.annotators["1major-game-force"] = dd_and_combo_annotate
	h.annotators["slam-makes-dd"] = dd_and_combo_annotate
	// h.annotators["1n-slam-try"] = deal_solve.annotate
	// h.annotators["2c-any-slam-try"] = deal_solve.annotate
	// h.annotators["slam-hands-32-plus-hcp"] = deal_solve.annotate

	return h
}

// Release the maps `make_hooks` allocated.
free_hooks :: proc(h: ^Hooks) {
	delete(h.filters)
	delete(h.annotators)
	h^ = {}
}

// The `cli` view of the tables, for `cli.main_program` / a hand-wired `Options`.
gen_hooks :: proc(h: ^Hooks) -> cli.Gen_Hooks {
	return cli.Gen_Hooks{dd_filters = h.filters, dd_annotators = h.annotators}
}
