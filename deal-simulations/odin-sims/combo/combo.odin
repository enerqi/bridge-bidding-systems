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
import "core:mem"
import "core:strings"
import "core:sync"
import si "core:sys/info"
import "core:thread"

import "norn:norn"

// The number of ranks in a suit (2..A) and the bit mask with all of them set. A suit holding is a
// `u16` with bit `r` set iff the hand holds the rank whose backing value is `r` (Two=0 .. Ace=12) —
// exactly the encoding of `norn.Hand_Summary.suits[suit]`, so NS holdings drop straight in.
RANKS :: 13
FULL_SUIT :: u16(1 << RANKS) - 1 // 0x1FFF: all 13 ranks present

// Fan the four independent per-partnership work units of `annotate(.Html_Cards)` out across worker
// threads (see `annotate`). Compile-time toggle: `-define:COMBO_THREADS=false` forces the serial path,
// which must produce byte-identical output — the parity check for the threaded path.
COMBO_THREADS :: #config(COMBO_THREADS, true)

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

// --- Equivalence-class split enumeration ------------------------------------------------------
//
// WHY THIS EXISTS (read before the code). To turn one suit into a trick distribution we must consider
// every way the opponents' missing cards could be split between East and West and solve each — that is
// the `east` loop the callers below run. With `m` missing cards there are 2^m such splits, and for a
// 6- or 7-card suit that inner solve dominated the whole program's runtime (see PERFORMANCE.md §4.2).
//
// The saving insight is that MOST OF THOSE SPLITS PLAY OUT IDENTICALLY. A spot card in the opponents'
// hands only matters for whether it beats one of OUR cards (or loses to one). If we hold NO card ranked
// between two of the missing cards, then those two missing cards are INTERCHANGEABLE: it makes no
// difference to the tricks taken which of the two East holds and which West holds — swapping them just
// relabels cards that behave the same. So the missing cards fall into "equivalence BLOCKS": a block is a
// run of missing ranks sitting next to each other with none of OUR cards wedged in between.
//
// Worked example — we hold A K Q 5 4 3 2 (so the opponents are missing J T 9 8 7 6). We have nothing
// between the 6 and the J (our next cards up and down are the Q and the 5), so all six missing cards
// J T 9 8 7 6 form ONE block: for trick-taking they are six identical tokens. What actually matters is
// only HOW MANY of them East holds (0..6), not which ones. That turns 2^6 = 64 distinct splits into just
// 7 cases. We solve one representative layout per case and multiply its result by how many of the 64
// real splits it stands for. When there are several blocks (our spot cards interleave the opponents'),
// we enumerate the count in each block independently — the product of the per-block choices.
//
// EXACTNESS. Every one of the 2^m real splits maps to exactly one (per-block count) pattern; all the
// real splits behind a pattern give the SAME number of tricks AND leave East the same total length `a`
// (so they carry the same vacant-space weight the callers apply). Counting a pattern `mult` times
// therefore reproduces the old per-split sum term for term — the output is byte-identical, and `mult` is
// a whole number so the arithmetic is exact. Worst case (our cards interleave EVERY gap, so every block
// has size 1) there is one pattern per split and `mult` is always 1: identical to the old loop, never
// slower. Best case (one big block) it collapses spectacularly, which is the common honour-heavy shape.
//
// `Split_Iter` walks the patterns one at a time (no allocation). Used by BOTH phases: `suit_joint_table`
// (Phase-1 census) and `sd_line_joint_table` / `sd_line_distribution` (Phase-2 fixed line).
@(private)
Split_Iter :: struct {
	blocks: [RANKS]u16, // each block's rank mask (a block = a run of adjacent missing cards, no NS card between)
	sizes:  [RANKS]int, // how many cards are in each block
	counts: [RANKS]int, // the pattern currently being visited: how many of each block's cards East holds
	nblk:   int, // number of blocks
	done:   bool, // set once every pattern has been visited
}

// Split the opponents' `missing` cards (= FULL_SUIT & ~ns) into equivalence blocks. Because `missing` has
// a bit set for each opponent card and clear for each of OUR cards, a block is exactly a maximal run of
// adjacent set bits (a stretch of missing ranks with no NS card — a cleared bit — interrupting it). A
// void suit (`missing == 0`) yields zero blocks: one trivial pattern (East holds nothing), handled by
// `split_iter_next`.
@(private)
split_iter_init :: proc(missing: u16) -> Split_Iter {
	it: Split_Iter
	m := missing
	for m != 0 {
		lo := int(intrinsics.count_trailing_zeros(m))
		hi := lo
		for hi + 1 < RANKS && (m & rank_bit(hi + 1)) != 0 {
			hi += 1
		}
		mask: u16
		for r in lo ..= hi {
			mask |= rank_bit(r)
		}
		it.blocks[it.nblk] = mask
		it.sizes[it.nblk] = hi - lo + 1
		it.nblk += 1
		m &= ~mask
	}
	return it
}

// The `k` highest cards of `mask` (callers guarantee k ≤ how many cards `mask` holds). Since a block's
// cards are interchangeable, ANY k of them is a valid stand-in for "East holds k cards of this block";
// we always pick the top k so the representative layout is built the same way every time.
@(private)
top_k_bits :: proc "contextless" (mask: u16, k: int) -> u16 {
	out: u16
	m := mask
	for _ in 0 ..< k {
		r := highest_rank(m)
		out |= rank_bit(r)
		m &= ~rank_bit(r)
	}
	return out
}

// Hand back the next pattern, or `ok == false` once they are all done. For the pattern we return a
// representative East holding (the top `counts[b]` cards of each block), East's total length `a`, and
// `mult` = how many of the real 2^m splits this one pattern stands for. `mult` is the product over blocks
// of C(block size, East's count in it): the number of ways to choose WHICH cards of each block go to East
// (all giving the same tricks). West simply gets whatever of `missing` East did not take.
@(private)
split_iter_next :: proc(it: ^Split_Iter) -> (east: u16, a: int, mult: f64, ok: bool) {
	if it.done {
		return 0, 0, 0, false
	}
	mult = 1
	for b in 0 ..< it.nblk {
		k := it.counts[b]
		east |= top_k_bits(it.blocks[b], k)
		a += k
		mult *= g_binom[it.sizes[b]][k]
	}
	ok = true

	// Step to the next pattern the way a car odometer rolls over: bump the first block's count; if it
	// passed that block's size, reset it to 0 and carry into the next block; and so on. When the carry
	// runs off the last block every combination has been visited. (A void suit has no blocks, so the very
	// first step lands here and finishes after the single trivial pattern above.)
	i := 0
	for {
		if i == it.nblk {
			it.done = true
			break
		}
		it.counts[i] += 1
		if it.counts[i] <= it.sizes[i] {
			break
		}
		it.counts[i] = 0
		i += 1
	}
	return
}

// --- Per-suit joint table over all E/W splits -------------------------------------------------

// The JOINT per-suit table: `count[a][k]` = the number of E/W splits in this suit where East holds
// exactly `a` of the opponents' cards AND the double-dummy result is exactly `k` tricks. These are RAW
// concrete-split counts (a plain tally of the 2^m possible splits, each weight 1), NOT vacant-space-
// weighted — the cross-suit combinatorics are supplied later by `joint_total`, which folds the four
// suits under the true constraint "East holds 13 cards total". (The table is now filled via the
// equivalence-class enumeration — see `Split_Iter` — so each entry is bumped by a whole pattern's
// `mult` at once rather than one split at a time, but the totals are identical: still the exact split
// count.) Keeping the East-length axis `a` (rather than collapsing straight to `p[k]`) is exactly what
// lets that constraint be enforced across suits — the fix for the independence bias the old
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
suit_joint_table :: proc(
	north, south: u16,
	memo_in: ^map[Suit_Layout]int = nil,
) -> Suit_Joint_Table {
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

	// Enumerate equivalence-class patterns of East's holding (one representative per pattern, weighted by
	// `mult` = the concrete splits it stands for) instead of all 2^m submasks. See `Split_Iter`.
	it := split_iter_init(missing)
	for {
		east, a, mult, ok := split_iter_next(&it)
		if !ok {
			break
		}
		west := missing & ~east

		layout: Suit_Layout
		layout[SEAT_N] = north
		layout[SEAT_S] = south
		layout[SEAT_E] = east
		layout[SEAT_W] = west

		tricks := suit_dd_tricks(layout, memo)
		tbl.count[a][tricks] += mult
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
// `memo_in` (optional) lets a caller supply a persistent, `clear()`-reused minimax memo so this proc allocates
// nothing on the heap across deals (see the per-worker thread-local memo in `annotate`). When `nil`, a throwaway
// map is made/freed as before. The memo is a pure cache (`suit_joint_table` clears it on entry per suit), so
// supplying a reused map is byte-identical to a fresh one.
analyse_ns :: proc(north, south: norn.Hand_Summary, memo_in: ^map[Suit_Layout]int = nil) -> Deal_Analysis {
	// Build each suit's joint (length × tricks) table once; the per-suit rows take its marginal, and the
	// combined total is the CONSTRAINED joint convolution over the four tables (East holds 13 total, NS
	// tricks capped at 13) — not an independent convolution of the four marginals. See `joint_total`.
	tables: [norn.Suit]Suit_Joint_Table
	local: map[Suit_Layout]int // one scratch map reused (cleared) across the 4 suits
	memo := memo_in
	if memo == nil {
		local = make(map[Suit_Layout]int)
		memo = &local
	}
	defer if memo_in == nil {delete(local)}
	for suit in norn.Suit {
		tables[suit] = suit_joint_table(north.suits[suit], south.suits[suit], memo)
	}
	return finish_census(tables)
}

// Assemble a `Deal_Analysis` from the four already-built per-suit joint tables: each suit's row is that
// table's marginal (the exact hypergeometric), the total is the constrained joint convolution. Split out so
// the threaded render path (which builds the four tables on separate worker tasks) and `analyse_ns` share the
// identical assembly — the parity seam. See PERFORMANCE.md §9.4.
@(private)
finish_census :: proc(tables: [norn.Suit]Suit_Joint_Table) -> Deal_Analysis {
	a: Deal_Analysis
	for suit in norn.Suit {
		a.suits[suit] = marginal_from_table(tables[suit])
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

// The two partnerships, as `Seat` sets — the only valid "known" pairs for a 2-hand (declarer + dummy)
// board, since declarer and dummy are always partners.
NS_SIDE :: bit_set[norn.Seat]{.North, .South}
EW_SIDE :: bit_set[norn.Seat]{.East, .West}

// Resolve the two `Hand_Summary`s of a `Parsed_Board`'s fully-known partnership — the shared front
// end for the 2-hand (declarer + dummy) entry points below. `ok` is false unless EXACTLY one
// partnership is known: `known == {N,S}` or `{E,W}`. A 4-hand board (both sides known) is rejected on
// purpose — route those through `analyse_deal_ns`, which fixes the declaring side as N/S; these procs
// exist for the ambiguous 2-hand case where the known pair IS the side to analyse. A lone hand or a
// non-partnership pair is also false.
@(private)
parsed_board_partnership :: proc(
	board: norn.Parsed_Board,
) -> (
	a, b: norn.Hand_Summary,
	side: bit_set[norn.Seat],
	ok: bool,
) {
	switch board.known {
	case NS_SIDE:
		return norn.summarize(board.deal[.North]), norn.summarize(board.deal[.South]), NS_SIDE, true
	case EW_SIDE:
		return norn.summarize(board.deal[.East]), norn.summarize(board.deal[.West]), EW_SIDE, true
	}
	return {}, {}, {}, false
}

// Analyse the known partnership of a `Parsed_Board` — the DOUBLE-DUMMY census entry point for the
// 2-hand (declarer + dummy) flow, where a PBN tag (from `norn.parse_pbn_deal`) specifies exactly two
// hands. The combo model needs only the two partners' holdings (the defenders' 26 cards stay unknown,
// split over every E/W layout), so no full deal is required. Returns the census analysis (the per-suit
// / combined trick CEILING), the side analysed, and `ok` (see `parsed_board_partnership`).
analyse_parsed_board :: proc(
	board: norn.Parsed_Board,
) -> (
	a: Deal_Analysis,
	side: bit_set[norn.Seat],
	ok: bool,
) {
	n, s, resolved, k := parsed_board_partnership(board)
	if !k {
		return {}, {}, false
	}
	return analyse_ns(n, s), resolved, true
}

// The SINGLE-DUMMY companion to `analyse_parsed_board`: the achievable-play bundle for the known
// partnership (per-suit best-line marginals, recommended line names, the SD combined total, and the
// adaptive P(>= t) make curve — everything the card page's blue `sd`/`>=sd` rows show). Same known-side
// resolution and `ok` contract. Together the two give the DD ceiling vs SD achievable for a 2-hand
// board with no full deal / no DDS par. Uses `context.temp_allocator` internally (result copies out by
// value, so the caller may reset that arena afterwards — see `sd_bundle`).
sd_bundle_parsed_board :: proc(
	board: norn.Parsed_Board,
) -> (
	sd: Sd_Bundle,
	side: bit_set[norn.Seat],
	ok: bool,
) {
	n, s, resolved, k := parsed_board_partnership(board)
	if !k {
		return {}, {}, false
	}
	return sd_bundle(n, s), resolved, true
}

// --- G1: read-only per-suit candidate view (aids plan groundwork) -----------------------------
//
// `Sd_Bundle` carries only the RECOMMENDED (best-by-mean) line per suit — enough for the card page. The
// teaching aids B (suit-combination odds per line) and C (safety / min-variance line) need to compare ALL
// candidates per suit, so this exposes them as a small by-value summary. Kept SEPARATE from `Sd_Bundle`
// (and from the threaded render path) on purpose: the HTML golden pins `Sd_Bundle`'s fields, and these
// slices live on the caller's allocator — so widening the bundle is avoided until B/C wire to HTML.

// One candidate single-dummy line with the two teaching summaries B/C read off its achieved distribution:
// `mean` = E[tricks], `floor` = guaranteed tricks (`sure_tricks`). `dist` is the full marginal for any
// finer question (e.g. `p_reach` at the pivotal trick).
Line_Summary :: struct {
	name:  string,
	dist:  Suit_Trick_Dist,
	mean:  f64,
	floor: int,
}

// Every candidate line per suit for a known partnership, each summarised (mean + guaranteed floor), in
// DISPLAY_SUITS order (s,h,d,c) — so index `i` lines up with `Sd_Bundle.best_marg[i]` and the text
// report's per-suit rows. The read-only candidate view (aids plan G1) the text advisor's B/C blocks
// consume. Caller owns the four returned slices (allocated from `allocator`).
suit_line_summaries :: proc(
	north, south: norn.Hand_Summary,
	allocator := context.allocator,
) -> [4][]Line_Summary {
	out: [4][]Line_Summary
	for suit, i in DISPLAY_SUITS {
		lrs := suit_candidate_lines(north.suits[suit], south.suits[suit], allocator)
		defer delete(lrs, allocator)
		sums := make([]Line_Summary, len(lrs), allocator)
		for lr, j in lrs {
			sums[j] = Line_Summary {
				name  = lr.name,
				dist  = lr.dist,
				mean  = expected_tricks(lr.dist.p),
				floor = sure_tricks(lr.dist.p),
			}
		}
		out[i] = sums
	}
	return out
}

// Parsed-board wrapper for `suit_line_summaries` — same known-side resolution and `ok` contract as
// `sd_bundle_parsed_board` (exactly one fully-known partnership). The G1 entry point for the 2-hand text
// advisor.
line_summaries_parsed_board :: proc(
	board: norn.Parsed_Board,
	allocator := context.allocator,
) -> (
	cands: [4][]Line_Summary,
	side: bit_set[norn.Seat],
	ok: bool,
) {
	n, s, resolved, k := parsed_board_partnership(board)
	if !k {
		return {}, {}, false
	}
	return suit_line_summaries(n, s, allocator), resolved, true
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

// The GUARANTEED floor of a trick distribution: the smallest `k` with `p[k] > 0` — the tricks the
// holding takes in even its WORST layout (every E/W split yields at least this many). The teaching
// counterpart of `expected_tricks` (the mean) and `p_at_least` (the make tail): "sure winners" for the
// winner/loser count (aids plan A) and the safety-play floor (C). A degenerate all-zero `p` → 0.
// (The `p[k]` come from exact integer weights ÷ a fixed denom, so a truly-empty count stays exactly 0.0
// and a populated one is well clear of it — a plain `> 0` needs no epsilon.)
sure_tricks :: proc(p: [RANKS + 1]f64) -> int {
	for k in 0 ..= RANKS {
		if p[k] > 0 {
			return k
		}
	}
	return 0
}

// P(reach AT LEAST `k` tricks) — a named alias of `p_at_least` for the line-odds blocks (aids plan B/C),
// which talk in "the chance this line reaches the pivotal trick". Same value; the name reads better next
// to `sure_tricks`/`expected_tricks` in that vocabulary.
p_reach :: proc(p: [RANKS + 1]f64, k: int) -> f64 {
	return p_at_least(p, k)
}

// --- Human-readable report --------------------------------------------------------------------

// Render an analysis as a text table: one row per suit giving P(exactly k tricks) as percentages,
// then the combined total row and the cumulative P(>= k) tail. Caller owns the returned string
// (allocated from `allocator`). `target` is highlighted in the tail line.
format_analysis :: proc(a: ^Deal_Analysis, target: int, allocator := context.allocator) -> string {
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
// `write_suits_json_sd`/`_lines`/`_tips`, and `adaptive_at_least_curve`). One gather (`gather_candidate_tables`)
// + `pick_partnership_sd` does it ONCE; the writers read from the resulting `Partnership_Sd`. The `[4]` axis is
// DISPLAY_SUITS order (s,h,d,c) — the same order every writer walks — so per-suit indices line up with `keys`.
//
// PARITY: deriving each suit's row from its joint table (`marginal_from_table`) is byte-identical to the
// old `sd_line_distribution` path — both sum the SAME per-split integer weights (all partial sums
// ≤ C(26,13) ≈ 1.04e7, exact in f64), then divide by the same denom. Same line chosen, same numbers.
Partnership_Sd :: struct {
	cand:      [4][]Line_Joint, // every candidate line's joint table per suit (drives the adaptive DP)
	best_idx:  [4]int, // index into cand[i] of the best-by-mean line (the recommended blind line)
	best_marg: [4]Suit_Trick_Dist, // that line's marginal trick distribution (the data-*-sd row)
}

// Pick the best-by-mean line per suit from ALREADY-GATHERED candidate tables, caching its index + marginal.
// Picks identically to `best_line_by_mean`/`sd_best_joint_table` (same candidate order, first-wins on ties,
// means equal by the parity note above). Split from the gather so the threaded render path (which gathers the
// per-suit candidate tables on separate worker tasks) shares this pick with the serial path — the parity seam.
@(private)
pick_partnership_sd :: proc(cand: [4][]Line_Joint) -> Partnership_Sd {
	ps: Partnership_Sd
	ps.cand = cand
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

// Does a genuine finesse exist in this holding — an HONOUR (Ten or higher) sitting below a missing honour it
// can trap? A finesse promotes a card past a missing honour; that card must itself be an honour. On solid
// tops (AKQ...) the only card below the top missing rank is a spot (e.g. the 7), which can never win a
// finesse — the line is really a cash. Used to keep the recommended-line LABEL and tooltip honest (a
// finesse-family line with no real tenace is shown/narrated as a cash), independent of WHY the SD model
// ranked it first (free-entry timing can inch a "finesse" ahead on a blocked suit like KQ opposite Axxx).
@(private)
holding_has_real_finesse :: proc(north, south: u16) -> bool {
	combined := north | south
	missing := FULL_SUIT & ~combined
	top_missing := -1
	for r := RANKS - 1; r >= 0; r -= 1 {
		if missing & rank_bit(r) != 0 {top_missing = r; break}
	}
	if top_missing < 0 {
		return false // no missing card at all -> nothing to finesse
	}
	fc := -1
	for r := top_missing - 1; r >= 0; r -= 1 {
		if combined & rank_bit(r) != 0 {fc = r; break}
	}
	// A real finesse card is an honour: Ten or higher. RANK_TEN is the lowest rank worth finessing with.
	return fc >= RANK_TEN
}

// The line name to SHOW and NARRATE for a holding: a finesse-family pick with no real tenace is presented as
// the plain cash it actually is (top-down; a duck-then-finesse becomes a duck-one), so the recommended-line
// label and its tooltip stay honest — no "finesse the 7" on solid AKQ. Other names (and finesses on a genuine
// tenace) pass through unchanged. Shared by write_suits_lines_json (the label) and describe_suit_line (the
// tooltip) so the two never disagree.
@(private)
display_line_name :: proc(north, south: u16, name: string) -> string {
	if !holding_has_real_finesse(north, south) {
		switch name {
		case "finesse", "finesse-other":
			return "top-down"
		case "duck-then-finesse":
			return "duck-one"
		}
	}
	return name
}

// Assemble a partnership's whole `Sd_Bundle` (the four card-page single-dummy blobs, all by value) from its
// already-gathered candidate joint tables: pick the best line per suit, then derive the SD total and adaptive
// make curve. Shared by `sd_bundle` (serial gather) and the threaded render path (per-suit gather tasks), so
// both emit byte-identical JSON.
@(private)
finish_sd :: proc(cand: [4][]Line_Joint) -> Sd_Bundle {
	ps := pick_partnership_sd(cand)
	out: Sd_Bundle
	out.best_marg = ps.best_marg
	for i in 0 ..< 4 {
		out.best_name[i] = ps.cand[i][ps.best_idx[i]].name
	}
	out.totsd = sd_joint_total_of(&ps)
	out.atl = adaptive_curve_from(ps.cand)
	return out
}

// The ACHIEVABLE single-dummy combined total from precomputed per-partnership data: the constrained joint
// convolution (`joint_total`) of the four best-by-mean SD line joint tables. The deduped counterpart of
// `sd_joint_total` — reuses the tables the partnership gather already built instead of re-enumerating.
@(private)
sd_joint_total_of :: proc(ps: ^Partnership_Sd) -> [RANKS + 1]f64 {
	tables: [norn.Suit]Suit_Joint_Table
	for suit, i in DISPLAY_SUITS {
		tables[suit] = ps.cand[i][ps.best_idx[i]].tbl
	}
	return joint_total(tables)
}

// --- Parallel work: persistent pool (see `annotate`) -------------------------------------------
//
// `annotate(.Html_Cards)` decomposes into 16 independent per-SUIT units (see `Suit_Census_Task`/`Suit_Sd_Task`
// below): the double-dummy census suit and the single-dummy candidate gather, for each of the 4 suits × 2
// partnerships. Every unit reads only its two suit holdings plus the read-only `g_binom` table and writes its
// own by-value result, so they run concurrently with no shared state.
//
// PERSISTENT POOL (PERFORMANCE.md §9.4 / §10 #1). The units run on a process-lifetime `thread.Pool` created
// ONCE (lazily, `g_pool_once`) and reused for every deal — the pre-pool path spawned fresh OS threads per deal
// (~144 across a 48-deal batch). Completion is a per-deal `sync.Wait_Group` (NOT `pool_finish`, which tears the
// pool down — it calls `pool_join`). `annotate` is the pool's sole user and runs serially (norn serializes
// annotated scenarios, §9.1), so exactly the tasks one deal adds are ever in flight.
@(private)
g_pool: thread.Pool
@(private)
g_pool_once: sync.Once
@(private)
g_pool_started: bool // set by init_pool; gates shutdown so it is a no-op when the pool was never used

// The most pool workers we ever need = the fine-grained per-deal task count (8 census + 8 SD suit-tasks; the
// 1A assemble phase's 2 finish_sd tasks run in a separate phase, never concurrent with the 16). Sizing to this
// lets every task of one deal run concurrently; more workers would only ever idle.
POOL_MAX_WORKERS :: 16

// One-time pool bring-up (via `g_pool_once`): workers = min(physical cores, `POOL_MAX_WORKERS`), started and
// idle-blocked on the pool semaphore until `annotate` feeds them. They live until `shutdown` (or process exit);
// see PERFORMANCE.md §9.4.
@(private)
init_pool :: proc() {
	workers := POOL_MAX_WORKERS
	if physical, _, ok := si.cpu_core_count(); ok {
		workers = min(max(physical, 1), POOL_MAX_WORKERS)
	}
	thread.pool_init(&g_pool, context.allocator, workers)
	thread.pool_start(&g_pool)
	g_pool_started = true
}

// Pointers to a worker's two persistent memo maps, registered (under `g_scratch_mutex`) the first time that
// thread runs a task so `shutdown` can free them from the main thread. Both the map HEADER and its backing live
// on the heap (the thread-local only holds these pointers — see the tls_memo_* note), so after `pool_join` has
// terminated the workers the main thread frees them safely; nothing dereferences a dead thread's TLS. Freeing a
// heap allocation is not thread-affine, so cross-thread free is fine. See PERFORMANCE.md §8.2.
@(private)
Scratch_Reg :: struct {
	census: ^map[Suit_Layout]int,
	sd:     ^map[u64]int,
}
@(private)
g_scratch_regs: [dynamic]Scratch_Reg
@(private)
g_scratch_mutex: sync.Mutex

// --- Optional phase profiling (`-define:COMBO_PROFILE=true`, default off) -----------------------
//
// Splits `annotate(.Html_Cards)`'s per-deal cost into three phases so the serial main-thread tail can be seen
// against the parallel suit phase (PERFORMANCE.md §9.4 / §10 priority 1): [0] PARALLEL = dispatch + wait on the
// 16 suit-tasks; [1] ASSEMBLE = `finish_census`×2 on the caller overlapped with the two pooled `finish_sd` joint
// DPs (§10 #1A), until join; [2] JSON = the `write_*` string building. Accumulates raw CPU cycles across calls
// (proportions, not calibrated time); the
// bench reads them via `profile_read` and scales by the measured ms/deal. Zero cost when off: `prof_now` folds
// to a constant 0 and `prof_add` to nothing, so the timestamps are still "used" (no unused-var error).
COMBO_PROFILE :: #config(COMBO_PROFILE, false)
@(private)
g_prof: [3]i64 // cumulative cycles: [parallel, assemble, json] (read_cycle_counter is i64)

@(private)
prof_now :: #force_inline proc() -> i64 {
	when COMBO_PROFILE {
		return intrinsics.read_cycle_counter()
	} else {
		return 0
	}
}

@(private)
prof_add :: #force_inline proc(a, b, c, d: i64) {
	when COMBO_PROFILE {
		g_prof[0] += b - a
		g_prof[1] += c - b
		g_prof[2] += d - c
	}
}

// Reset / read the phase-cycle accumulators (the bench brackets its annotate loop with these).
profile_reset :: proc() {g_prof = {}}
profile_read :: proc() -> [3]i64 {return g_prof}

// Stop and free the persistent pool + every worker's memo maps. Optional — safe to skip (the OS reclaims it all
// at exit) — but a leak-checked build (sim's tracking allocator) wants the allocations released, so the CLI calls
// this before finalising. No-op if the pool was never started (non-threaded build, or no Html_Cards deal ran).
// Order matters: `pool_join` first so the workers are dead and no longer touch their thread-local memos.
shutdown :: proc() {
	when COMBO_THREADS {
		if g_pool_started {
			thread.pool_join(&g_pool)
			for reg in g_scratch_regs {
				delete(reg.census^) // free the map backing
				free(reg.census) // then the heap-resident map header itself (see tls_memo_* note)
				delete(reg.sd^)
				free(reg.sd)
			}
			delete(g_scratch_regs)
			g_scratch_regs = nil
			thread.pool_destroy(&g_pool)
			g_pool_started = false
		}
	}
}

// Per-worker persistent scratch (PERFORMANCE.md §8.2 / §10 #2). Each pool worker — and the calling thread — owns,
// in THREAD-LOCAL storage, a per-deal TEMP arena (candidate slices, reset each deal) backed by a fixed BSS array,
// plus the two minimax memo maps on the heap — created once and then `clear()`-reused (never deleted) across every
// deal that worker handles. So after warmup a deal does ZERO heap allocation for combo (the old path made/deleted
// 4 maps + a stack arena per deal); the only per-thread heap objects are the two memo maps' backing, freed once by
// `shutdown`. The memos are pure caches that `suit_joint_table`/`sd_line_joint_table` clear on entry, so reuse is
// byte-identical to a fresh map. The temp arena is bounded (candidate tables ~32 KB ≪ 256 KB); the memos stay on
// the heap rather than a fixed arena so they can grow without a size ceiling (an undersized arena silently drops
// memo entries → correct but slow — a real regression that bit an earlier revision).
TLS_TEMP_SIZE :: 256 * 1024
@(private)
@(thread_local)
tls_ready: bool
@(private)
@(thread_local)
tls_temp_arena: mem.Arena
@(private)
@(thread_local)
tls_temp_backing: [TLS_TEMP_SIZE]u8
// The two memo maps are held on the HEAP, the thread-local only owning a POINTER to each (not the map
// header itself). This matters at teardown: `thread.pool_join` terminates the worker OS threads, which
// destroys their thread-local storage — so `shutdown` must not read a map header out of a dead thread's
// TLS to find its backing. Heap-resident headers stay valid for the main thread to free after the join
// (the registered pointer value is captured once and never changes). A TLS-resident header would be
// freed with the thread and dereferencing it in `shutdown` is a use-after-free (a real crash on join).
@(private)
@(thread_local)
tls_memo_census: ^map[Suit_Layout]int
@(private)
@(thread_local)
tls_memo_sd: ^map[u64]int

// Lazily initialise this thread's scratch (BSS temp arena + both heap memo maps on first use, registered for
// `shutdown`) and hand back pointers to the two persistent memos plus the temp-arena allocator. The CALLER must
// assign the returned allocator to `context.temp_allocator` in its OWN scope (setting it inside here would not
// propagate — Odin gives each proc its own `context` copy) and reset it with `mem.free_all(context.temp_allocator)`
// after the deal; the arena + memos persist for the next deal this thread handles.
@(private)
worker_scratch :: proc() -> (census: ^map[Suit_Layout]int, sd: ^map[u64]int, alloc: mem.Allocator) {
	if !tls_ready {
		mem.arena_init(&tls_temp_arena, tls_temp_backing[:])
		tls_memo_census = new(map[Suit_Layout]int) // heap header (see the tls_memo_* note above), zero-value == empty map
		tls_memo_sd = new(map[u64]int)
		tls_ready = true
		sync.mutex_lock(&g_scratch_mutex)
		append(&g_scratch_regs, Scratch_Reg{tls_memo_census, tls_memo_sd})
		sync.mutex_unlock(&g_scratch_mutex)
	}
	return tls_memo_census, tls_memo_sd, mem.arena_allocator(&tls_temp_arena)
}

// Everything the card page's single-dummy blobs need for ONE partnership, all by value (no pointers into
// the transient joint tables the worker allocated and freed). Public: it is the return type of the
// 2-hand entry point `sd_bundle_parsed_board`, consumed by the `pbn_analyse` driver.
Sd_Bundle :: struct {
	best_marg: [4]Suit_Trick_Dist, // per-suit best-line marginal → data-*-sd
	best_name: [4]string, // per-suit recommended line name → data-*-lines / -tips
	totsd:     [RANKS + 1]f64, // achievable single-dummy combined total → data-*-totsd
	atl:       [RANKS + 1]f64, // adaptive P(>= t) make curve → data-*-atl
}

// Compute a partnership's whole single-dummy bundle: gather the candidate joint tables (Phase-2) then assemble
// (pick best line per suit, SD total, adaptive curve). Serial path; the threaded render path gathers per-suit
// on the pool and calls `finish_sd` directly. Allocates the transient tables on `context.temp_allocator`; the
// RESULT copies out by value, so the caller is free to reset that arena afterwards.
@(private)
sd_bundle :: proc(north, south: norn.Hand_Summary, memo_in: ^map[u64]int = nil) -> Sd_Bundle {
	cand := gather_candidate_tables(north, south, context.temp_allocator, memo_in)
	return finish_sd(cand)
}

// The number of candidate lines per suit (`candidate_lines` returns `[N_CANDIDATE_LINES]Sd_Line`); the SD
// per-suit task writes exactly this many `Line_Joint`s by value.
N_CANDIDATE_LINES :: 5

// --- Fine-grained per-SUIT worker tasks (see `annotate`) ---------------------------------------
//
// The coarse 4-unit split (census ×2, SD bundle ×2) was capped by its longest unit — one SD bundle's four
// serial suit-gathers. Splitting to the SUIT level (8 census + 8 SD = 16 independent tasks per deal) makes the
// critical path ONE suit, letting >4 cores engage. Each `thread.Task_Proc` reads `task.data`, runs on this
// worker's thread-local scratch (`worker_scratch` — its own memo maps + temp arena), writes `.out` BY VALUE
// (fixed-size `Suit_Joint_Table` / `[N]Line_Joint`, line names are static literals — nothing points into the
// worker's arena), then signals the deal's `Wait_Group`. The results are assembled on the calling thread via
// the shared `finish_census`/`finish_sd` seams, so the output is byte-identical to the serial path. See
// PERFORMANCE.md §9.4. (§10 #1B — merging census+SD into 8 coarser tasks — was tried and MEASURED SLOWER:
// 9.1 → ~11 ms. The coarser task serialises census+SD and removes the scheduler slack that hides their
// imbalance; the pool mutex was NOT the bottleneck 1B assumed. Reverted — the fine 16-task split stands.)
@(private)
Suit_Census_Task :: struct {
	north, south: u16, // one suit's NS holdings
	out:          Suit_Joint_Table,
	wg:           ^sync.Wait_Group,
}
@(private)
Suit_Sd_Task :: struct {
	north, south: u16,
	out:          [N_CANDIDATE_LINES]Line_Joint,
	wg:           ^sync.Wait_Group,
}

@(private)
suit_census_task :: proc(t: thread.Task) {
	task := (^Suit_Census_Task)(t.data)
	census, _, alloc := worker_scratch()
	context.temp_allocator = alloc
	task.out = suit_joint_table(task.north, task.south, census)
	mem.free_all(context.temp_allocator) // reset the arena; backing + memos persist for the next deal
	sync.wait_group_done(task.wg)
}

@(private)
suit_sd_task :: proc(t: thread.Task) {
	task := (^Suit_Sd_Task)(t.data)
	_, sd, alloc := worker_scratch()
	context.temp_allocator = alloc
	lines := candidate_lines()
	for line, j in lines {
		task.out[j] = Line_Joint {
			name = line.name,
			tbl  = sd_line_joint_table(task.north, task.south, line, sd),
		}
	}
	mem.free_all(context.temp_allocator)
	sync.wait_group_done(task.wg)
}

// ASSEMBLE-phase task (PERFORMANCE.md §10 #1A): one partnership's whole `finish_sd` — the two
// `adaptive_curve_from` joint DPs are the serial-tail bottleneck, and NS vs EW are independent, so
// running each on the pool overlaps them (~5.2 ms serial → ~2.6 ms) while the caller does the cheap
// census assembles. `cand` views the caller's per-suit `Suit_Sd_Task.out` stack arrays (live until the
// caller joins). `finish_sd` is a pure stack DP over `cand` (no shared state) so the result is identical
// to the serial call — the `-define:COMBO_THREADS=false` parity gate covers it.
@(private)
Sd_Finish_Task :: struct {
	cand: [4][]Line_Joint,
	out:  Sd_Bundle,
	wg:   ^sync.Wait_Group,
}

@(private)
sd_finish_task :: proc(t: thread.Task) {
	task := (^Sd_Finish_Task)(t.data)
	// finish_sd's DP is stack-only, but set the worker's temp arena defensively (a helper could allocate)
	// and to keep this thread off the shared process temp allocator.
	_, _, alloc := worker_scratch()
	context.temp_allocator = alloc
	task.out = finish_sd(task.cand)
	mem.free_all(context.temp_allocator)
	sync.wait_group_done(task.wg)
}

// The Phase-2 ACHIEVABLE per-suit distributions, same JSON shape as `write_suits_json` but each suit's
// `p[k]` is the best fixed single-dummy LINE by mean (brick 2), read from precomputed `ps.best_marg`.
// Where `write_suits_json` is the double-dummy CEILING (census, hindsight), this is a concrete blind line
// a declarer can actually adopt; the card page shows both so the gap (the double-dummy tax) is visible.
// (The optimal search `sd_optimal_distribution` is only better on long holdings — rare on a random
// deal — and much slower, so the render path uses the candidate best-line, coherent with the DP curve.)
write_suits_json_sd :: proc(b: ^strings.Builder, sd: ^Sd_Bundle) {
	keys := [4]string{"s", "h", "d", "c"}

	strings.write_byte(b, '{')
	for key, i in keys {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, `"%s":[`, key)
		p := sd.best_marg[i].p
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
write_suits_lines_json :: proc(b: ^strings.Builder, sd: ^Sd_Bundle, north, south: norn.Hand_Summary) {
	strings.write_byte(b, '[')
	for suit, i in DISPLAY_SUITS {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		// Show the honest line: a finesse with no real tenace is relabelled as a cash (see display_line_name).
		fmt.sbprintf(b, `"%s"`, display_line_name(north.suits[suit], south.suits[suit], sd.best_name[i]))
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
describe_cash :: proc(
	b: ^strings.Builder,
	combined, winners: u16,
	top_missing, n_win, ns_len: int,
) {
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
describe_suit_line :: proc(
	north, south: u16,
	line_name: string,
	allocator := context.temp_allocator,
) -> string {
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
		if missing & rank_bit(r) != 0 {top_missing = r; break}
	}
	winners: u16 // your cards ranking above the opponents best card
	if top_missing < 0 {
		winners = combined
	} else {
		for r := 12; r > top_missing; r -= 1 {winners |= combined & rank_bit(r)}
	}
	n_win := card_count(winners)

	// The hand the recommended finesse line leads TOWARD and inserts from — the source of the card actually
	// run. `line_finesse`/`line_duck_then_finesse` lead toward the strong honour hand; `line_finesse_other`
	// leads toward the WEAKER hand, so on a two-way holding whose touching honours straddle the hands (AJ
	// opposite KT, missing the Q) the card run is the LOWER honour from the weak hand (the ten), not the
	// higher honour describe_finesse would otherwise name off `combined`. Narrating from this hand keeps the
	// tooltip's card in step with the recommended line.
	disp := display_line_name(north, south, line_name)
	strong := strong_honour_seat(north, south)
	strong_hold := north if strong == SEAT_N else south
	weak_hold := south if strong == SEAT_N else north
	insert_hold := strong_hold
	if disp == "finesse-other" {
		insert_hold = weak_hold
	}

	// Present a finesse with no real tenace as the cash it actually is (see display_line_name), so the tooltip
	// matches the relabelled cell and never narrates a bogus finesse of a spot card.
	switch disp {
	case "finesse", "finesse-other":
		describe_finesse(&b, combined, winners, insert_hold, top_missing, n_win, ns_len)
	case "duck-one":
		strings.write_string(
			&b,
			"Duck the first round: play low from both hands and let the opponents win it. Then cash your winners",
		)
		if n_win > 0 {
			strings.write_string(&b, " (")
			write_cards_desc(&b, winners)
			strings.write_string(&b, ")")
		}
		strings.write_string(&b, ". Ducking keeps a guard and can set up your long cards.")
	case "duck-then-finesse":
		strings.write_string(
			&b,
			"Duck the first round (play low from both hands), then take the finesse. ",
		)
		describe_finesse(&b, combined, winners, insert_hold, top_missing, n_win, ns_len)
		strings.write_string(&b, " Ducking first keeps an entry so the finesse can be repeated.")
	case:
		describe_cash(&b, combined, winners, top_missing, n_win, ns_len)
	}
	return strings.to_string(b)
}

// Narrate the finesse line in terms of the actual cards: lead low toward the INSERTING hand's top cards and
// run its highest honour below the opponents best card. `insert_hold` is the hand the recommended line leads
// toward (see describe_suit_line) — narrating the finesse card from THAT hand keeps the tooltip in step with
// the line, which on a straddled two-way (AJ opposite KT: `finesse-other` runs the ten from the weak hand)
// differs from the highest honour in `combined`. Falls back to a cash narration when the inserting hand holds
// no card below the top missing rank (nothing to finesse with there). Shared by the plain and compound
// finesse cases. NO apostrophes / double quotes (single-quoted HTML attribute).
@(private)
describe_finesse :: proc(
	b: ^strings.Builder,
	combined, winners, insert_hold: u16,
	top_missing, n_win, ns_len: int,
) {
	finesse_card := -1
	if top_missing >= 0 {
		for r := top_missing - 1; r >= 0; r -= 1 {
			if insert_hold & rank_bit(r) != 0 {finesse_card = r; break}
		}
	}
	if finesse_card < 0 {
		describe_cash(b, combined, winners, top_missing, n_win, ns_len)
		return
	}
	tops: u16
	for r := 12; r > finesse_card; r -= 1 {tops |= insert_hold & rank_bit(r)}
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
	strings.write_string(
		b,
		" sits with the opponent who plays before your high hand (about even money); if not, it loses.",
	)
}

// Emit the per-suit line NARRATIONS as a JSON array of strings (one per suit s,h,d,c), pairing each
// with its recommended line (`best_line_by_mean`). The card page shows these as hover tooltips.
write_suits_tips_json :: proc(
	b: ^strings.Builder,
	sd: ^Sd_Bundle,
	north, south: norn.Hand_Summary,
) {
	strings.write_byte(b, '[')
	for suit, i in DISPLAY_SUITS {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		desc := describe_suit_line(north.suits[suit], south.suits[suit], sd.best_name[i])
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

// Per-suit combination PATTERN notes (aids plan B) as a JSON array of strings in DISPLAY_SUITS order —
// e.g. `["two-way finesse — guess ...","","",""]`. The card page appends each to that suit's line tooltip.
// Purely combo geometry (`combination_note`), so it needs no --sample. The phrases carry no quotes or
// backslashes, but are escaped defensively (they sit in a single-quoted HTML attribute as JSON strings).
write_suits_notes_json :: proc(b: ^strings.Builder, north, south: norn.Hand_Summary) {
	strings.write_byte(b, '[')
	for suit, i in DISPLAY_SUITS {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		note := combination_note(north.suits[suit], south.suits[suit])
		strings.write_byte(b, '"')
		for c in transmute([]u8)note {
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

// Per-suit GUARANTEED floor (aids plan A) as a JSON int array `[f_s,f_h,f_d,f_c]` in DISPLAY_SUITS order:
// the recommended blind line's sure tricks (`sure_tricks` of `best_marg`). The card page sums these for the
// winner count and the gap to the slider target.
write_suits_floor_json :: proc(b: ^strings.Builder, sd: ^Sd_Bundle) {
	strings.write_byte(b, '[')
	for i in 0 ..< 4 {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d", sure_tricks(sd.best_marg[i].p))
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

	switch format {
	case .Html_Handviewer:
		a := analyse_ns(ds[.North], ds[.South])
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
		// The four partnership results (census + single-dummy bundle for NS and EW). Under `COMBO_THREADS`
		// each is decomposed to the SUIT level and the 16 per-suit tasks run on the persistent pool, then the
		// calling thread assembles them via `finish_census`/`finish_sd`; otherwise all four run serially. Both
		// paths go through the same assembly seams, so the writers below see byte-identical values.
		a, ew: Deal_Analysis
		ns_sd, ew_sd: Sd_Bundle

		prof_a := prof_now() // phase profiling (COMBO_PROFILE): a=start, b=after parallel, c=after assemble, d=after JSON
		prof_b: i64

		when COMBO_THREADS {
			sync.once_do(&g_pool_once, init_pool)

			// 8 census suit-tasks (NS + EW, one per suit) + 8 SD suit-tasks. Each writes its result by value
			// into these arrays; nothing is shared, so no locking beyond the completion `Wait_Group`.
			ns_ct, ew_ct: [norn.Suit]Suit_Census_Task
			ns_st, ew_st: [4]Suit_Sd_Task

			wg: sync.Wait_Group
			sync.wait_group_add(&wg, 16)
			for suit in norn.Suit {
				ns_ct[suit] = {north = ds[.North].suits[suit], south = ds[.South].suits[suit], wg = &wg}
				ew_ct[suit] = {north = ds[.East].suits[suit], south = ds[.West].suits[suit], wg = &wg}
			}
			for suit, i in DISPLAY_SUITS {
				ns_st[i] = {north = ds[.North].suits[suit], south = ds[.South].suits[suit], wg = &wg}
				ew_st[i] = {north = ds[.East].suits[suit], south = ds[.West].suits[suit], wg = &wg}
			}
			for suit in norn.Suit {
				thread.pool_add_task(&g_pool, context.allocator, suit_census_task, &ns_ct[suit])
				thread.pool_add_task(&g_pool, context.allocator, suit_census_task, &ew_ct[suit])
			}
			for i in 0 ..< 4 {
				thread.pool_add_task(&g_pool, context.allocator, suit_sd_task, &ns_st[i])
				thread.pool_add_task(&g_pool, context.allocator, suit_sd_task, &ew_st[i])
			}
			sync.wait_group_wait(&wg)
			// Drain the pool's done list so `tasks_done` does not grow across the batch (results are already
			// in the task structs by value).
			for {
				_, ok := thread.pool_pop_done(&g_pool)
				if !ok {break}
			}
			prof_b = prof_now() // end of the parallel suit phase

			// Assemble. `cand`/`*_tables` view the per-suit task outputs (stack arrays, live until this scope
			// ends) in DISPLAY_SUITS / suit order. The two `finish_sd` calls carry the joint-DP cost (§10 #1A),
			// and NS vs EW are independent, so dispatch BOTH to the pool and run the cheap `finish_census` pair
			// on this thread meanwhile — overlapping the two ~2.6 ms adaptive curves instead of serialising them.
			ns_tables, ew_tables: [norn.Suit]Suit_Joint_Table
			for suit in norn.Suit {
				ns_tables[suit] = ns_ct[suit].out
				ew_tables[suit] = ew_ct[suit].out
			}
			ns_cand := [4][]Line_Joint{ns_st[0].out[:], ns_st[1].out[:], ns_st[2].out[:], ns_st[3].out[:]}
			ew_cand := [4][]Line_Joint{ew_st[0].out[:], ew_st[1].out[:], ew_st[2].out[:], ew_st[3].out[:]}

			wg2: sync.Wait_Group
			sync.wait_group_add(&wg2, 2)
			ns_sdt := Sd_Finish_Task{cand = ns_cand, wg = &wg2}
			ew_sdt := Sd_Finish_Task{cand = ew_cand, wg = &wg2}
			thread.pool_add_task(&g_pool, context.allocator, sd_finish_task, &ns_sdt)
			thread.pool_add_task(&g_pool, context.allocator, sd_finish_task, &ew_sdt)

			a = finish_census(ns_tables) // cheap; runs under the two pooled SD assembles
			ew = finish_census(ew_tables)

			sync.wait_group_wait(&wg2)
			for {
				_, ok := thread.pool_pop_done(&g_pool)
				if !ok {break}
			}
			ns_sd = ns_sdt.out
			ew_sd = ew_sdt.out
		} else {
			prof_b = prof_now() // serial: no parallel phase; all compute lands in ASSEMBLE
			a = analyse_ns(ds[.North], ds[.South])
			ew = analyse_ns(ds[.East], ds[.West])
			ns_sd = sd_bundle(ds[.North], ds[.South])
			ew_sd = sd_bundle(ds[.East], ds[.West])
		}
		prof_c := prof_now() // end of assemble; JSON writing follows

		strings.write_string(builder, `<div class="combo" data-ns='`)
		write_suits_json(builder, &a)
		strings.write_string(builder, `' data-ns-sd='`)
		write_suits_json_sd(builder, &ns_sd)
		strings.write_string(builder, `' data-ns-tot='`)
		write_curve_json(builder, a.total)
		strings.write_string(builder, `' data-ns-totsd='`)
		write_curve_json(builder, ns_sd.totsd)
		strings.write_string(builder, `' data-ns-atl='`)
		write_curve_json(builder, ns_sd.atl)
		strings.write_string(builder, `' data-ns-lines='`)
		write_suits_lines_json(builder, &ns_sd, ds[.North], ds[.South])
		strings.write_string(builder, `' data-ns-tips='`)
		write_suits_tips_json(builder, &ns_sd, ds[.North], ds[.South])
		strings.write_string(builder, `' data-ns-notes='`)
		write_suits_notes_json(builder, ds[.North], ds[.South])
		strings.write_string(builder, `' data-ns-floor='`)
		write_suits_floor_json(builder, &ns_sd)
		strings.write_string(builder, `' data-ew='`)
		write_suits_json(builder, &ew)
		strings.write_string(builder, `' data-ew-sd='`)
		write_suits_json_sd(builder, &ew_sd)
		strings.write_string(builder, `' data-ew-tot='`)
		write_curve_json(builder, ew.total)
		strings.write_string(builder, `' data-ew-totsd='`)
		write_curve_json(builder, ew_sd.totsd)
		strings.write_string(builder, `' data-ew-atl='`)
		write_curve_json(builder, ew_sd.atl)
		strings.write_string(builder, `' data-ew-lines='`)
		write_suits_lines_json(builder, &ew_sd, ds[.East], ds[.West])
		strings.write_string(builder, `' data-ew-tips='`)
		write_suits_tips_json(builder, &ew_sd, ds[.East], ds[.West])
		strings.write_string(builder, `' data-ew-notes='`)
		write_suits_notes_json(builder, ds[.East], ds[.West])
		strings.write_string(builder, `' data-ew-floor='`)
		write_suits_floor_json(builder, &ew_sd)
		strings.write_string(builder, `'></div>`)
		prof_add(prof_a, prof_b, prof_c, prof_now()) // parallel / assemble / JSON split
		free_all(context.temp_allocator)
	case .Pretty:
		a := analyse_ns(ds[.North], ds[.South])
		table := format_analysis(&a, 0, context.temp_allocator)
		strings.write_string(builder, "\n")
		strings.write_string(builder, table)
	case .Line, .Numeric, .Handviewer, .Pbn:
	// unreachable: filtered out above
	}
}
