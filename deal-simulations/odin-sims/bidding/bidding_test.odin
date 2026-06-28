package bidding

/*
	conditions_test.odin — unit tests for the bridge conditions.

	Hands are built explicitly so each qualifying/non-qualifying case is unambiguous.
*/

import "core:testing"
import "norn:norn"

// A flat 17-count (4-3-3-3): spades A K Q J, hearts A K x, rest low.
flat_17 :: proc() -> norn.Hand {
	return norn.Hand {
		norn.make_card(.Spades, .Ace),
		norn.make_card(.Spades, .King),
		norn.make_card(.Spades, .Queen),
		norn.make_card(.Spades, .Jack),
		norn.make_card(.Hearts, .Ace),
		norn.make_card(.Hearts, .King),
		norn.make_card(.Hearts, .Two),
		norn.make_card(.Diamonds, .Two),
		norn.make_card(.Diamonds, .Three),
		norn.make_card(.Diamonds, .Four),
		norn.make_card(.Clubs, .Two),
		norn.make_card(.Clubs, .Three),
		norn.make_card(.Clubs, .Four),
	}
}

// An unbalanced 16-count, 5-5-2-1: spades A K Q x x, hearts A K x x x, short minors.
unbalanced_16 :: proc() -> norn.Hand {
	return norn.Hand {
		norn.make_card(.Spades, .Ace),
		norn.make_card(.Spades, .King),
		norn.make_card(.Spades, .Queen),
		norn.make_card(.Spades, .Two),
		norn.make_card(.Spades, .Three),
		norn.make_card(.Hearts, .Ace),
		norn.make_card(.Hearts, .King),
		norn.make_card(.Hearts, .Four),
		norn.make_card(.Hearts, .Five),
		norn.make_card(.Hearts, .Six),
		norn.make_card(.Diamonds, .Two),
		norn.make_card(.Diamonds, .Three),
		norn.make_card(.Clubs, .Two),
	}
}

@(test)
test_is_flattish :: proc(t: ^testing.T) {
	testing.expect(t, is_flattish(flat_17()), "4-3-3-3 is flattish")
	testing.expect(t, !is_flattish(unbalanced_16()), "5-5-2-1 is not flattish")
}

@(test)
test_is_strong_1c :: proc(t: ^testing.T) {
	// 16 unbalanced -> qualifies.
	testing.expect(t, is_strong_1c(unbalanced_16()), "unbalanced 16 should open strong 1C")
	// 17 flat -> does not (shown as a strong notrump instead).
	testing.expect(t, !is_strong_1c(flat_17()), "flat 17 should not open strong 1C")
	// Below 16 -> never.
	testing.expect(t, !is_strong_1c(norn.Hand{}), "an empty/low hand is not a strong 1C")
}
