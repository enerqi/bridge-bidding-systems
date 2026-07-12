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

// Monte-Carlo the full make-% grid for the known partnership `side` (one of NS_SIDE / EW_SIDE — the two
// seats named in `side` must both be in `board.known`), over `n_samples` constrained deals. See the file
// header for HOW the sampled layouts get their (correct, a-priori-weighted) variety. Each layout is
// solved with `dds.CalcDDtable` (the whole 5-strain × 4-declarer grid in one call) and each strain's
// best-of-pair declarer trick count is tallied into `hist[strain]`. `seed` makes the sample reproducible.
//
// ok=false if `side` is not exactly a fully-known partnership, n_samples <= 0, or DDS fails.
sample_grid :: proc(
	board: norn.Parsed_Board,
	side: bit_set[norn.Seat],
	n_samples: int,
	seed: u64 = 0,
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

	// Own, seeded RNG (safe & reproducible regardless of the caller's context; see count_accepted_seeded).
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)

	// The two known seats' declarer indices in DDS's grid (norn Seat and dds Hand share N/E/S/W order).
	ha, hb := dds.Hand(int(a)), dds.Hand(int(b))

	tbl: dds.Table_Results
	for _ in 0 ..< n_samples {
		td := to_table_deal(norn.deal_board_predealt(pd))
		if dds.CalcDDtable(td, &tbl) != .NO_FAULT {
			return {}, false
		}
		for strain in dds.Strain {
			// Best of the two pair members declaring — the pair plays it from the stronger side.
			tk := max(int(tbl.resTable[strain][ha]), int(tbl.resTable[strain][hb]))
			tk = clamp(tk, 0, 13)
			result.hist[strain][tk] += 1
		}
	}
	result.n = n_samples
	return result, true
}

// Monte-Carlo make-probability for one `contract` declared by `side` — a thin one-strain read of
// `sample_grid` (see it for the sampling method and guards). ok mirrors sample_grid.
sample_contract :: proc(
	board: norn.Parsed_Board,
	side: bit_set[norn.Seat],
	contract: Contract,
	n_samples: int,
	seed: u64 = 0,
) -> (
	Sample_Result,
	bool,
) {
	grid, ok := sample_grid(board, side, n_samples, seed)
	if !ok {
		return {}, false
	}
	return result_for(grid, contract), true
}

// Extract the one-contract Sample_Result from a computed grid (no solving). The card page bakes the whole
// grid and does this read client-side per picked contract; the CLI does it once here.
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
