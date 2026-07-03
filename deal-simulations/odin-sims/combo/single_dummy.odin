package combo

/*
	single_dummy.odin — Phase 2, brick 1: the FIXED-LINE single-dummy evaluator.

	================================================================================================
	WHAT THIS ADDS OVER PHASE 1
	================================================================================================

	Phase 1 (`combo.odin`) is a CENSUS: for each E/W layout it takes that layout's double-dummy
	optimum (declarer sees all four hands) and tallies the results. That UPPER-BOUNDS what a real
	declarer takes, because a real declarer is BLIND to the E/W split and must commit to one line of
	play before the cards reveal themselves (see the "WHAT p[k] IS" section of `combo.odin`).

	Phase 2 models the blind declarer. A "line" (`Sd_Line`) is a deterministic strategy that decides
	each card FROM PUBLIC INFORMATION ONLY — declarer's own two holdings plus every card already
	played — never from the hidden E/W split. This file EVALUATES one such fixed line:

	    for every E/W layout, play the suit out with declarer following the line and the DEFENDERS
	    playing double-dummy (perfect, minimising NS tricks); weight each layout by its a-priori
	    vacant-space probability (same weights as Phase 1); tally -> a real, achievable
	    `Suit_Trick_Dist`.

	This distribution is what a player who ADOPTS THIS LINE actually achieves, so its mean is <= the
	Phase-1 census mean; the difference is the "double-dummy tax" — the cost of not seeing the cards.

	================================================================================================
	WHY EVALUATING A FIXED LINE IS EXACT AND CHEAP (and the optimal SEARCH is not)
	================================================================================================

	Evaluating ONE fixed line has no hidden-information difficulty: the line's choices depend only on
	public cards, so within any single layout declarer's moves are fully determined and the defenders
	simply best-respond (a plain minimisation — `sd_trick`'s defender nodes). We do that layout by
	layout, independently, and the line is guaranteed self-consistent (identical public history =>
	identical line choice) because it is one pure function.

	Finding the BEST line is the hard part (partial-observability minimax: the defenders can false-card
	to exploit declarer's uncertainty, coupling the layouts through declarer's shared future choices).
	That is the NEXT increment — an optimiser that SEARCHES over lines using this evaluator as its
	scoring oracle. This file deliberately stops at "score a line I hand you".

	Assumptions 1 (free entries — declarer leads every trick, from either hand) and 2 (suits solved in
	isolation) are inherited from Phase 1 unchanged; see `combo.odin`. Only assumption 3 (perfect
	information) is what Phase 2 relaxes, and only for DECLARER — the defence stays double-dummy.
*/

import "base:intrinsics"

// The public view handed to a line when it must choose declarer's card. It EXCLUDES the E/W split by
// construction (that is the hidden information); everything here is derivable from the played cards.
Sd_View :: struct {
	north, south: u16, // declarer's CURRENT holdings (this suit), after cards already played
	own:          u16, // the holding of the seat being asked to play (== north or south)
	played:       u16, // every rank already played to the table (all seats, this deal so far)
	seat:         int, // which seat is on play: SEAT_N or SEAT_S
	rho_rank:     int, // rank the right-hand defender just played this trick, or -1 (e.g. on lead)
	win_rank:     int, // highest rank played so far in the current trick (-1 if none)
	win_ns:       bool, // is an NS seat currently winning the trick?
}

// A deterministic declarer strategy for ONE suit. `lead` picks which hand leads and the card; it is
// consulted at the start of every trick (free entries — declarer is always on lead). `partner` picks
// the card for declarer's SECOND seat in the trick, after the intervening defender has played, so it
// can react to the card on its right. Both must return a rank the named hand actually holds; the
// evaluator falls back to that hand's lowest card if a line returns an illegal rank.
Sd_Line :: struct {
	name:    string,
	lead:    proc(north, south, played: u16) -> (seat: int, rank: int),
	partner: proc(v: Sd_View) -> int,
}

// --- rank helpers -----------------------------------------------------------------------------

@(private)
lowest_rank :: proc "contextless" (m: u16) -> int {
	return int(intrinsics.count_trailing_zeros(m)) // m != 0 assumed by callers
}

@(private)
highest_rank :: proc "contextless" (m: u16) -> int {
	return 15 - int(intrinsics.count_leading_zeros(m)) // m != 0 assumed by callers
}

// --- the fixed-line game driver ---------------------------------------------------------------

// NS tricks taken in the suit when declarer follows `line` and the defenders play double-dummy
// (perfect, minimising), for ONE fully known layout. Free entries: `line.lead` chooses the leading
// hand and card every trick; declarer is never forced to lead from the "wrong" hand.
sd_deal_tricks :: proc(line: Sd_Line, north, south, east, west: u16) -> int {
	hands := Suit_Layout{}
	hands[SEAT_N] = north
	hands[SEAT_S] = south
	hands[SEAT_E] = east
	hands[SEAT_W] = west
	return sd_from_lead(line, hands)
}

// Position with declarer on lead: cash out the trivial cases, else consult the line for the lead and
// play the trick.
@(private)
sd_from_lead :: proc(line: Sd_Line, hands: Suit_Layout) -> int {
	ns := card_count(hands[SEAT_N]) + card_count(hands[SEAT_S])
	if ns == 0 {
		return 0 // no cards to lead: no more NS tricks
	}
	ew := card_count(hands[SEAT_E]) + card_count(hands[SEAT_W])
	if ew == 0 {
		return ns // opponents exhausted: every remaining NS card wins
	}

	played := FULL_SUIT & ~(hands[SEAT_N] | hands[SEAT_S] | hands[SEAT_E] | hands[SEAT_W])
	seat, rank := line.lead(hands[SEAT_N], hands[SEAT_S], played)
	// Guard against a malformed line: the lead hand must be NS and actually hold the card.
	if !is_ns(seat) || hands[seat] & rank_bit(rank) == 0 {
		seat = SEAT_N if hands[SEAT_N] != 0 else SEAT_S
		rank = highest_rank(hands[seat])
	}

	next := hands
	next[seat] &= ~rank_bit(rank)
	order := [4]int{seat, (seat + 1) % 4, (seat + 2) % 4, (seat + 3) % 4}
	return sd_trick(line, next, order, 1, seat, rank)
}

// One ply within a trick. `order` is the clockwise seat sequence, `idx` the number of seats that have
// already played (the leader counts as idx 1 — see `sd_from_lead`). Declarer's seats are forced by
// `line` (the lead already played; the partner via `line.partner`); defender seats MINIMISE over
// their legal cards (double-dummy defence). When the trick completes, score it and recurse to the
// next lead.
@(private)
sd_trick :: proc(line: Sd_Line, hands: Suit_Layout, order: [4]int, idx, win_seat, win_rank: int) -> int {
	if idx == 4 {
		pt := 1 if is_ns(win_seat) else 0
		return pt + sd_from_lead(line, hands)
	}

	seat := order[idx]
	hold := hands[seat]
	if hold == 0 {
		return sd_trick(line, hands, order, idx + 1, win_seat, win_rank) // void follows nothing
	}

	if is_ns(seat) {
		// Declarer's partner seat: the line chooses, reacting to the card on its right.
		rho := order[idx - 1]
		v := Sd_View {
			north    = hands[SEAT_N],
			south    = hands[SEAT_S],
			own      = hold,
			played   = FULL_SUIT & ~(hands[SEAT_N] | hands[SEAT_S] | hands[SEAT_E] | hands[SEAT_W]),
			seat     = seat,
			rho_rank = win_rank if !is_ns(rho) else -1,
			win_rank = win_rank,
			win_ns   = is_ns(win_seat),
		}
		r := line.partner(v)
		if hold & rank_bit(r) == 0 {
			r = lowest_rank(hold) // fallback: a legal card
		}
		next := hands
		next[seat] &= ~rank_bit(r)
		ws, wr := win_seat, win_rank
		if r > win_rank {
			ws, wr = seat, r
		}
		return sd_trick(line, next, order, idx + 1, ws, wr)
	}

	// Defender seat: minimise NS tricks over every legal card.
	best := max(int)
	m := hold
	for m != 0 {
		r := int(intrinsics.count_trailing_zeros(m))
		m &= m - 1

		next := hands
		next[seat] &= ~rank_bit(r)
		ws, wr := win_seat, win_rank
		if r > win_rank {
			ws, wr = seat, r
		}
		v := sd_trick(line, next, order, idx + 1, ws, wr)
		if v < best {
			best = v
		}
	}
	return best
}

// --- distribution over all E/W splits (mirrors Phase 1's enumeration, but for a fixed line) -----

// The trick distribution for ONE suit when declarer commits to `line`, given NS's two holdings.
// Enumerates every E/W split, plays it out with `sd_deal_tricks` (double-dummy defence), and weights
// by the same vacant-space a-priori probability Phase 1 uses (see `suit_trick_distribution`). The
// returned `p[]` sums to 1. This is the "achievable" companion to Phase 1's census.
sd_line_distribution :: proc(north, south: u16, line: Sd_Line) -> Suit_Trick_Dist {
	ns := north | south
	ns_len := card_count(ns)

	dist: Suit_Trick_Dist
	dist.max_tricks = ns_len
	if ns_len == 0 {
		dist.p[0] = 1
		return dist
	}
	if ns_len == RANKS {
		dist.p[RANKS] = 1
		return dist
	}

	missing := FULL_SUIT & ~ns
	m := card_count(missing)
	denom := g_binom[26][13]

	east := missing
	for {
		west := missing & ~east
		a := card_count(east)
		tricks := sd_deal_tricks(line, north, south, east, west)
		dist.p[tricks] += g_binom[26 - m][13 - a]

		if east == 0 {
			break
		}
		east = (east - 1) & missing
	}

	for k in 0 ..= RANKS {
		dist.p[k] /= denom
	}
	return dist
}

// The double-dummy tax for a suit under a given line: the mean tricks the line actually achieves
// (single-dummy), the Phase-1 census mean (double-dummy ceiling), and the gap between them (>= 0).
// A wide gap flags a guess-heavy suit (a finesse the line must commit to blind); a zero gap means the
// line captures everything the layout offers (solid suits, forced positions).
sd_census_gap :: proc(north, south: u16, line: Sd_Line) -> (sd_mean, census_mean, gap: f64) {
	sd := sd_line_distribution(north, south, line)
	census := suit_trick_distribution(north, south)
	sd_mean = expected_tricks(sd.p)
	census_mean = expected_tricks(census.p)
	gap = census_mean - sd_mean
	return
}

// --- shipped reference line -------------------------------------------------------------------

// `line_top_down` — a simple, honest reference line: every trick, lead the HIGHEST card NS holds
// (from whichever hand holds it); declarer's partner always plays its LOWEST card. This "bang down
// the top cards" strategy is NOT claimed optimal — it never finesses and never ducks — but it is a
// well-defined blind line, useful as a baseline and to exercise the evaluator. Optimal / smarter
// lines (finesse, safety play, and the search that chooses among them) are the next increment.
line_top_down :: Sd_Line {
	name    = "top-down",
	lead    = proc(north, south, played: u16) -> (seat: int, rank: int) {
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
