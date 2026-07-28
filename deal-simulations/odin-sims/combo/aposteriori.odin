package combo

/*
	aposteriori.odin — vacant-space / a-posteriori re-weighting under KNOWN opponent shape.

	The rest of combo assumes the a-priori 13-13 model: before we know anything, each defender is
	equally likely to hold any card, so a suit's E/W split gets the hypergeometric weight
	`C(26-m,13-a)/C(26,13)` (see `marginal_from_table`) and the four suits fold under "East holds 13 of
	the 26 opponent cards" (`joint_total`). When something is KNOWN about the defenders' distribution —
	a shown-out suit, a bid-out length, a count signal — those weights skew, and the best line can flip
	(a drop overtakes a finesse; a finesse reverses direction).

	This file computes the exact a-posteriori distributions and line choice under MINIMUM per-defender
	per-suit lengths ("West is known to hold at least 5 spades"). A minimum is not a single vacant-space
	scalar (West could hold 5, 6, 7...), so we do NOT approximate with a scalar swap — instead we restrict
	the joint length DP that `analyse_ns`/`joint_total` already run:

	    "defender X holds >= q cards in this suit"  is an INDEX RANGE on East's per-suit length `a`:
	        X = the `a`-side (`lo`):  a >= q
	        X = the other side (`hi`): (m - a) >= q  <=>  a <= m - q

	Restrict `a` to `[alo, ahi]` per suit, keep the whole-deal "East ends on exactly 13" constraint, and
	renormalise by the SURVIVING weight instead of C(26,13). That is exact (it integrates over every
	length the minimum allows), handles minimums / exact counts (q on both sides) / voids uniformly, and
	the cross-suit coupling — East long here is short there — falls straight out of the DP.

	Only used when a constraint is actually present (`Opp_Constraints.active`); the unconstrained render
	path keeps the existing `finish_census`/`marginal_from_table` code untouched, so a page with no
	opponent knowledge entered is byte-identical to before.
*/

import "norn:norn"

// Minimum cards each defender is KNOWN to hold, per suit. `lo` indexes the defender counted by a joint
// table's East-length axis `a`; `hi` the other defender. All-zero => no knowledge (the a-priori model, and
// callers should take the existing unconstrained path). The two minimums in one suit must leave room for
// the opponents' cards there (`lo[s] + hi[s] <= m`), else the deal is infeasible.
Opp_Constraints :: struct {
	lo, hi: [norn.Suit]int,
	active: bool,
}

// The allowed East-length range `[alo, ahi]` for a suit under the two per-suit minimums. `alo` from the
// `a`-side defender's minimum, `ahi` from the other's (its q cards are taken OFF East's maximum). Clamped
// to the physically possible `0..m`; `alo > ahi` signals the minimums contradict this holding.
@(private = "file")
suit_a_range :: proc(tbl: Suit_Joint_Table, lo, hi: int) -> (alo, ahi: int) {
	alo = max(lo, 0)
	ahi = tbl.m - max(hi, 0)
	if ahi > tbl.m {
		ahi = tbl.m
	}
	return
}

// Per-suit East-LENGTH weight within the allowed range: `lw[a] = sum_k count[a][k]` (the number of E/W
// splits with East holding `a` of this suit's `m` cards, ignoring tricks), 0 outside `[alo, ahi]`. The
// length weight is line-INDEPENDENT — a line redistributes a split's tricks across `k`, never East's card
// count — so census and every candidate SD line share it, and it is exactly what the cross-suit
// convolution needs. (Unconstrained, `lw[a] = C(m,a)`.)
@(private = "file")
length_weights :: proc(tbl: Suit_Joint_Table, alo, ahi: int) -> (lw: [RANKS + 1]f64) {
	for a in alo ..= ahi {
		s: f64
		for k in 0 ..= RANKS {
			s += tbl.count[a][k]
		}
		lw[a] = s
	}
	return
}

// Convolve two East-length weight vectors, capping the total at 13 (East never holds more than 13 cards —
// paths that would exceed it are impossible deals and dropped, exactly as the joint DP prunes `e + a > 13`).
@(private = "file")
conv_len :: proc(x, y: [RANKS + 1]f64) -> (z: [RANKS + 1]f64) {
	for i in 0 ..= RANKS {
		if x[i] == 0 {
			continue
		}
		for j in 0 ..= RANKS - i {
			if y[j] == 0 {
				continue
			}
			z[i + j] += x[i] * y[j]
		}
	}
	return
}

// Everything the constrained assembly and the SD line re-pick share: per-suit allowed ranges, the
// leave-one-out East-length weight of the OTHER three suits (`others[S][e]` = ways the other suits give
// East `e` cards, honouring their minimums), and the total surviving deal weight `D` (the renormaliser,
// = number of a-priori deals consistent with every minimum). `feasible` is false when some suit's minimums
// contradict the holding or no deal satisfies all of them at once (`D == 0`).
@(private)
Constraint_Ctx :: struct {
	alo, ahi: [norn.Suit]int,
	others:   [norn.Suit][RANKS + 1]f64,
	D:        f64,
	feasible: bool,
}

// Build the shared context from the four census joint tables + the constraints. `others` and `D` derive
// only from the length weights (line-independent), so this is computed once and reused by both the census
// assembly and the SD best-line re-pick.
@(private)
constraint_ctx :: proc(tables: [norn.Suit]Suit_Joint_Table, oc: Opp_Constraints) -> (ctx: Constraint_Ctx) {
	lw: [norn.Suit][RANKS + 1]f64
	for suit in norn.Suit {
		ctx.alo[suit], ctx.ahi[suit] = suit_a_range(tables[suit], oc.lo[suit], oc.hi[suit])
		if ctx.alo[suit] > ctx.ahi[suit] {
			return // feasible stays false
		}
		lw[suit] = length_weights(tables[suit], ctx.alo[suit], ctx.ahi[suit])
	}

	// Leave-one-out length convolution: others[S] = the other three suits folded together.
	for S in norn.Suit {
		conv: [RANKS + 1]f64
		conv[0] = 1
		for suit in norn.Suit {
			if suit == S {
				continue
			}
			conv = conv_len(conv, lw[suit])
		}
		ctx.others[S] = conv
	}

	// D = total surviving weight = sum_a lw[S][a] * others[S][13-a] for any S (all equal, = full 4-suit
	// length convolution at East==13). Compute off the first suit.
	first := norn.Suit(0)
	for a in ctx.alo[first] ..= ctx.ahi[first] {
		e := RANKS - a
		if e < 0 {
			continue
		}
		ctx.D += lw[first][a] * ctx.others[first][e]
	}
	ctx.feasible = ctx.D > 0
	return
}

// The constrained per-suit MEAN tricks of one candidate line's joint table, given the shared context's
// leave-one-out coupling for that suit. `sum_{a in range} sum_k k * count[a][k] * others[S][13-a] / D`.
// Used to re-rank the candidate lines: coupling shifts the length distribution, so the line with the best
// mean can differ from the a-priori pick.
@(private)
constrained_line_mean :: proc(ctx: ^Constraint_Ctx, S: norn.Suit, tbl: Suit_Joint_Table) -> f64 {
	acc: f64
	for a in ctx.alo[S] ..= ctx.ahi[S] {
		e := RANKS - a
		if e < 0 {
			continue
		}
		w := ctx.others[S][e]
		if w == 0 {
			continue
		}
		for k in 0 ..= RANKS {
			c := tbl.count[a][k]
			if c == 0 {
				continue
			}
			acc += f64(k) * c * w
		}
	}
	return acc / ctx.D
}

// Best-by-mean SD candidate line per suit UNDER the constraints — the a-posteriori counterpart of
// `pick_partnership_sd`. Each candidate's mean uses the constrained coupling (`constrained_line_mean`); the
// coupling is line-independent, so the one `ctx` (built from the census tables) serves every candidate. When
// the vacant-space skew makes an alternative line more likely, the returned index differs from the a-priori
// pick — this is exactly the "use the better line once the shape is known" flip. `cand`/`best` are in
// DISPLAY_SUITS order.
@(private)
constrained_best_idx :: proc(cand: [4][]Line_Joint, ctx: ^Constraint_Ctx) -> (best: [4]int) {
	for suit, i in DISPLAY_SUITS {
		best_mean := f64(-1)
		for lj, j in cand[i] {
			mn := constrained_line_mean(ctx, suit, lj.tbl)
			if mn > best_mean {
				best_mean = mn
				best[i] = j
			}
		}
	}
	return
}

// The a-posteriori `Deal_Analysis` (per-suit marginals + combined total) under the constraints. The
// per-suit marginal is the leave-one-out coupling applied to that suit's census table; the total is the
// same constrained joint length×trick DP `joint_total` runs, with `a` restricted per suit and the denom =
// the surviving weight `D`. Returns `feasible = false` (and a zeroed analysis) when the constraints admit
// no deal — the caller then falls back to the unconstrained analysis rather than showing an empty table.
@(private)
constrained_census :: proc(tables: [norn.Suit]Suit_Joint_Table, ctx: ^Constraint_Ctx) -> (out: Deal_Analysis) {
	// Per-suit marginals via leave-one-out coupling.
	for S in norn.Suit {
		tbl := tables[S]
		m: [RANKS + 1]f64
		for a in ctx.alo[S] ..= ctx.ahi[S] {
			e := RANKS - a
			if e < 0 {
				continue
			}
			w := ctx.others[S][e]
			if w == 0 {
				continue
			}
			for k in 0 ..= RANKS {
				m[k] += tbl.count[a][k] * w
			}
		}
		for k in 0 ..= RANKS {
			out.suits[S].p[k] = m[k] / ctx.D
		}
		out.suits[S].max_tricks = tbl.ns_len
	}

	// Combined total: the constrained joint DP (East ends on 13; tricks capped at 13), renormalised by D.
	h: [RANKS + 1][RANKS + 1]f64 // h[east_len][capped trick total]
	h[0][0] = 1
	for suit in norn.Suit {
		tbl := tables[suit]
		nh: [RANKS + 1][RANKS + 1]f64
		for e in 0 ..= RANKS {
			for t in 0 ..= RANKS {
				hv := h[e][t]
				if hv == 0 {
					continue
				}
				for a in ctx.alo[suit] ..= ctx.ahi[suit] {
					if e + a > RANKS {
						break
					}
					for k in 0 ..= RANKS {
						c := tbl.count[a][k]
						if c == 0 {
							continue
						}
						nt := min(t + k, RANKS)
						nh[e + a][nt] += hv * c
					}
				}
			}
		}
		h = nh
	}
	for t in 0 ..= RANKS {
		out.total[t] = h[RANKS][t] / ctx.D
	}
	return
}
