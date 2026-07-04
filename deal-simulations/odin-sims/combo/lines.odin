package combo

/*
	lines.odin — Phase 2, brick 2: the candidate-line generator.

	Brick 1 (`single_dummy.odin`) SCORES one blind line. This file supplies a small set of real,
	generic blind lines — the strategic axes a declarer actually chooses among in a single suit — and
	the machinery to compare them:

	  * `line_top_down`   (in single_dummy.odin) — cash the highest card every trick; never finesse.
	                       The "play for the drop" baseline.
	  * `line_finesse`    — lead low toward the honour hand; the partner inserts the CHEAPEST card that
	                       beats the right-hand defender (a finesse when they play low, a cover when
	                       they play an honour). The "take the finesse" line.
	  * `line_duck_one`   — concede the first round (both hands play low), then cash top-down. The
	                       "duck to keep control / prepare a long suit" line.

	These are deliberately GENERIC heuristics (they apply to any holding), not the per-holding optimum —
	finding that is brick 3 (the optimal single-dummy SEARCH). Their job here is to give brick 4's DP a
	real, cheap set of alternatives to choose among.

	The comparison tools:
	  * `suit_candidate_lines` evaluates every candidate on a holding -> a `Line_Result` per line.
	  * `pareto_lines` keeps only the NON-DOMINATED ones: line A dominates B when A's P(>= k) tail is
	    at least B's for every k and strictly greater for some k. What survives is the Pareto frontier —
	    for any make-target you might pick, the best line for it is in this set (the doc's "candidate set
	    = the Pareto lines, one maximising P(>= k) per k").
	  * `best_line` picks the single line maximising P(>= target) (ties broken by mean tricks) — the
	    one-suit answer that brick 4 will generalise into a residual-target DP across all four suits.
*/

// A named line together with the trick distribution it achieves on a given holding (single-dummy,
// double-dummy defence — from brick 1's `sd_line_distribution`).
Line_Result :: struct {
	name: string,
	dist: Suit_Trick_Dist,
}

// The generic candidate lines, in a stable order. Returned by value (a small fixed array of constant
// `Sd_Line`s) so callers needn't manage storage.
candidate_lines :: proc() -> [3]Sd_Line {
	return {line_top_down, line_finesse, line_duck_one}
}

// `line_finesse` — lead low toward the honour hand and insert the cheapest card that beats the
// right-hand defender. On a tenace (AQ, KJ, ...) this is the finesse; with solid tops it degrades to
// cashing them; with nothing it just loses low. A well-defined blind line, the natural complement to
// `line_top_down`.
line_finesse :: Sd_Line {
	name    = "finesse",
	lead    = proc(north, south, played: u16) -> (seat: int, rank: int) {
		// Honour hand = the seat holding the single highest NS card; lead low from the OTHER hand
		// toward it (or from the honour hand itself if its partner is void).
		hon := SEAT_N if (north != 0 && (south == 0 || highest_rank(north) >= highest_rank(south))) else SEAT_S
		lead_seat := SEAT_S if hon == SEAT_N else SEAT_N
		lead_hold := south if lead_seat == SEAT_S else north
		if lead_hold == 0 {
			lead_seat = hon
			lead_hold = north if hon == SEAT_N else south
		}
		return lead_seat, lowest_rank(lead_hold)
	},
	partner = proc(v: Sd_View) -> int {
		// Insert the cheapest card that beats the right-hand defender's card (the finesse / cover).
		if v.rho_rank >= 0 {
			m := v.own
			for m != 0 {
				r := lowest_rank(m)
				m &= m - 1
				if r > v.rho_rank {
					return r // lowest card strictly above RHO — iterating low->high, first hit is cheapest
				}
			}
		}
		return lowest_rank(v.own)
	},
}

// `line_duck_one` — concede the opening round (lead low, partner low), then cash top-down. Ducking
// once can strip the defenders' small cards / preserve a stopper; whether it gains is holding-specific,
// which is exactly why it is a distinct candidate for the frontier to keep or discard.
line_duck_one :: Sd_Line {
	name    = "duck-one",
	lead    = proc(north, south, played: u16) -> (seat: int, rank: int) {
		if played == 0 {
			// First trick of the suit: lead low (duck) from a non-void hand.
			if south != 0 {
				return SEAT_S, lowest_rank(south)
			}
			return SEAT_N, lowest_rank(north)
		}
		// Thereafter behave like top-down: lead the highest NS card.
		if north == 0 {
			return SEAT_S, highest_rank(south)
		}
		if south == 0 {
			return SEAT_N, highest_rank(north)
		}
		hn, hs := highest_rank(north), highest_rank(south)
		if hn >= hs {
			return SEAT_N, hn
		}
		return SEAT_S, hs
	},
	partner = proc(v: Sd_View) -> int {return lowest_rank(v.own)},
}

// --- comparing the candidates -----------------------------------------------------------------

// Evaluate every candidate line on one holding. Caller owns the returned slice.
suit_candidate_lines :: proc(north, south: u16, allocator := context.allocator) -> []Line_Result {
	lines := candidate_lines()
	out := make([]Line_Result, len(lines), allocator)
	for line, i in lines {
		out[i] = Line_Result {
			name = line.name,
			dist = sd_line_distribution(north, south, line),
		}
	}
	return out
}

// Does `b` dominate `a`? True when b's P(>= k) tail is >= a's for every k and strictly greater for at
// least one — so b is at least as good for every make-target and better for some.
@(private)
line_dominates :: proc(a, b: Suit_Trick_Dist) -> bool {
	EPS :: 1e-9
	ge_all := true
	gt_some := false
	for k in 0 ..= RANKS {
		ta := p_at_least(a.p, k)
		tb := p_at_least(b.p, k)
		if tb < ta - EPS {
			ge_all = false
			break
		}
		if tb > ta + EPS {
			gt_some = true
		}
	}
	return ge_all && gt_some
}

@(private)
dist_near_equal :: proc(a, b: Suit_Trick_Dist) -> bool {
	EPS :: 1e-9
	for k in 0 ..= RANKS {
		if abs(p_at_least(a.p, k) - p_at_least(b.p, k)) > EPS {
			return false
		}
	}
	return true
}

// The Pareto frontier of a candidate set: drop every line another line dominates, and de-duplicate
// lines with (essentially) identical distributions — keeping the first, so a stable, minimal set of
// genuinely distinct choices remains. Caller owns the returned slice.
pareto_lines :: proc(cands: []Line_Result, allocator := context.allocator) -> []Line_Result {
	keep := make([dynamic]Line_Result, allocator)
	outer: for c, i in cands {
		for other, j in cands {
			if i == j {
				continue
			}
			if line_dominates(c.dist, other.dist) {
				continue outer // dominated -> drop
			}
			if j < i && dist_near_equal(c.dist, other.dist) {
				continue outer // an earlier clone already represents this distribution
			}
		}
		append(&keep, c)
	}
	return keep[:]
}

// The single best candidate line for a target trick count: maximise P(>= target), ties broken by the
// higher mean. This is the one-suit make-line; brick 4 turns "fixed target per suit" into a
// residual-target DP that folds the four suits together under a pluggable objective.
best_line :: proc(north, south: u16, target: int) -> Line_Result {
	lines := candidate_lines()
	best: Line_Result
	best_key := f64(-1)
	best_mean := f64(-1)
	for line in lines {
		dist := sd_line_distribution(north, south, line)
		key := p_at_least(dist.p, target)
		mean := expected_tricks(dist.p)
		if key > best_key + 1e-12 || (abs(key - best_key) <= 1e-12 && mean > best_mean) {
			best_key = key
			best_mean = mean
			best = Line_Result{name = line.name, dist = dist}
		}
	}
	return best
}
