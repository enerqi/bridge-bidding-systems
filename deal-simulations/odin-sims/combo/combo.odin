package combo

/*
	combo — the "naive card combination analyser" (Phase 1).

	================================================================================================
	WHAT THIS COMPUTES (read this first if the words below are unfamiliar)
	================================================================================================

	A bridge deal has 4 players — North, East, South, West — sitting around a table. North + South
	are partners ("we", the declaring side NS); East + West are the opponents ("they", the defenders
	EW). Each player holds 13 cards. In each of the 4 suits (clubs/diamonds/hearts/spades) the 13
	ranks (2,3,...,10,J,Q,K,A) are split among the 4 players.

	When you "play" a suit you win a number of TRICKS in it. This tool answers, for ONE partnership
	(NS) and ONE deal:

	    "For each of my 4 suits, if I set out to cash tricks in that suit, what is the CHANCE I take
	     exactly 0 tricks? exactly 1? ... exactly n? And, combining the 4 suits, what is the chance I
	     reach some TARGET total number of tricks (e.g. the 9 needed for 3NT)?"

	The NS cards are known (they are dealt). What is NOT known is how the opponents' cards in each
	suit are divided between East and West — and that division is exactly what decides how many
	tricks a holding produces. So the answer is a PROBABILITY over all the ways the opponents' cards
	could lie, not a single number.

	================================================================================================
	THE THREE SIMPLIFYING ASSUMPTIONS ("naive")
	================================================================================================

	Real card play is much harder than this because of three things we deliberately IGNORE:

	1. ENTRIES. To lead a suit you must be "on lead" in the right hand. Getting from North's hand to
	   South's hand costs a trick elsewhere (an "entry"). Real play is a constant fight over entries.
	   We assume ENTRIES ARE FREE: declarer may lead the suit from whichever of the two hands (N or S)
	   it likes, as many times as it likes. This is the meaning of "naive" in the file name — and it
	   is why we can analyse each suit in ISOLATION (see assumption 2) and why we can't just hand the
	   whole deal to a normal double-dummy solver (which respects entries).

	2. SUIT INDEPENDENCE. We treat the 4 suits as independent and simply ADD up the tricks. In real
	   play the suits interact (a long suit squeezes opponents in another, discards matter, etc.).
	   Ignoring that is what lets us combine the 4 per-suit answers by a simple "convolution" (below).

	3. PERFECT INFORMATION (this is "DOUBLE-DUMMY"). Each layout is solved as if all four hands are
	   FACE-UP — everyone sees every card. Real bridge is a game of HIDDEN information: defenders see
	   only dummy and their own hand, declarer never sees the defenders' cards, and much of the skill
	   (and most of the swings) is the guessing that hidden information forces. Our model has none of
	   that, and it cuts BOTH ways, so a per-suit number can look wrong in either direction:
	     * It never lets DECLARER misguess — every finesse is taken the right way, every drop-vs-hook
	       is resolved by seeing the cards. That is OPTIMISTIC for NS (real declarers guess wrong).
	     * It never lets the DEFENCE misdefend — the opponents always duck, cover, and unblock
	       perfectly. That is PESSIMISTIC for NS (real defenders err), and it is why a holding like
	       Q985 opposite a stiff K reads as ~1 trick: the defence is assumed to find the ace-timing
	       every time.
	   There is also NO CONTRACT in view. Because each suit is judged alone, the defenders simply
	   MINIMISE tricks in THAT suit — they have no goal like "take this ace now or the contract runs",
	   "duck to keep declarer off dummy", or "we only need one more to beat it". Real defensive
	   decisions ("if I win this it goes off") depend on the whole hand and the contract; none of that
	   exists here. Likewise declarer maximises SUIT tricks, not "makes the contract".

	All three assumptions make the tool an approximate GUIDE ("hints at the best line"), not a truth
	engine. The double-dummy par made by the real solver (package `dd`) remains the ground truth — and
	note it shares assumption 3 (par is also double-dummy); what this tool drops on top of par is
	entries and suit interaction (1 and 2). Modelling the hidden-information / single-dummy game (real
	guessing, contract-directed defence) is a much larger undertaking — see the Phase-2 design notes.

	WHY THE TOTAL READS HIGH — THE TEMPO / RACE-FOR-THE-LEAD CAVEAT (the practically important one).
	Assumptions 1 + 2 together mean we let NS take ALL its tricks WITHOUT EVER SURRENDERING THE LEAD.
	Real bridge is a race: to develop extra tricks NS usually has to LOSE THE LEAD FIRST (a failing
	finesse, conceding an early round). The instant the defenders are on lead they CASH THEIR OWN
	winners — and may beat the contract before NS ever runs its suits. Because we solve each suit in
	isolation with free entries, a defender ace in the 4th suit is correctly counted as a defender trick
	IN THAT SUIT (NS is not credited it), but the model NEVER lets that ace, or a whole defensive suit,
	be cashed IN TEMPO while NS is still setting up — the cross-suit race simply does not exist here.
	So the summed total is an UPPER BOUND that does not know who gets in first: a hand that reads "13
	tricks" can really be fewer once the opponents grab the lead and cash. This is a property of the
	MODEL (entries + independence), NOT of the vacant-space weighting — the joint-convolution fix
	(COMBO_ANALYSER.md) does not address it; only whole-deal play with entries and a contract does, i.e.
	`dd` par. When combo and par disagree on the total, PAR is the honest number; combo answers the
	narrower "what tricks are even available in each suit", not "who wins the race for them".

	================================================================================================
	HOW A SINGLE SUIT IS SOLVED  ("double-dummy", "minimax")
	================================================================================================

	Fix one suit and one specific way the opponents' cards are split between E and W. Now all 52...
	well, all 13 cards of THIS suit are known to us (N, S, E, W holdings are all pinned down). We ask:
	with best play by us AND best defence by them, how many tricks do NS take? Because every card is
	known to the solver, this is called DOUBLE-DUMMY (as if all four hands are face-up on the table).

	The way to compute "best play against best defence" is MINIMAX: build the game tree of every
	legal card, where WE choose cards to MAXIMISE our trick count and THEY choose cards to MINIMISE
	it, and take the best-vs-best value. The suit has at most 13 cards, so this tree is tiny and we
	brute-force it (with memoisation — see `suit_dd_tricks`).

	Our specific model of a suit in isolation, given free entries, is: DECLARER LEADS EVERY TRICK,
	choosing which hand (N or S) leads and which card. The defenders only ever follow. This is the
	honest "if I have to broach this suit myself, with all the entries I want" count. It naturally
	includes "ducking" (declarer leads low from both hands, conceding the trick, then leads again),
	and it does NOT gift declarer a favourable lead from the defenders (which real isolation can't
	guarantee). See `suit_dd_tricks` / `play_card` for the exact rules.

	================================================================================================
	FROM ONE LAYOUT TO A DISTRIBUTION  ("enumerate splits", "vacant spaces")
	================================================================================================

	We don't know the real E/W split, so we consider EVERY possible one, solve each double-dummy, and
	weight it by how LIKELY that split is a priori. With `m` opponent cards in the suit there are 2^m
	ways to hand each card to E or W; `m <= 8` in almost all real holdings, so this is cheap.

	The a-priori weight of a particular split uses "vacant spaces": before we know anything, East and
	West each have 13 card-slots, 26 between them. The chance that a SPECIFIC set of `a` of the `m`
	suit cards lands with East (and the other `m-a` with West) is

	    C(26 - m, 13 - a) / C(26, 13)

	(the number of ways to fill the rest of East's 13 slots from the 26-m remaining unknown cards,
	over all ways to fill East's hand). Summed over all splits this is 1 (Vandermonde's identity), so
	we accumulate the unnormalised numerators into a trick histogram and divide by C(26,13) at the
	end. See `suit_trick_distribution`. (Because each suit is weighted with a fresh 13/13 vacant-space
	count, the per-suit answers are only APPROXIMATELY jointly consistent — another face of the
	"naive" independence assumption.)

	================================================================================================
	WHAT p[k] IS — A CENSUS OF PER-LAYOUT OPTIMA, NOT A LINE YOU PLAY
	================================================================================================

	Be careful what the distribution means — this is the most-misread part of the tool. For each E/W
	split we compute the BEST-play-vs-BEST-defence trick count (the minimax above), then simply TALLY
	how often each count arises:

	    p[k] = the weighted fraction of E/W layouts whose double-dummy result is exactly k tricks.

	It is a CENSUS OF OUTCOMES, not the score of a strategy. Two consequences, both a common trip-up:

	  * Every entry IS optimal play — but only for ITS layout. Each number is the most tricks best
	    play can wring from that one lie of the cards against best defence. Nothing careless happens;
	    "this holding takes 1 trick 87% of the time" is 87% of layouts having a double-dummy value of 1.

	  * It is NOT a line you could actually adopt. Hitting each layout's maximum needs you to SEE that
	    layout (take the finesse the winning way, drop when it drops, ...). A real declarer commits to
	    ONE line BLIND and does worse on average. So p[k] is the distribution of the per-deal CEILING
	    counted up — outcomes under hindsight — and it UPPER-BOUNDS "how often I really take k tricks".

	Read it as "how often are k tricks even AVAILABLE (double-dummy) with this holding", not "how
	often will I make k". Turning the census into the best single BLIND line — the figure a player can
	truly achieve, where finesse-vs-drop is a real guess — is the single-dummy Phase-2 problem.

	================================================================================================
	COMBINING THE 4 SUITS  ("convolution", "target")
	================================================================================================

	Given the 4 independent per-suit trick distributions, the distribution of the TOTAL is their
	"convolution": P(total = t) = sum over (i+j+k+l = t) of the product of the four per-suit
	probabilities. `convolve` does this two-at-a-time. Then P(total >= target) is just the tail sum
	(`p_at_least`). The natural default `target` is the double-dummy par trick count from package
	`dd`, but any 1..13 can be asked.

	NOTE: because there is only ONE candidate line per suit in this Phase-1 tool (the double-dummy
	maximum), the "pick the best combination of lines" optimisation degenerates into this plain
	convolution. Real per-suit LINE trade-offs (finesse vs safety play) are a single-dummy concept and
	are Phase 2 — see the design notes accompanying this file.
*/

import "base:intrinsics"
import "core:fmt"
import "core:strings"

import "norn:norn"

// The number of ranks in a suit (2..A) and the bit mask with all of them set. A suit holding is a
// `u16` with bit `r` set iff the hand holds the rank whose backing value is `r` (Two=0 .. Ace=12) —
// exactly the encoding of `norn.Hand_Summary.suits[suit]`, so NS holdings drop straight in.
RANKS :: 13
FULL_SUIT :: u16(1 << RANKS) - 1 // 0x1FFF: all 13 ranks present

// Seat indices into a `[4]u16` per-suit layout, matching `norn.Seat` backing values exactly
// (North=0, East=1, South=2, West=3, clockwise). NS = the even seats, EW = the odd ones.
SEAT_N :: 0
SEAT_E :: 1
SEAT_S :: 2
SEAT_W :: 3

// A per-suit layout: the four hands' holdings in ONE suit, indexed by the SEAT_* constants. The four
// masks partition `FULL_SUIT` (every rank in the suit sits in exactly one hand).
Suit_Layout :: [4]u16

// The chance of taking exactly `k` tricks in a single suit, for k = 0..13. `p[k]` is 0 for k above
// `max_tricks` (which equals the combined NS length — you cannot win more tricks than you hold
// cards). The entries sum to 1.
Suit_Trick_Dist :: struct {
	p:          [RANKS + 1]f64,
	max_tricks: int,
}

// The full result for one deal from NS's point of view: the four per-suit distributions plus the
// convolved distribution of the TOTAL trick count (`total[t]` = P(NS take t tricks across all four
// suits, under the naive assumptions)).
Deal_Analysis :: struct {
	suits: [norn.Suit]Suit_Trick_Dist,
	total: [RANKS + 1]f64,
}

// --- Binomials (for the vacant-space split weights) -------------------------------------------

// Pascal's triangle up to C(26, k), built once at startup. Indexed [n][k]; entries with k > n are 0.
// f64 because the weights are only ever multiplied/divided, never used as exact integers, and C(26,13)
// = 10,400,600 is far inside f64's exact-integer range anyway.
@(private)
g_binom: [27][27]f64

@(init)
@(private)
init_binom :: proc "contextless" () {
	for n in 0 ..= 26 {
		g_binom[n][0] = 1
		for k in 1 ..= n {
			upper := f64(0)
			if k <= n - 1 {
				upper = g_binom[n - 1][k]
			}
			g_binom[n][k] = g_binom[n - 1][k - 1] + upper
		}
	}
}

// --- Bit helpers ------------------------------------------------------------------------------

@(private)
card_count :: proc "contextless" (m: u16) -> int {
	return int(intrinsics.count_ones(m))
}

@(private)
rank_bit :: proc "contextless" (r: int) -> u16 {
	return u16(1) << uint(r)
}

// Is this seat one of ours (North or South)? NS are the even seat indices (0, 2).
@(private)
is_ns :: proc "contextless" (seat: int) -> bool {
	return (seat & 1) == 0
}

// --- The single-suit double-dummy solver ------------------------------------------------------

// Maximum tricks NS can take in ONE suit, double-dummy, under the free-entry model (declarer leads
// every trick from the hand of its choice; defenders only follow). `layout` gives all four hands'
// holdings in the suit. `memo` caches the answer for each between-tricks position (keyed by the four
// holdings), which collapses the otherwise-repeated sub-trees — positions recur constantly, both
// within one solve and across the many E/W splits `suit_trick_distribution` feeds in.
//
// The value of a position depends ONLY on the four remaining holdings (not on any history), precisely
// because declarer always regains the lead — so the four-mask layout is a sound memo key.
@(private)
suit_dd_tricks :: proc(layout: Suit_Layout, memo: ^map[Suit_Layout]int) -> int {
	// Terminal positions FIRST, before touching the memo. The minimax bottoms out at these constantly
	// (every line eventually exhausts one side), and each is one popcount to (re)compute — far cheaper
	// than a map lookup + insert. Caching them would flood the memo with trivia and pay map traffic for
	// nothing; only the genuine (non-terminal) minimax positions are worth memoising.
	nn := card_count(layout[SEAT_N])
	sn := card_count(layout[SEAT_S])
	if nn + sn == 0 {
		return 0 // nothing left to lead: no more tricks for us
	}
	if card_count(layout[SEAT_E]) + card_count(layout[SEAT_W]) == 0 {
		// Opponents exhausted: declarer cashes freely, but BOTH NS hands still follow every trick, so
		// two NS cards are spent per trick and the extra cards of the shorter hand are wasted. The
		// tricks left are therefore max(len N, len S), NOT their sum (which would double-count a suit
		// running in both hands — a real overcount bug when opponents run out with NS cards in both).
		return max(nn, sn)
	}

	if v, ok := memo[layout]; ok {
		return v
	}

	// Declarer chooses which hand leads this trick (free entries). Try both, keep the better.
	best := 0
	for leader in ([2]int{SEAT_N, SEAT_S}) {
		if layout[leader] == 0 {
			continue // can't lead from a hand void in the suit
		}
		// Clockwise play order starting at the leader: leader, +1, +2, +3 (mod 4).
		order := [4]int{leader, (leader + 1) % 4, (leader + 2) % 4, (leader + 3) % 4}
		v := play_card(layout, order, 0, -1, -1, memo)
		if v > best {
			best = v
		}
	}

	memo[layout] = best
	return best
}

// One ply of the within-trick minimax. `order` is the clockwise seat sequence for this trick;
// `idx` is how many seats have already played (0..4); `win_seat`/`win_rank` track the card currently
// winning the trick (-1/-1 before anyone has played). Declarer's seats pick the card that MAXIMISES
// eventual NS tricks, defenders' seats the card that MINIMISES it. When all four seats have acted the
// trick is scored (+1 if an NS seat won it) and we recurse into the next trick via `suit_dd_tricks`.
@(private)
play_card :: proc(
	layout: Suit_Layout,
	order: [4]int,
	idx: int,
	win_seat: int,
	win_rank: int,
	memo: ^map[Suit_Layout]int,
) -> int {
	if idx == 4 {
		// Trick complete. `win_seat` is set (the leader always plays a card), so no -1 here.
		trick := 1 if is_ns(win_seat) else 0
		return trick + suit_dd_tricks(layout, memo)
	}

	seat := order[idx]
	holding := layout[seat]
	if holding == 0 {
		// A hand void in the suit plays nothing and cannot win the trick — skip it. (Only followers
		// can be void; the leader was checked non-void by the caller.)
		return play_card(layout, order, idx + 1, win_seat, win_rank, memo)
	}

	declarer := is_ns(seat)
	// Sentinels bracketing the real 0..13 range so the first candidate always replaces them.
	best := -1 if declarer else RANKS + 1

	// Try every card the seat could play. `m` walks the set bits (ranks) of the holding.
	m := holding
	for m != 0 {
		r := int(intrinsics.count_trailing_zeros(m)) // lowest rank still to try
		m &= m - 1 // clear that bit

		next := layout
		next[seat] = holding & ~rank_bit(r)

		win_s, win_r := win_seat, win_rank
		if r > win_rank { 	// a higher card takes over the trick
			win_s, win_r = seat, r
		}

		v := play_card(next, order, idx + 1, win_s, win_r, memo)
		if declarer {
			if v > best {best = v}
		} else {
			if v < best {best = v}
		}
	}
	return best
}

// Double-dummy NS tricks for ONE fully-specified suit layout (all four hands' rank masks given),
// under the free-entry model. A thin public wrapper over `suit_dd_tricks` with a throwaway memo —
// handy for probing/verifying a specific holding without going through the whole split enumeration.
dd_tricks :: proc(north, east, south, west: u16) -> int {
	memo := make(map[Suit_Layout]int)
	defer delete(memo)
	layout := Suit_Layout{}
	layout[SEAT_N] = north
	layout[SEAT_E] = east
	layout[SEAT_S] = south
	layout[SEAT_W] = west
	return suit_dd_tricks(layout, &memo)
}

// --- Per-suit joint table over all E/W splits -------------------------------------------------

// The JOINT per-suit table: `count[a][k]` = the number of E/W splits in this suit where East holds
// exactly `a` of the opponents' cards AND the double-dummy result is exactly `k` tricks. These are RAW
// submask counts (each split weight 1), NOT vacant-space-weighted — the cross-suit combinatorics are
// supplied later by `joint_total`, which folds the four suits under the true constraint "East holds 13
// cards total". Keeping the East-length axis `a` (rather than collapsing straight to `p[k]`) is exactly
// what lets that constraint be enforced across suits — the fix for the independence bias the old
// per-suit-marginal-then-convolve path carried (see COMBO_ANALYSER.md joint-model notes).
Suit_Joint_Table :: struct {
	count:  [RANKS + 1][RANKS + 1]f64, // [east_len a][tricks k], raw split count
	m:      int, // opponents' cards in the suit (= 13 - ns_len); a ranges 0..m
	ns_len: int,
}

// Build the joint table for ONE suit from NS's two holdings, scoring each split double-dummy (the
// Phase-1 census "ceiling"). Enumerates every submask of the opponents' cards as East's holding, exactly
// like the old `suit_trick_distribution`, but tallies into `count[a][k]` instead of a vacant-space-
// weighted marginal. Degenerate suits (NS void / NS holds all 13) still enumerate the length axis: a
// void suit contributes 0 tricks but a WHOLE range of East lengths (`count[a][0] = C(13,a)`), which the
// joint DP needs to keep East's total-length budget honest.
// `memo_in` (optional): a caller-owned scratch map REUSED across suits so the 8 census tables of a deal
// share one backing allocation instead of an alloc+free each. This proc `clear`s it on entry (each suit's
// Suit_Layout space is independent — different suits share rank positions numerically, so entries must NOT
// carry over). `nil` → make a throwaway internally (standalone callers). See `analyse_ns`.
suit_joint_table :: proc(north, south: u16, memo_in: ^map[Suit_Layout]int = nil) -> Suit_Joint_Table {
	ns := north | south // NS's combined holding in the suit (the two hands are disjoint)
	ns_len := card_count(ns)

	tbl: Suit_Joint_Table
	tbl.ns_len = ns_len
	tbl.m = RANKS - ns_len

	// Degenerate shortcuts (avoid enumerating 2^13 splits). NS void: every split gives 0 tricks, so the
	// only axis is East's length — `count[a][0] = C(m,a)`. NS holds the whole suit: one empty split, all
	// 13 tricks.
	if ns_len == 0 {
		for a in 0 ..= tbl.m {
			tbl.count[a][0] = g_binom[tbl.m][a]
		}
		return tbl
	}
	if ns_len == RANKS {
		tbl.count[0][RANKS] = 1
		return tbl
	}

	missing := FULL_SUIT & ~ns // the opponents' cards in this suit

	// Reuse the caller's scratch map if given (cleared, so no stale cross-suit entries), else a throwaway.
	local: map[Suit_Layout]int
	memo := memo_in
	if memo == nil {
		local = make(map[Suit_Layout]int)
		memo = &local
	} else {
		clear(memo)
	}
	defer if memo_in == nil {delete(local)}

	// Enumerate every submask of `missing` as East's holding (West gets the complement): visits `missing`
	// first and 0 last, 2^m masks in all.
	east := missing
	for {
		west := missing & ~east
		a := card_count(east)

		layout: Suit_Layout
		layout[SEAT_N] = north
		layout[SEAT_S] = south
		layout[SEAT_E] = east
		layout[SEAT_W] = west

		tricks := suit_dd_tricks(layout, memo)
		tbl.count[a][tricks] += 1

		if east == 0 {
			break
		}
		east = (east - 1) & missing
	}
	return tbl
}

// Collapse a joint table to the per-suit MARGINAL trick distribution (the `p[k]` used for the per-suit
// table rows). This re-applies the vacant-space weight the joint table deliberately left out: a split
// with East holding `a` of the suit's `m` opponent cards has a-priori weight `C(26-m,13-a)/C(26,13)`
// (the ways to fill East's other 13-a slots from the 26-m cards outside the suit). Summing that over the
// count table reproduces exactly the hypergeometric marginal — the same number the old direct
// enumeration produced, and provably the TRUE per-suit marginal of the joint model (linearity /
// Vandermonde), so the per-suit view is unchanged by the joint fix; only the combined total changes.
marginal_from_table :: proc(tbl: Suit_Joint_Table) -> Suit_Trick_Dist {
	dist: Suit_Trick_Dist
	dist.max_tricks = tbl.ns_len
	denom := g_binom[26][13]
	for a in 0 ..= tbl.m {
		w := g_binom[26 - tbl.m][13 - a]
		if w == 0 {
			continue
		}
		for k in 0 ..= RANKS {
			dist.p[k] += tbl.count[a][k] * w
		}
	}
	for k in 0 ..= RANKS {
		dist.p[k] /= denom
	}
	return dist
}

// The per-suit trick distribution, given NS's two holdings (North's and South's rank masks — e.g.
// `north_summary.suits[.Hearts]` and the South equivalent). Thin wrapper: build the joint table and take
// its marginal. The returned `p[]` sums to 1. (Kept as the public per-suit entry point; the combined
// total no longer convolves these — see `joint_total`.)
suit_trick_distribution :: proc(north, south: u16) -> Suit_Trick_Dist {
	return marginal_from_table(suit_joint_table(north, south))
}

// --- The constrained joint convolution --------------------------------------------------------

// Fold four per-suit joint tables into the EXACT combined trick distribution, under the two true
// whole-deal constraints the old independent convolution ignored:
//
//   1. LENGTH — East holds exactly 13 of the 26 opponent cards. The DP carries East's running length
//      `e` (0..13) across suits and keeps only the `e == 13` states at the end, so a split is counted
//      iff East can still fit it. This forbids the jointly-impossible length combinations independence
//      allowed (e.g. East long in two suits at once) and, crucially, correlates the suits: a layout with
//      East long here is short there, exactly as in a real deal.
//   2. TRICK CAP — NS take at most 13 tricks total. The running trick total `t` is clamped at 13 (the
//      `min(t+k, 13)`). This is the SAME safety net the old `convolve` applied, still needed because the
//      free-entry per-suit model can over-count tricks even for a single consistent deal (assumption 1);
//      the joint fix removes the LENGTH error, not the free-entry one.
//
// Each full assignment with `e == 13` is exactly one of the C(26,13) equally-likely deals, so the raw
// counts sum to C(26,13) at `e == 13` and normalising by it yields a proper distribution (always sums to
// 1, no drop, no collapse). State `h[e][t]`; O(suits · 14^4) — trivial.
//
// PRECONDITION: the tables must come from a FULL 13-card partnership (NS holds 26 cards total, so the
// opponents hold exactly 26 and East 13). Real deals always satisfy this; partial hands would make the
// `e == 13` normalisation wrong (unlike the per-suit marginal, which is independent of the other suits).
joint_total :: proc(tables: [norn.Suit]Suit_Joint_Table) -> [RANKS + 1]f64 {
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
				for a in 0 ..= tbl.m {
					if e + a > RANKS {
						break // East cannot hold more than 13 cards total — prune
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

	denom := g_binom[26][13] // == sum over t of h[13][t]
	total: [RANKS + 1]f64
	for t in 0 ..= RANKS {
		total[t] = h[RANKS][t] / denom
	}
	return total
}

// --- Combining suits --------------------------------------------------------------------------

// Convolve two trick distributions: the distribution of the SUM of two independent trick counts.
// `out[t] = sum over i+j=t of a[i]*b[j]`, with any total exceeding RANKS (13) CLAMPED onto index 13.
//
// The clamp is a safety net for the naive independence assumption. The four suits are folded as if
// independent, so a strong NS is credited near-max tricks in EVERY suit at once and the running total
// can exceed 13 — an impossible outcome (NS takes at most 13 tricks total). Earlier this overflow was
// DROPPED (`j in 0..=RANKS-i`), which under-normalised the total (sum < 1, so P(>=0) < 1) and, for very
// strong hands, collapsed the whole distribution toward zero. Clamping instead conserves all mass
// (`sum(out)` stays == sum(a)*sum(b) == 1) with no division, and parks the impossible surplus on "NS
// take all 13" — the correct ceiling for a hand that "wants" more than 13. This keeps the total a valid
// probability distribution but does NOT correct the mean bias the independence introduces (the mass at
// 13 is a crude stand-in); a constrained joint convolution is the proper fix — see COMBO_ANALYSER.md.
@(private)
convolve :: proc(a, b: [RANKS + 1]f64) -> [RANKS + 1]f64 {
	out: [RANKS + 1]f64
	for i in 0 ..= RANKS {
		if a[i] == 0 {
			continue
		}
		for j in 0 ..= RANKS {
			if b[j] == 0 {
				continue
			}
			t := min(i + j, RANKS)
			out[t] += a[i] * b[j]
		}
	}
	return out
}

// The full analysis for a deal, from NS's seats. Pass the two partners' `Hand_Summary` (as produced
// by `norn.summarize` / `norn.summarize_deal`). Computes each suit's distribution and convolves the
// four into the total.
analyse_ns :: proc(north, south: norn.Hand_Summary) -> Deal_Analysis {
	a: Deal_Analysis

	// Build each suit's joint (length × tricks) table once; the per-suit rows take its marginal, and the
	// combined total is the CONSTRAINED joint convolution over the four tables (East holds 13 total, NS
	// tricks capped at 13) — not an independent convolution of the four marginals. See `joint_total`.
	tables: [norn.Suit]Suit_Joint_Table
	memo := make(map[Suit_Layout]int) // one scratch map reused (cleared) across the 4 suits
	defer delete(memo)
	for suit in norn.Suit {
		tbl := suit_joint_table(north.suits[suit], south.suits[suit], &memo)
		tables[suit] = tbl
		a.suits[suit] = marginal_from_table(tbl)
	}
	a.total = joint_total(tables)
	return a
}

// The ACHIEVABLE single-dummy combined total for a partnership: the constrained joint convolution
// (`joint_total`) of the four best-by-mean SD line tables (`sd_best_joint_table`). The single-dummy
// companion to `analyse_ns`'s `total` (which is the double-dummy census). Baked for the card page so its
// `tot`/`sd` rows honour the joint constraints rather than an independent convolution.
sd_joint_total :: proc(north, south: norn.Hand_Summary) -> [RANKS + 1]f64 {
	tables: [norn.Suit]Suit_Joint_Table
	for suit in norn.Suit {
		tables[suit] = sd_best_joint_table(north.suits[suit], south.suits[suit])
	}
	return joint_total(tables)
}

// Convenience wrapper: analyse the North-South pair of a whole dealt board.
analyse_deal_ns :: proc(board: norn.Deal) -> Deal_Analysis {
	ds := norn.summarize_deal(board)
	return analyse_ns(ds[.North], ds[.South])
}

// The probability of taking AT LEAST `target` tricks, from any trick distribution's `p[]` (a per-suit
// `Suit_Trick_Dist.p` or the combined `Deal_Analysis.total`). This is the headline "chance of making
// the contract" figure; `target` defaults sensibly to the double-dummy par level (package `dd`).
p_at_least :: proc(p: [RANKS + 1]f64, target: int) -> f64 {
	sum := f64(0)
	for k in max(target, 0) ..= RANKS {
		sum += p[k]
	}
	return sum
}

// The expected (mean) trick count of a distribution — a compact one-number summary of a suit or of
// the whole hand.
expected_tricks :: proc(p: [RANKS + 1]f64) -> f64 {
	sum := f64(0)
	for k in 0 ..= RANKS {
		sum += f64(k) * p[k]
	}
	return sum
}

// --- Human-readable report --------------------------------------------------------------------

// Render an analysis as a text table: one row per suit giving P(exactly k tricks) as percentages,
// then the combined total row and the cumulative P(>= k) tail. Caller owns the returned string
// (allocated from `allocator`). `target` is highlighted in the tail line.
format_analysis :: proc(
	a: ^Deal_Analysis,
	target: int,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)

	// Column header: trick counts 0..13.
	strings.write_string(&b, "suit ")
	for k in 0 ..= RANKS {
		cell(&b, fmt.tprintf("%d", k))
	}
	strings.write_string(&b, "   E[tr]\n")

	// One row per suit (spades first, matching how bridge hands are conventionally displayed).
	display := [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}
	for suit in display {
		d := a.suits[suit]
		fmt.sbprintf(&b, "  %c  ", norn.suit_letter(suit))
		for k in 0 ..= RANKS {
			write_pct(&b, d.p[k])
		}
		fmt.sbprintf(&b, "   %.2f\n", expected_tricks(d.p))
	}

	// Combined total distribution and its expected value.
	strings.write_string(&b, "---\ntot  ")
	for k in 0 ..= RANKS {
		write_pct(&b, a.total[k])
	}
	fmt.sbprintf(&b, "   %.2f\n", expected_tricks(a.total))

	// Cumulative "at least k tricks" tail, and the headline figure at the target.
	strings.write_string(&b, ">=k  ")
	for k in 0 ..= RANKS {
		write_pct(&b, p_at_least(a.total, k))
	}
	strings.write_string(&b, "\n")
	// Headline figure at the requested target — omitted when `target` is out of the 1..13 range (0 =
	// "no single target", e.g. the annotator, which lets the reader read any level off the >=k row).
	if target >= 1 && target <= RANKS {
		fmt.sbprintf(&b, "P(>= %d tricks) = %.1f%%\n", target, 100 * p_at_least(a.total, target))
	}

	return strings.to_string(b)
}

// --- Machine-readable distributions (for the interactive card page) ---------------------------

// Emit the four per-suit trick distributions as a compact JSON object keyed by suit letter:
//
//	{"s":[p0,p1,...,p13],"h":[...],"d":[...],"c":[...]}
//
// Each array is the full 0..13 `p[k]` (trailing zeros beyond the suit's `max_tricks` included, so the
// consumer needn't special-case lengths). This is the seam for the CLIENT-SIDE combo table: the card
// page's script parses this, convolves the four suits, and renders the trick table + adjustable
// P(>= target) live — so no table is baked server-side (unlike `format_analysis`, kept for the text
// formats). Suit order s,h,d,c matches the card page's display order.
write_suits_json :: proc(b: ^strings.Builder, a: ^Deal_Analysis) {
	keys := [4]struct {
		suit: norn.Suit,
		key:  string,
	}{{.Spades, "s"}, {.Hearts, "h"}, {.Diamonds, "d"}, {.Clubs, "c"}}

	strings.write_byte(b, '{')
	for e, i in keys {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, `"%s":[`, e.key)
		d := a.suits[e.suit]
		for k in 0 ..= RANKS {
			if k > 0 {
				strings.write_byte(b, ',')
			}
			write_prob(b, d.p[k])
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, '}')
}

// --- Per-partnership shared SD data (Phase-2 dedup, PERFORMANCE.md §2) -------------------------
//
// Every Html_Cards writer below needs the SAME per-suit single-dummy candidate evaluation: the best line
// by mean (its name, its marginal, its joint table) plus every candidate's joint table for the adaptive
// DP. Computed independently they enumerated the 2^m E/W splits ~5× per suit (across `sd_joint_total`,
// `write_suits_json_sd`/`_lines`/`_tips`, and `adaptive_at_least_curve`). `build_partnership_sd` does it
// ONCE; the writers read from it. The `[4]` axis is DISPLAY_SUITS order (s,h,d,c) — the same order every
// writer walks — so per-suit indices line up with the writers' `keys` arrays.
//
// PARITY: deriving each suit's row from its joint table (`marginal_from_table`) is byte-identical to the
// old `sd_line_distribution` path — both sum the SAME per-split integer weights (all partial sums
// ≤ C(26,13) ≈ 1.04e7, exact in f64), then divide by the same denom. Same line chosen, same numbers.
Partnership_Sd :: struct {
	cand:      [4][]Line_Joint, // every candidate line's joint table per suit (drives the adaptive DP)
	best_idx:  [4]int, // index into cand[i] of the best-by-mean line (the recommended blind line)
	best_marg: [4]Suit_Trick_Dist, // that line's marginal trick distribution (the data-*-sd row)
}

// Evaluate a partnership's four suits ONCE: build every candidate line's joint table, then pick the
// best-by-mean line per suit and cache its marginal. Everything the Html_Cards writers emit derives from
// this. Picks identically to `best_line_by_mean`/`sd_best_joint_table` (same candidate order, first-wins
// on ties, means equal by the parity note above). `cand` is on `allocator` (temp in the render path).
@(private)
build_partnership_sd :: proc(
	north, south: norn.Hand_Summary,
	allocator := context.temp_allocator,
) -> Partnership_Sd {
	ps: Partnership_Sd
	ps.cand = gather_candidate_tables(north, south, allocator)
	for i in 0 ..< 4 {
		best_mean := f64(-1)
		for lj, j in ps.cand[i] {
			marg := marginal_from_table(lj.tbl)
			mn := expected_tricks(marg.p)
			if mn > best_mean {
				best_mean = mn
				ps.best_idx[i] = j
				ps.best_marg[i] = marg
			}
		}
	}
	return ps
}

// The ACHIEVABLE single-dummy combined total from precomputed per-partnership data: the constrained joint
// convolution (`joint_total`) of the four best-by-mean SD line joint tables. The deduped counterpart of
// `sd_joint_total` — reuses the tables `build_partnership_sd` already built instead of re-enumerating.
@(private)
sd_joint_total_of :: proc(ps: ^Partnership_Sd) -> [RANKS + 1]f64 {
	tables: [norn.Suit]Suit_Joint_Table
	for suit, i in DISPLAY_SUITS {
		tables[suit] = ps.cand[i][ps.best_idx[i]].tbl
	}
	return joint_total(tables)
}

// The Phase-2 ACHIEVABLE per-suit distributions, same JSON shape as `write_suits_json` but each suit's
// `p[k]` is the best fixed single-dummy LINE by mean (brick 2), read from precomputed `ps.best_marg`.
// Where `write_suits_json` is the double-dummy CEILING (census, hindsight), this is a concrete blind line
// a declarer can actually adopt; the card page shows both so the gap (the double-dummy tax) is visible.
// (The optimal search `sd_optimal_distribution` is only better on long holdings — rare on a random
// deal — and much slower, so the render path uses the candidate best-line, coherent with the DP curve.)
write_suits_json_sd :: proc(b: ^strings.Builder, ps: ^Partnership_Sd) {
	keys := [4]string{"s", "h", "d", "c"}

	strings.write_byte(b, '{')
	for key, i in keys {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, `"%s":[`, key)
		p := ps.best_marg[i].p
		for k in 0 ..= RANKS {
			if k > 0 {
				strings.write_byte(b, ',')
			}
			write_prob(b, p[k])
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, '}')
}

// Write the per-suit RECOMMENDED blind line names as a JSON array `["s","h","d","c"]` (the best fixed
// single-dummy line by mean per suit — `best_line_by_mean`, brick 2). Same suit order s,h,d,c as the
// distribution blobs, so the card page can label each suit row with how to play it.
write_suits_lines_json :: proc(b: ^strings.Builder, ps: ^Partnership_Sd) {
	strings.write_byte(b, '[')
	for i in 0 ..< 4 {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		name := ps.cand[i][ps.best_idx[i]].name
		fmt.sbprintf(b, `"%s"`, name)
	}
	strings.write_byte(b, ']')
}

// Rank glyphs indexed by the 0..12 bit position (Two=0 .. Ace=12).
@(private)
RANK_NAMES := [13]string{"2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"}

// Write the held ranks of `m`, highest first, space-separated (e.g. "A K Q").
@(private)
write_cards_desc :: proc(b: ^strings.Builder, m: u16) {
	first := true
	for r := 12; r >= 0; r -= 1 {
		if m & rank_bit(r) != 0 {
			if !first {strings.write_byte(b, ' ')}
			strings.write_string(b, RANK_NAMES[r])
			first = false
		}
	}
}

// Narrate the "cash from the top" plan for a holding.
@(private)
describe_cash :: proc(b: ^strings.Builder, combined, winners: u16, top_missing, n_win, ns_len: int) {
	if top_missing < 0 {
		strings.write_string(b, "Cash from the top: ")
		write_cards_desc(b, combined)
		strings.write_string(b, " — every card is a winner.")
	} else if n_win == 0 {
		strings.write_string(b, "No sure winners here (the opponents hold the ")
		strings.write_string(b, RANK_NAMES[top_missing])
		strings.write_string(b, "). You lose the early rounds; you score only if the suit runs.")
	} else {
		strings.write_string(b, "Cash your winners from the top: ")
		write_cards_desc(b, winners)
		strings.write_string(b, ".")
		if n_win < ns_len {
			strings.write_string(b, " After those, the opponents ")
			strings.write_string(b, RANK_NAMES[top_missing])
			strings.write_string(b, " and lower take the rest.")
		}
	}
}

// A short, holding-aware narration of the recommended blind line for one suit — shown as a hover
// tooltip on the card page. Best-effort: it describes the chosen heuristic (cash / finesse / duck) in
// terms of the ACTUAL cards held. Deliberately uses NO apostrophes or double quotes (it is emitted
// inside a single-quoted HTML attribute, as a JSON string).
describe_suit_line :: proc(north, south: u16, line_name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	combined := north | south
	ns_len := card_count(combined)
	if ns_len == 0 {
		strings.write_string(&b, "Void: no cards in this suit.")
		return strings.to_string(b)
	}

	missing := FULL_SUIT & ~combined
	top_missing := -1
	for r := 12; r >= 0; r -= 1 {
		if missing & rank_bit(r) != 0 {top_missing = r;break}
	}
	winners: u16 // your cards ranking above the opponents best card
	if top_missing < 0 {
		winners = combined
	} else {
		for r := 12; r > top_missing; r -= 1 {winners |= combined & rank_bit(r)}
	}
	n_win := card_count(winners)

	switch line_name {
	case "finesse", "finesse-other":
		describe_finesse(&b, combined, winners, top_missing, n_win, ns_len)
	case "duck-one":
		strings.write_string(&b, "Duck the first round: play low from both hands and let the opponents win it. Then cash your winners")
		if n_win > 0 {
			strings.write_string(&b, " (")
			write_cards_desc(&b, winners)
			strings.write_string(&b, ")")
		}
		strings.write_string(&b, ". Ducking keeps a guard and can set up your long cards.")
	case "duck-then-finesse":
		strings.write_string(&b, "Duck the first round (play low from both hands), then take the finesse. ")
		describe_finesse(&b, combined, winners, top_missing, n_win, ns_len)
		strings.write_string(&b, " Ducking first keeps an entry so the finesse can be repeated.")
	case:
		describe_cash(&b, combined, winners, top_missing, n_win, ns_len)
	}
	return strings.to_string(b)
}

// Narrate the finesse line in terms of the actual cards: lead low toward the top cards and insert the
// highest touching honour below the opponents best card. Falls back to a cash narration when NS holds no
// card below the top missing rank (nothing to finesse with). Shared by the plain and compound finesse
// cases. NO apostrophes / double quotes (single-quoted HTML attribute).
@(private)
describe_finesse :: proc(b: ^strings.Builder, combined, winners: u16, top_missing, n_win, ns_len: int) {
	finesse_card := -1
	if top_missing >= 0 {
		for r := top_missing - 1; r >= 0; r -= 1 {
			if combined & rank_bit(r) != 0 {finesse_card = r;break}
		}
	}
	if finesse_card < 0 {
		describe_cash(b, combined, winners, top_missing, n_win, ns_len)
		return
	}
	tops: u16
	for r := 12; r > finesse_card; r -= 1 {tops |= combined & rank_bit(r)}
	strings.write_string(b, "Lead a low card toward your ")
	if tops != 0 {
		write_cards_desc(b, tops)
	} else {
		strings.write_string(b, "high cards")
	}
	strings.write_string(b, ", then finesse: play the ")
	strings.write_string(b, RANK_NAMES[finesse_card])
	strings.write_string(b, ". It wins when the ")
	strings.write_string(b, RANK_NAMES[top_missing])
	strings.write_string(b, " sits with the opponent who plays before your high hand (about even money); if not, it loses.")
}

// Emit the per-suit line NARRATIONS as a JSON array of strings (one per suit s,h,d,c), pairing each
// with its recommended line (`best_line_by_mean`). The card page shows these as hover tooltips.
write_suits_tips_json :: proc(b: ^strings.Builder, ps: ^Partnership_Sd, north, south: norn.Hand_Summary) {
	strings.write_byte(b, '[')
	for suit, i in DISPLAY_SUITS {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		name := ps.cand[i][ps.best_idx[i]].name
		desc := describe_suit_line(north.suits[suit], south.suits[suit], name)
		// JSON string; the narration contains no quotes/backslashes, but escape defensively.
		strings.write_byte(b, '"')
		for c in transmute([]u8)desc {
			switch c {
			case '"':
				strings.write_string(b, "\\\"")
			case '\\':
				strings.write_string(b, "\\\\")
			case:
				strings.write_byte(b, c)
			}
		}
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
}

// Write a 0..13 curve (e.g. the adaptive P(>= t) make curve) as a compact JSON array `[c0,...,c13]`.
write_curve_json :: proc(b: ^strings.Builder, curve: [RANKS + 1]f64) {
	strings.write_byte(b, '[')
	for k in 0 ..= RANKS {
		if k > 0 {
			strings.write_byte(b, ',')
		}
		write_prob(b, curve[k])
	}
	strings.write_byte(b, ']')
}

// A single probability as a compact JSON number: bare "0" for the (common) exact zeros, else the
// shortest round-trippable form (`%g`). Values are all finite in [0,1], so this is always valid JSON.
@(private)
write_prob :: proc(b: ^strings.Builder, p: f64) {
	if p <= 0 {
		strings.write_string(b, "0")
		return
	}
	fmt.sbprintf(b, "%g", p)
}

// A probability as a right-aligned integer percentage, or a dot when it is effectively zero (so the
// meaningful cells stand out in the grid).
@(private)
write_pct :: proc(b: ^strings.Builder, p: f64) {
	if p < 0.005 {
		cell(b, ".")
	} else {
		cell(b, fmt.tprintf("%.0f", 100 * p))
	}
}

// Write `s` right-aligned in a 5-wide, space-padded column. (Odin's `fmt` width flag zero-pads
// numeric verbs, so the padding is done by hand.)
@(private)
cell :: proc(b: ^strings.Builder, s: string) {
	for _ in len(s) ..< 5 {
		strings.write_byte(b, ' ')
	}
	strings.write_string(b, s)
}

// --- Deal annotator (norn.Deal_Annotator) -----------------------------------------------------

// A `norn.Deal_Annotator`: append the naive combined-holding trick table after a rendered board.
// Deliberately INDEPENDENT of the DDS `dd` package — no solver, no par — so it can run without `--dd`.
// Pair it with `dd.annotate` in the consumer (see sim.odin) to show BOTH the double-dummy par caption
// and this make-chance guide. It emits only for the human-facing formats:
//   - Html_Handviewer : the static text table in a <pre> block beneath the board
//   - Html_Cards      : ONLY the raw per-suit distributions, as a `data-suits` JSON blob on a `.combo`
//                       sibling of the compass; the norn card page's script convolves them client-side
//                       and renders an interactive table with an adjustable P(>= target) (the carousel
//                       groups the sibling into the slide and folds it under the Par toggle)
//   - Pretty          : the static text table, after the layout
//   - Line/Numeric/Handviewer/Pbn : nothing (machine-parsed, or no room in the grammar)
//
// For the text formats `target = 0` is passed to `format_analysis` so no single make-chance line is
// highlighted — the >=k row lets the reader read off any level; the card page makes that interactive.
annotate :: proc(builder: ^strings.Builder, board: norn.Deal, format: norn.Output_Format) {
	// Full switch (no #partial), like dd.annotate: a newly added Output_Format must be classified
	// here rather than silently skipped or corrupted.
	switch format {
	case .Line, .Numeric, .Handviewer, .Pbn:
		return
	case .Html_Handviewer, .Html_Cards, .Pretty:
	// emitted below
	}

	ds := norn.summarize_deal(board)
	a := analyse_ns(ds[.North], ds[.South])

	switch format {
	case .Html_Handviewer:
		table := format_analysis(&a, 0, context.temp_allocator)
		strings.write_string(
			builder,
			`<div style="max-width:900px;margin:0 auto;color:#444;font-size:0.75rem"><pre style="display:inline-block;text-align:left">`,
		)
		strings.write_string(builder, table)
		strings.write_string(builder, "</pre></div>")
	case .Html_Cards:
		// A `.combo` sibling after the `.compass` (and the dd `.par`). The card page's carousel script
		// pulls every sibling up to the next board into the slide. We emit, for BOTH partnerships
		// (the page can flip N/S <-> E/W), three JSON blobs each:
		//   data-{ns,ew}      = per-suit double-dummy CENSUS p[k]     (the ceiling / hindsight)
		//   data-{ns,ew}-sd   = per-suit achievable single-dummy line p[k]  (a real blind line)
		//   data-{ns,ew}-atl  = the adaptive optimum P(>= t) make curve (brick-4 DP over candidate lines)
		// The page convolves the per-suit blobs and shows the CEILING vs ACHIEVABLE (the gap is the
		// double-dummy tax), with the ADAPTIVE curve driving the "P(>= target)" readouts. Nothing baked.
		// `data-{ns,ew}-tot`/`-totsd` are the BAKED combined totals from the constrained joint convolution
		// (`joint_total`: East holds 13, tricks capped at 13) — census and single-dummy. The page uses
		// these directly instead of convolving the per-suit marginals client-side (which was independent,
		// so length-inconsistent). Per-suit `-sd`/`-atl`/`-lines`/`-tips` are unchanged.
		ew := analyse_ns(ds[.East], ds[.West])

		// Phase-2 dedup (PERFORMANCE.md §2): evaluate each partnership's candidate lines ONCE, then read
		// the SD total, the make curve, and every per-suit row (sd / lines / tips) off the shared result —
		// instead of the four writers + curve + total each re-enumerating the same splits.
		ns_sd := build_partnership_sd(ds[.North], ds[.South], context.temp_allocator)
		ew_sd := build_partnership_sd(ds[.East], ds[.West], context.temp_allocator)
		ns_atl := adaptive_curve_from(ns_sd.cand)
		ew_atl := adaptive_curve_from(ew_sd.cand)
		ns_totsd := sd_joint_total_of(&ns_sd)
		ew_totsd := sd_joint_total_of(&ew_sd)

		strings.write_string(builder, `<div class="combo" data-ns='`)
		write_suits_json(builder, &a)
		strings.write_string(builder, `' data-ns-sd='`)
		write_suits_json_sd(builder, &ns_sd)
		strings.write_string(builder, `' data-ns-tot='`)
		write_curve_json(builder, a.total)
		strings.write_string(builder, `' data-ns-totsd='`)
		write_curve_json(builder, ns_totsd)
		strings.write_string(builder, `' data-ns-atl='`)
		write_curve_json(builder, ns_atl)
		strings.write_string(builder, `' data-ns-lines='`)
		write_suits_lines_json(builder, &ns_sd)
		strings.write_string(builder, `' data-ns-tips='`)
		write_suits_tips_json(builder, &ns_sd, ds[.North], ds[.South])
		strings.write_string(builder, `' data-ew='`)
		write_suits_json(builder, &ew)
		strings.write_string(builder, `' data-ew-sd='`)
		write_suits_json_sd(builder, &ew_sd)
		strings.write_string(builder, `' data-ew-tot='`)
		write_curve_json(builder, ew.total)
		strings.write_string(builder, `' data-ew-totsd='`)
		write_curve_json(builder, ew_totsd)
		strings.write_string(builder, `' data-ew-atl='`)
		write_curve_json(builder, ew_atl)
		strings.write_string(builder, `' data-ew-lines='`)
		write_suits_lines_json(builder, &ew_sd)
		strings.write_string(builder, `' data-ew-tips='`)
		write_suits_tips_json(builder, &ew_sd, ds[.East], ds[.West])
		strings.write_string(builder, `'></div>`)
		free_all(context.temp_allocator)
	case .Pretty:
		table := format_analysis(&a, 0, context.temp_allocator)
		strings.write_string(builder, "\n")
		strings.write_string(builder, table)
	case .Line, .Numeric, .Handviewer, .Pbn:
	// unreachable: filtered out above
	}
}
