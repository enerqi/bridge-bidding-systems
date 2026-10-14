package deal_solve

/*
	sample.odin — the DDS-sampling whole-hand make-% engine for the 2-hand (declarer + dummy) advisor.

	combo (the naive per-suit analyser) cannot see cross-suit play — suit independence forbids squeezes,
	endplays, entries, and the tempo race — so its combined total is an unchecked upper bound when there
	is no 4-hand DDS par to anchor it (COMBO_ANALYSER.md, "★ NEXT MAJOR LINE OF WORK" / Track 2). This
	engine is that anchor: given the two KNOWN hands, Monte-Carlo the unknown 26 cards into the two
	defender seats, run a REAL full-deal double-dummy solve on each sampled layout, and aggregate into a
	per-strain trick histogram → a make-% for any contract. Every cross-suit technique comes for free
	inside each per-layout solve, so the aggregate is a genuine whole-hand make-probability — the honest
	verdict combo lacks solo.

	It is a per-layout DOUBLE-DUMMY census (a ceiling that already bakes in entries/squeezes/tempo per
	solve, far better than combo's per-suit ceiling); the true achievable single-dummy number is a
	whole-deal POMDP and out of scope. Report it as "X% over N deals", the honest ceiling serious tools
	report.

	One solve gives EVERY contract. `dds.CalcDDtable` returns the full 5-strain × 4-declarer trick grid
	for a layout in a single call, so ONE solve per sampled layout populates a make-% for every strain
	and level at once — which is exactly what the card page's contract picker needs (the viewer flips
	strain/level with no re-solve). `sample_grid` is the core; `sample_contract` is a thin one-strain
	read of it.

	----------------------------------------------------------------------------------------------------
	HOW THE SAMPLER GETS A REPRESENTATIVE VARIETY OF LAYOUTS (read this — it is the crux of correctness)
	----------------------------------------------------------------------------------------------------

	The two known hands fix 26 cards; the other 26 are unknown, split between the two defenders. We do
	NOT hand-craft "interesting" splits. Instead we deal the 26 free cards UNIFORMLY at random into the
	two 13-card defender seats (`norn.deal_hands_predealt` predeals the known cards, shuffles the rest,
	and fills the empty seats). That single mechanism gives the correct variety for free, in two senses
	the request calls out:

	1. SUIT SPLITS APPEAR IN PROPORTION TO THEIR A-PRIORI PROBABILITY. A uniform deal of the free cards
	   is, by construction, a uniform draw over all C(26,13) ways the defenders can hold them. So each
	   particular split of a suit occurs as often as it actually arises at the table — the vacant-space /
	   hypergeometric odds. Example: a suit with 5 cards missing splits 3-2 in ~67.8% of layouts, 4-1 in
	   ~28.3%, 5-0 in ~3.9%. We never encode those numbers; they emerge because 67.8% of the uniform
	   arrangements yield a 3-2. Averaging make/no-make over these samples is therefore a probability
	   weighted by how likely each layout is — the honest expectation, not a flat average over split
	   TYPES (which would massively over-weight the rare 5-0). (Verified: `test_sample_split_distribution_
	   matches_apriori` checks the empirical split frequencies against the exact hypergeometric.)

	2. MISSING HIGH CARDS MOVE BETWEEN THE DEFENDERS ACROSS SAMPLES. Every unknown honour (a missing K,
	   Q, J …) lands with one defender or the other, sample by sample, with the correct frequency — a
	   missing king sits with a given defender about half the time, tilted by that defender's length in
	   the suit (a longer hand is likelier to hold it), again straight out of the uniform deal. So a
	   finesse that needs the king onside is right in exactly the fraction of samples where it is onside,
	   and the make-% integrates over the guess automatically. Nothing special is done for honours; they
	   are just cards in the uniform shuffle, and "which defender holds card X" is uniform over the
	   layouts consistent with the known hands.

	Because each layout is then solved DOUBLE-DUMMY, within a layout declarer never misguesses (optimistic
	per layout) — but the guess still costs across the sample set: it is wrong in the layouts where it is
	wrong, and those are counted at their real frequency. So the aggregate captures the a-priori guess
	odds even though no single solve does. This is the standard "N-deal simulation" method serious tools
	use; the only knob is N (more samples = tighter estimate, `stderr = sqrt(p(1-p)/N)`), not the choice
	of layouts.

	FUTURE (not done): variance reduction. Plain Monte-Carlo is unbiased but its error shrinks only as
	1/sqrt(N). Stratifying on a pivotal unknown (e.g. force half the samples to put a decisive missing
	king with East, half with West, then re-weight by the split odds) would cut variance for the same N.
	We deliberately keep plain uniform sampling for now — it is correct and simple, and N is cheap at
	export; stratification is an optimisation, not a fix.

	Reuse: norn generates the constrained samples; dds solves them. Like every DDS call here it assumes
	single-threaded use (DDS shares process-global transposition tables).

	THE SPLIT (2026-10-13): everything but the solving - the layouts, the grids, the lead sub-grids, the tax and
	the page's JSON - is `sampled`'s, which the shared-deals player runs in the browser with DDS in wasm. This
	file keeps the native solve (DDS's own thread pool, a batch at a time) and names `sampled`'s types and procs
	under their old names here, so the advisor and the tests read as before.
*/

import dds "dds:."
import "norn:norn"
import "../sampled"

// `sampled`'s, under the names this package has always used. `Strain` is DDS's order (spades first, notrumps
// last); DDS's own enum (`dds.Strain`) is the same order, so a value converts by cast.
Strain :: sampled.Strain
Contract :: sampled.Contract
Grid_Result :: sampled.Grid_Result
Sample_Result :: sampled.Sample_Result
Card_Constraint :: sampled.Card_Constraint
Held_Card :: sampled.Held_Card
Sample_Constraints :: sampled.Sample_Constraints
Solved_Sample :: sampled.Solved_Sample
Lead_Card_Hist :: sampled.Lead_Card_Hist
Lead_Grids :: sampled.Lead_Grids
SAMPLE_MAX_REDEAL :: sampled.SAMPLE_MAX_REDEAL
ADAPTIVE_MIN_SAMPLES :: sampled.ADAPTIVE_MIN_SAMPLES
ADAPTIVE_CI_HALFWIDTH :: sampled.ADAPTIVE_CI_HALFWIDTH
parse_contract :: sampled.parse_contract
contract_label :: sampled.contract_label
solved_sample_free :: sampled.solved_sample_free
lead_grids_from_sample :: sampled.lead_grids_from_sample
result_for :: sampled.result_for
worst_lead :: sampled.worst_lead
best_contract :: sampled.best_contract

// Hard per-call cap on DD tables for CalcAllTables; DDS spreads a chunk this size across its pool. It is also
// `sampled.ROUND`, the size of the rounds the adaptive stop is checked after.
@(private)
SOLVE_BATCH :: dds.MAXNOOFTABLES
#assert(SOLVE_BATCH == sampled.ROUND)
#assert(size_of(dds.Table_Results) == size_of(sampled.Table))

// DD-solve every layout, filling `out[i]` (len == len(layouts)) with that layout's full 5-strain × 4-declarer
// grid, a chunk at a time: each CalcAllTables call solves up to SOLVE_BATCH layouts spread across DDS's thread
// pool - the only safe way to multithread DDS, whose transposition tables are process-global. The all-false
// trumpFilter keeps every strain; `nil` par pointer with NO_PAR_CALC skips par scoring. false on any DDS fault.
@(private)
solve_layouts :: proc(layouts: []norn.Deal, out: []sampled.Table) -> bool {
	filter: [dds.Strain]b32 // all false -> DDS computes every denomination
	i := 0
	for i < len(layouts) {
		chunk := min(SOLVE_BATCH, len(layouts) - i)
		deals: dds.Table_Deals
		deals.noOfTables = i32(chunk)
		for j in 0 ..< chunk {
			deals.deals[j] = to_table_deal(layouts[i + j])
		}
		res: dds.Tables_Res
		if dds.CalcAllTables(&deals, dds.NO_PAR_CALC, &filter, &res, nil) != .NO_FAULT {
			return false
		}
		for j in 0 ..< chunk {
			out[i + j] = transmute(sampled.Table)res.results[j]
		}
		i += chunk
	}
	return true
}

// Draw `n_samples` constrained layouts for the fully-known partnership `side` and DD-solve them ONCE into a
// `Solved_Sample` (side fully known; n_samples > 0; DDS succeeds; constraints satisfiable within the redeal
// budget). Free the result with `solved_sample_free`.
solve_sample :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	n_samples: int,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
) -> (
	s: Solved_Sample,
	ok: bool,
) {
	if n_samples <= 0 {
		return {}, false
	}
	pd, a, b, pok := sampled.predeal_side(board, side)
	if !pok {
		return {}, false
	}
	layouts := make([]norn.Deal, n_samples)
	tables := make([]sampled.Table, n_samples)
	if !sampled.generate_layouts(pd, seed, constraints, layouts) || !solve_layouts(layouts, tables) {
		delete(layouts)
		delete(tables)
		return {}, false // constraints unsatisfiable within the redeal budget, or a DDS fault
	}
	return {layouts = layouts, tables = tables, side = side, a = a, b = b, n = n_samples}, true
}

// Adaptive early-stop sampling: draw all `n_cap` seeded layouts (generation is cheap — pure RNG, no DDS) but
// DD-solve only a PREFIX of them, a round of SOLVE_BATCH at a time, stopping as soon as the gating contract's
// make-% is resolved (`sampled.adaptive_stop`). Because we solve a deterministic PREFIX of the same seeded
// layout stream, the result is byte-identical to a fixed-N run truncated at the stop point. `target`/
// `has_target` name the gating contract; with `has_target=false` the current best-EV contract is re-picked each
// round. Returns the resolved batch (its `.n` = samples actually solved) and the gating contract. Free with
// `solved_sample_free`.
solve_sample_adaptive :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	n_cap: int,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
	target: Contract = {},
	has_target: bool = false,
) -> (
	s: Solved_Sample,
	gating: Contract,
	ok: bool,
) {
	if n_cap <= 0 {
		return {}, {}, false
	}
	pd, a, b, pok := sampled.predeal_side(board, side)
	if !pok {
		return {}, {}, false
	}
	layouts := make([]norn.Deal, n_cap)
	tables := make([]sampled.Table, n_cap)
	if !sampled.generate_layouts(pd, seed, constraints, layouts) {
		delete(layouts)
		delete(tables)
		return {}, {}, false // constraints unsatisfiable within the redeal budget
	}
	grid: Grid_Result
	gc := target
	done := 0
	for done < n_cap {
		round := min(SOLVE_BATCH, n_cap - done)
		if !solve_layouts(layouts[done:done + round], tables[done:done + round]) {
			delete(layouts)
			delete(tables)
			return {}, {}, false // a DDS fault
		}
		sampled.tally(&grid, tables[done:done + round], a, b)
		done += round
		if sampled.adaptive_stop(grid, &gc, has_target, n_cap) {
			break
		}
	}
	// Reslice to the solved prefix; the base pointer is unchanged, so solved_sample_free's delete still frees
	// the whole allocation (the default heap allocator frees by pointer). The unsolved tail is never read.
	return {layouts = layouts[:done], tables = tables[:done], side = side, a = a, b = b, n = done}, gc, true
}

// Monte-Carlo the full make-% grid for the known partnership `side` over `n_samples` constrained deals (see the
// file header for HOW the sampled layouts get their variety). `constraints` (empty = none) are DEFENDER
// inferences — suit-length bounds and specific-card locations — enforced by REJECT SAMPLING, a uniform draw
// over the constrained set. ok=false if `side` is not a fully-known partnership, n_samples <= 0, DDS fails, or
// the constraints are so tight a sample could not be found within SAMPLE_MAX_REDEAL redeals.
sample_grid :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	n_samples: int,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
) -> (
	result: Grid_Result,
	ok: bool,
) {
	s, sok := solve_sample(board, side, n_samples, seed, constraints)
	if !sok {
		return {}, false
	}
	defer solved_sample_free(&s)
	sampled.tally(&result, s.tables, s.a, s.b)
	return result, true
}

// Sample the base grid AND all opening-lead sub-grids in one pass into `out` (see Lead_Grids). Same
// args/guards as `sample_grid`. `out` is caller-provided (~118 KB, written through a pointer).
sample_lead_grids :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	n_samples: int,
	out: ^Lead_Grids,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
) -> (
	ok: bool,
) {
	out^ = {}
	s, sok := solve_sample(board, side, n_samples, seed, constraints)
	if !sok {
		return false
	}
	defer solved_sample_free(&s)
	lead_grids_from_sample(&s, out)
	return true
}

// Monte-Carlo make-probability for one `contract` declared by `side` — a thin one-strain read of
// `sample_grid`. ok mirrors sample_grid.
sample_contract :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	contract: Contract,
	n_samples: int,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
) -> (
	Sample_Result,
	bool,
) {
	grid, ok := sample_grid(board, side, n_samples, seed, constraints)
	if !ok {
		return {}, false
	}
	return result_for(grid, contract), true
}

// Grid_Results for a FULLY-KNOWN deal — ONE per partnership. Each strain's histogram is a single SPIKE at
// that side's double-dummy trick count (the better of its two declarers), n=1: the EXACT double-dummy census,
// letting the card page's contract picker + trick slider act as a live double-dummy explorer. One solve for
// both sides, reusing solve_table's per-board cache. ok mirrors solve_table (DDS must succeed).
exact_grids :: proc(deal: norn.Deal) -> (ns: Grid_Result, ew: Grid_Result, ok: bool) {
	res, rok := solve_table(deal)
	if !rok {
		return {}, {}, false
	}
	ns.n, ew.n = 1, 1
	for st in dds.Strain {
		nst := max(int(res.resTable[st][dds.Hand.North]), int(res.resTable[st][dds.Hand.South]))
		ewt := max(int(res.resTable[st][dds.Hand.East]), int(res.resTable[st][dds.Hand.West]))
		ns.hist[Strain(st)][clamp(nst, 0, 13)] = 1
		ew.hist[Strain(st)][clamp(ewt, 0, 13)] = 1
	}
	return ns, ew, true
}
