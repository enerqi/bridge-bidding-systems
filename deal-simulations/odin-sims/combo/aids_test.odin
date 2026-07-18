package combo

/*
	aids_test.odin — tests for the learner-aids groundwork (LEARNER_AIDS_PLAN.md G1/G2).

	G2 dist helpers: `sure_tricks` (guaranteed floor) and `p_reach` (P(>= k) alias).
	G1 candidate view: `suit_line_summaries` exposes every candidate line per suit with mean + floor,
	in DISPLAY_SUITS order, without perturbing `Sd_Bundle`.
*/

import "core:strings"
import "core:testing"

import "norn:norn"

@(private = "file")
mask :: proc(ranks: ..norn.Rank) -> u16 {
	m: u16
	for r in ranks {
		m |= u16(1) << uint(r)
	}
	return m
}

// AKQ opposite void: three solid tricks, guaranteed in every layout — floor is exactly the length.
// A void holding floors at 0. And a distribution's floor never exceeds its mean.
@(test)
test_sure_tricks_floor :: proc(t: ^testing.T) {
	solid := sd_line_distribution(mask(.Ace, .King, .Queen), 0, line_top_down)
	testing.expectf(t, sure_tricks(solid.p) == 3, "AKQ floor = %d, want 3", sure_tricks(solid.p))

	empty := sd_line_distribution(0, 0, line_top_down)
	testing.expectf(t, sure_tricks(empty.p) == 0, "void floor = %d, want 0", sure_tricks(empty.p))

	// AQ opp xx: the finesse can LOSE (K onside-only), so its floor is below its mean — a real gap.
	fin := sd_line_distribution(mask(.Ace, .Queen), mask(.Three, .Two), line_finesse)
	testing.expectf(
		t,
		f64(sure_tricks(fin.p)) < expected_tricks(fin.p),
		"AQ finesse floor %d should be below mean %.3f",
		sure_tricks(fin.p),
		expected_tricks(fin.p),
	)
}

// `p_reach` is exactly `p_at_least`, and the tail is monotone non-increasing in k.
@(test)
test_p_reach_alias :: proc(t: ^testing.T) {
	d := sd_line_distribution(mask(.Ace, .King, .Jack), mask(.Four, .Three, .Two), line_finesse)
	for k in 0 ..= RANKS {
		testing.expect(t, p_reach(d.p, k) == p_at_least(d.p, k), "p_reach must equal p_at_least")
	}
	for k in 1 ..= RANKS {
		testing.expectf(
			t,
			p_reach(d.p, k) <= p_reach(d.p, k - 1) + 1e-12,
			"tail not monotone at k=%d",
			k,
		)
	}
}

// `suit_line_summaries` returns one entry per candidate line for each suit, in DISPLAY_SUITS order,
// each carrying a valid distribution whose mean/floor match the standalone helpers.
@(test)
test_suit_line_summaries :: proc(t: ^testing.T) {
	n, s: norn.Hand_Summary
	n.suits[.Spades] = mask(.Ace, .Queen) // a real two-way-ish finesse suit for NS
	s.suits[.Spades] = mask(.Three, .Two)
	n.suits[.Hearts] = mask(.Ace, .King, .Queen) // solid
	// diamonds/clubs left void

	cands := suit_line_summaries(n, s)
	defer for c in cands {
		delete(c)
	}

	// One slice per DISPLAY_SUITS index, each with the full candidate set.
	for i in 0 ..< 4 {
		testing.expectf(
			t,
			len(cands[i]) == N_CANDIDATE_LINES,
			"suit %d: %d candidates, want %d",
			i,
			len(cands[i]),
			N_CANDIDATE_LINES,
		)
	}

	// Spades is index 0 (DISPLAY_SUITS). Every summary's mean/floor must agree with the helpers.
	for ls in cands[0] {
		sum := f64(0)
		for k in 0 ..= RANKS {
			sum += ls.dist.p[k]
		}
		testing.expectf(t, abs(sum - 1) < 1e-9, "line %s: dist sums to %v", ls.name, sum)
		testing.expect(t, ls.mean == expected_tricks(ls.dist.p), "mean out of sync")
		testing.expect(t, ls.floor == sure_tricks(ls.dist.p), "floor out of sync")
	}

	// The solid heart suit (index 1) floors at 3 on every candidate line.
	for ls in cands[1] {
		testing.expectf(t, ls.floor == 3, "AKQ line %s floor = %d, want 3", ls.name, ls.floor)
	}
}

// `combination_note` names the standard patterns from card geometry (aids plan B2).
@(test)
test_combination_note :: proc(t: ^testing.T) {
	// AJ opposite KT: a genuine two-way finesse for the queen (a card above Q in both hands).
	two_way := combination_note(mask(.Ace, .Jack), mask(.King, .Ten))
	testing.expectf(t, strings.contains(two_way, "two-way"), "AJ/KT note = %q, want two-way", two_way)

	// AQ opposite xx: a ONE-way finesse (the king must be onside), not two-way.
	one_way := combination_note(mask(.Ace, .Queen), mask(.Three, .Two))
	testing.expectf(
		t,
		strings.contains(one_way, "finesse") && !strings.contains(one_way, "two-way"),
		"AQ/xx note = %q, want one-way finesse",
		one_way,
	)

	// A K J held, queen missing: length decides the hook. 8 cards → 8-ever; 9 → 9-never.
	eight := combination_note(mask(.Ace, .King, .Jack, .Three, .Two), mask(.Six, .Five, .Four))
	testing.expectf(t, strings.contains(eight, "8-ever"), "8-card AKJ note = %q, want 8-ever", eight)
	nine := combination_note(mask(.Ace, .King, .Jack, .Four, .Three, .Two), mask(.Seven, .Six, .Five))
	testing.expectf(t, strings.contains(nine, "9-never"), "9-card AKJ note = %q, want 9-never", nine)

	// A solid AKQ has no combination to guess.
	solid := combination_note(mask(.Ace, .King, .Queen), 0)
	testing.expectf(t, solid == "", "AKQ note = %q, want empty", solid)
}

// `suit_combo_advice` bundles the candidate view with the best-mean / best-floor picks and the note.
@(test)
test_suit_combo_advice :: proc(t: ^testing.T) {
	n, s: norn.Hand_Summary
	n.suits[.Spades] = mask(.Ace, .Jack) // two-way finesse suit
	s.suits[.Spades] = mask(.King, .Ten)

	advice := suit_combo_advice(n, s)
	defer for ad in advice {
		delete(ad.cands)
	}

	sp := advice[0] // spades = DISPLAY_SUITS index 0
	testing.expectf(t, strings.contains(sp.note, "two-way"), "spades note = %q", sp.note)
	testing.expect(t, len(sp.cands) == N_CANDIDATE_LINES, "candidate count")
	testing.expect(
		t,
		sp.best_mean_idx >= 0 && sp.best_mean_idx < len(sp.cands),
		"best_mean_idx in range",
	)
	// best-by-mean really has the max mean; best-by-floor really has the max floor.
	for ls in sp.cands {
		testing.expect(t, sp.cands[sp.best_mean_idx].mean >= ls.mean - 1e-12, "best_mean is max mean")
		testing.expect(t, sp.cands[sp.best_floor_idx].floor >= ls.floor, "best_floor is max floor")
	}
}

// aids plan C — the safety-play gate. The generic candidate lines can FLOOR pessimistically (the
// mechanical `finesse` throws a trick optimal play keeps), so a raw best-floor > best-mean-floor gap is
// usually an ARTIFACT, not a real safety trade. The definitive test is `sd_optimal_distribution`: only a
// genuine max-vs-safe trade when even the mean-maximising OPTIMAL line's own floor falls short of the
// safety floor. In the free-entry double-dummy model that never happens (free entries let one line
// cash-to-guarantee AND finesse-for-extra), so the gate must SUPPRESS on every holding — that is why
// `print_safety` is (correctly) silent. This pins the invariant so a future regression can't silently
// start emitting the misleading artifact advice.
@(test)
test_safety_gate_suppresses_artifacts :: proc(t: ^testing.T) {
	Case :: struct {
		tag:  string,
		n, s: u16,
	}
	// A spread of holdings, incl. ones where the raw candidate gap FIRES (AKJ98) and classic combos.
	cases := []Case {
		{"AKJ98 (AJ9/K8)", mask(.Ace, .Jack, .Nine), mask(.King, .Eight)},
		{"AJT7/Q9", mask(.Ace, .Jack, .Ten, .Seven), mask(.Queen, .Nine)},
		{"AJ8/QT", mask(.Ace, .Jack, .Eight), mask(.Queen, .Ten)},
		{"AQxxx/Kxxx", mask(.Ace, .Queen, .Six, .Five, .Four), mask(.King, .Seven, .Three, .Two)},
		{"AJTx/Kxxx", mask(.Ace, .Jack, .Ten, .Four), mask(.King, .Seven, .Six, .Five)},
	}
	for c in cases {
		// best candidate floor (the "safety" line the raw gap would propose).
		best_floor := 0
		for line in candidate_lines() {
			best_floor = max(best_floor, sure_tricks(sd_line_distribution(c.n, c.s, line).p))
		}
		opt, exact := sd_optimal_distribution(c.n, c.s)
		// The gate suppresses iff the optimal line already secures the safety floor (or is unverifiable).
		suppressed := !exact || sure_tricks(opt.p) >= best_floor
		testing.expectf(t, suppressed, "%s: gate must suppress (no genuine safety trade)", c.tag)
	}
}

// aids plan F — the entry/timing heuristic's geometry helpers.
@(test)
test_entry_helpers :: proc(t: ^testing.T) {
	// AJT opposite 765: honour hand holds the ace; K and Q are missing below it → 2 finesse leads
	// (a REPEATED finesse), led from the seat OPPOSITE the honour hand.
	n := mask(.Ace, .Jack, .Ten)
	s := mask(.Seven, .Six, .Five)
	testing.expectf(t, finesse_leads_needed(n, s) == 2, "AJT/765 leads = %d, want 2", finesse_leads_needed(n, s))
	testing.expect(t, finesse_leading_seat(n, s) == SEAT_S, "led from opposite the honour hand")
	// A solid AKQ opposite void has no missing honour below the ace → no finesse lead needed.
	testing.expect(t, finesse_leads_needed(mask(.Ace, .King, .Queen), 0) == 0, "solid needs no finesse")

	// sure_side_entries: the top solid run from the ace in each side suit, excluding the develop suit.
	suits := [4]u16{mask(.Ace, .King, .Five), mask(.Three, .Two), mask(.Ace), mask(.King, .Queen)}
	testing.expectf(t, sure_side_entries(suits, 0) == 1, "excl S = %d, want 1 (only ♦A)", sure_side_entries(suits, 0))
	testing.expectf(t, sure_side_entries(suits, 1) == 3, "excl H = %d, want 3 (♠AK + ♦A)", sure_side_entries(suits, 1))
}
