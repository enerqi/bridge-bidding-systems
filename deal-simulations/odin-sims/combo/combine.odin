package combo

/*
	combine.odin — Phase 2, brick 4: the objective layer + the residual-target DP over the four suits.

	Bricks 1–3 produce, per suit, real achievable trick distributions (from fixed lines, candidate
	lines, or the optimal search). This brick chooses HOW to combine the four suits, and toward WHAT
	goal — because the right line depends on the goal (see the "Objective-function factoring" note in
	COMBO_ANALYSER.md).

	================================================================================================
	THE OBJECTIVE IS A WEIGHT VECTOR
	================================================================================================

	Every goal we care about is an ADDITIVE functional of the total-trick distribution: its value is
	`sum over t of P(total = t) * w[t]`, where `w[t]` is the reward for finishing with exactly `t`
	tricks. That single vector `w` captures them all:

	  * "make the contract"  → w[t] = 1 for t >= target, else 0   (so the value is P(>= target))
	  * expected tricks      → w[t] = t
	  * IMPs / raw score     → w[t] = the score for taking t tricks in the contract (any scale)
	  * matchpoints          → w[t] = P(field < t) + 1/2 P(field = t)   (beat-the-field, needs a field
	                           distribution — Phase 1's census is a ready-made "what the field can do")

	So the objective plugs in as data, not code: `Objective` is just `w`, and `apply_objective` scores a
	distribution against it.

	================================================================================================
	TWO WAYS TO COMBINE (both provided)
	================================================================================================

	1. BEST FIXED COMBINATION (`best_fixed_combination`) — choose ONE line per suit up front to maximise
	   the objective of the convolved total. Reportable ("play these four lines") and gives a concrete
	   total distribution. With a handful of candidate lines per suit this is a tiny exhaustive search.

	2. ADAPTIVE OPTIMUM (`optimal_adaptive_value` / `adaptive_at_least_curve`) — the residual-target DP.
	   Play the suits in order and let each suit's line depend on what the earlier suits produced (real
	   declarers count as they go). It is >= the fixed combination (adapting can only help) and is the true
	   optimum for the goal.

	   Two combination models appear here, deliberately:
	     * INDEPENDENT (`dp_value` — the illustration primitive, kept private): `h(i, a) = max_L sum_b
	       P_L(b) h(i+1, a+b)`, folding per-suit MARGINALS as if the suits were independent. Correct for
	       reasoning about isolated suits and usable on synthetic/partial holdings.
	     * JOINT (`dp_value_joint` — the whole-deal version the real-deal API uses): carries East's running
	       card count as a second DP axis so the four suits fold under the true constraints — East holds 13
	       of the 26 opponent cards, NS take at most 13 tricks — exactly the fix `joint_total` (combo.odin)
	       applies to the census/SD totals, now threaded through the adaptive line choice. Needs full 13-
	       card hands. This is what the card page's make curve (`data-*-atl`) comes from.

	Candidate lines per suit come from brick 2 (`suit_candidate_lines` / `candidate_lines`); the DP/search
	picks among them. (`best_fixed_combination` still combines by independent convolution — a reportable
	"play these four lines" illustration; the joint refinement lives in the ADAPTIVE path, which is what the
	card page surfaces.)
*/

import "norn:norn"

// The reward for finishing with exactly `t` total NS tricks. Any additive goal is one of these.
Objective :: distinct [RANKS + 1]f64

// "Make": value = P(total >= target). The default goal, matching the card page's P(>= target) slider.
objective_at_least :: proc(target: int) -> Objective {
	o: Objective
	for t in 0 ..= RANKS {
		if t >= target {
			o[t] = 1
		}
	}
	return o
}

// IMPs (teams / rubber): the value is dominated by the make/fail CLIFF at the contract, with only a
// small tilt for over/undertricks — so the line that maximises IMPs is essentially the SAFEST one that
// maximises P(>= target). We model that directly as the make objective: `objective_imps(target)` is
// `objective_at_least(target)`. (A full IMP-scaled score would need the contract level + vulnerability;
// for LINE SELECTION it does not change the answer — safety first.) Contrast `objective_matchpoints`,
// where beating the field on overtricks can be worth risking the contract.
objective_imps :: proc(target: int) -> Objective {
	return objective_at_least(target)
}

// Expected tricks: value = E[total]. A linear goal — no cross-suit interaction, so the best
// combination is just the best-mean line in each suit and the adaptive DP equals the fixed one.
objective_expected_tricks :: proc() -> Objective {
	o: Objective
	for t in 0 ..= RANKS {
		o[t] = f64(t)
	}
	return o
}

// Matchpoints against a field whose total-trick distribution is `field` (e.g. Phase 1's census — what
// the field can extract double-dummy in the same contract): value = expected matchpoints in [0,1],
// `w[t] = P(field < t) + 1/2 P(field = t)`. This is where risking the contract for an overtrick can
// pay: beating the field, not merely making, is rewarded.
objective_matchpoints :: proc(field: [RANKS + 1]f64) -> Objective {
	o: Objective
	for t in 0 ..= RANKS {
		less := f64(0)
		for u in 0 ..< t {
			less += field[u]
		}
		o[t] = less + 0.5 * field[t]
	}
	return o
}

// Score a total-trick distribution against an objective: sum_t total[t] * w[t].
apply_objective :: proc(total: [RANKS + 1]f64, obj: Objective) -> f64 {
	s := f64(0)
	for t in 0 ..= RANKS {
		s += total[t] * obj[t]
	}
	return s
}

// The result of choosing one line per suit: the chosen line name per suit, the resulting total
// distribution, and the objective value it achieves.
Line_Combination :: struct {
	lines: [norn.Suit]string,
	total: [RANKS + 1]f64,
	value: f64,
}

DISPLAY_SUITS :: [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}

// Gather the candidate lines for all four suits of an NS pair. Caller owns the returned slices.
@(private)
gather_candidates :: proc(
	north, south: norn.Hand_Summary,
	allocator := context.allocator,
) -> [4][]Line_Result {
	out: [4][]Line_Result
	for suit, i in DISPLAY_SUITS {
		out[i] = suit_candidate_lines(north.suits[suit], south.suits[suit], allocator)
	}
	return out
}

// Choose ONE line per suit to maximise the objective of the convolved total — an exhaustive search
// over the (few) candidate lines per suit. Returns the winning line per suit, the total distribution,
// and the objective value.
best_fixed_combination :: proc(
	north, south: norn.Hand_Summary,
	obj: Objective,
) -> Line_Combination {
	cand := gather_candidates(north, south, context.temp_allocator)

	best: Line_Combination
	best.value = -1
	found := false

	for a in cand[0] {
		for b in cand[1] {
			ab := convolve(a.dist.p, b.dist.p)
			for c in cand[2] {
				abc := convolve(ab, c.dist.p)
				for d in cand[3] {
					total := convolve(abc, d.dist.p)
					v := apply_objective(total, obj)
					if !found || v > best.value {
						found = true
						best.value = v
						best.total = total
						best.lines[DISPLAY_SUITS[0]] = a.name
						best.lines[DISPLAY_SUITS[1]] = b.name
						best.lines[DISPLAY_SUITS[2]] = c.name
						best.lines[DISPLAY_SUITS[3]] = d.name
					}
				}
			}
		}
	}
	return best
}

// --- The JOINT adaptive DP (the whole-deal version the card page surfaces) --------------------
//
// `best_fixed_combination`/`dp_value` above combine the four suits by INDEPENDENT trick convolution — the
// objective-layer primitive, correct as a model of isolated suits and usable on synthetic/partial
// holdings (the tests lean on that). But for a REAL deal the four suits are NOT independent: East holds
// exactly 13 of the 26 opponent cards, so being long in one suit forces shortness in another, and NS take
// at most 13 tricks total. `dp_value_joint` below folds the suits under those two constraints — the same
// fix `joint_total` applies to the census/SD totals, now carried THROUGH the adaptive line choice — and it
// is what `optimal_adaptive_value` / `adaptive_at_least_curve` (the real-deal, card-page-facing API) use.

// A candidate line together with its JOINT (east_len × tricks) table for one suit. The length axis is
// exactly what lets the four suits be folded under the "East holds 13" constraint; a plain per-suit
// marginal (`Line_Result.dist`) cannot express it. `name` is carried only for parity with `Line_Result`.
@(private)
Line_Joint :: struct {
	name: string,
	tbl:  Suit_Joint_Table,
}

// Gather, for each of the four suits, one `Line_Joint` per candidate line — the joint-model counterpart
// of `gather_candidates`. Each table comes from `sd_line_joint_table` (enumerate every E/W split, play the
// fixed line out double-dummy, tally raw counts by East's length and the trick result). Caller owns the
// returned slices.
@(private)
gather_candidate_tables :: proc(
	north, south: norn.Hand_Summary,
	allocator := context.allocator,
) -> [4][]Line_Joint {
	out: [4][]Line_Joint
	lines := candidate_lines()
	// One scratch map reused (cleared per call) across all 4×5 line evaluations — collapses what was an
	// alloc+free per joint table into a single backing allocation for the whole gather.
	memo := make(map[u64]int)
	defer delete(memo)
	for suit, i in DISPLAY_SUITS {
		lj := make([]Line_Joint, len(lines), allocator)
		for line, j in lines {
			lj[j] = Line_Joint {
				name = line.name,
				tbl  = sd_line_joint_table(north.suits[suit], south.suits[suit], line, &memo),
			}
		}
		out[i] = lj
	}
	return out
}

// The residual-target DP over candidate lines, JOINT (length-constrained) version. Where the independent
// `dp_value` carried only "tricks taken so far" (`a`) and convolved per-suit marginals, this carries BOTH
//   e = East's cards used by the suits already folded (0..13), and
//   a = NS tricks already in (0..13, capped),
// so the four suits combine under the true whole-deal constraints (East holds 13 of the 26 opponent
// cards; NS take at most 13 tricks) rather than as if independent.
//
// State g[e][a]. Terminal (after all four suits) g4[e][a] = obj[a] if e == 13 — a valid 13/13 deal —
// else 0 (an assignment where East does not end with exactly 13 cards is not a real deal). Recursion for
// suit i, using each candidate line's joint table `count_L[a_i][k]` (a_i = East's length in the suit, k =
// the line's tricks there):
//
//     g_i[e][a] = max over candidate lines L of
//                     sum_{a_i, k}  count_L[a_i][k] * g_{i+1}[ e + a_i ][ min(a + k, 13) ]
//
// The answer is g0[0][0] / C(26,13): the valid deals are exactly the e==13 terminal paths, and there are
// C(26,13) of them, so dividing turns the accumulated weighted counts into a probability-weighted value.
//
// LINE CHOICE conditions on BOTH e and a. `a` (tricks) is the same information the independent DP adapted
// on. `e` (East's used length) is also legitimately observable: a declarer counting the hand knows how
// many cards each defender has followed with, hence East's length in the suits already played. Allowing
// the line to use it keeps this an adaptive OPTIMUM — an upper bound on blind play, never below the fixed
// combination — consistent with the model's other double-dummy idealisations.
//
// PRECONDITION: full 13-card hands (so the opponents hold 26 and East 13) — see `joint_total`. Real deals
// always satisfy this; partial/synthetic holdings would break the e==13 normalisation (use the
// independent `best_fixed_combination` for those).
@(private)
dp_value_joint :: proc(cand: [4][]Line_Joint, obj: Objective) -> f64 {
	// Terminal layer g4[e][a]: reward obj[a] only on the e == 13 row; every other length is an invalid
	// (non-)deal and stays 0.
	g: [RANKS + 1][RANKS + 1]f64
	for a in 0 ..= RANKS {
		g[RANKS][a] = obj[a]
	}

	// Fold the suits in reverse (3, 2, 1, 0), each layer maximising over its candidate lines per (e, a).
	for i := 3; i >= 0; i -= 1 {
		ng: [RANKS + 1][RANKS + 1]f64
		for e in 0 ..= RANKS {
			for a in 0 ..= RANKS {
				best := f64(0)
				have := false
				for L in cand[i] {
					s := f64(0)
					for ai in 0 ..= L.tbl.m {
						if e + ai > RANKS {
							break // East cannot exceed 13 cards — this and larger a_i are impossible
						}
						for k in 0 ..= RANKS {
							c := L.tbl.count[ai][k]
							if c == 0 {
								continue
							}
							s += c * g[e + ai][min(a + k, RANKS)]
						}
					}
					if !have || s > best {
						best = s
						have = true
					}
				}
				ng[e][a] = best
			}
		}
		g = ng
	}
	return g[0][0] / g_binom[26][13]
}

// The adaptive optimum for one objective, JOINT model (gathers the per-line joint tables, runs the DP).
// The whole-deal counterpart of the independent `best_fixed_combination`: `optimal_adaptive_value >=` the
// joint fixed combination, since adapting the line to what has already happened can only help.
// PRECONDITION: full 13-card hands (see `dp_value_joint`).
optimal_adaptive_value :: proc(north, south: norn.Hand_Summary, obj: Objective) -> f64 {
	cand := gather_candidate_tables(north, south, context.temp_allocator)
	return dp_value_joint(cand, obj)
}

// The whole "best achievable P(>= t)" curve for t = 0..13 — the joint adaptive optimum of the make
// objective at every target, computed with ONE gather of the per-line joint tables. `curve[t]` is the best
// chance of taking AT LEAST `t` total tricks a blind declarer can arrange, folding the four suits under
// the East-holds-13 / 13-trick-cap constraints (NOT an independent convolution — the length-independence
// fix, mirroring `joint_total`, now applied to the adaptive curve). Monotone non-increasing, `curve[0] =
// 1`. This is the DP result the card page surfaces as the `data-*-atl` blob / the `>=sd` overlay row.
// PRECONDITION: full 13-card hands (see `dp_value_joint`).
adaptive_at_least_curve :: proc(north, south: norn.Hand_Summary) -> [RANKS + 1]f64 {
	cand := gather_candidate_tables(north, south, context.temp_allocator)
	return adaptive_curve_from(cand)
}

// The make curve from ALREADY-GATHERED candidate joint tables — the reusable core of
// `adaptive_at_least_curve`, split out so the render path (`annotate`) can share ONE gather of the
// tables across the curve, the SD total, and the per-suit rows instead of re-gathering (PERFORMANCE.md §2).
@(private)
adaptive_curve_from :: proc(cand: [4][]Line_Joint) -> [RANKS + 1]f64 {
	res: [RANKS + 1]f64
	for t in 0 ..= RANKS {
		res[t] = dp_value_joint(cand, objective_at_least(t))
	}
	return res
}
