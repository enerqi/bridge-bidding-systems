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
	  4. The board's achievable = the make-% of the BEST fixed blind commit POLICY across ALL pivots jointly.
	     A policy fixes a finesse direction for every guess; on a layout it misguesses the pivots whose
	     trapped honour sits the wrong way, each costing -1 trick (additive), so the layout makes iff
	     t - (#misguessed) ≥ need. We take the policy maximising the make fraction (2^n_pivots policies, n
	     tiny). This COMPOUNDS independent guesses — two knife-edge two-way finesses on a cold ceiling drop
	     it to ~25%, not the ~50% a single-worst view would report. With one pivot it is exactly step 3; with
	     none, achievable == ceiling. `pivots[i].achievable` still reports each guess's MARGINAL make-% (that
	     guess alone, others assumed right) for labelling, dominant (lowest-marginal) first.

	This is APPROXIMATE but honest-DIRECTION: achievable ≤ ceiling always (a commit can only lose vs
	peeking), and the tax is the gap the entry/tempo/guess help already warns about in words. It gives the
	4th reconciliation rung `ceiling · blind(combo-SD) · simulated(DDS ceiling) · achievable(tax)`. It does
	NOT model squeezes/endplays that the ceiling's per-layout solve already captures, nor guesses looser
	than a tight two-way tenace (those are left untaxed = slightly optimistic, deliberately conservative
	against PIMC's pessimistic floor). Cost ≈ sample.odin's ceiling (same solves), so it bakes at export.

	Single-threaded, like every DDS call here (DDS shares process-global transposition tables).
*/

import "base:intrinsics"
import "core:slice"

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

// Identify the blind TWO-WAY guesses in the two known hands: a defender-held honour C (rank Ten..King)
// that declarer can finesse EITHER way. Geometry:
//   * combined: declarer holds BOTH immediate neighbours of C (C+1 and C-1) — a tight tenace that traps C
//     (this excludes "solid tops" like AKQ missing J, where the card just below J is a defender card), AND
//   * per-hand: EACH declaring hand holds a card ranked above C — so declarer can lead toward a trap from
//     either side, i.e. the guess is genuinely two-way rather than a single forced finesse.
// The floor is the TEN: a two-way finesse for the ten (declarer holding the J and 9 around it, with a card
// above in both hands — e.g. K9 opp AJ, missing QT) is a genuine binary guess, and it is the case that
// yields two INDEPENDENT same-suit pivots (Q and T, separated by the held J). Deeper cards (a two-way for
// the nine) are essentially never a trick-deciding guess, so the range stops at the ten. The Ace is never a
// target (nothing outranks it); a King is never two-way (it would need the Ace above it in BOTH hands);
// adjacent missing honours (e.g. missing KQ together) fail the neighbour test and are left untaxed. Returns
// the pivot CARDS (up to TAX_MAX_PIVOTS).
@(private)
two_way_guess_pivots :: proc(deal: norn.Deal, a, b: norn.Seat) -> (out: [TAX_MAX_PIVOTS]norn.Card, n: int) {
	combined := side_suit_masks(deal, a, b)
	for suit in norn.Suit {
		held := combined[suit]
		ha := hand_suit_mask(deal[a], suit)
		hb := hand_suit_mask(deal[b], suit)
		for r in int(norn.Rank.Ten) ..= int(norn.Rank.King) {
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

	ha, hb := dds.Hand(int(a)), dds.Hand(int(b))

	strain := contract.strain
	need := contract.level + 6
	ceiling_hist: [14]int
	total_tricks := 0
	// joint_hist[combo][t]: layouts whose pivot-holder pattern is `combo` (bit i = defender holding pivot i)
	// and whose DD trick count is t. Feeds the best-policy joint achievable (step 4). Sized for the full cap
	// but only the low 2^n_pivots combos are ever touched.
	joint_hist: [1 << TAX_MAX_PIVOTS][14]int

	// Same constrained layouts as the ceiling sample (identical seed), DD-solved as a parallel batch.
	layouts, tables, sok := sample_solved(pd, n_samples, seed, constraints)
	if !sok {
		return {}, false
	}
	defer delete(layouts)
	defer delete(tables)
	for tbl, si in tables {
		layout := layouts[si]
		// Best of the two pair members declaring, matching sample_grid's ceiling exactly.
		tk := clamp(max(int(tbl.resTable[strain][ha]), int(tbl.resTable[strain][hb])), 0, 13)
		ceiling_hist[tk] += 1
		total_tricks += tk
		// Split each pivot's tricks by which defender holds the trapped honour this layout, and build the
		// joint holder-pattern for the best-policy achievable.
		combo := 0
		for i in 0 ..< n_pivots {
			holder := defender_holding(layout, defs, tracks[i].card)
			tracks[i].hist[holder][tk] += 1
			combo |= holder << uint(i)
		}
		joint_hist[combo][tk] += 1
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

	// Per-pivot MARGINAL make-% (each guess alone, for labelling) ...
	for i in 0 ..< n_pivots {
		result.pivots[i] = Tax_Pivot {
			card       = tracks[i].card,
			achievable = committed_make_pct(tracks[i].hist, need, n_samples),
		}
	}
	// ... and the board achievable = the best fixed blind policy across ALL pivots jointly (step 4). With no
	// guesses there is nothing to commit, so it stays at the ceiling.
	result.achievable_pct = result.ceiling_pct
	if n_pivots > 0 {
		result.achievable_pct = joint_achievable_pct(joint_hist[:], n_pivots, need, n_samples)
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

// The JOINT achievable make-% over all pivots (step 4): the best fixed blind commit policy. A policy is an
// n-bit mask fixing a finesse direction per pivot; on a layout with holder-pattern `combo` it misguesses the
// pivots where the committed direction differs (popcount(combo XOR policy)), each -1 trick, so the layout
// makes iff t ≥ need + misguesses. Returns the make fraction of the best policy. 2^n policies × 2^n combos,
// n ≤ TAX_MAX_PIVOTS and in practice a handful, so this is trivial.
@(private = "file")
joint_achievable_pct :: proc(joint: [][14]int, n_pivots, need, n: int) -> f64 {
	combos := 1 << uint(n_pivots)
	best := 0
	for policy in 0 ..< combos {
		make := 0
		for combo in 0 ..< combos {
			mis := intrinsics.count_ones(combo ~ policy)
			thr := need + mis
			for k in thr ..< 14 {
				make += joint[combo][k]
			}
		}
		if make > best {
			best = make
		}
	}
	return f64(best) / f64(n) * 100
}

// Order the pivots by achievable make-% ASCENDING (dominant guess — the one that hurts most — first), so
// pivots[0] is the guess that set `achievable_pct`. The slice is tiny (≤ TAX_MAX_PIVOTS).
@(private = "file")
sort_pivots_dominant_first :: proc(pivots: []Tax_Pivot) {
	slice.sort_by(pivots, proc(a, b: Tax_Pivot) -> bool {return a.achievable < b.achievable})
}
