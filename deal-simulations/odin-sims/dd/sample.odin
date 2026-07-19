package dd

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
	two 13-card defender seats (`norn.deal_board_predealt` predeals the known cards, shuffles the rest,
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
*/

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strings"

import dds "dds:."
import "norn:norn"

// Re-export of dds.Strain so callers (the CLI) can name the strain type without importing the dds
// collection themselves — keeps the DDS dependency inside this package.
Strain :: dds.Strain

// A parsed contract: level 1..7 and strain. Kept opaque to callers (the CLI parses a "4H" string via
// parse_contract and passes this straight to sample_contract) so nothing outside `dd` touches dds types.
Contract :: struct {
	level:  int,
	strain: Strain,
}

// The full sampled make-% grid: over `n` constrained layouts, `hist[strain][k]` counts the layouts whose
// declaring pair took exactly k tricks double-dummy in that strain (the better of the two pair members
// declaring — the pair plays from the stronger side). ONE grid answers every contract: make-% for
// (strain, level) is the tail of `hist[strain]` at level+6. Baked whole into the card page for the
// contract picker.
Grid_Result :: struct {
	n:    int,
	hist: [dds.Strain][14]int,
}

// The aggregate for ONE contract, extracted from a Grid_Result. make_pct / stderr_pct are percentages;
// stderr is the binomial standard error sqrt(p(1-p)/N)*100 (the "±" on the verdict).
Sample_Result :: struct {
	n:           int,
	hist:        [14]int,
	make_count:  int,
	level:       int,
	need:        int, // tricks required = level + 6
	strain:      dds.Strain,
	make_pct:    f64,
	stderr_pct:  f64,
	mean_tricks: f64,
}

// Parse a contract string like "4H", "3NT", "6C" into a Contract. Level is a single digit 1..7; the
// remainder is the strain (S/H/D/C/NT, case-insensitive). ok=false on any malformed input.
parse_contract :: proc(s: string) -> (c: Contract, ok: bool) {
	t := strings.trim_space(s)
	if len(t) < 2 {
		return {}, false
	}
	level := int(t[0] - '0')
	if level < 1 || level > 7 {
		return {}, false
	}
	strain, s_ok := parse_strain(t[1:])
	if !s_ok {
		return {}, false
	}
	return Contract{level = level, strain = strain}, true
}

// Parse a strain token: NT (either case) or a single suit letter S/H/D/C.
@(private)
parse_strain :: proc(tok: string) -> (dds.Strain, bool) {
	if strings.equal_fold(tok, "NT") || strings.equal_fold(tok, "N") {
		return .NT, true
	}
	if len(tok) != 1 {
		return .NT, false
	}
	switch tok[0] {
	case 'S', 's':
		return .Spades, true
	case 'H', 'h':
		return .Hearts, true
	case 'D', 'd':
		return .Diamonds, true
	case 'C', 'c':
		return .Clubs, true
	}
	return .NT, false
}

// Render a contract as "4H" / "3NT" for captions and reports. Temp-allocated. strain_label (dd.odin)
// gives S/H/D/C/NT.
contract_label :: proc(c: Contract) -> string {
	return fmt.tprintf("%d%s", c.level, strain_label(c.strain))
}

// One inference about a DEFENDER's shape: their card count in `suit` must lie in [min, max] (inclusive).
// A void is {max = 0}; a known 6-card suit is {min = 6, max = 6}; "5+" is {min = 5, max = 13}. Built from
// bidding / show-out inferences the user supplies.
Card_Constraint :: struct {
	seat: norn.Seat,
	suit: norn.Suit,
	min:  int,
	max:  int,
}

// One inference that a specific card sits with a specific DEFENDER — the opening lead (the leader holds
// the card led) or any card seen. Conditions the sample on where that exact card lies.
Held_Card :: struct {
	seat: norn.Seat,
	card: norn.Card,
}

// The full set of defender inferences to condition a sample on: suit-length bounds (`shape`) and
// specific-card locations (`held`). Empty = unconstrained. Passed to sample_grid; enforced by reject
// sampling (see there).
Sample_Constraints :: struct {
	shape: []Card_Constraint,
	held:  []Held_Card,
}

// True if there is nothing to condition on (so the reject loop can be skipped entirely).
@(private)
constraints_empty :: proc(c: Sample_Constraints) -> bool {
	return len(c.shape) == 0 && len(c.held) == 0
}

// Per sampled deal, how many random redeals we try to hit the constraints before giving up (see
// sample_grid). The COMMON case finds a match on the first try (unconstrained, or a single void/length),
// so a big cap costs nothing there — it only lets COMPOUND rare conditions through (e.g. a void AND a
// specific card ≈ 0.1% of deals, which a 5k cap failed ~2% of samples on, tanking the whole run). At 50k
// the per-sample miss probability is negligible for anything down to ~0.05%; a genuinely impossible set
// still terminates (50k × n_samples deals) and fails cleanly.
SAMPLE_MAX_REDEAL :: 50000

// Does `board`'s dealt cards satisfy every constraint (shape bounds AND card locations)?
@(private)
satisfies :: proc(board: norn.Deal, cons: Sample_Constraints) -> bool {
	for c in cons.shape {
		n := 0
		for card in board[c.seat] {
			if norn.card_suit(card) == c.suit {
				n += 1
			}
		}
		if n < c.min || n > c.max {
			return false
		}
	}
	held_loop: for h in cons.held {
		for card in board[h.seat] {
			if card == h.card {
				continue held_loop
			}
		}
		return false // the required card is not with the required seat
	}
	return true
}

// --- batched sampling: generate the constrained layouts, then DD-solve them through DDS's OWN thread pool.
// One `CalcDDtable`-per-layout serial loop leaves every core but one idle; DDS instead parallelises a BATCH
// internally via `CalcAllTables`. That is the only safe way to multithread DDS — its transposition tables
// are process-global, so we must never call the solver from our own threads (see dd.odin). Splitting layout
// GENERATION (pure seeded RNG) from SOLVING keeps the draw sequence — hence every tally — byte-identical to
// the old loop, so this is a pure speedup. All three sampling passes below funnel through `sample_solved`.

// Hard per-call cap on DD tables for CalcAllTables; DDS spreads a chunk this size across its pool.
@(private)
SOLVE_BATCH :: dds.MAXNOOFTABLES

// Reject-sample `n` constrained layouts with a seeded RNG into `out` (len == n). Identical draw order to the
// old one-at-a-time loop (solving never touched the RNG), so results stay byte-stable. false if some sample
// could not be drawn within SAMPLE_MAX_REDEAL redeals (constraints too tight).
@(private)
generate_layouts :: proc(pd: norn.Predeal, n: int, seed: u64, cons: Sample_Constraints, out: []norn.Deal) -> bool {
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)
	unconstrained := constraints_empty(cons)
	for i in 0 ..< n {
		found := false
		for _ in 0 ..< SAMPLE_MAX_REDEAL {
			layout := norn.deal_board_predealt(pd)
			if unconstrained || satisfies(layout, cons) {
				out[i] = layout
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// DD-solve every layout, filling `out[i]` (len == len(layouts)) with that layout's full 5-strain × 4-declarer
// grid — the same content CalcDDtable produced per layout, just computed a chunk at a time. Each CalcAllTables
// call solves up to SOLVE_BATCH layouts spread across DDS's thread pool. The all-false trumpFilter keeps every
// strain; `nil` par pointer with NO_PAR_CALC skips par scoring. false on any DDS fault.
@(private)
solve_layouts :: proc(layouts: []norn.Deal, out: []dds.Table_Results) -> bool {
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
			out[i + j] = res.results[j]
		}
		i += chunk
	}
	return true
}

// Generate `n` constrained layouts and DD-solve them as a batch (see generate_layouts / solve_layouts),
// returning parallel slices where `layouts[i]` is solved into `tables[i]`. The single choke point the three
// sampling passes share, so they all get the batched (parallel) solve. Caller frees both slices.
@(private)
sample_solved :: proc(
	pd: norn.Predeal,
	n: int,
	seed: u64,
	cons: Sample_Constraints,
	allocator := context.allocator,
) -> (
	layouts: []norn.Deal,
	tables: []dds.Table_Results,
	ok: bool,
) {
	layouts = make([]norn.Deal, n, allocator)
	tables = make([]dds.Table_Results, n, allocator)
	if !generate_layouts(pd, n, seed, cons, layouts) || !solve_layouts(layouts, tables) {
		delete(layouts, allocator)
		delete(tables, allocator)
		return nil, nil, false
	}
	return layouts, tables, true
}

// Monte-Carlo the full make-% grid for the known partnership `side` (one of NS_SIDE / EW_SIDE — the two
// seats named in `side` must both be in `board.known`), over `n_samples` constrained deals. See the file
// header for HOW the sampled layouts get their (correct, a-priori-weighted) variety. Each layout is
// solved with `dds.CalcDDtable` (the whole 5-strain × 4-declarer grid in one call) and each strain's
// best-of-pair declarer trick count is tallied into `hist[strain]`. `seed` makes the sample reproducible.
//
// `constraints` (empty = none) are DEFENDER inferences — suit-length bounds (voids/lengths from the
// bidding) and specific-card locations (the opening lead, any card seen): only layouts satisfying ALL of
// them are kept, by REJECT SAMPLING — deal uniformly, discard inconsistent layouts. This yields a uniform
// draw over the constrained set, i.e. the correct conditional distribution GIVEN the inferences (still
// a-priori-weighted, just conditioned), so a finesse's success rate, splits, and honour locations all
// shift to their post-inference odds. Each constraint should name a defender seat (the two seats NOT in
// `side`); constraining a known seat is pointless (it is fixed by the predeal) but harmless.
//
// ok=false if `side` is not exactly a fully-known partnership, n_samples <= 0, DDS fails, or the
// constraints are so tight that a sample could not be found within SAMPLE_MAX_REDEAL redeals.
sample_grid :: proc(
	board: norn.Parsed_Board,
	side: bit_set[norn.Seat],
	n_samples: int,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
) -> (
	result: Grid_Result,
	ok: bool,
) {
	// The two declaring seats. `side` is NS_SIDE or EW_SIDE; both must be known.
	a, b: norn.Seat
	if .North in side {
		a, b = .North, .South
	} else if .East in side {
		a, b = .East, .West
	} else {
		return {}, false
	}
	if (board.known & side) != side {
		return {}, false
	}
	if n_samples <= 0 {
		return {}, false
	}

	// Predeal the 26 known cards to their seats; deal_board_predealt fills the two defenders at random.
	pd: norn.Predeal
	for seat in ([2]norn.Seat{a, b}) {
		for k in 0 ..< norn.HAND_SIZE {
			norn.predeal_add(&pd, seat, board.deal[seat][k])
		}
	}
	if valid, _ := norn.predeal_validate(pd); !valid {
		return {}, false // duplicate cards across the two known hands — malformed input
	}

	// The two known seats' declarer indices in DDS's grid (norn Seat and dds Hand share N/E/S/W order).
	ha, hb := dds.Hand(int(a)), dds.Hand(int(b))

	// Draw the constrained layouts (reject sampling, seeded) and DD-solve them as a parallel batch.
	layouts, tables, sok := sample_solved(pd, n_samples, seed, constraints)
	if !sok {
		return {}, false // constraints unsatisfiable within the redeal budget, or a DDS fault
	}
	defer delete(layouts)
	defer delete(tables)
	for tbl in tables {
		for strain in dds.Strain {
			// Best of the two pair members declaring — the pair plays it from the stronger side.
			tk := clamp(max(int(tbl.resTable[strain][ha]), int(tbl.resTable[strain][hb])), 0, 13)
			result.hist[strain][tk] += 1
		}
	}
	result.n = n_samples
	return result, true
}

// One card's sub-sample: over the layouts where a chosen DEFENDER (the opening leader) holds this card,
// `hist[strain][k]` is that leader's-partner-opposite DECLARER's trick tally (single declarer, since a
// known lead fixes the declarer) and `n` the sub-sample size. `n < grid n` (only some layouts put the
// card with that defender), so the make-% off it carries a wider ± — bake `n` so that is honest.
Lead_Card_Hist :: struct {
	hist: [dds.Strain][14]int,
	n:    int,
}

// The whole-board make-% grid PLUS every opening-lead-conditioned sub-grid, from ONE sample pass. `base`
// is the unconditioned BEST-OF-PAIR grid (== sample_grid; no lead known, so the pair declares from its
// better side). `seat[D][card]` (only the two DEFENDER seats populated, indexed by `int(card)`) is the
// sub-grid conditioned on defender D holding that exact card = "the opening lead was that card, from D";
// because a known lead fixes the leader and hence the DECLARER (= D's pair-partner-opposite), those use
// that SINGLE declarer's tricks, not best-of-pair. Derived by FILTERING the solved samples (each records
// who holds every card), so no extra solves: the card page bakes these and a lead picker switches among
// them instantly. NB the CLI `--lead` (Held_Card via sample_grid) is a more general card-location
// constraint that keeps best-of-pair; this opening-lead model is stricter/honester.
Lead_Grids :: struct {
	base: Grid_Result,
	seat: [norn.Seat][52]Lead_Card_Hist,
	n:    int,
}

// Sample the base grid AND all opening-lead sub-grids in one pass into `out` (see Lead_Grids). Same
// args/guards as `sample_grid`; `side` names the known pair, so the two DEFENDER seats (the others) get
// card sub-grids. `out` is caller-provided (it is ~118 KB — too big to return by value without risking a
// deep-call stack overflow, so it is written through a pointer and zeroed here first).
sample_lead_grids :: proc(
	board: norn.Parsed_Board,
	side: bit_set[norn.Seat],
	n_samples: int,
	out: ^Lead_Grids,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
) -> (
	ok: bool,
) {
	out^ = {}
	a, b: norn.Seat
	if .North in side {
		a, b = .North, .South
	} else if .East in side {
		a, b = .East, .West
	} else {
		return false
	}
	if (board.known & side) != side || n_samples <= 0 {
		return false
	}
	defenders := bit_set[norn.Seat]{.North, .East, .South, .West} - side

	pd: norn.Predeal
	for seat in ([2]norn.Seat{a, b}) {
		for k in 0 ..< norn.HAND_SIZE {
			norn.predeal_add(&pd, seat, board.deal[seat][k])
		}
	}
	if valid, _ := norn.predeal_validate(pd); !valid {
		return false
	}

	ha, hb := dds.Hand(int(a)), dds.Hand(int(b))

	// Draw the constrained layouts and DD-solve them as a parallel batch, then FILTER each solved layout into
	// the base grid + the opening-lead sub-grids (no extra solves — every sub-grid reuses the same table).
	layouts, tables, sok := sample_solved(pd, n_samples, seed, constraints)
	if !sok {
		return false
	}
	defer delete(layouts)
	defer delete(tables)
	for tbl, si in tables {
		layout := layouts[si]
		// Base grid: best-of-pair tricks per strain (no lead known -> the pair declares from its better side).
		for strain in dds.Strain {
			tk := clamp(max(int(tbl.resTable[strain][ha]), int(tbl.resTable[strain][hb])), 0, 13)
			out.base.hist[strain][tk] += 1
		}
		// Lead sub-grids: a known opening lead fixes the LEADER, hence the DECLARER (leader = declarer's
		// LHO, so declarer = leader's RHO = (leader+3)%4, always the leader's pair partner). So each
		// defender's card sub-grids use THAT declarer's tricks (single declarer), not best-of-pair — the
		// honest "you are declarer and this was led" number.
		for d in defenders {
			decl := dds.Hand((int(d) + 3) % 4)
			dtks: [dds.Strain]int
			for strain in dds.Strain {
				dtks[strain] = clamp(int(tbl.resTable[strain][decl]), 0, 13)
			}
			for card in layout[d] {
				ci := int(card)
				out.seat[d][ci].n += 1
				for strain in dds.Strain {
					out.seat[d][ci].hist[strain][dtks[strain]] += 1
				}
			}
		}
	}
	out.base.n = n_samples
	out.n = n_samples
	return true
}

// Monte-Carlo make-probability for one `contract` declared by `side` — a thin one-strain read of
// `sample_grid` (see it for the sampling method and guards). ok mirrors sample_grid.
sample_contract :: proc(
	board: norn.Parsed_Board,
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

// Extract the one-contract Sample_Result from a computed grid (no solving). The card page bakes the whole
// grid and does this read client-side per picked contract; the CLI does it once here.
// Grid_Results for a FULLY-KNOWN deal — ONE per partnership. Each strain's histogram is a single SPIKE at
// that side's double-dummy trick count (the better of its two declarers), n=1. There is nothing to sample —
// the deal is known — so this is the EXACT double-dummy census, letting the card page's contract picker +
// trick slider act as a live double-dummy explorer that follows the N/S↔E/W toggle. One solve for both
// sides, reusing solve_table's per-board cache (dd.annotate has usually just solved this same deal). ok
// mirrors solve_table (DDS must succeed).
exact_grids :: proc(deal: norn.Deal) -> (ns: Grid_Result, ew: Grid_Result, ok: bool) {
	res, rok := solve_table(deal)
	if !rok {
		return {}, {}, false
	}
	ns.n, ew.n = 1, 1
	for st in dds.Strain {
		nst := max(int(res.resTable[st][dds.Hand.North]), int(res.resTable[st][dds.Hand.South]))
		ewt := max(int(res.resTable[st][dds.Hand.East]), int(res.resTable[st][dds.Hand.West]))
		ns.hist[st][clamp(nst, 0, 13)] = 1
		ew.hist[st][clamp(ewt, 0, 13)] = 1
	}
	return ns, ew, true
}

result_for :: proc(grid: Grid_Result, contract: Contract) -> (r: Sample_Result) {
	r.n = grid.n
	r.hist = grid.hist[contract.strain]
	r.level = contract.level
	r.need = contract.level + 6
	r.strain = contract.strain
	total := 0
	for k in 0 ..< 14 {
		if k >= r.need {
			r.make_count += r.hist[k]
		}
		total += k * r.hist[k]
	}
	p := f64(r.make_count) / f64(r.n)
	r.make_pct = p * 100
	r.stderr_pct = math.sqrt(p * (1 - p) / f64(r.n)) * 100
	r.mean_tricks = f64(total) / f64(r.n)
	return
}

// The KILLING opening lead for `contract`: over the already-sampled opening-lead sub-grids, the defender
// card whose sub-grid yields the LOWEST make-% (the lead that beats the contract most often). Returns that
// card, its make-%, the sub-sample size `n` (a rare card has few samples → a wider ±, so it is reported for
// the caller to gauge), and the unconditioned baseline make-%. `ok` is false when no sub-grid clears
// `min_n` (guards tiny-n noise). Only DEFENDER seats (not in `side`) carry sub-grids. Pure reducer over the
// grids `sample_lead_grids` already filled — no extra solves. (Aids plan D.)
worst_lead :: proc(
	leads: ^Lead_Grids,
	contract: Contract,
	side: bit_set[norn.Seat],
	min_n := 20,
) -> (
	card: norn.Card,
	make_pct: f64,
	n: int,
	base_pct: f64,
	ok: bool,
) {
	base_pct = result_for(leads.base, contract).make_pct
	defenders := bit_set[norn.Seat]{.North, .East, .South, .West} - side
	worst := 101.0 // above any real percentage, so the first qualifying card replaces it
	for d in defenders {
		for ci in 0 ..< 52 {
			lc := leads.seat[d][ci]
			if lc.n < min_n {
				continue // too few samples for an honest make-% off this card
			}
			r := result_for(Grid_Result{n = lc.n, hist = lc.hist}, contract)
			if r.make_pct < worst {
				worst = r.make_pct
				card = norn.Card(ci)
				n = lc.n
				ok = true
			}
		}
	}
	make_pct = worst
	return
}

// The best contract to suggest from a sampled grid, when the user gave no --contract: the strain+level
// maximising EXPECTED SCORE = P(make) × the (neutral, undoubled) making score. This is a "what would you
// bid" proxy — it rewards a contract for both making OFTEN and being WORTH bidding (the game/slam bonus
// in `contract_score`), so a cold 3NT beats a cold 2NT, a 55% game beats a 95% part-score, and a strong
// hand surfaces a slam. It ignores undertrick penalties (bidding too high), so treat it as a starting
// suggestion the picker can override, not a bidding oracle. ok=false only on an empty grid.
best_contract :: proc(grid: Grid_Result) -> (best: Contract, ok: bool) {
	if grid.n <= 0 {
		return {}, false
	}
	best_ev := -1.0
	for strain in dds.Strain {
		hist := grid.hist[strain]
		for level in 1 ..= 7 {
			need := level + 6
			made := 0
			for k in need ..< 14 {
				made += hist[k]
			}
			ev := f64(made) / f64(grid.n) * f64(contract_score(strain, i32(level)))
			if ev > best_ev {
				best_ev = ev
				best = Contract{level = level, strain = strain}
				ok = true
			}
		}
	}
	return
}
