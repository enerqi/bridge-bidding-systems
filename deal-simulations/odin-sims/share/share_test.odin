#+build !js
package share

import "core:encoding/base64"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:testing"
import "norn:combo"
import "norn:norn"
import "../par_caption"

// A page as the generator writes one (`norn.render_deals`): a random table for every board, optionally the
// card-combination analysis after each. Seeded, so a failure is the same failure next run.
@(private = "file")
generated_page :: proc(count: int, analyse: bool, seed: u64) -> (page: string, deals: []norn.Deal) {
	state := rand.create(seed)
	context.random_generator = rand.default_random_generator(&state)
	b := strings.builder_make()
	deals = make([]norn.Deal, count)
	norn.render_page_prologue(&b, .Html_Cards, "1C opener; South responds 2C/2D")
	for &deal in deals {
		deal = norn.deal_hands()
		norn.render_deal_html_cards(&b, deal, randomize_table = true)
		if analyse {
			combo.annotate(&b, deal, .Html_Cards)
		}
		strings.write_byte(&b, '\n')
	}
	norn.render_page_epilogue(&b, .Html_Cards)
	return strings.to_string(b), deals
}

@(private = "file")
same_hands :: proc(a, b: norn.Deal, seats: bit_set[norn.Seat]) -> bool {
	for seat in seats {
		x, y: [norn.DECK_SIZE]bool
		for card in a[seat] {
			x[card] = true
		}
		for card in b[seat] {
			y[card] = true
		}
		if x != y {
			return false
		}
	}
	return true
}

// THE property the link rests on: a page read back and rebuilt is the page, byte for byte - so the reader of a
// link sees exactly what the sender saw.
@(test)
test_a_generated_page_rebuilds_byte_for_byte :: proc(t: ^testing.T) {
	page, deals := generated_page(24, false, 7)
	defer delete(page)
	defer delete(deals)
	title, boards, ok := boards_from_page(page)
	defer delete(boards)
	testing.expect(t, ok)
	testing.expect_value(t, title, "1C opener; South responds 2C/2D")
	testing.expect_value(t, len(boards), 24)
	for board, i in boards {
		testing.expect(t, same_hands(board.deal, deals[i], ALL_SEATS))
	}

	// Through the link and back, so the format is in the loop too.
	fragment := encode({title = title, boards = boards})
	defer delete(fragment)
	shared, err := decode(fragment)
	defer destroy(shared)
	testing.expect_value(t, err, Decode_Error.None)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render(&b, shared)
	testing.expect(t, strings.to_string(b) == page, "the rebuilt page differs from the generated one")
}

// The same with the card-combination analysis, which the player computes rather than carries.
@(test)
test_an_analysed_page_rebuilds_byte_for_byte :: proc(t: ^testing.T) {
	page, deals := generated_page(3, true, 11)
	defer delete(page)
	defer delete(deals)
	title, boards, ok := boards_from_page(page)
	defer delete(boards)
	testing.expect(t, ok)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render(&b, {title = title, analyse = true, boards = boards})
	testing.expect(t, strings.to_string(b) == page, "the rebuilt analysed page differs")
	combo.shutdown()
}

// A 2-hand board: the two known hands survive, the other two stay face down, and no dealer appears.
@(test)
test_a_two_hand_board_keeps_its_two_hands :: proc(t: ^testing.T) {
	state := rand.create(3)
	context.random_generator = rand.default_random_generator(&state)
	deal := norn.deal_hands()
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	norn.render_page_prologue(&b, .Html_Cards, "Two-hand advisor")
	norn.render_deal_html_cards(&b, deal, known = EAST_WEST)
	strings.write_byte(&b, '\n')
	norn.render_page_epilogue(&b, .Html_Cards)
	page := strings.to_string(b)

	_, boards, ok := boards_from_page(page)
	defer delete(boards)
	testing.expect(t, ok)
	testing.expect_value(t, boards[0].known, EAST_WEST)
	testing.expect(t, same_hands(boards[0].deal, deal, EAST_WEST))
	_, has_dealer := boards[0].table.dealer.?
	testing.expect(t, !has_dealer)

	again := strings.builder_make()
	defer strings.builder_destroy(&again)
	render(&again, {title = "Two-hand advisor", boards = boards})
	testing.expect(t, strings.to_string(again) == page)
}

// Every table and every kind of known-ness through the byte and back.
@(test)
test_the_table_byte_round_trips :: proc(t: ^testing.T) {
	for v in norn.Vulnerability {
		for dealer in 0 ..= 4 {
			for known in ([]bit_set[norn.Seat]{ALL_SEATS, NORTH_SOUTH, EAST_WEST}) {
				table := norn.Table{vulnerability = v}
				if dealer < 4 {
					table.dealer = norn.Seat(dealer)
				}
				back, back_known, ok := unpack_table(pack_table(table, known))
				testing.expect(t, ok)
				testing.expect_value(t, back, table)
				testing.expect_value(t, back_known, known)
			}
		}
	}
}

@(test)
test_48_boards_make_a_896_character_link :: proc(t: ^testing.T) {
	boards := make([]Board, 48)
	defer delete(boards)
	for &board in boards {
		board = {deal = norn.deal_hands(), known = ALL_SEATS}
	}
	fragment := encode({boards = boards})
	defer delete(fragment)
	testing.expect_value(t, len(fragment), len(VERSION_PREFIX) + 899) // (2 + 48 * 14) bytes, base64url unpadded
}

@(test)
test_what_is_not_a_link_is_refused_by_name :: proc(t: ^testing.T) {
	boards := []Board{{deal = norn.deal_hands(), known = ALL_SEATS}}
	fragment := encode({title = "t", boards = boards})
	defer delete(fragment)

	expect_error :: proc(t: ^testing.T, text: string, want: Decode_Error, loc := #caller_location) {
		shared, err := decode(text)
		defer destroy(shared)
		testing.expect_value(t, err, want, loc = loc)
	}
	expect_error(t, "", .Not_A_Share)
	expect_error(t, "v2.AAAA", .Not_A_Share)
	expect_error(t, "v1.not*base64", .Bad_Text)
	expect_error(t, fragment[:len(fragment) - 4], .Truncated)

	// No title, then a board whose every card is North's (all zero bits).
	bytes := make([]u8, 2 + BOARD_BYTES)
	defer delete(bytes)
	everything_north := encode_raw(bytes)
	defer delete(everything_north)
	expect_error(t, everything_north, .Bad_Deal)
}

// `bytes` as a link, whatever they hold - for payloads no encoder would write.
@(private = "file")
encode_raw :: proc(bytes: []u8) -> string {
	text := base64.encode(bytes, base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	return strings.concatenate({VERSION_PREFIX, text})
}

@(test)
test_a_long_title_is_cut_between_characters :: proc(t: ^testing.T) {
	title := strings.repeat("♠", 100) // 3 bytes each
	defer delete(title)
	fragment := encode({title = title})
	defer delete(fragment)
	shared, err := decode(fragment)
	defer destroy(shared)
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect_value(t, len(shared.title), 255)
	testing.expect(t, strings.has_prefix(title, shared.title))
}

// Par travels as the solver's numbers and comes back as the same caption, for every shape a caption takes: a
// made contract with overtricks, a doubled sacrifice, two contracts, a negative score, no contract list, and no
// par at all. The numbers are made up - `share` has no solver - but `par_caption` writes the caption the
// generator writes from real ones (`just sims test-player` checks that with DDS).
@(test)
test_par_rebuilds_byte_for_byte :: proc(t: ^testing.T) {
	state := rand.create(5)
	context.random_generator = rand.default_random_generator(&state)
	contract :: proc(level: int, denom: par_caption.Denom, seats: par_caption.Seats, over := 0, under := 0) -> par_caption.Contract {
		return {level = level, denom = denom, seats = seats, over_tricks = over, under_tricks = under}
	}
	pars := []Board_Par {
		{have = true, par = {score = 420, number = 1, contracts = {0 = contract(4, .Spades, .NS)}}},
		{have = true, par = {score = 300, number = 1, contracts = {0 = contract(5, .Diamonds, .EW, under = 2)}}},
		{have = true, par = {score = 980, number = 2, contracts = {0 = contract(6, .Spades, .NS), 1 = contract(6, .Hearts, .N)}}},
		{have = true, par = {score = -430, number = 1, contracts = {0 = contract(3, .NT, .EW, over = 1)}}},
		{have = true, par = {score = 0}},
		{have = false},
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	norn.render_page_prologue(&b, .Html_Cards, "par")
	for &par in pars {
		for strain in par_caption.Strain {
			for hand in par_caption.Hand {
				par.tricks[strain][hand] = rand.int_max(14)
			}
		}
		deal := norn.deal_hands()
		norn.render_deal_html_cards(&b, deal, randomize_table = true)
		par_caption.write_html_caption(&b, &par.tricks, &par.par, par.have, norn.summarize_deal(deal), cards = true)
		strings.write_byte(&b, '\n')
	}
	norn.render_page_epilogue(&b, .Html_Cards)
	page := strings.to_string(b)

	title, boards, ok := boards_from_page(page)
	defer delete(boards)
	testing.expect(t, ok)
	for board, i in boards {
		got, has := board.par.?
		testing.expect(t, has, "a board's par was not read back")
		testing.expect_value(t, got, pars[i])
	}
	fragment := encode({title = title, boards = boards})
	defer delete(fragment)
	shared, err := decode(fragment)
	defer destroy(shared)
	testing.expect_value(t, err, Decode_Error.None)
	again := strings.builder_make()
	defer strings.builder_destroy(&again)
	render(&again, shared)
	testing.expect(t, strings.to_string(again) == page, "the rebuilt par page differs")
}

// A 2-hand advisor board keeps its CCA: the known pair, the target and `combo` over that pair come back.
@(test)
test_a_two_hand_board_keeps_its_cca :: proc(t: ^testing.T) {
	state := rand.create(9)
	context.random_generator = rand.default_random_generator(&state)
	board := Board {
		deal   = norn.deal_hands(),
		known  = NORTH_SOUTH,
		target = 10,
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render(&b, {title = "Two-hand advisor (declarer + dummy)", analyse = true, boards = []Board{board}})
	page := strings.to_string(b)
	testing.expect(t, strings.contains(page, `<div class="cca-meta" data-known="ns" hidden></div>`))
	testing.expect(t, strings.contains(page, `<div class="combo"`), "no CCA data for the known pair")

	title, boards, ok := boards_from_page(page)
	defer delete(boards)
	testing.expect(t, ok)
	testing.expect_value(t, boards[0].target, 10)
	fragment := encode({title = title, analyse = true, boards = boards})
	defer delete(fragment)
	shared, err := decode(fragment)
	defer destroy(shared)
	testing.expect_value(t, err, Decode_Error.None)
	again := strings.builder_make()
	defer strings.builder_destroy(&again)
	render(&again, shared)
	testing.expect(t, strings.to_string(again) == page, "the rebuilt 2-hand page differs")
	combo.shutdown()
}

// THE GOLDEN LINKS: every link in `testdata/golden_links.txt` must still decode to exactly what it carried
// (`testdata/golden_links.expected`). See that file's header for the rule this holds: a shipped link format is
// frozen, and a new one is a new version, not an edit.
//
// What is compared is the decoded DATA, written out plainly (`describe`), not a rendered page - the card page is
// free to change; what a link MEANS is not. The expected file is recorded once, by this test, when it is missing
// (the run then fails, so a recording is always a deliberate second run). Never re-record it to make this pass.
@(test)
test_every_golden_link_still_reads :: proc(t: ^testing.T) {
	dir := #directory
	links_path := strings.concatenate({dir, "/testdata/golden_links.txt"}, context.temp_allocator)
	expected_path := strings.concatenate({dir, "/testdata/golden_links.expected"}, context.temp_allocator)
	links, lerr := os.read_entire_file_from_path(links_path, context.temp_allocator)
	if !testing.expectf(t, lerr == nil, "cannot read %s", links_path) {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	count := 0
	text := string(links)
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		space := strings.index_byte(line, ' ')
		if !testing.expectf(t, space > 0, "a golden line is <name> <fragment>: %q", line) {
			continue
		}
		name, fragment := line[:space], strings.trim_space(line[space + 1:])
		shared, err := decode(fragment, context.temp_allocator)
		testing.expectf(t, err == .None, "golden link %q no longer decodes: %v", name, err)
		fmt.sbprintf(&b, "== %s\n", name)
		describe(&b, shared)
		count += 1
	}
	testing.expect(t, count > 0, "no golden links")
	got := strings.to_string(b)

	want, werr := os.read_entire_file_from_path(expected_path, context.temp_allocator)
	if werr != nil {
		_ = os.write_entire_file(expected_path, transmute([]u8)got)
		testing.expect(t, false, "recorded testdata/golden_links.expected - check it by eye, then run again")
		return
	}
	// The file may have been checked out with CRLF line ends.
	want_text, _ := strings.replace_all(string(want), "\r\n", "\n", context.temp_allocator)
	if want_text != got {
		lines_got := strings.split_lines(got, context.temp_allocator)
		lines_want := strings.split_lines(want_text, context.temp_allocator)
		for i in 0 ..< max(len(lines_got), len(lines_want)) {
			g := lines_got[i] if i < len(lines_got) else "(nothing)"
			w := lines_want[i] if i < len(lines_want) else "(nothing)"
			if g != w {
				testing.expectf(t, false, "a golden link reads differently (line %d)\n  now:  %s\n  was:  %s", i + 1, g, w)
				break
			}
		}
	}
}

// What a decoded link carries, one line per board, in plain words: the hands, the table, which hands are known,
// and the par numbers or CCA target.
@(private = "file")
describe :: proc(b: ^strings.Builder, shared: Shared) {
	fmt.sbprintf(b, "title %q, analyse %v, %d boards\n", shared.title, shared.analyse, len(shared.boards))
	for board, i in shared.boards {
		fmt.sbprintf(b, "%d: ", i + 1)
		for seat in norn.Seat {
			if seat not_in board.known {
				fmt.sbprintf(b, "%v:- ", seat)
				continue
			}
			line := strings.builder_make(context.temp_allocator)
			norn.write_hand_line(&line, board.deal[seat])
			fmt.sbprintf(b, "%v:%s ", seat, strings.to_string(line))
		}
		fmt.sbprintf(b, "| vul %v, dealer ", board.table.vulnerability)
		if dealer, has_dealer := board.table.dealer.?; has_dealer {
			fmt.sbprintf(b, "%v", dealer)
		} else {
			strings.write_string(b, "none")
		}
		if board.target > 0 {
			fmt.sbprintf(b, ", target %d", board.target)
		}
		if par, has := board.par.?; has {
			if par.have {
				fmt.sbprintf(b, " | par %d", par.par.score)
				for c in par.par.contracts[:par.par.number] {
					fmt.sbprintf(b, " %d%v %v +%d -%d", c.level, c.denom, c.seats, c.over_tricks, c.under_tricks)
				}
			} else {
				strings.write_string(b, " | par n/a")
			}
			strings.write_string(b, " | tricks")
			for strain in par_caption.Strain {
				fmt.sbprintf(b, " %v", strain)
				for hand in par_caption.Hand {
					fmt.sbprintf(b, " %d", par.tricks[strain][hand])
				}
			}
		}
		strings.write_byte(b, '\n')
	}
}
