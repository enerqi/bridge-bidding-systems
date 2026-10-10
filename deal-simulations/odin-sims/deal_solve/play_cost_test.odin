package deal_solve

import "core:strings"
import "core:testing"

import dds "dds:."
import "norn:norn"

// Two boards of a real vugraph segment (BBO archive 87351): open room board 13 (2♦ by West, 29 cards then a
// claim of 7) and board 14 (4♥ by West, 49 cards then a claim of 10).
@(private = "file")
O13 :: "md|3SKT87HT2DJ3CQT754,SAJ3HK4DKQ9852C98,S42HAQ986DAT74CA6,SQ965HJ753D6CKJ32|sv|b|mb|1H|mb|p|mb|p|mb|2D|mb|p|mb|p|mb|p|pc|s4|pc|s5|pc|sK|pc|sA|pc|dQ|pc|d4|pc|d6|pc|d3|pc|d8|pc|d7|pc|h3|pc|dJ|pc|h2|pc|h4|pc|hQ|pc|h5|pc|cA|pc|c2|pc|c4|pc|c8|pc|hA|pc|h7|pc|hT|pc|hK|pc|h9|pc|hJ|pc|c5|pc|c9|pc|c3|mc|7|"
@(private = "file")
O14 :: "md|4SQT63H852DKQ72C92,S7HAQJ973DA643C84,SA98HK4DT98CJT753,SKJ542HT6DJ5CAKQ6|sv|o|mb|1S|mb|p|mb|2H|mb|p|mb|3C|mb|p|mb|3H|mb|p|mb|4H|mb|p|mb|p|mb|p|pc|dT|pc|d5|pc|dQ|pc|dA|pc|c8|pc|c3|pc|cK|pc|c2|pc|cA|pc|c9|pc|c4|pc|c5|pc|cQ|pc|h2|pc|h3|pc|c7|pc|d3|pc|d8|pc|dJ|pc|dK|pc|h5|pc|hA|pc|h4|pc|h6|pc|d4|pc|d9|pc|hT|pc|d2|pc|c6|pc|s3|pc|h7|pc|cT|pc|s7|pc|sA|pc|s2|pc|s6|pc|cJ|pc|s4|pc|d7|pc|h9|pc|hQ|pc|hK|pc|s5|pc|h8|pc|s8|pc|sJ|pc|sT|pc|hJ|pc|d6|mc|10|"

// The per-card costs hang together: the first value is the DD table's number for the contract, every card
// moves the trajectory by exactly its cost in its own side's disfavour, and a card is among the best cards
// exactly when it cost nothing.
@(test)
test_play_cost_is_consistent :: proc(t: ^testing.T) {
	init()
	for record in ([]string{O13, O14}) {
		board, err := norn.parse_lin_deal(record)
		testing.expect_value(t, err, norn.Lin_Parse_Error.None)
		contract := board.contract.?
		play := board.play.?
		cost, ok := play_cost(board.deal, contract, play)
		testing.expect(t, ok)
		testing.expect_value(t, cost.count, play.count)

		table, tok := solve_table(board.deal)
		testing.expect(t, tok)
		testing.expect_value(
			t,
			int(cost.value[0]),
			int(table.resTable[strain_to_dds(contract.strain)][dds.Hand(int(contract.declarer))]),
		)

		walk := norn.play_walk_start(board.deal, contract)
		for i in 0 ..< play.count {
			seat := norn.play_walk_next_seat(&walk).?
			declaring := int(seat) % 2 == int(contract.declarer) % 2
			step := int(cost.value[i + 1]) - int(cost.value[i])
			testing.expectf(
				t,
				step == (-int(cost.cost[i]) if declaring else int(cost.cost[i])),
				"card %d: step %d cost %d",
				i,
				step,
				cost.cost[i],
			)
			in_best := cost.best[i] & (u64(1) << u64(play.cards[i])) != 0
			testing.expectf(t, in_best == (cost.cost[i] == 0), "card %d best/cost mismatch", i)
			_ = norn.play_walk_card(&walk, play.cards[i])
		}
	}
}

// A whole play, all 52 cards: the last value is the tricks the declaring side actually took.
@(test)
test_play_cost_whole_play :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_lin_deal(O13)
	contract := board.contract.?
	// Finish the record's play with the lowest legal card each turn.
	play := board.play.?
	walk := norn.play_tricks(board.deal, contract, play)
	for play.count < norn.DECK_SIZE {
		for card in 0 ..< norn.DECK_SIZE {
			if norn.play_walk_card(&walk, norn.Card(card)) == .None {
				play.cards[play.count] = norn.Card(card)
				play.count += 1
				break
			}
		}
	}
	cost, ok := play_cost(board.deal, contract, play)
	testing.expect(t, ok)
	testing.expect_value(t, walk.trick_count, norn.PLAY_TRICKS)
	testing.expect_value(t, int(cost.value[norn.DECK_SIZE]), walk.declarer_tricks)
}

// The `data-play` bake: who played what, trick winners, the hands, the trajectory, and the best cards only
// where a card cost a trick (declarer's ♦8 at trick 3 here).
@(test)
test_play_json :: proc(t: ^testing.T) {
	init()
	board, _ := norn.parse_lin_deal(O13)
	contract := board.contract.?
	play := board.play.?
	cost, ok := play_cost(board.deal, contract, play)
	testing.expect(t, ok)
	b := strings.builder_make(context.temp_allocator)
	write_play_json(&b, board.deal, contract, play, cost)
	json := strings.to_string(b)
	for want in ([]string {
			`{"dec":"W","con":"2D","hands":{"N":"42.AQ986.AT74.A6",`,
			`"c":["4S","5S","KS","AS","QD",`,
			`"by":"NESWWNESWNESSWNE`,
			`"win":"WWSNNNE"`,
			`"dd":[8,8,8,8,8,8,8,8,8,7,`,
			`"best":{"8":[`,
			`"res":7}`,
		}) {
		testing.expectf(t, strings.contains(json, want), "missing %q in %s", want, json)
	}
	testing.expect(t, !strings.contains(json, `"err"`))
	testing.expect_value(t, strings.count(json, `":[`) - 3, 1) // one costly card: c, dd, cost + one best entry

	// Unsolved, and cut at a bad card: no trajectory, and the cut is reported.
	bad, _ := strings.replace(O13, "pc|dQ|", "pc|sK|", 1, context.temp_allocator)
	board2, _ := norn.parse_lin_deal(bad)
	b2 := strings.builder_make(context.temp_allocator)
	write_play_json(&b2, board2.deal, board2.contract.?, board2.play.?, nil)
	json2 := strings.to_string(b2)
	testing.expect(t, !strings.contains(json2, `"dd"`))
	testing.expect(t, strings.contains(json2, `"err":"Not_Held","erri":4`))
}
