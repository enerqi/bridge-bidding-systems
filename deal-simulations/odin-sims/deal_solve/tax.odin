package deal_solve

/*
	tax.odin — the misguess-TAX estimator: a cheap, export-friendly ACHIEVABLE single-dummy make-%.

	The problem (COMBO_ANALYSER.md "★ 2-hand advisor", NOT-DONE #1). sample.odin's make-% is a per-layout
	DOUBLE-DUMMY census: every sampled layout is solved with declarer PEEKING at the defenders, so the
	aggregate is a CEILING. The honest number a player wants is lower — declarer must commit ONE blind
	policy across all layouts (a whole-deal POMDP). The industry estimator of that gap is PIMC (spiked as
	pimc.odin, deleted 2026-10-09 - see git history), but full PIMC is BOTH expensive (~50-500x the ceiling)
	AND finicky (naive PIMC undershoots via DD-value-tie procrastination). This file is the DECIDED cheaper alternative: estimate the tax the
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

import "norn:norn"
import "../sampled"

// The filters are `sampled`'s (shared with the shared-deals player); the names this package has always used.
TAX_MAX_PIVOTS :: sampled.TAX_MAX_PIVOTS
Tax_Pivot :: sampled.Tax_Pivot
Tax_Result :: sampled.Tax_Result
Lead_Tax_Entry :: sampled.Lead_Tax_Entry
Lead_Tax :: sampled.Lead_Tax
tax_from_sample :: sampled.tax_from_sample
lead_tax_from_sample :: sampled.lead_tax_from_sample
two_way_guess_pivots :: sampled.two_way_guess_pivots

// Estimate the ACHIEVABLE single-dummy make-% for `contract` declared by the known partnership `side` (the
// two seats named in `side` must both be in `board.known`), over `n_samples` constrained layouts. Reuses
// sample.odin's sampling machinery (same reject-sampling `constraints`, same seeded RNG, one
// CalcDDtable/layout — NO extra solves). See the file header for the model. ok mirrors sample_grid's guards
// (side must be a fully-known partnership; n_samples > 0; DDS must succeed; constraints must be satisfiable
// within SAMPLE_MAX_REDEAL redeals).
misguess_tax :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	contract: Contract,
	n_samples: int,
	seed: u64 = 0,
	constraints: Sample_Constraints = {},
) -> (
	result: Tax_Result,
	ok: bool,
) {
	s, sok := solve_sample(board, side, n_samples, seed, constraints)
	if !sok {
		return {}, false
	}
	defer solved_sample_free(&s)
	return tax_from_sample(board, &s, contract)
}

