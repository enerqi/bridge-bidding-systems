package analyse

import "core:strings"
import "core:testing"

import "norn:combo"
import "norn:norn"

// Two boards of the real vugraph segment in norn's testdata (`vugraph-87351.lin`): a doubled 1NT the defence
// let make with two overtricks, and a 2H whose lead cost a trick.
MATCH_BOARDS :: `qx|o20|st||md|2SA9653H9DA7CKT754,SKQ4HKT7DKJ432CA9,SJTHAJ843DQ65CQ82,S872HQ652DT98CJ63|sv|b|mb|1N|mb|d|mb|p|mb|p|mb|p|pc|h4|pc|h2|pc|h9|pc|hT|pg||
pc|d2|pc|d5|pc|dT|pc|dA|pg||
pc|s3|pc|sK|pc|sT|pc|s2|pg||
pc|d3|pc|dQ|pc|d8|pc|d7|pg||
pc|sJ|pc|s7|pc|sA|pc|s4|pg||
pc|s5|pc|sQ|pc|d6|pc|s8|pg||
pc|hK|pc|h3|pc|h5|pc|c4|pg||
pc|dK|pc|c2|pc|d9|pc|c5|pg||
pc|d4|pc|c8|pc|c3|pc|c7|pg||
pc|dJ|pc|h8|pc|c6|pc|cT|pg||
mc|9|pg||
qx|o22|st||md|4S8HA764DA852CA432,SQ5HKQJ85DJ76CJ97,SJT632HT2DQT94CQ5,SAK974H93DK3CKT86|sv|e|mb|1S|mb|d|mb|p|mb|2D|mb|p|mb|p|mb|2H|mb|p|mb|p|mb|p|pc|d4|pc|d3|pc|dA|pc|d6|pg||
pc|s8|pc|sQ|pc|s2|pc|s4|pg||
pc|c7|pc|c5|pc|c6|pc|cA|pg||
pc|c2|pc|cJ|pc|cQ|pc|cK|pg||
pc|h3|pc|h4|pc|hK|pc|h2|pg||
pc|hJ|pc|hT|pc|h9|pc|hA|pg||
pc|c3|pc|c9|pc|d9|pc|c8|pg||
mc|10|pg||
`

// The whole path, solver included: every number of both boards, and the columns accounting for every trick
// between double dummy and the table (tricks = dd - declarer + defence + claim).
@(test)
test_the_match_table_judges_each_board :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	args := Args {
		text  = MATCH_BOARDS,
		table = "csv",
	}
	testing.expect_value(t, run(builder_sink(&b), &args), Result.Ok)
	lines := strings.split_lines(strings.trim_space(strings.to_string(b)), context.temp_allocator)
	testing.expect_value(t, len(lines), 3)
	if len(lines) != 3 {
		return
	}
	testing.expect_value(t, lines[1], "20 Open,1NTX W,yes,9,5,4,0,0,4,0,580,-500,-620,15,3,trick 3 S 3S")
	testing.expect_value(t, lines[2], "22 Open,2H W,yes,10,8,2,1,1,3,0,170,110,120,2,0,trick 1 N 4D")
	// As many fields in each row as the header names.
	header := strings.count(lines[0], ",")
	for line in lines[1:] {
		testing.expect_value(t, strings.count(line, ","), header)
	}
}

// The totals, without the solver: which kinds a board counts under, and what is summed where.
@(test)
test_tally_match_sums_by_kind :: proc(t: ^testing.T) {
	verdicts := []Board_Verdict {
		{
			contract = {level = 3, strain = .NoTrumps, declarer = .South},
			dd_tricks = 9,
			result = 8,
			has_par = true,
			par = 400,
			has_play = true,
			lead_cost = 1,
			defence_gave = 1,
			declarer_lost = 2,
			claim = 0,
		},
		{contract = {level = 2, strain = .Hearts, declarer = .East}, dd_tricks = 8, result = 9, has_par = true, par = 110},
		{contract = {level = 6, strain = .Spades, declarer = .North}, dd_tricks = 12},
	}
	totals := tally_match(verdicts)
	all := totals[.All]
	testing.expect_value(t, all.boards, 3)
	testing.expect_value(t, all.with_result, 2)
	testing.expect_value(t, all.tricks_vs_dd, 0)
	testing.expect_value(t, all.under, 1)
	testing.expect_value(t, all.over, 1)
	testing.expect_value(t, all.with_play, 1)
	testing.expect_value(t, all.costly_leads, 1)
	testing.expect_value(t, all.with_par, 2)
	testing.expect_value(t, all.at_par, 2) // both contracts score par played double dummy
	// 3NT one down (-50) against 400 is -10; 2H plus one (140) against 110 is +1.
	testing.expect_value(t, all.result_imps, -9)
	testing.expect_value(t, totals[.Game].boards, 1)
	testing.expect_value(t, totals[.Partscore].boards, 1)
	testing.expect_value(t, totals[.Slam].boards, 1)
	testing.expect_value(t, totals[.Notrumps].boards, 1)
	testing.expect_value(t, totals[.Suit].boards, 2)
}

@(test)
test_contract_kinds :: proc(t: ^testing.T) {
	c :: proc(level: int, strain: norn.Contract_Strain) -> norn.Contract {
		return {level = level, strain = strain}
	}
	testing.expect_value(t, contract_kinds(c(4, .Hearts)), bit_set[Contract_Kind]{.All, .Game, .Suit})
	testing.expect_value(t, contract_kinds(c(4, .Diamonds)), bit_set[Contract_Kind]{.All, .Partscore, .Suit})
	testing.expect_value(t, contract_kinds(c(3, .NoTrumps)), bit_set[Contract_Kind]{.All, .Game, .Notrumps})
	testing.expect_value(t, contract_kinds(c(7, .Clubs)), bit_set[Contract_Kind]{.All, .Slam, .Suit})
}

@(test)
test_parse_args_table :: proc(t: ^testing.T) {
	args, err := parse_args({"--table", "csv", "x"}, allow_stdin = false)
	defer args_free(&args)
	testing.expect_value(t, err, "")
	testing.expect_value(t, args.table, "csv")
	bad, bad_err := parse_args({"--table", "html", "x"}, allow_stdin = false)
	defer args_free(&bad)
	testing.expect(t, bad_err != "")
}

// The card page of a match carries the table, after the boards: a row a board, each opening its slide at the
// step after the first card that cost a trick (board 20's at trick 3's first card, board 22's at the lead).
@(test)
test_the_card_page_carries_the_match_table :: proc(t: ^testing.T) {
	// combo's thread pool is made on this test's allocator: stop it before the test's memory goes.
	defer combo.shutdown()
	out, page := strings.builder_make(), strings.builder_make()
	defer strings.builder_destroy(&out)
	defer strings.builder_destroy(&page)
	args := Args {
		text = MATCH_BOARDS,
	}
	testing.expect_value(t, run(builder_page_sink(&out, &page), &args), Result.Ok)
	html := strings.to_string(page)
	at := strings.index(html, `<div class="match-table" hidden>`)
	testing.expect(t, at > strings.last_index(html, `class="compass`), "the table follows the boards")
	if at < 0 {
		return
	}
	table := html[at:]
	testing.expect_value(t, strings.count(table, `<tr data-board=`), 2)
	testing.expect(t, strings.contains(table, `<tr data-board="0" data-step="9"><td class="l">20 Open</td>`))
	testing.expect(t, strings.contains(table, `<tr data-board="1" data-step="1"><td class="l">22 Open</td>`))
	testing.expect(t, strings.contains(table, `2 boards judged.`))
}

// One board is not a match: no table.
@(test)
test_one_board_has_no_match_table :: proc(t: ^testing.T) {
	// combo's thread pool is made on this test's allocator: stop it before the test's memory goes.
	defer combo.shutdown()
	out, page := strings.builder_make(), strings.builder_make()
	defer strings.builder_destroy(&out)
	defer strings.builder_destroy(&page)
	boards := MATCH_BOARDS
	first := boards[:strings.index(boards, "qx|o22")]
	args := Args {
		text = first,
	}
	testing.expect_value(t, run(builder_page_sink(&out, &page), &args), Result.Ok)
	testing.expect(t, !strings.contains(strings.to_string(page), `class="match-table"`))
}

// Two boards of a team match, both rooms: the swing to the open room's North-South, the bidding's share
// (both contracts played double dummy) and the play's (the rest). A board in one room only is not a pair.
@(test)
test_pair_rooms_splits_each_swing :: proc(t: ^testing.T) {
	boards := []norn.Board {
		{table = {number = 1, room = .Open}},
		{table = {number = 1, room = .Closed}},
		{table = {number = 2, room = .Open}},
		{table = {number = 2, room = .Closed}},
		{table = {number = 3, room = .Open}},
	}
	judged := []Judged {
		// 4S N +420 against 3S N +170: the bidding's 6 IMPs, all of it.
		{verdict = {contract = {level = 4, strain = .Spades, declarer = .North}, dd_tricks = 10, result = 10}, board = 0},
		{verdict = {contract = {level = 3, strain = .Spades, declarer = .North}, dd_tricks = 10, result = 10}, board = 1},
		// 3NT S one off (-50) against 3NT E made (NS -400): +8, though the contracts alone were +13.
		{verdict = {contract = {level = 3, strain = .NoTrumps, declarer = .South}, dd_tricks = 9, result = 8}, board = 2},
		{verdict = {contract = {level = 3, strain = .NoTrumps, declarer = .East}, dd_tricks = 9, result = 9}, board = 3},
		{verdict = {contract = {level = 1, strain = .Clubs, declarer = .North}, dd_tricks = 7, result = 7}, board = 4},
	}
	pairs := pair_rooms(boards, judged)
	testing.expect_value(t, len(pairs), 2)
	if len(pairs) != 2 {
		return
	}
	testing.expect_value(t, pairs[0].swing.?, 6)
	testing.expect_value(t, pairs[0].bid_swing, 6)
	testing.expect_value(t, pairs[1].open_ns.?, -50)
	testing.expect_value(t, pairs[1].closed_ns.?, -400)
	testing.expect_value(t, pairs[1].swing.?, 8)
	testing.expect_value(t, pairs[1].bid_swing, 13)
	totals := tally_rooms(pairs)
	testing.expect_value(t, totals.boards, 2)
	testing.expect_value(t, totals.imps, [2]int{14, 0})
	testing.expect_value(t, totals.bidding, [2]int{19, 0})
	testing.expect_value(t, totals.play, [2]int{0, 5})
}
