package sim_hooks

/*
	sim_hooks — this bidding system's double-dummy generation hooks, as data.

	`norn:cli` stays solver-agnostic: the hooks are function values a consumer supplies (`cli.Gen_Hooks`).
	This package is that supply — the name -> filter and name -> annotator bindings for THIS system's
	scenarios, the same bindings for every scenario FILE with a `double-dummy:` line, and the par caption
	`--par` puts on every other scenario.

	A SCENARIO'S HOOKS ARE PART OF IT, always on (2026-10-09). They used to run only behind `--dd`, a
	"double-dummy hooks" checkbox in the workbench that people could not remember the meaning of - and
	without it `slam-makes-dd` was just "32+ combined points" under a name that said otherwise. The
	run-level choice that is left is `--par`: caption every deal with its par, at the solver's cost.

	It exists as a package rather than as a block inside `sim.odin` because there are now two programs
	that generate deals — `sim.odin` (the CLI) and `workbench.odin` (the desktop app) — and a hook table
	copied into both is one a new scenario gets added to in one place only. The failure mode is silent:
	a scenario missing from the map gets no filter and no caption, which reads as a bug in the annotator
	rather than a missing entry.

	Kept out of `bidding` deliberately: these reference `deal_solve`, which links DDS, and `bidding` is
	lint-checked WITHOUT the `dds` collection (see the justfile's `lint`).
*/

import "core:strings"

import "../deal_solve"
import "../scenario_dsl"
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
// pass). Only scenarios listed here get a second stage; the rest are unfiltered. The filter
// *implementations* live in the `deal_solve` package; this is just the name -> filter binding.
//
// Per-scenario double-dummy ANNOTATORS (policy: which scenarios get the DD caption in their HTML).
// Per-scenario, not global, so the batch export still pools every scenario NOT listed here (annotators,
// like filters, make the scenario call DDS -> serial). `--par` captions the rest (see `gen_hooks`).
//
// `programs` are the scenarios loaded from FILES: each one with a `double-dummy:` line gets the matching
// `deal_solve.makes_filter` and the caption, keyed by its name. A file scenario named like a COMPILED one
// (`compiled`) is skipped: the compiled scenario wins the name in the registry (`cli.lookup`, first match),
// so the hooks under that name must stay the compiled scenario's.
make_hooks :: proc(
	programs: []^scenario_dsl.Program = nil,
	compiled: []cli.Scenario = nil,
	allocator := context.allocator,
) -> Hooks {
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

	for program in programs {
		dd, has := program.double_dummy.?
		if !has {
			continue
		}
		if _, clash := cli.lookup(compiled, program.name); clash {
			continue
		}
		sides, goals := MAKES_SIDE, MAKES_GOAL
		h.filters[program.name] = deal_solve.makes_filter(sides[dd.side], goals[dd.goal])
		h.annotators[program.name] = dd_and_combo_annotate
	}
	return h
}

// The language's words for a requirement, as `deal_solve`'s. Two enums rather than one shared type: the
// language must not link the solver.
@(private)
MAKES_SIDE :: [scenario_dsl.Makes_Side]deal_solve.Makes_Side {
	.North_South = .North_South,
	.East_West   = .East_West,
}

@(private)
MAKES_GOAL :: [scenario_dsl.Makes_Goal]deal_solve.Makes_Goal {
	.Game  = .Game,
	.Slam  = .Slam,
	.Grand = .Grand,
}

// Release the maps `make_hooks` allocated.
free_hooks :: proc(h: ^Hooks) {
	delete(h.filters)
	delete(h.annotators)
	h^ = {}
}

// The `cli` view of the tables, for `cli.main_program` / a hand-wired `Options`.
gen_hooks :: proc(h: ^Hooks) -> cli.Gen_Hooks {
	return cli.Gen_Hooks{dd_filters = h.filters, dd_annotators = h.annotators, par_annotator = dd_and_combo_annotate}
}
