#+build !js
// The player's REFERENCE side, for `check.mjs`: `native <count> <seed> <out-dir>` writes a card page the way
// the generator does (a random table every board), plus the same page with the card-combination analysis, the
// same again with the double-dummy par caption too (`--par`: DDS, which the player's own module does not
// have), each of that page's boards' `.sim-exact` element as the advisor writes it (`exact.txt`, a line a
// board: the player solves it with DDS in wasm and must write the same), a page whose boards carry recorded
// plays (`played`: random legal ones; `play.txt` is each play's element with what every card cost, solved
// natively, and `played-exact.txt` the explorer naming the contract played), and each page's link fragment READ
// BACK OUT OF THE PAGE (`share.boards_from_page`), as the workbench's `share`
// does. The wasm player must turn each fragment back into its page, byte for byte.
package main

import "core:encoding/base64"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "norn:combo"
import "norn:norn"
import "../deal_solve"
import "../replay"
import "../sampled"
import "../share"

main :: proc() {
	// `native --link <page.html>`: the link fragment for a page already written, as the workbench's `share
	// link` makes it - for a page from anywhere (the analysed advisor's, say), and for checking the page's own
	// Share button against it.
	if len(os.args) == 3 && os.args[1] == "--link" {
		data, err := os.read_entire_file_from_path(os.args[2], context.allocator)
		if err != nil {
			fmt.eprintln("could not read", os.args[2])
			os.exit(1)
		}
		page := string(data)
		title, boards, ok := share.boards_from_page(page)
		if !ok {
			fmt.eprintln("no boards in", os.args[2])
			os.exit(1)
		}
		fmt.println(share.encode({title = title, analyse = strings.contains(page, `<div class="combo"`), boards = boards}))
		return
	}
	if len(os.args) != 4 {
		fmt.eprintln("usage: native <count> <seed> <out-dir> | native --link <page.html>")
		os.exit(2)
	}
	count, _ := strconv.parse_int(os.args[1])
	seed, _ := strconv.parse_u64(os.args[2])
	dir := os.args[3]
	deal_solve.init()

	Kind :: enum {
		Plain,
		Analysed,
		Par,
		Played,
	}
	for kind in Kind {
		analyse := kind != .Plain
		state := rand.create(seed)
		context.random_generator = rand.default_random_generator(&state)
		b := strings.builder_make()
		exact := strings.builder_make()
		costed := strings.builder_make()
		norn.render_page_prologue(&b, .Html_Cards, "Shared deals")
		for i in 0 ..< count {
			deal := norn.deal_hands()
			table := norn.draw_table(.Html_Cards, true)
			norn.render_deal_html_cards_at(&b, deal, table)
			// PLAYED: three boards in four have a recorded play - random, legal, whole or cut short, one in five
			// with a claim's result - as the advisor's page has one from a record (`replay`), unsolved; what it
			// cost goes to `play.txt` for the player's DDS to match.
			board := norn.Board{deal = deal}
			if kind == .Played && i % 4 != 3 {
				contract := norn.Contract{1 + rand.int_max(7), norn.Contract_Strain(rand.int_max(5)), norn.Seat(rand.int_max(4))}
				play := replay.random_play(deal, contract, 52 if i % 2 == 0 else 1 + rand.int_max(51))
				if i % 5 == 1 {
					play.result = rand.int_max(14)
				}
				board.contract, board.play = contract, play
			}
			if kind == .Par || kind == .Played {
				deal_solve.annotate(&b, deal, .Html_Cards, table.vulnerability)
				if ns, ew, ok := deal_solve.exact_grids(deal); ok {
					strings.write_string(&exact, `<div class="sim-exact" hidden data-sim='`)
					deal_solve.write_exact_sim_json(&exact, &ns, &ew, board)
					strings.write_string(&exact, `'></div>`)
				}
				strings.write_byte(&exact, '\n')
			}
			if contract, has := board.contract.?; has {
				play := board.play.?
				replay.write_play_element(&b, deal, contract, play, nil)
				cost, ok := deal_solve.play_cost(deal, contract, play)
				if !ok {
					fmt.eprintln("DDS could not solve a play")
					os.exit(1)
				}
				replay.write_play_element(&costed, deal, contract, play, cost)
			}
			strings.write_byte(&costed, '\n')
			if analyse {
				combo.annotate(&b, deal, .Html_Cards)
			}
			strings.write_byte(&b, '\n')
		}
		norn.render_page_epilogue(&b, .Html_Cards)
		page := strings.to_string(b)

		title, boards, ok := share.boards_from_page(page)
		if !ok {
			fmt.eprintln("the page's boards could not be read back")
			os.exit(1)
		}
		fragment := share.encode({title = title, analyse = analyse, boards = boards})
		names := [Kind]string {
			.Plain    = "plain",
			.Analysed = "analysed",
			.Par      = "par",
			.Played   = "played",
		}
		name := names[kind]
		err1 := os.write_entire_file(fmt.tprintf("%s/%s.html", dir, name), b.buf[:])
		err2 := os.write_entire_file(fmt.tprintf("%s/%s.txt", dir, name), transmute([]u8)fragment)
		err3: os.Error
		switch kind {
		case .Par:
			err3 = os.write_entire_file(fmt.tprintf("%s/exact.txt", dir), exact.buf[:])
		case .Played:
			err3 = os.write_entire_file(fmt.tprintf("%s/played-exact.txt", dir), exact.buf[:])
			if err3 == nil {
				err3 = os.write_entire_file(fmt.tprintf("%s/play.txt", dir), costed.buf[:])
			}
		case .Plain, .Analysed:
		}
		if err1 != nil || err2 != nil || err3 != nil {
			fmt.eprintln("could not write to", dir)
			os.exit(1)
		}
		fmt.printfln("%s: %d boards, page %d bytes, link fragment %d characters", name, len(boards), len(page), len(fragment))
	}
	two_hand_pages(count, seed, dir)
	combo.shutdown()
}

// 2-HAND ADVISOR BOARDS (`twohand`): a page of boards showing only one side's hands, as a link carries them,
// and for each board what the advisor's sampling makes of it - its `.par` element (`sampled.txt`, a line a board),
// sampled natively from `TWO_HAND_CAP` layouts at most - and those layouts (`layouts.txt`: the cap, then each
// layout solved, base64url of 13 bytes each), so the player can be given the same layouts and must write the same
// element. Two boards in three name a contract (a `v3.` link), which the sampling reads instead of the grid's
// best, and every other board a card a defender holds (its opening lead), which every layout gives him. A small cap: node solves each layout in ~0.2s on one thread.
TWO_HAND_CAP :: 40

two_hand_pages :: proc(count: int, seed: u64, dir: string) {
	state := rand.create(seed)
	context.random_generator = rand.default_random_generator(&state)
	boards := make([]share.Board, min(count, 6))
	defer delete(boards)
	pars := strings.builder_make()
	layouts := strings.builder_make()
	for &board, i in boards {
		board = {
			deal   = norn.deal_hands(),
			known  = share.NORTH_SOUTH if i % 2 == 0 else share.EAST_WEST,
			target = 8 + i % 3,
		}
		board.table.vulnerability = norn.Vulnerability(i % 4)
		named: sampled.Contract
		has_named := i % 3 != 2
		if has_named {
			named = {1 + i % 7, sampled.Strain(i % 5)}
			board.contract = named
		}
		// Odd boards: a defender holds one of its cards (an opening lead); every third: the other defender has at
		// most four of a suit (a `--len`) - both of which the link carries to the player's sampling.
		cons := &board.constraints
		leader := norn.Seat.East if board.known == share.NORTH_SOUTH else norn.Seat.North
		if i % 2 == 1 {
			cons.held[0] = {leader, board.deal[leader][i % 13]}
			cons.held_count = 1
		}
		if i % 3 == 0 {
			cons.shape[0] = {norn.Seat((int(leader) + 2) % 4), norn.Suit(i % 4), 0, 4}
			cons.shape_count = 1
		}
		s, gating, ok := deal_solve.solve_sample_adaptive(
			norn.Board{deal = board.deal, known = board.known},
			board.known,
			TWO_HAND_CAP,
			u64(i),
			sampled.sample_constraints(cons),
			target = named,
			has_target = has_named,
		)
		if !ok {
			fmt.eprintln("DDS could not sample a 2-hand board")
			os.exit(1)
		}
		adv := sampled.advise(norn.Board{deal = board.deal, known = board.known}, &s, named, has_named, gating)
		sampled.write_advisor_par(&pars, board.target, board.known, &adv, board.contract, board.constraints)
		sampled.advice_free(&adv)
		strings.write_byte(&pars, 0) // the element starts and ends with a newline: boards are NUL-separated
		packed := make([]u8, len(s.layouts) * share.PACKED_DEAL_BYTES, context.temp_allocator)
		for layout, j in s.layouts {
			share.pack_deal(layout, packed[j * share.PACKED_DEAL_BYTES:])
		}
		fmt.sbprintfln(
			&layouts,
			"%d %s",
			TWO_HAND_CAP,
			base64.encode(packed, base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding}),
		)
		deal_solve.solved_sample_free(&s)
	}
	b := strings.builder_make()
	share.render(&b, {title = "Two-hand advisor (declarer + dummy)", analyse = true, boards = boards})
	page := strings.to_string(b)
	title, read, ok := share.boards_from_page(page)
	if !ok {
		fmt.eprintln("the 2-hand page's boards could not be read back")
		os.exit(1)
	}
	fragment := share.encode({title = title, analyse = true, boards = read})
	errs := [?]os.Error {
		os.write_entire_file(fmt.tprintf("%s/twohand.html", dir), b.buf[:]),
		os.write_entire_file(fmt.tprintf("%s/twohand.txt", dir), transmute([]u8)fragment),
		os.write_entire_file(fmt.tprintf("%s/sampled.txt", dir), pars.buf[:]),
		os.write_entire_file(fmt.tprintf("%s/layouts.txt", dir), layouts.buf[:]),
	}
	for err in errs {
		if err != nil {
			fmt.eprintln("could not write to", dir)
			os.exit(1)
		}
	}
	fmt.printfln("twohand: %d boards, page %d bytes, link fragment %d characters", len(read), len(page), len(fragment))
}
