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

	2. ADAPTIVE OPTIMUM (`optimal_adaptive_value`) — the residual-target DP. Play the suits in order and
	   let each suit's line depend on how many tricks the earlier suits produced (real declarers count
	   as they go). `h(i, a)` = best achievable objective when suits i.. are still to come and `a` tricks
	   are already in: `h(i, a) = max over lines L of sum_b P_L(b) * h(i+1, a+b)`, `h(4, a) = w[a]`. This
	   is >= the fixed combination (adapting can only help) and is the true optimum for the goal.

	Candidate lines per suit come from brick 2 (`suit_candidate_lines`); the DP/search picks among them.
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
gather_candidates :: proc(north, south: norn.Hand_Summary, allocator := context.allocator) -> [4][]Line_Result {
	out: [4][]Line_Result
	for suit, i in DISPLAY_SUITS {
		out[i] = suit_candidate_lines(north.suits[suit], south.suits[suit], allocator)
	}
	return out
}

// Choose ONE line per suit to maximise the objective of the convolved total — an exhaustive search
// over the (few) candidate lines per suit. Returns the winning line per suit, the total distribution,
// and the objective value.
best_fixed_combination :: proc(north, south: norn.Hand_Summary, obj: Objective) -> Line_Combination {
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

// The residual-target DP over a fixed candidate set: `h(i, a) = max_L sum_b P_L(b) h(i+1, a+b)`,
// `h(4, a) = obj[a]`, answer `h(0, 0)`. Each suit's line may depend on the tricks already taken
// (adaptive), so this is >= any fixed line-per-suit combination.
@(private)
dp_value :: proc(cand: [4][]Line_Result, obj: Objective) -> f64 {
	h := ([RANKS + 1]f64)(obj) // h(4, a) = w[a]
	for i := 3; i >= 0; i -= 1 {
		next: [RANKS + 1]f64
		for a in 0 ..= RANKS {
			best := f64(0)
			have := false
			for L in cand[i] {
				s := f64(0)
				for b in 0 ..= RANKS - a {
					s += L.dist.p[b] * h[a + b]
				}
				if !have || s > best {
					best = s
					have = true
				}
			}
			next[a] = best
		}
		h = next
	}
	return h[0]
}

// The adaptive optimum for one objective (gathers candidates, then runs the DP).
optimal_adaptive_value :: proc(north, south: norn.Hand_Summary, obj: Objective) -> f64 {
	cand := gather_candidates(north, south, context.temp_allocator)
	return dp_value(cand, obj)
}

// The whole "best achievable P(>= t)" curve for t = 0..13 — the adaptive optimum of the make objective
// at every target, computed with ONE candidate gather. `curve[t]` is the best chance of taking AT LEAST
// `t` total tricks a blind declarer can arrange (>= the tail of any fixed combination). Monotone
// non-increasing, `curve[0] = 1`. This is the objective/DP result the card page surfaces.
adaptive_at_least_curve :: proc(north, south: norn.Hand_Summary) -> [RANKS + 1]f64 {
	cand := gather_candidates(north, south, context.temp_allocator)
	res: [RANKS + 1]f64
	for t in 0 ..= RANKS {
		res[t] = dp_value(cand, objective_at_least(t))
	}
	return res
}
