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
import "../replay"
import "../sampled"

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

// A page with RECORDED PLAY (the advisor's, from a LIN or PBN record) travels as a `v2.` link and rebuilds byte for
// byte: whole plays and cut ones, a claim's result, a play stopped at a bad card, and boards with no play between
// them. Without a play in the set the link stays `v1.`.
@(test)
test_a_page_with_play_rebuilds_byte_for_byte :: proc(t: ^testing.T) {
	state := rand.create(21)
	context.random_generator = rand.default_random_generator(&state)
	boards := make([]Board, 8)
	defer delete(boards)
	for &board, i in boards {
		board = {deal = norn.deal_hands(), known = ALL_SEATS}
		board.table.vulnerability = norn.Vulnerability(i % 4)
		if i % 3 == 2 {
			continue // no play
		}
		contract := norn.Contract {
			level    = 1 + rand.int_max(7),
			strain   = norn.Contract_Strain(rand.int_max(5)),
			declarer = norn.Seat(rand.int_max(4)),
		}
		play := replay.random_play(board.deal, contract, 52 if i % 2 == 0 else 1 + rand.int_max(51))
		if i == 1 {
			play.result = 9
		}
		if i == 4 {
			play.error, play.error_index = .Revoke, play.count
		}
		board.play = Board_Play{contract, play}
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render(&b, {title = "Played", boards = boards})
	page := strings.to_string(b)
	testing.expect_value(t, strings.count(page, `<div class="play" hidden data-play='`), 6)

	title, read, ok := boards_from_page(page)
	defer delete(read)
	testing.expect(t, ok)
	for board, i in read {
		testing.expect_value(t, board.play, boards[i].play)
	}
	fragment := encode({title = title, boards = read})
	defer delete(fragment)
	testing.expect(t, strings.has_prefix(fragment, VERSION_2_PREFIX), fragment[:3])
	shared, err := decode(fragment)
	defer destroy(shared)
	testing.expect_value(t, err, Decode_Error.None)
	again := strings.builder_make()
	defer strings.builder_destroy(&again)
	render(&again, shared)
	testing.expect(t, strings.to_string(again) == page, "the rebuilt page with play differs")

	// The same boards without their plays are a `v1.` link, as before there were any.
	for &board in read {
		board.play = nil
	}
	plain := encode({title = title, boards = read})
	defer delete(plain)
	testing.expect(t, strings.has_prefix(plain, VERSION_PREFIX), plain[:3])
}

// Every card of many random plays packs and unpacks to itself, and a card its player cannot hold is refused.
@(test)
test_a_play_packs_card_for_card :: proc(t: ^testing.T) {
	state := rand.create(4)
	context.random_generator = rand.default_random_generator(&state)
	for _ in 0 ..< 300 {
		deal := norn.deal_hands()
		contract := norn.Contract{1 + rand.int_max(7), norn.Contract_Strain(rand.int_max(5)), norn.Seat(rand.int_max(4)), .None}
		play := replay.random_play(deal, contract, 1 + rand.int_max(52))
		bytes := make([dynamic]u8, context.temp_allocator)
		replay.pack_play(&bytes, deal, contract, play)
		testing.expect(t, len(bytes) <= 2 + 26, "a whole play is 28 bytes at most")
		back_contract, back, used, ok := replay.unpack_play(bytes[:], deal)
		testing.expect(t, ok && used == len(bytes))
		testing.expect_value(t, back_contract, contract)
		testing.expect_value(t, back, play)
	}
	// An opening lead at index 13: no hand holds 14 cards.
	_, _, _, ok := replay.unpack_play([]u8{1, 0, 13}, norn.deal_hands())
	testing.expect(t, !ok)
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
	expect_error(t, "v4.AAAA", .Not_A_Share)
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

// A 2-hand board's named contract and defender inferences travel (`v3.`): the page carries them as
// `data-contract`, `data-held` and `data-shape`, the link as bytes after the target, and a board without them
// reads as none. Bytes no encoder writes are refused.
@(test)
test_a_two_hand_contract_travels :: proc(t: ^testing.T) {
	state := rand.create(11)
	context.random_generator = rand.default_random_generator(&state)
	boards := []Board {
		{deal = norn.deal_hands(), known = NORTH_SOUTH, target = 10, contract = sampled.Contract{4, .Hearts}},
		{deal = norn.deal_hands(), known = EAST_WEST, target = 9},
		{deal = norn.deal_hands(), known = EAST_WEST, target = 9, contract = sampled.Contract{3, .NT}},
	}
	first := &boards[0].constraints
	first.held[0] = {.East, boards[0].deal[.East][2]}
	first.held[1] = {.West, boards[0].deal[.West][9]}
	first.shape[0] = {.West, .Spades, 0, 3}
	first.held_count, first.shape_count = 2, 1
	boards[1].constraints.shape[0] = {.North, .Hearts, 5, 13}
	boards[1].constraints.shape[1] = {.South, .Clubs, 0, 0}
	boards[1].constraints.shape_count = 2
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render(&b, {title = "Two-hand advisor (declarer + dummy)", analyse = true, boards = boards})
	page := strings.to_string(b)
	testing.expect(t, strings.contains(page, `data-target="9" data-shape="N:H:5-13 S:C:0-0" hidden></div>`))
	testing.expect(t, strings.contains(page, `<div class="par" data-target="9" data-contract="3nt" hidden></div>`))
	testing.expect(t, strings.contains(page, `data-target="10" data-contract="4h" data-held="E:`), "the held cards are on the page")
	testing.expect(t, strings.contains(page, ` data-shape="W:S:0-3" hidden>`))

	title, read, ok := boards_from_page(page)
	defer delete(read)
	testing.expect(t, ok)
	fragment := encode({title = title, analyse = true, boards = read})
	defer delete(fragment)
	testing.expect(t, strings.has_prefix(fragment, VERSION_3_PREFIX), "a named 2-hand contract makes a v3. link")
	shared, err := decode(fragment)
	defer destroy(shared)
	testing.expect_value(t, err, Decode_Error.None)
	for board, i in shared.boards {
		testing.expectf(t, board.contract == boards[i].contract, "board %d: %v, want %v", i + 1, board.contract, boards[i].contract)
		testing.expectf(t, board.constraints == boards[i].constraints, "board %d: %v, want %v", i + 1, board.constraints, boards[i].constraints)
	}
	again := strings.builder_make()
	defer strings.builder_destroy(&again)
	render(&again, shared)
	testing.expect(t, strings.to_string(again) == page, "the rebuilt 2-hand page differs")

	// Without a contract or an inference the same boards are a v1. link, as before.
	boards[1].constraints = {}
	plain := encode({title = title, analyse = true, boards = boards[1:2]})
	defer delete(plain)
	testing.expect(t, strings.has_prefix(plain, VERSION_PREFIX))

	// The first board's bytes after its target: the contract, the count (2 held, 1 length), the two held cards,
	// the length's two bytes. Each broken alone is refused.
	at := 2 + len(title) + BOARD_BYTES + 1
	refused :: proc(t: ^testing.T, fragment: string, at: int, value: u8, why: string) {
		bytes, _ := base64.decode(fragment[3:], base64.DEC_URL_TABLE, allocator = context.temp_allocator, options = {.No_Padding})
		bytes[at] = value
		broken := strings.concatenate({VERSION_3_PREFIX, base64.encode(bytes, base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})})
		defer delete(broken)
		bad, err := decode(broken)
		defer destroy(bad)
		testing.expectf(t, err == .Bad_Table, "%s: %v", why, err)
	}
	refused(t, fragment, at, u8(sampled.Strain.Hearts) << 3, "a contract of level 0")
	refused(t, fragment, at + 2, 1 | u8(norn.Seat.North) << 6, "a held card on a known seat")
	refused(t, fragment, at + 4, u8(norn.Seat.North), "a length on a known seat")
	refused(t, fragment, at + 4, u8(norn.Seat.West) | 5 << 4, "a length's fewest above its most")
	refused(t, fragment, at + 5, 14, "a length above 13")
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
		if c, has := board.contract.?; has {
			fmt.sbprintf(b, ", contract %d%v", c.level, c.strain)
		}
		cons := board.constraints
		for h in cons.held[:cons.held_count] {
			fmt.sbprintf(b, ", %v holds %s", h.seat, replay.card_word(h.card))
		}
		for c in cons.shape[:cons.shape_count] {
			fmt.sbprintf(b, ", %v has %d-%d %v", c.seat, c.min, c.max, c.suit)
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
		if p, has := board.play.?; has {
			fmt.sbprintf(
				b,
				" | play %d%s %v:",
				p.contract.level,
				replay.contract_strain_word(p.contract.strain),
				p.contract.declarer,
			)
			for card in p.play.cards[:p.play.count] {
				fmt.sbprintf(b, " %s", replay.card_word(card))
			}
			if res, has_res := p.play.result.?; has_res {
				fmt.sbprintf(b, ", result %d", res)
			}
			if p.play.error != .None {
				fmt.sbprintf(b, ", %v at %d", p.play.error, p.play.error_index)
			}
		}
		strings.write_byte(b, '\n')
	}
}
