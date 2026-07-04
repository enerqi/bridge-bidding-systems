package combo

/*
	combo_test.odin — unit tests for the naive card-combination analyser.

	Run:  odin test combo -collection:norn=<norn> -out:target/debug/test-combo.exe
	(there is no justfile recipe yet; the `lint` recipe already type-checks the package.)

	The tests split into three kinds:
	  1. Fully-specified layouts fed to `suit_dd_tricks` — the minimax has a single known answer, so
	     these pin the double-dummy engine itself (finesses, cashing tops, length tricks).
	  2. `suit_trick_distribution` sanity — every distribution must sum to 1, and trivial holdings
	     (void / solid / whole suit) must land entirely on the obvious trick count.
	  3. The combining layer — convolution stays normalised and P(>=k) is a correct tail.
*/

import "core:testing"

import "norn:norn"

// Build a suit mask from an explicit list of ranks (small test helper).
@(private = "file")
mask :: proc(ranks: ..norn.Rank) -> u16 {
	m: u16
	for r in ranks {
		m |= u16(1) << uint(r)
	}
	return m
}

// Solve a fully-specified layout with a throwaway memo (tests don't share one).
@(private = "file")
dd :: proc(n, e, s, w: u16) -> int {
	memo := make(map[Suit_Layout]int)
	defer delete(memo)
	layout := Suit_Layout{}
	layout[SEAT_N] = n
	layout[SEAT_E] = e
	layout[SEAT_S] = s
	layout[SEAT_W] = w
	return suit_dd_tricks(layout, &memo)
}

// AKQ opposite a void: three solid winners, always three tricks, whatever the opponents hold.
@(test)
test_dd_three_solid_tops :: proc(t: ^testing.T) {
	n := mask(.Ace, .King, .Queen)
	// Opponents hold the other ten ranks; the exact split cannot matter.
	e := mask(.Jack, .Ten, .Nine, .Eight, .Seven)
	w := mask(.Six, .Five, .Four, .Three, .Two)
	testing.expect_value(t, dd(n, e, 0, w), 3)
}

// AK opposite two small: exactly two tricks (the ace and king). No length (only four cards), the
// opponents win everything once the tops are gone.
@(test)
test_dd_ak_opposite_small :: proc(t: ^testing.T) {
	n := mask(.Ace, .King)
	s := mask(.Three, .Two)
	e := mask(.Queen, .Jack, .Ten, .Nine, .Eight)
	w := mask(.Seven, .Six, .Five, .Four)
	testing.expect_value(t, dd(n, e, s, w), 2)
}

// AQ opposite two small, missing the King. Double-dummy the solver "sees" the king:
//   - King with West (behind the AQ) -> the finesse wins -> 2 tricks.
//   - King with East (in front)      -> the finesse loses -> 1 trick.
// This is the canonical finesse and exercises second/third/fourth-hand card choice in the minimax.
@(test)
test_dd_finesse_king_onside :: proc(t: ^testing.T) {
	n := mask(.Ace, .Queen)
	s := mask(.Three, .Two)
	others := mask(.Jack, .Ten, .Nine, .Eight, .Seven, .Six, .Five, .Four)

	// King onside (West): 2 tricks.
	w_on := mask(.King) | (others & mask(.Jack, .Ten, .Nine, .Eight))
	e_on := others & mask(.Seven, .Six, .Five, .Four)
	testing.expect_value(t, dd(n, e_on, s, w_on), 2)

	// King offside (East): 1 trick.
	e_off := mask(.King) | (others & mask(.Jack, .Ten, .Nine, .Eight))
	w_off := others & mask(.Seven, .Six, .Five, .Four)
	testing.expect_value(t, dd(n, e_off, s, w_off), 1)
}

// A void NS hand takes no tricks regardless of the (irrelevant) opposing holding.
@(test)
test_dd_void_ns :: proc(t: ^testing.T) {
	e := mask(.Ace, .King, .Queen, .Jack, .Ten, .Nine, .Seven)
	w := mask(.Eight, .Six, .Five, .Four, .Three, .Two)
	testing.expect_value(t, dd(0, e, 0, w), 0)
}

// Every per-suit distribution must be a probability distribution: entries sum to 1.
@(test)
test_distribution_sums_to_one :: proc(t: ^testing.T) {
	cases := [][2]u16 {
		{mask(.Ace, .Queen), mask(.Three, .Two)}, // finesse combo
		{mask(.Ace, .King, .Jack), mask(.Four, .Three, .Two)}, // two tops + a finesse
		{mask(.King, .Queen), mask(.Five, .Four)}, // no ace
		{mask(.Ace), 0}, // singleton ace opposite void
	}
	for c in cases {
		d := suit_trick_distribution(c[0], c[1])
		sum := f64(0)
		for k in 0 ..= RANKS {
			sum += d.p[k]
		}
		testing.expectf(t, abs(sum - 1) < 1e-9, "distribution sum = %v, want 1", sum)
	}
}

// AKQ opposite a void: the whole distribution collapses onto exactly three tricks.
@(test)
test_distribution_solid_is_certain :: proc(t: ^testing.T) {
	d := suit_trick_distribution(mask(.Ace, .King, .Queen), 0)
	testing.expectf(t, abs(d.p[3] - 1) < 1e-9, "P(3 tricks) = %v, want 1", d.p[3])
	testing.expect_value(t, d.max_tricks, 3)
}

// Holding the entire suit (all 13 ranks between the two hands): thirteen certain tricks.
@(test)
test_distribution_whole_suit :: proc(t: ^testing.T) {
	d := suit_trick_distribution(FULL_SUIT, 0)
	testing.expectf(t, abs(d.p[13] - 1) < 1e-9, "P(13 tricks) = %v, want 1", d.p[13])
}

// AQ opposite xx: the finesse is roughly even money, so both the 1-trick and 2-trick outcomes carry
// real probability and they (alone) account for essentially all the mass.
@(test)
test_distribution_finesse_is_two_sided :: proc(t: ^testing.T) {
	d := suit_trick_distribution(mask(.Ace, .Queen), mask(.Three, .Two))
	testing.expect(t, d.p[1] > 0.3, "P(1 trick) should be substantial")
	testing.expect(t, d.p[2] > 0.3, "P(2 tricks) should be substantial")
	testing.expectf(t, abs(d.p[1] + d.p[2] - 1) < 1e-6, "1- and 2-trick outcomes should dominate")
}

// The combined total distribution stays normalised, and P(>=k) is a correct, monotone tail.
@(test)
test_combined_normalised_and_tail :: proc(t: ^testing.T) {
	// A concrete pair of hands. North: solid-ish; South: filler. MUST be a full 13/13 split — the joint
	// convolution (`joint_total`) constrains East to exactly 13 of the 26 opponent cards, so partial hands
	// would break normalisation. Real deals (`summarize_deal`) are always 13 cards.
	north := norn.Hand_Summary {
		suits = {
			.Spades = mask(.Ace, .King, .Queen, .Two),
			.Hearts = mask(.Ace, .King, .Three, .Two),
			.Diamonds = mask(.Ace, .Five, .Four),
			.Clubs = mask(.Seven, .Six),
		},
	}
	south := norn.Hand_Summary {
		suits = {
			.Spades = mask(.Five, .Four, .Three),
			.Hearts = mask(.Queen, .Jack, .Ten),
			.Diamonds = mask(.King, .Six),
			.Clubs = mask(.Ace, .King, .Eight, .Three, .Two),
		},
	}
	a := analyse_ns(north, south)

	sum := f64(0)
	for k in 0 ..= RANKS {
		sum += a.total[k]
	}
	testing.expectf(t, abs(sum - 1) < 1e-9, "total distribution sum = %v, want 1", sum)

	// P(>=0) is certain; the tail is non-increasing in k; P(>=14) is impossible.
	testing.expectf(t, abs(p_at_least(a.total, 0) - 1) < 1e-9, "P(>=0) must be 1")
	prev := p_at_least(a.total, 0)
	for k in 1 ..= RANKS {
		cur := p_at_least(a.total, k)
		testing.expectf(t, cur <= prev + 1e-12, "tail not monotone at k=%d", k)
		prev = cur
	}
}
