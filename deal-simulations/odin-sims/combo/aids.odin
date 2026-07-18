package combo

/*
	aids.odin — combo-side helpers for the learner declarer-play aids (LEARNER_AIDS_PLAN.md B & C).

	B (suit-combination odds per line) and C (safety / min-variance line) both compare ALL candidate
	lines per suit and want two extra things the raw `Line_Summary` view (G1) doesn't carry:
	  * a PATTERN NAME for the suit — "two-way finesse", "8-ever/9-never", "one-way finesse"
	    (`combination_note`), read from the two known holdings' geometry, no solving; and
	  * the best line BY MEAN vs the best line BY FLOOR (the safety trade C teaches).

	`Suit_Combo_Advice` bundles both onto the G1 candidate slice so the text advisor builds B and C from
	one call. Everything here is solver-free (combo has no `dd`/DDS dependency); the pattern geometry
	deliberately MIRRORS `dd/tax.odin`'s `two_way_guess_pivots` so the note a suit shows lines up with the
	blind two-way guess the misguess-tax estimator prices (aids plan B3 cross-link).
*/

import "core:fmt"

import "norn:norn"

// Honour rank bit positions (Two=0 .. Ace=12), for the combination classifier.
@(private)
RANK_TEN :: 8
@(private)
RANK_JACK :: 9
@(private)
RANK_QUEEN :: 10
@(private)
RANK_KING :: 11
@(private)
RANK_ACE :: 12

// True iff `m` holds any rank strictly ABOVE `r` (a card that can lead/win over rank `r`).
@(private)
has_rank_above :: proc "contextless" (m: u16, r: int) -> bool {
	return (m >> uint(r + 1)) != 0
}

// Name the standard suit-combination PATTERN in the two known holdings, or "" when none applies. Read
// purely from card geometry (no distribution, no solving). Priority: two-way finesse (the costliest blind
// guess) → 8-ever/9-never (a length-decided hook) → one-way finesse. The two-way test mirrors
// `dd/tax.odin` exactly, so the phrase aligns with the priced misguess tax.
combination_note :: proc(north, south: u16) -> string {
	ns := north | south
	ns_len := card_count(ns)
	if ns_len == 0 {
		return ""
	}

	// Two-way finesse: a missing honour C (Ten..King) trapped by a tight tenace (C+1 AND C-1 both held)
	// that declarer can attack from EITHER hand (a card above C in each). Name the top such guess. Same
	// geometry as dd/tax.odin `two_way_guess_pivots`.
	for r := RANK_KING; r >= RANK_TEN; r -= 1 {
		if ns & rank_bit(r) != 0 {
			continue // we hold C — not a defender card, no guess
		}
		above := ns & rank_bit(r + 1) != 0
		below := r > 0 && ns & rank_bit(r - 1) != 0
		if !above || !below {
			continue // not a tight two-sided tenace around C
		}
		if has_rank_above(north, r) && has_rank_above(south, r) {
			return fmt.tprintf("two-way finesse — guess which defender holds the %s", RANK_NAMES[r])
		}
	}

	// 8-ever / 9-never: A, K and J held with the queen missing — a one-way hook whose right answer flips on
	// combined length (nine cards → play for the drop; eight → finesse the jack).
	if ns & rank_bit(RANK_ACE) != 0 &&
	   ns & rank_bit(RANK_KING) != 0 &&
	   ns & rank_bit(RANK_JACK) != 0 &&
	   ns & rank_bit(RANK_QUEEN) == 0 {
		if ns_len >= 9 {
			return "9-never — cash A K and play for the queen to drop"
		}
		return "8-ever — finesse the jack for the missing queen"
	}

	// One-way finesse: a missing honour trapped by a tenace (both neighbours held) but attackable from only
	// one side. Name the honour that must be onside.
	for r := RANK_KING; r >= RANK_QUEEN; r -= 1 {
		if ns & rank_bit(r) != 0 {
			continue
		}
		above := ns & rank_bit(r + 1) != 0
		below := r > 0 && ns & rank_bit(r - 1) != 0
		if above && below {
			return fmt.tprintf("finesse — needs the %s onside", RANK_NAMES[r])
		}
	}
	return ""
}

// Everything B and C need for ONE suit: the full candidate view (G1), the index of the best line by MEAN
// (the card page's recommendation) and by FLOOR (the max-guaranteed safety line), and the pattern note.
Suit_Combo_Advice :: struct {
	cands:                  []Line_Summary, // every candidate line (mean + guaranteed floor); caller owns it
	best_mean_idx:          int, // index into `cands` of the highest-mean line (matches Sd_Bundle's pick)
	best_floor_idx:         int, // index of the highest-guaranteed-floor line (ties → higher mean)
	note:                   string, // combination pattern phrase, or "" (temp-allocated by `combination_note`)
	north_holding:          u16, // this suit's NS holdings — so C can run the optimal-line search (below) lazily
	south_holding:          u16,
}

// Per-suit combination advice for a known partnership, in DISPLAY_SUITS order (s,h,d,c). Builds on the G1
// candidate view (`suit_line_summaries`) and adds the best-by-mean / best-by-floor picks + the pattern
// note. Caller owns each `cands` slice (allocated from `allocator`).
suit_combo_advice :: proc(
	north, south: norn.Hand_Summary,
	allocator := context.allocator,
) -> [4]Suit_Combo_Advice {
	out: [4]Suit_Combo_Advice
	cands4 := suit_line_summaries(north, south, allocator)
	for suit, i in DISPLAY_SUITS {
		cs := cands4[i]
		bm, bf := 0, 0
		for ls, j in cs {
			if ls.mean > cs[bm].mean {
				bm = j // first-wins on ties (strict >), matching Sd_Bundle's best-by-mean pick
			}
			if ls.floor > cs[bf].floor || (ls.floor == cs[bf].floor && ls.mean > cs[bf].mean) {
				bf = j
			}
		}
		out[i] = Suit_Combo_Advice {
			cands          = cs,
			best_mean_idx  = bm,
			best_floor_idx = bf,
			note           = combination_note(north.suits[suit], south.suits[suit]),
			north_holding  = north.suits[suit],
			south_holding  = south.suits[suit],
		}
	}
	return out
}

// --- F (entry / timing heuristic) — LEARNER_AIDS_PLAN.md F -------------------------------------
//
// The naive model assumes FREE ENTRIES. These three geometry-only helpers let the text advisor partly
// walk that back: warn when a suit's recommended FINESSE must be led from one hand more than once, but
// that hand has few outside entries to get back there. Crude on purpose (a real entry count needs the
// whole-hand play); the F warning stays conservative and is tagged HEURISTIC.

// The seat a finesse in this suit must be LED FROM (repeatedly): the hand OPPOSITE the honour hand (the
// seat holding the single highest NS card). The finesse machinery leads low from here toward the honour.
finesse_leading_seat :: proc(north, south: u16) -> int {
	hon := strong_honour_seat(north, south)
	return SEAT_S if hon == SEAT_N else SEAT_N
}

// Crude count of finesse leads a suit needs = missing (opponent-held) ranks INTERIOR to the honour
// hand's span — a card sitting between the honour hand's lowest and highest card, which you must lead
// toward the honour hand to trap. Each interior gap is one such lead, so 2+ means a REPEATED finesse
// (AJT missing K,Q → 2), the case where a short entry to the leading hand actually bites. A solid run
// (AKQ) has no interior gap → 0. Geometry only, no solving.
finesse_leads_needed :: proc(north, south: u16) -> int {
	ns := north | south
	hon := strong_honour_seat(north, south)
	hon_hold := north if hon == SEAT_N else south
	if card_count(hon_hold) < 2 {
		return 0 // a finesse needs a tenace (2+ cards spanning a gap)
	}
	top := highest_rank(hon_hold)
	bot := lowest_rank(hon_hold)
	n := 0
	for r := bot + 1; r < top; r += 1 {
		if ns & rank_bit(r) == 0 { // an opponent card inside the honour hand's span — a finesse target
			n += 1
		}
	}
	return n
}

// Sure quick entries to a hand from its SIDE suits (all but `exclude`, DISPLAY_SUITS order): the top
// solid run down from the ace in each other suit (A→1, AK→2, AKQ→3 …). A crude HIGH-CARD entry count —
// it ignores ruffing entries (no trump suit in view here) and long-card entries, so it UNDER-counts;
// the F warning is deliberately conservative for that reason.
sure_side_entries :: proc(suits: [4]u16, exclude: int) -> int {
	total := 0
	for hold, i in suits {
		if i == exclude {
			continue
		}
		for r := RANK_ACE; r >= 0; r -= 1 {
			if hold & rank_bit(r) == 0 {
				break // first gap from the top ends the solid run
			}
			total += 1
		}
	}
	return total
}

// Parsed-board wrapper for `suit_combo_advice` — same known-side resolution and `ok` contract as
// `sd_bundle_parsed_board`. The B/C entry point for the 2-hand text advisor.
suit_combo_advice_parsed_board :: proc(
	board: norn.Parsed_Board,
	allocator := context.allocator,
) -> (
	advice: [4]Suit_Combo_Advice,
	side: bit_set[norn.Seat],
	ok: bool,
) {
	n, s, resolved, k := parsed_board_partnership(board)
	if !k {
		return {}, {}, false
	}
	return suit_combo_advice(n, s, allocator), resolved, true
}
