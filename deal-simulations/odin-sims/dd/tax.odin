package dd

/*
	tax.odin — the misguess-TAX estimator: a cheap, export-friendly ACHIEVABLE single-dummy make-%.

	The problem (COMBO_ANALYSER.md "★ 2-hand advisor", NOT-DONE #1). sample.odin's make-% is a per-layout
	DOUBLE-DUMMY census: every sampled layout is solved with declarer PEEKING at the defenders, so the
	aggregate is a CEILING. The honest number a player wants is lower — declarer must commit ONE blind
	policy across all layouts (a whole-deal POMDP). The industry estimator of that gap is PIMC (pimc.odin,
	the spike), but full PIMC is BOTH expensive (~50-500x the ceiling) AND finicky (naive PIMC undershoots
	via DD-value-tie procrastination). This file is the DECIDED cheaper alternative: estimate the tax the
	blind two-way GUESSES cost, WITHOUT a play-out, reusing sample.odin's sampling loop.

	THE MODEL (candidate #1, "per-layout DD-vs-fixed-guess delta").
	  1. From the two KNOWN hands, geometrically identify the blind TWO-WAY guesses — a missing honour C
	     that declarer can finesse EITHER WAY (a tight tenace around C, with a card above C in BOTH hands;
	     see `two_way_guess_pivots`). These are the decisions double-dummy always gets right for free and a
	     blind declarer cannot. One-way (forced) finesses are NOT guesses — declarer just takes them — so
	     they are excluded (they would be over-taxed by the -1 below).
	  2. Sample constrained layouts and DD-solve each (exactly sample.odin's loop, one CalcDDtable/layout,
	     NO extra solves). Alongside the ceiling histogram, tally each pivot's DD trick count SPLIT by which
	     defender holds C.
	  3. For a pivot C, a blind declarer commits to finessing toward ONE defender. When C is with that
	     defender the guess is right and he gets the DD result; when C is with the OTHER he MISGUESSES and,
	     for a clean two-way finesse, loses exactly one trick vs the DD optimum (t-1). So over the sample:
	         committed-toward-d = (layouts C∈d with t≥need) + (layouts C∈other with t≥need+1)
	     and the achievable facing THAT guess is the better of the two commit directions (max over d). The
	     -1 only bites at the knife edge (t==need); a contract with an overtrick to spare survives a
	     misguess, so a non-pivotal guess is self-correctingly untaxed.
	  4. The board's achievable = ceiling docked by the DOMINANT guess (the pivot with the LOWEST committed
	     make-%). Multiple independent guesses would compound (true achievable a touch lower); v1 reports
	     the single worst, matching the doc's "single dominant two-way guess" framing.

	This is APPROXIMATE but honest-DIRECTION: achievable ≤ ceiling always (a commit can only lose vs
	peeking), and the tax is the gap the entry/tempo/guess help already warns about in words. It gives the
	4th reconciliation rung `ceiling · blind(combo-SD) · simulated(DDS ceiling) · achievable(tax)`. It does
	NOT model squeezes/endplays that the ceiling's per-layout solve already captures, nor guesses looser
	than a tight two-way tenace (those are left untaxed = slightly optimistic, deliberately conservative
	against PIMC's pessimistic floor). Cost ≈ sample.odin's ceiling (same solves), so it bakes at export.

	Single-threaded, like every DDS call here (DDS shares process-global transposition tables).
*/

import "core:math/rand"

import dds "dds:."
import "norn:norn"

// The maximum number of distinct two-way guesses we track on one board. Real deals have at most a small
// handful of genuine two-way tenaces; a fixed cap keeps `Tax_Result` a value type (no allocation).
TAX_MAX_PIVOTS :: 8

// One identified blind two-way guess and the achievable make-% a declarer gets when facing it (the better
// of the two commit directions). `card` is the trapped honour the guess is about.
Tax_Pivot :: struct {
	card:       norn.Card,
	achievable: f64, // committed make-% facing THIS guess alone (percent)
}

// The misguess-tax verdict for one contract. `ceiling_pct` is the per-layout DD census make-% (identical
// to `sample_contract` on the same board/seed); `achievable_pct` is that ceiling docked by the dominant
// blind two-way guess; `tax_pts` is the gap (the cost of playing blind). `pivots[:n_pivots]` are the
// identified guesses, DOMINANT FIRST (pivots[0] is the one that set `achievable_pct`). No pivots ->
// achievable == ceiling (nothing to guess).
Tax_Result :: struct {
	n:              int,
	level:          int,
	need:           int, // tricks required = level + 6
	strain:         dds.Strain,
	ceiling_pct:    f64,
	achievable_pct: f64,
	tax_pts:        f64,
	mean_tricks:    f64,
	n_pivots:       int,
	pivots:         [TAX_MAX_PIVOTS]Tax_Pivot,
}

// Per-suit rank bitmask (bit r = the declaring side holds rank r, deuce=0 .. ace=12) over the two KNOWN
// hands combined — the holding the guess geometry is read from.
@(private = "file")
side_suit_masks :: proc(deal: norn.Deal, a, b: norn.Seat) -> (masks: [norn.Suit]u16) {
	for seat in ([2]norn.Seat{a, b}) {
		for card in deal[seat] {
			masks[norn.card_suit(card)] |= u16(1) << u16(norn.card_rank(card))
		}
	}
	return
}

// Per-suit mask for ONE hand — used to require a card ABOVE the guessed honour in BOTH hands, the test
// that separates a genuine TWO-WAY guess (finessable either direction) from a one-way (forced) finesse.
@(private = "file")
hand_suit_mask :: proc(hand: norn.Hand, suit: norn.Suit) -> (m: u16) {
	for card in hand {
		if norn.card_suit(card) == suit {
			m |= u16(1) << u16(norn.card_rank(card))
		}
	}
	return
}

// True iff `mask` has any bit set for a rank strictly ABOVE `r`.
@(private = "file")
has_above :: proc(mask: u16, r: int) -> bool {
	for hi in r + 1 ..< norn.RANK_COUNT {
		if mask & (u16(1) << u16(hi)) != 0 {
			return true
		}
	}
	return false
}

// Identify the blind TWO-WAY guesses in the two known hands: a defender-held honour C (rank Jack..King)
// that declarer can finesse EITHER way. Geometry:
//   * combined: declarer holds BOTH immediate neighbours of C (C+1 and C-1) — a tight tenace that traps C
//     (this excludes "solid tops" like AKQ missing J, where the card just below J is a defender card), AND
//   * per-hand: EACH declaring hand holds a card ranked above C — so declarer can lead toward a trap from
//     either side, i.e. the guess is genuinely two-way rather than a single forced finesse.
// The Ace is never a target (nothing outranks it); adjacent missing honours (e.g. missing KQ together) fail
// the neighbour test and are conservatively left untaxed. Returns the pivot CARDS (up to TAX_MAX_PIVOTS).
@(private)
two_way_guess_pivots :: proc(deal: norn.Deal, a, b: norn.Seat) -> (out: [TAX_MAX_PIVOTS]norn.Card, n: int) {
	combined := side_suit_masks(deal, a, b)
	for suit in norn.Suit {
		held := combined[suit]
		ha := hand_suit_mask(deal[a], suit)
		hb := hand_suit_mask(deal[b], suit)
		for r in int(norn.Rank.Jack) ..= int(norn.Rank.King) {
			bit := u16(1) << u16(r)
			if held & bit != 0 {
				continue // declarer holds C -> not a defender card, no guess
			}
			above_held := held & (u16(1) << u16(r + 1)) != 0 // C+1 (in range: r <= King, so r+1 <= Ace)
			below_held := r > 0 && (held & (u16(1) << u16(r - 1)) != 0)
			if !above_held || !below_held {
				continue // not a tight two-sided tenace around C
			}
			if !has_above(ha, r) || !has_above(hb, r) {
				continue // not finessable from BOTH hands -> one-way (forced), not a guess
			}
			if n < TAX_MAX_PIVOTS {
				out[n] = norn.make_card(suit, norn.Rank(r))
				n += 1
			}
		}
	}
	return
}

// Per-pivot running tallies during the sample pass: `hist[i][k]` counts layouts where defender `defs[i]`
// holds the pivot card AND the declaring pair took k tricks double-dummy in the contract strain.
@(private = "file")
Pivot_Track :: struct {
	card: norn.Card,
	hist: [2][14]int,
}

// Estimate the ACHIEVABLE single-dummy make-% for `contract` declared by the known partnership `side` (the
// two seats named in `side` must both be in `board.known`), over `n_samples` constrained layouts. Reuses
// sample.odin's sampling machinery (same reject-sampling `constraints`, same seeded RNG, one
// CalcDDtable/layout — NO extra solves). See the file header for the model. ok mirrors sample_grid's guards
// (side must be a fully-known partnership; n_samples > 0; DDS must succeed; constraints must be satisfiable
// within SAMPLE_MAX_REDEAL redeals).
misguess_tax :: proc(
	board: norn.Parsed_Board,
	side: bit_set[norn.Seat],
	contract: Contract,
	n_samples: int,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
) -> (
	result: Tax_Result,
	ok: bool,
) {
	a, b: norn.Seat
	if .North in side {
		a, b = .North, .South
	} else if .East in side {
		a, b = .East, .West
	} else {
		return {}, false
	}
	if (board.known & side) != side || n_samples <= 0 {
		return {}, false
	}

	// The two defender seats (the ones NOT declaring), in a fixed order for the per-pivot split.
	defs: [2]norn.Seat
	{
		i := 0
		for seat in norn.Seat {
			if seat not_in side {
				defs[i] = seat
				i += 1
			}
		}
	}

	pd: norn.Predeal
	for seat in ([2]norn.Seat{a, b}) {
		for k in 0 ..< norn.HAND_SIZE {
			norn.predeal_add(&pd, seat, board.deal[seat][k])
		}
	}
	if valid, _ := norn.predeal_validate(pd); !valid {
		return {}, false
	}

	// The blind two-way guesses to tax (from the known hands' geometry alone — same on every layout).
	pivot_cards, n_pivots := two_way_guess_pivots(board.deal, a, b)
	tracks: [TAX_MAX_PIVOTS]Pivot_Track
	for i in 0 ..< n_pivots {
		tracks[i].card = pivot_cards[i]
	}

	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)
	ha, hb := dds.Hand(int(a)), dds.Hand(int(b))
	unconstrained := constraints_empty(constraints)

	strain := contract.strain
	need := contract.level + 6
	ceiling_hist: [14]int
	total_tricks := 0

	tbl: dds.Table_Results
	for _ in 0 ..< n_samples {
		layout: norn.Deal
		found := false
		for _ in 0 ..< SAMPLE_MAX_REDEAL {
			layout = norn.deal_board_predealt(pd)
			if unconstrained || satisfies(layout, constraints) {
				found = true
				break
			}
		}
		if !found {
			return {}, false
		}
		if dds.CalcDDtable(to_table_deal(layout), &tbl) != .NO_FAULT {
			return {}, false
		}
		// Best of the two pair members declaring, matching sample_grid's ceiling exactly.
		tk := clamp(max(int(tbl.resTable[strain][ha]), int(tbl.resTable[strain][hb])), 0, 13)
		ceiling_hist[tk] += 1
		total_tricks += tk
		// Split each pivot's tricks by which defender holds the trapped honour this layout.
		for i in 0 ..< n_pivots {
			holder := defender_holding(layout, defs, tracks[i].card)
			tracks[i].hist[holder][tk] += 1
		}
	}

	result.n = n_samples
	result.level = contract.level
	result.need = need
	result.strain = strain
	result.mean_tricks = f64(total_tricks) / f64(n_samples)

	ceiling_make := 0
	for k in need ..< 14 {
		ceiling_make += ceiling_hist[k]
	}
	result.ceiling_pct = f64(ceiling_make) / f64(n_samples) * 100

	// Achievable = ceiling docked by the dominant guess. With no guesses, nothing to dock.
	result.achievable_pct = result.ceiling_pct
	for i in 0 ..< n_pivots {
		ach := committed_make_pct(tracks[i].hist, need, n_samples)
		result.pivots[i] = Tax_Pivot {
			card       = tracks[i].card,
			achievable = ach,
		}
		if ach < result.achievable_pct {
			result.achievable_pct = ach
		}
	}
	result.n_pivots = n_pivots
	sort_pivots_dominant_first(result.pivots[:n_pivots])
	result.tax_pts = result.ceiling_pct - result.achievable_pct
	return result, true
}

// Which of the two defenders holds `card` in this layout (0 or 1). A pivot card is by construction a
// DEFENDER card, so it is always with defs[0] or defs[1]; the scan returns 1 unless it is found with
// defs[0] (so a card that somehow isn't with either — impossible for a real pivot — folds harmlessly into
// the defs[1] stratum rather than crashing).
@(private = "file")
defender_holding :: proc(layout: norn.Deal, defs: [2]norn.Seat, card: norn.Card) -> int {
	for c in layout[defs[0]] {
		if c == card {
			return 0
		}
	}
	return 1
}

// The achievable make-% facing ONE two-way guess: the better of the two commit directions. Committing to
// finesse toward defender d makes when C is with d and the DD result makes (t≥need), OR when C is with the
// OTHER defender but the contract had a trick to spare (t≥need+1, surviving the one-trick misguess). See
// the file header, step 3.
@(private = "file")
committed_make_pct :: proc(hist: [2][14]int, need, n: int) -> f64 {
	right0, right1 := 0, 0 // C with defs[0]/defs[1] AND makes double-dummy (guess right)
	spare0, spare1 := 0, 0 // C with defs[0]/defs[1] AND makes even after a -1 misguess (t≥need+1)
	for k in need ..< 14 {
		right0 += hist[0][k]
		right1 += hist[1][k]
	}
	for k in need + 1 ..< 14 {
		spare0 += hist[0][k]
		spare1 += hist[1][k]
	}
	commit_toward_0 := right0 + spare1 // right when C∈d0, survives misguess when C∈d1
	commit_toward_1 := right1 + spare0
	best := max(commit_toward_0, commit_toward_1)
	return f64(best) / f64(n) * 100
}

// Order the pivots by achievable make-% ASCENDING (dominant guess — the one that hurts most — first), so
// pivots[0] is the guess that set `achievable_pct`. Selection sort; the slice is tiny (≤ TAX_MAX_PIVOTS).
@(private = "file")
sort_pivots_dominant_first :: proc(pivots: []Tax_Pivot) {
	for i in 0 ..< len(pivots) {
		lo := i
		for j in i + 1 ..< len(pivots) {
			if pivots[j].achievable < pivots[lo].achievable {
				lo = j
			}
		}
		if lo != i {
			pivots[i], pivots[lo] = pivots[lo], pivots[i]
		}
	}
}
