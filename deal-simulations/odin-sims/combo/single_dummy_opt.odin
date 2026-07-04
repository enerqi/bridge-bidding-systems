package combo

/*
	single_dummy_opt.odin — Phase 2, brick 3: the OPTIMAL single-dummy search.

	Bricks 1–2 score/compare FIXED lines. This finds the game-optimal blind line for a suit: the most
	tricks a declarer who cannot see the E/W split can guarantee on average against perfect (double-
	dummy) defence. It is a partial-observability minimax over declarer's information sets.

	================================================================================================
	THE TWO THINGS THAT MAKE THIS HARD (and how each is handled)
	================================================================================================

	(1) DECLARER IS BLIND, so at every declarer decision the SAME card must be chosen across all the
	    layouts still consistent with what has been seen ("the belief"). We enforce this by carrying the
	    belief as an explicit weighted world-set and letting declarer nodes pick ONE action for the
	    whole set (never a per-world action — that would be "strategy fusion", cheating by seeing the
	    split).

	(2) THE DEFENCE CAN FALSE-CARD. A double-dummy defender, seeing everything, can choose WHICH of its
	    cards to play so as to pool otherwise-distinguishable layouts and hand declarer a guess. So a
	    defender node is not a per-world min — it is a min over the whole ASSIGNMENT of cards to worlds,
	    where worlds that play the same rank become one (indistinguishable) belief for declarer's future.
	    We enumerate that assignment exactly (`opt_defender`). Card EQUIVALENCE (a run of the defender's
	    cards with no live outside card between them is one choice — `canonical_plays`) keeps the
	    enumeration small.

	Because the exact search is exponential in the number of MISSING cards, it is only tractable when NS
	holds most of the suit (few opponents' cards). A budget + active-world cap bound the work; if a suit
	blows the budget the result falls back to brick 2's best fixed line and is flagged `exact = false`.

	The recursion returns a DISTRIBUTION over tricks (not just a mean): declarer maximises / the defence
	minimises the distribution's mean, but the full vector is carried so brick 4 can later re-score it
	under a different objective (IMPs, matchpoints) by swapping the comparison key.

	Inherited from Phase 1 unchanged: free entries (declarer leads every trick) and suit isolation.
*/

import "base:intrinsics"
import "core:slice"
import "core:strings"

DEFAULT_OPT_BUDGET :: 1_500_000 // continuation nodes before we give up and fall back
ASSIGN_CAP :: 20_000 // most card-to-world assignments we will enumerate at one defender node

Vec :: [RANKS + 1]f64

// One layout in the belief: the opponents' current holdings in the suit plus its a-priori weight.
Opt_World :: struct {
	e, w: u16,
	wt:   f64,
}

Opt_Solver :: struct {
	budget:   int,
	overflow: bool,
	memo:     map[string]Vec, // transposition table, keyed on the belief (n, s, weighted world-set)
}

// Canonical key for a declarer-on-lead belief: the shared holdings plus the sorted multiset of
// worlds (each opponents' masks + weight). Different move orders that reach the same position share a
// key, so the memo collapses the (large) transposition overlap. Allocated on the temp allocator.
@(private)
opt_key :: proc(n, s: u16, worlds: []Opt_World) -> string {
	ws := make([]Opt_World, len(worlds), context.temp_allocator)
	copy(ws, worlds)
	slice.sort_by(ws, proc(a, b: Opt_World) -> bool {
		if a.e != b.e {return a.e < b.e}
		if a.w != b.w {return a.w < b.w}
		return a.wt < b.wt
	})

	b := strings.builder_make(context.temp_allocator)
	put16 :: proc(b: ^strings.Builder, v: u16) {
		strings.write_byte(b, u8(v))
		strings.write_byte(b, u8(v >> 8))
	}
	put16(&b, n)
	put16(&b, s)
	for w in ws {
		put16(&b, w.e)
		put16(&b, w.w)
		bits := transmute(u64)w.wt
		for i in 0 ..< 8 {
			strings.write_byte(&b, u8(bits >> uint(8 * i)))
		}
	}
	return strings.to_string(b)
}

// --- vector helpers ---------------------------------------------------------------------------

@(private)
vec_add :: proc(a, b: Vec) -> Vec {
	r := a
	for k in 0 ..= RANKS {
		r[k] += b[k]
	}
	return r
}

// Shift a trick distribution up by `pt` (0 or 1) tricks — used when a completed trick is won by NS.
@(private)
vec_shift :: proc(v: Vec, pt: int) -> Vec {
	if pt == 0 {
		return v
	}
	r: Vec
	for k in 0 ..< RANKS {
		r[k + 1] = v[k]
	}
	return r
}

@(private)
vec_mean :: proc(v: Vec) -> f64 {
	s := f64(0)
	for k in 0 ..= RANKS {
		s += f64(k) * v[k]
	}
	return s
}

// --- card-equivalence -------------------------------------------------------------------------

// The distinct cards `hold` can play, given the other live cards `others` (all cards still in any hand
// except this seat's). Cards of `hold` in a run uninterrupted by a live outside card are equivalent —
// we keep the lowest of each such run. (Played cards do not separate a run; they are gone.)
@(private)
canonical_plays :: proc "contextless" (hold, others: u16) -> u16 {
	res: u16
	sep := true // before the lowest card, treat as separated so the first card is always kept
	for r in 0 ..= 12 {
		bit := u16(1) << uint(r)
		if others & bit != 0 {
			sep = true
			continue
		}
		if hold & bit != 0 {
			if sep {
				res |= bit
			}
			sep = false
		}
	}
	return res
}

// --- public entry points ----------------------------------------------------------------------

// The optimal single-dummy trick distribution for a suit, and whether it is exact. When the exact
// search exceeds its budget (typically short NS holdings with many missing cards), this falls back to
// the best fixed candidate line (by mean) from brick 2 and returns `exact = false`.
sd_optimal_distribution :: proc(north, south: u16, budget := DEFAULT_OPT_BUDGET) -> (dist: Suit_Trick_Dist, exact: bool) {
	ns := north | south
	ns_len := card_count(ns)

	dist.max_tricks = ns_len
	if ns_len == 0 {
		dist.p[0] = 1
		return dist, true
	}
	if ns_len == RANKS {
		dist.p[RANKS] = 1
		return dist, true
	}

	missing := FULL_SUIT & ~ns
	m := card_count(missing)
	denom := g_binom[26][13]

	// Build the initial belief: every E/W split with its vacant-space weight.
	worlds := make([dynamic]Opt_World, 0, 1 << uint(m), context.temp_allocator)
	east := missing
	for {
		west := missing & ~east
		a := card_count(east)
		append(&worlds, Opt_World{e = east, w = west, wt = g_binom[26 - m][13 - a]})
		if east == 0 {
			break
		}
		east = (east - 1) & missing
	}

	sv := Opt_Solver {
		budget = budget,
		memo   = make(map[string]Vec, context.temp_allocator),
	}
	v := opt_solve(&sv, north, south, worlds[:])
	if sv.overflow {
		// Fall back to the best fixed line by mean.
		best := best_line_by_mean(north, south)
		return best.dist, false
	}

	for k in 0 ..= RANKS {
		dist.p[k] = v[k] / denom
	}
	return dist, true
}

// The optimal single-dummy mean tricks for a suit (and whether exact). Convenience over the full
// distribution.
sd_optimal_expected_tricks :: proc(north, south: u16) -> (mean: f64, exact: bool) {
	dist, ok := sd_optimal_distribution(north, south)
	return expected_tricks(dist.p), ok
}

// The best fixed candidate line by mean tricks (used as the fallback when the exact search overflows).
@(private)
best_line_by_mean :: proc(north, south: u16) -> Line_Result {
	lines := candidate_lines()
	best: Line_Result
	best_mean := f64(-1)
	for line in lines {
		d := sd_line_distribution(north, south, line)
		mn := expected_tricks(d.p)
		if mn > best_mean {
			best_mean = mn
			best = Line_Result{name = line.name, dist = d}
		}
	}
	return best
}

// --- the minimax ------------------------------------------------------------------------------

// Declarer on lead over belief `worlds` (shared holdings `n`,`s`). Returns the optimal weighted trick
// distribution for the rest of the deal. Declarer maximises the distribution's mean over the lead
// choice (which hand, which card) — one choice for the whole belief.
@(private)
opt_solve :: proc(sv: ^Opt_Solver, n, s: u16, worlds: []Opt_World) -> Vec {
	if sv.overflow {
		return Vec{}
	}

	if n == 0 && s == 0 {
		total := f64(0)
		for w in worlds {
			total += w.wt
		}
		r: Vec
		r[0] = total
		return r
	}

	// Transposition memo: a hit is free (no budget spent).
	key := opt_key(n, s, worlds)
	if v, ok := sv.memo[key]; ok {
		return v
	}
	sv.budget -= 1
	if sv.budget < 0 {
		sv.overflow = true
		return Vec{}
	}

	best: Vec
	have := false
	best_mean := f64(0)
	for hand in ([2]int{SEAT_N, SEAT_S}) {
		hold := n if hand == SEAT_N else s
		if hold == 0 {
			continue
		}
		// Only distinct leads: cards in a run with no other live card between them are equivalent.
		m := canonical_plays(hold, FULL_SUIT & ~hold)
		for m != 0 {
			r := int(intrinsics.count_trailing_zeros(m))
			m &= m - 1

			nn, ss := n, s
			if hand == SEAT_N {
				nn &= ~rank_bit(r)
			} else {
				ss &= ~rank_bit(r)
			}
			order := [4]int{hand, (hand + 1) % 4, (hand + 2) % 4, (hand + 3) % 4}
			v := opt_trick(sv, nn, ss, worlds, order, 1, hand, r)
			if sv.overflow {
				return Vec{}
			}
			mn := vec_mean(v)
			if !have || mn > best_mean {
				best = v
				best_mean = mn
				have = true
			}
		}
	}
	if !sv.overflow {
		sv.memo[key] = best
	}
	return best
}

// One ply within a trick. `idx` counts seats already played (leader = idx 1). Declarer seats maximise
// (one card for the whole belief); defender seats minimise over the card-to-world assignment.
@(private)
opt_trick :: proc(sv: ^Opt_Solver, n, s: u16, worlds: []Opt_World, order: [4]int, idx, win_seat, win_rank: int) -> Vec {
	if sv.overflow {
		return Vec{}
	}

	if idx == 4 {
		pt := 1 if is_ns(win_seat) else 0
		cont := opt_solve(sv, n, s, worlds)
		return vec_shift(cont, pt)
	}

	seat := order[idx]

	if is_ns(seat) {
		hold := n if seat == SEAT_N else s
		if hold == 0 {
			return opt_trick(sv, n, s, worlds, order, idx + 1, win_seat, win_rank) // void follows nothing
		}
		best: Vec
		have := false
		best_mean := f64(0)
		m := canonical_plays(hold, FULL_SUIT & ~hold) // only distinct partner cards
		for m != 0 {
			r := int(intrinsics.count_trailing_zeros(m))
			m &= m - 1

			nn, ss := n, s
			if seat == SEAT_N {
				nn &= ~rank_bit(r)
			} else {
				ss &= ~rank_bit(r)
			}
			ws, wr := win_seat, win_rank
			if r > win_rank {
				ws, wr = seat, r
			}
			v := opt_trick(sv, nn, ss, worlds, order, idx + 1, ws, wr)
			if sv.overflow {
				return Vec{}
			}
			mn := vec_mean(v)
			if !have || mn > best_mean {
				best = v
				best_mean = mn
				have = true
			}
		}
		return best
	}

	return opt_defender(sv, n, s, worlds, order, idx, win_seat, win_rank, seat)
}

// A defender seat: minimise over the assignment of a card to each world (false-carding). Worlds where
// this seat is void play nothing (one fixed group). Active worlds each choose among their canonical
// plays; worlds that play the same rank pool into one belief for declarer's future. We enumerate every
// assignment and keep the one with the least mean.
@(private)
opt_defender :: proc(sv: ^Opt_Solver, n, s: u16, worlds: []Opt_World, order: [4]int, idx, win_seat, win_rank, seat: int) -> Vec {
	// Partition into void worlds (fixed) and active worlds (choose a card). Active count is unbounded
	// (a solid suit has many worlds but each with one forced play); only the ASSIGNMENT PRODUCT — the
	// number of distinct card-to-world combinations we must enumerate — is capped.
	void_worlds: [dynamic]Opt_World
	void_worlds.allocator = context.temp_allocator
	active: [dynamic]Opt_World
	active.allocator = context.temp_allocator
	cands: [dynamic]u16 // canonical playable ranks (as a bitmask) per active world
	cands.allocator = context.temp_allocator
	product := 1

	for w in worlds {
		hold := w.e if seat == SEAT_E else w.w
		if hold == 0 {
			append(&void_worlds, w)
			continue
		}
		others := (n | s | w.e | w.w) & ~hold
		c := canonical_plays(hold, others)
		append(&active, w)
		append(&cands, c)
		product *= card_count(c)
		if product > ASSIGN_CAP {
			sv.overflow = true
			return Vec{}
		}
	}
	n_active := len(active)

	// The void group continues unchanged (nothing played, winner intact).
	base: Vec
	have_base := false
	if len(void_worlds) > 0 {
		base = opt_trick(sv, n, s, void_worlds[:], order, idx + 1, win_seat, win_rank)
		have_base = true
		if sv.overflow {
			return Vec{}
		}
	}

	if n_active == 0 {
		return base if have_base else Vec{}
	}

	// Enumerate assignments (mixed-radix over each active world's candidate ranks), keep the min mean.
	chosen := make([]int, n_active, context.temp_allocator) // the rank each active world plays now
	best: Vec
	have := false
	best_mean := f64(0)

	assign_rec(sv, n, s, order, idx, win_seat, win_rank, seat, active[:], cands[:], chosen, 0, base, have_base, &best, &have, &best_mean)
	if sv.overflow {
		return Vec{}
	}
	return best if have else base
}

// Recurse over active worlds assigning each a canonical card; at the leaf, group by played rank,
// continue each group, sum with the void `base`, and keep the least-mean assignment.
@(private)
assign_rec :: proc(
	sv: ^Opt_Solver,
	n, s: u16,
	order: [4]int,
	idx, win_seat, win_rank, seat: int,
	active: []Opt_World,
	cands: []u16,
	chosen: []int,
	i: int,
	base: Vec,
	have_base: bool,
	best: ^Vec,
	have: ^bool,
	best_mean: ^f64,
) {
	if sv.overflow {
		return
	}

	if i == len(active) {
		// Leaf: group active worlds by the rank they played (worlds sharing a rank are one belief for
		// declarer), continue each group, add the void `base`, and keep the least-mean assignment.
		groups: [RANKS][dynamic]Opt_World
		for g in 0 ..< RANKS {
			groups[g].allocator = context.temp_allocator
		}
		for w, k in active {
			append(&groups[chosen[k]], w)
		}

		total := base if have_base else Vec{}
		for r in 0 ..< RANKS {
			if len(groups[r]) == 0 {
				continue
			}
			ws, wr := win_seat, win_rank
			if r > win_rank {
				ws, wr = seat, r
			}
			// Remove the played card from each world in the group (its lowest canonical card).
			reduced := make([dynamic]Opt_World, 0, len(groups[r]), context.temp_allocator)
			for w in groups[r] {
				rw := w
				if seat == SEAT_E {
					rw.e &= ~rank_bit(r)
				} else {
					rw.w &= ~rank_bit(r)
				}
				append(&reduced, rw)
			}
			v := opt_trick(sv, n, s, reduced[:], order, idx + 1, ws, wr)
			if sv.overflow {
				return
			}
			total = vec_add(total, v)
		}

		mn := vec_mean(total)
		if !have^ || mn < best_mean^ {
			best^ = total
			best_mean^ = mn
			have^ = true
		}
		return
	}

	// Try each canonical card for active world `i`, then recurse to the next.
	m := cands[i]
	for m != 0 {
		r := int(intrinsics.count_trailing_zeros(m))
		m &= m - 1
		chosen[i] = r
		assign_rec(sv, n, s, order, idx, win_seat, win_rank, seat, active, cands, chosen, i + 1, base, have_base, best, have, best_mean)
		if sv.overflow {
			return
		}
	}
}
