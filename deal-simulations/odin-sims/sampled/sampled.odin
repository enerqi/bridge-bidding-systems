/*
sampled — the 2-hand advisor's SAMPLING, everything but the solver.

The advisor (`analyse`, for a board with only declarer's and dummy's hands) deals the 26 unseen cards to the
two defenders many times over, solves every layout double dummy, and reads a make-% for every contract, the
opening-lead sub-grids and the misguess tax out of the solved batch (deal_solve/sample.odin's header explains
why that is the honest number). The SOLVING is DDS's - one `CalcAllTables` batch at a time natively, one
`CalcDDtable` a layout in the shared-deals player's Web Workers - and everything around it is here, with no
engine in it, so the two produce their figures with the same code:

	generate_layouts                 the layouts to solve (seeded, reject-sampled on the constraints)
	tally / adaptive_stop            the running grid, and when to stop solving
	lead_grids_from_sample           the opening-lead sub-grids         \
	tax_from_sample                  the misguess tax                    > filters over one solved batch
	lead_tax_from_sample             the tax under each opening lead    /
	advise                           all three for a board, the contract resolved
	write_advisor_par                the `.par` element the card page reads them from

The layouts come from `core:math/rand`, which is not the same sequence on wasm32 (its `int` is 32 bits): a
board sampled in the browser is sampled from other layouts than the same board natively, with the same
statistics. What is held equal (`test-player`) is everything after the layouts.
*/
package sampled

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strings"

import "norn:norn"
import "../par_caption"

// The five strains in DDS's order (spades first, notrumps last): the order of a solved table's rows.
Strain :: par_caption.Strain

// A contract: level 1..7 and strain.
Contract :: struct {
	level:  int,
	strain: Strain,
}

// One layout's double-dummy table, DDS's `ddTableResults` field for field (80 bytes): tricks for every strain
// and declarer (hands N E S W).
Table :: struct {
	res: [Strain][4]i32,
}

#assert(size_of(Table) == 80)

// The full sampled make-% grid: over `n` constrained layouts, `hist[strain][k]` counts the layouts whose
// declaring pair took exactly k tricks double-dummy in that strain (the better of the two pair members
// declaring - the pair plays from the stronger side). ONE grid answers every contract: make-% for
// (strain, level) is the tail of `hist[strain]` at level+6. Baked whole into the card page for the
// contract picker.
Grid_Result :: struct {
	n:    int,
	hist: [Strain][14]int,
}

// The aggregate for ONE contract, extracted from a Grid_Result. make_pct / stderr_pct are percentages;
// stderr is the binomial standard error sqrt(p(1-p)/N)*100 (the "±" on the verdict).
Sample_Result :: struct {
	n:           int,
	hist:        [14]int,
	make_count:  int,
	level:       int,
	need:        int, // tricks required = level + 6
	strain:      Strain,
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
parse_strain :: proc(tok: string) -> (Strain, bool) {
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

// Render a contract as "4H" / "3NT" for captions and reports. Temp-allocated.
contract_label :: proc(c: Contract) -> string {
	return fmt.tprintf("%d%s", c.level, par_caption.strain_label(c.strain))
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
// specific-card locations (`held`). Empty = unconstrained. Enforced by reject sampling (see
// generate_layouts).
Sample_Constraints :: struct {
	shape: []Card_Constraint,
	held:  []Held_Card,
}

// Per sampled deal, how many random redeals we try to hit the constraints before giving up. The COMMON case
// finds a match on the first try (unconstrained, or a single void/length), so a big cap costs nothing there —
// it only lets COMPOUND rare conditions through (e.g. a void AND a specific card ≈ 0.1% of deals, which a 5k
// cap failed ~2% of samples on, tanking the whole run). At 50k the per-sample miss probability is negligible
// for anything down to ~0.05%; a genuinely impossible set still terminates (50k × n_samples deals) and fails
// cleanly.
SAMPLE_MAX_REDEAL :: 50000

// Adaptive early-stop knobs (see `adaptive_stop`). Stop once the primary contract's 95% make-% CI half-width
// (1.96·binomial SE) is within ADAPTIVE_CI_HALFWIDTH points — a 4-point band is about as tight as the fixed-N
// default already is for a middling contract — but never below ADAPTIVE_MIN_SAMPLES samples (the floor that
// keeps the lead sub-grids and non-picked contract cells, which ride the same batch, usable). The check is made
// after every ROUND layouts solved: DDS's batch size natively (`MAXNOOFTABLES`), and the player's rounds too,
// so the two stop at the same points.
ADAPTIVE_MIN_SAMPLES :: 200
ADAPTIVE_CI_HALFWIDTH :: 4.0
ROUND :: 40

// True if there is nothing to condition on (so the reject loop can be skipped entirely).
@(private)
constraints_empty :: proc(c: Sample_Constraints) -> bool {
	return len(c.shape) == 0 && len(c.held) == 0
}

// Does `deal`'s dealt cards satisfy every constraint (shape bounds AND card locations)?
@(private)
satisfies :: proc(deal: norn.Deal, cons: Sample_Constraints) -> bool {
	for c in cons.shape {
		n := 0
		for card in deal[c.seat] {
			if norn.card_suit(card) == c.suit {
				n += 1
			}
		}
		if n < c.min || n > c.max {
			return false
		}
	}
	held_loop: for h in cons.held {
		for card in deal[h.seat] {
			if card == h.card {
				continue held_loop
			}
		}
		return false // the required card is not with the required seat
	}
	return true
}

// Reject-sample `len(out)` constrained layouts with a seeded RNG into `out`. false if some sample could not be
// drawn within SAMPLE_MAX_REDEAL redeals (constraints too tight).
generate_layouts :: proc(pd: norn.Predeal, seed: u64, cons: Sample_Constraints, out: []norn.Deal) -> bool {
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)
	unconstrained := constraints_empty(cons)
	for i in 0 ..< len(out) {
		found := false
		for _ in 0 ..< SAMPLE_MAX_REDEAL {
			layout := norn.deal_hands_predealt(pd)
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

// Resolve `side` to its two declaring seats and predeal their 26 known cards. ok=false if `side` is not a
// fully-known partnership or the two hands share a card. Shared front-matter for the sampling entry points.
predeal_side :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
) -> (
	pd: norn.Predeal,
	a: norn.Seat,
	b: norn.Seat,
	ok: bool,
) {
	if .North in side {
		a, b = .North, .South
	} else if .East in side {
		a, b = .East, .West
	} else {
		return {}, {}, {}, false
	}
	if (board.known & side) != side {
		return {}, {}, {}, false
	}
	for seat in ([2]norn.Seat{a, b}) {
		for k in 0 ..< norn.HAND_SIZE {
			norn.predeal_add(&pd, seat, board.deal[seat][k])
		}
	}
	if valid, _ := norn.predeal_validate(pd); !valid {
		return {}, {}, {}, false // duplicate cards across the two known hands — malformed input
	}
	return pd, a, b, true
}

// A once-solved batch of constrained layouts for a known partnership `side`, reusable by the lead-grid, the
// misguess-tax and the per-lead tax filters (each a PURE FILTER over the solved tables). `a`/`b` are the two
// declaring seats. Free with `solved_sample_free`.
Solved_Sample :: struct {
	layouts: []norn.Deal,
	tables:  []Table,
	side:    bit_set[norn.Seat],
	a, b:    norn.Seat,
	n:       int,
}

// Release a Solved_Sample's layout/table slices (no-op on a zero value).
solved_sample_free :: proc(s: ^Solved_Sample) {
	delete(s.layouts)
	delete(s.tables)
	s^ = {}
}

// Add solved layouts to the best-of-pair grid (the pair declares from its better side).
tally :: proc(grid: ^Grid_Result, tables: []Table, a, b: norn.Seat) {
	for tbl in tables {
		for strain in Strain {
			tk := clamp(max(int(tbl.res[strain][int(a)]), int(tbl.res[strain][int(b)])), 0, 13)
			grid.hist[strain][tk] += 1
		}
	}
	grid.n += len(tables)
}

// After a round: the contract that gates the stop (`gating`, re-picked as the grid's best unless the caller
// fixed one) and whether its make-% is resolved - a 95% half-width of ADAPTIVE_CI_HALFWIDTH points or less,
// once ADAPTIVE_MIN_SAMPLES (or the whole cap, if smaller) are in. Knife-edge contracts never resolve within
// the cap and run it all; lopsided ones stop short.
adaptive_stop :: proc(grid: Grid_Result, gating: ^Contract, has_target: bool, n_cap: int) -> bool {
	if !has_target {
		if bc, ok := best_contract(grid); ok {
			gating^ = bc
		}
	}
	if grid.n >= n_cap {
		return true
	}
	if grid.n < min(ADAPTIVE_MIN_SAMPLES, n_cap) {
		return false
	}
	return 1.96 * result_for(grid, gating^).stderr_pct <= ADAPTIVE_CI_HALFWIDTH
}

// One card's sub-sample: over the layouts where a chosen DEFENDER (the opening leader) holds this card,
// `hist[strain][k]` is that leader's-partner-opposite DECLARER's trick tally (single declarer, since a
// known lead fixes the declarer) and `n` the sub-sample size. `n < grid n` (only some layouts put the
// card with that defender), so the make-% off it carries a wider ± — bake `n` so that is honest.
Lead_Card_Hist :: struct {
	hist: [Strain][14]int,
	n:    int,
}

// The whole-board make-% grid PLUS every opening-lead-conditioned sub-grid, from ONE sample pass. `base`
// is the unconditioned BEST-OF-PAIR grid (no lead known, so the pair declares from its better side).
// `seat[D][card]` (only the two DEFENDER seats populated, indexed by `int(card)`) is the sub-grid conditioned
// on defender D holding that exact card = "the opening lead was that card, from D"; because a known lead fixes
// the leader and hence the DECLARER (= D's pair-partner-opposite), those use that SINGLE declarer's tricks,
// not best-of-pair. Derived by FILTERING the solved samples (each records who holds every card), so no extra
// solves: the card page bakes these and a lead picker switches among them instantly.
Lead_Grids :: struct {
	base: Grid_Result,
	seat: [norn.Seat][52]Lead_Card_Hist,
	n:    int,
}

// Fill the base grid + all opening-lead sub-grids (see Lead_Grids) by FILTERING an already-solved batch — no
// solving here.
lead_grids_from_sample :: proc(s: ^Solved_Sample, out: ^Lead_Grids) {
	out^ = {}
	defenders := bit_set[norn.Seat]{.North, .East, .South, .West} - s.side
	for tbl, si in s.tables {
		layout := s.layouts[si]
		for strain in Strain {
			tk := clamp(max(int(tbl.res[strain][int(s.a)]), int(tbl.res[strain][int(s.b)])), 0, 13)
			out.base.hist[strain][tk] += 1
		}
		// A known opening lead fixes the LEADER, hence the DECLARER (leader = declarer's LHO, so declarer =
		// leader's RHO = (leader+3)%4, always the leader's pair partner): each defender's card sub-grids use
		// THAT declarer's tricks, not best-of-pair.
		for d in defenders {
			decl := (int(d) + 3) % 4
			dtks: [Strain]int
			for strain in Strain {
				dtks[strain] = clamp(int(tbl.res[strain][decl]), 0, 13)
			}
			for card in layout[d] {
				ci := int(card)
				out.seat[d][ci].n += 1
				for strain in Strain {
					out.seat[d][ci].hist[strain][dtks[strain]] += 1
				}
			}
		}
	}
	out.base.n = s.n
	out.n = s.n
}

// Extract the one-contract Sample_Result from a computed grid (no solving).
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

// The KILLING opening lead for `contract`: over the sampled opening-lead sub-grids, the defender card whose
// sub-grid yields the LOWEST make-% (the lead that beats the contract most often). Returns that card, its
// make-%, the sub-sample size `n` and the unconditioned baseline make-%. `ok` is false when no sub-grid clears
// `min_n` (guards tiny-n noise). Only DEFENDER seats (not in `side`) carry sub-grids.
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

// The best contract to suggest from a sampled grid, when none was given: the strain+level maximising EXPECTED
// SCORE = P(make) × the (neutral, undoubled) making score. A "what would you bid" proxy — it rewards a contract
// for both making OFTEN and being WORTH bidding, so a cold 3NT beats a cold 2NT, a 55% game beats a 95%
// part-score, and a strong hand surfaces a slam. It ignores undertrick penalties, so treat it as a starting
// suggestion the picker can override. ok=false only on an empty grid.
best_contract :: proc(grid: Grid_Result) -> (best: Contract, ok: bool) {
	if grid.n <= 0 {
		return {}, false
	}
	best_ev := -1.0
	for strain in Strain {
		hist := grid.hist[strain]
		for level in 1 ..= 7 {
			made := 0
			for k in level + 6 ..< 14 {
				made += hist[k]
			}
			ev := f64(made) / f64(grid.n) * f64(par_caption.contract_score(strain, level))
			if ev > best_ev {
				best_ev = ev
				best = Contract{level = level, strain = strain}
				ok = true
			}
		}
	}
	return
}
