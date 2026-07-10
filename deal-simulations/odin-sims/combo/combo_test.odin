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

// The 2-hand (declarer + dummy) entry: a PBN tag with two known partners parses and analyses. N holds
// all 13 spades and S all 13 hearts — a degenerate but valid board — so each of those suits is 13
// certain tricks and the combined total caps at 13.
@(test)
test_analyse_parsed_board_two_hand :: proc(t: ^testing.T) {
	board, perr := norn.parse_pbn_deal(`N:AKQJT98765432... - .AKQJT98765432.. -`)
	testing.expect_value(t, perr, norn.Pbn_Parse_Error.None)

	a, side, ok := analyse_parsed_board(board)
	testing.expect(t, ok, "known N/S partnership should analyse")
	testing.expect_value(t, side, NS_SIDE)

	testing.expect(t, a.suits[.Spades].p[RANKS] > 0.999, "all spades -> 13 tricks certain")
	testing.expect(t, a.suits[.Hearts].p[RANKS] > 0.999, "all hearts -> 13 tricks certain")
	testing.expect(t, a.total[RANKS] > 0.999, "combined total caps at 13")

	sum := f64(0)
	for v in a.total {
		sum += v
	}
	testing.expect(t, abs(sum - 1) < 1e-9, "total distribution normalised")
}

// A board with only one known hand is not a full partnership, so the analysis is refused.
@(test)
test_analyse_parsed_board_rejects_non_partnership :: proc(t: ^testing.T) {
	board, _ := norn.parse_pbn_deal(`N:AKQJT98765432... - - -`)
	_, _, ok := analyse_parsed_board(board)
	testing.expect(t, !ok, "single known hand is not a full partnership")
}

// The single-dummy companion resolves the same known partnership and produces a valid bundle. With N
// all spades and S all hearts (both solid running suits), the achievable SD total also caps at 13 —
// no finesse needed, so SD matches the census ceiling here.
@(test)
test_sd_bundle_parsed_board_two_hand :: proc(t: ^testing.T) {
	board, perr := norn.parse_pbn_deal(`N:AKQJT98765432... - .AKQJT98765432.. -`)
	testing.expect_value(t, perr, norn.Pbn_Parse_Error.None)

	sd, side, ok := sd_bundle_parsed_board(board)
	testing.expect(t, ok, "known N/S partnership should produce an SD bundle")
	testing.expect_value(t, side, NS_SIDE)
	testing.expect(t, sd.totsd[RANKS] > 0.999, "solid suits -> achievable SD total caps at 13")
	testing.expect(t, sd.atl[0] > 0.999, "P(>= 0) is certain")
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
