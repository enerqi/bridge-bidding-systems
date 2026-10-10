package deal_solve

import "core:testing"
import "norn:norn"

// A deal where North-South have a laydown grand in spades (all the top cards, 13 trumps between them)
// and East-West nothing.
@(private = "file")
NS_GRAND :: `[Deal "N:AKQJT98.AKQ.AK.A 7654.JT9.QJ.KQJ2 32.8765.T98.T987 .432.765432.6543"]`

// The side x goal grid behind a scenario file's `double-dummy:` line: the levels nest (a grand is a slam is
// a game), and East-West is the same test as North-South with the table turned a quarter.
@(test)
test_side_makes_reads_the_right_side_and_level :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	board, err := norn.parse_pbn_deal(NS_GRAND)
	testing.expect_value(t, err, norn.Pbn_Parse_Error.None)
	deal := board.deal

	for goal in Makes_Goal {
		testing.expectf(t, side_makes(deal, .North_South, goal), "N/S make %v", goal)
		testing.expectf(t, !side_makes(deal, .East_West, goal), "E/W do not make %v", goal)
		testing.expect(t, makes_filter(.North_South, goal)(deal), "the N/S filter agrees")
		testing.expect(t, !makes_filter(.East_West, goal)(deal), "the E/W filter agrees")
	}

	// A quarter turn: North's cards to East, East's to South, and so on. East-West now hold the grand.
	turned: norn.Deal
	turned[.East], turned[.South], turned[.West], turned[.North] = deal[.North], deal[.East], deal[.South], deal[.West]
	for goal in Makes_Goal {
		testing.expectf(t, side_makes(turned, .East_West, goal), "turned, E/W make %v", goal)
		testing.expectf(t, !side_makes(turned, .North_South, goal), "turned, N/S do not make %v", goal)
	}
}
