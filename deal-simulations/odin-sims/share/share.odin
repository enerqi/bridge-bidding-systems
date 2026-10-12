// A set of card-page boards as a LINK: the payload a shared page carries in its URL fragment, and the page
// rebuilt from it (SHARING_PLAN.md, Tier B).
//
// The link is `player.html#v1.<base64url>`. The player is one fixed file (norn compiled to wasm, `player/`)
// that renders the card page from the fragment in the reader's browser, so sharing uploads nothing: the
// static host serves the same file to everyone, and never sees the deals (a fragment is not sent to it).
//
// The payload, before base64url:
//
//	byte 0       flags: bit 0 = run the card-combination analysis (norn:combo) on each board
//	byte 1       the title's length in bytes, then the title (UTF-8, at most 255 bytes)
//	then 14 bytes a board:
//	  13 bytes   the deal: each card's seat in two bits, in norn's card order (`pack_deal`)
//	  1 byte     the table: bits 0-1 vulnerability, bits 2-4 the dealer (0-3 a seat, 4 none),
//	             bits 5-6 which hands are known (0 all four, 1 north-south, 2 east-west),
//	             bit 7 more follows, by the kind of board:
//	  a whole deal: its double-dummy PAR, ~16 bytes (`par_caption.pack`: the trick table and the par result)
//	  a 2-hand deal: 1 byte, the CCA's starting target (tricks)
//
// 48 boards are 672 bytes, 896 characters of link; with par, about 16 bytes a board more. Nothing compresses
// them further: a deal is already dense.
//
// The par is the solver's NUMBERS, not its caption: the player writes the caption from them with the same
// code the generator does (`par_caption`), because the solver itself (DDS) cannot run in a browser. The page
// carries the same bytes on each caption (`data-par`), which is where `boards_from_page` reads them.
//
// No package here touches an engine (no DDS, no Sciter), so the whole format is unit-tested natively and the
// same code is what the wasm player runs.
//
// THE RULE: A SHIPPED FORMAT IS FROZEN. Links live for ever (pasted into chats, forum posts, mail) and the player
// at the published address is replaced whenever the card page changes - it is one address, not one per version,
// so every player must read every link any earlier one was given. So:
//   - nothing above changes meaning for `v1.`: no field reused, no bit given a second job, no reader that now
//     rejects what it used to accept (the unused bits stay zero and are refused, which is what leaves room);
//   - a change is a NEW VERSION (`v2.`), with its own encoder, and the `v1.` decoder STAYS, so old links keep
//     opening in the new player;
//   - `testdata/golden_links.txt` holds real links of every kind, and `test_every_golden_link_still_reads` (plus
//     `just sims test-player`, in the wasm module itself) fails when one stops reading the same. Those goldens
//     are appended to when a new kind of link appears, and never edited or re-recorded to make a test pass.
// The card page may change freely: a link means its DEALS (and their table, par numbers, targets), not a layout.
package share

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "norn:combo"
import "norn:norn"
import "../par_caption"

// What a link starts with. A different format gets a different version; an old player refuses it by name
// rather than misreading it.
VERSION_PREFIX :: "v1."

// The bytes of one board in the payload.
BOARD_BYTES :: PACKED_DEAL_BYTES + 1
PACKED_DEAL_BYTES :: 13
MAX_TITLE_BYTES :: 255

ALL_SEATS :: bit_set[norn.Seat]{.North, .East, .South, .West}
NORTH_SOUTH :: bit_set[norn.Seat]{.North, .South}
EAST_WEST :: bit_set[norn.Seat]{.East, .West}

// One board of a shared page. For a 2-hand deal the unknown seats still hold the other 26 cards (some
// split of them), so `deal` is always a whole deal; `known` says which hands the page shows.
Board :: struct {
	deal:  norn.Deal,
	table: norn.Table,
	known: bit_set[norn.Seat],
	par:   Maybe(Board_Par), // a whole deal's double-dummy par
	// A 2-hand deal's CCA target (the advisor's `.par` div, `data-target`), 0 for none: with it, the player
	// rebuilds that board's card-combination panel - for the known pair, as the advisor does.
	target: int,
}

// A board's double-dummy par, as the solver gave it: what its caption is written from.
Board_Par :: par_caption.Board_Par

Shared :: struct {
	title:   string,
	analyse: bool,
	boards:  []Board,
}

Decode_Error :: enum {
	None,
	Not_A_Share, // no `v1.` prefix: not a link of this kind, or a newer format
	Bad_Text, // not base64url
	Truncated, // the bytes stop part-way through the header or a board
	Bad_Deal, // a seat with other than 13 cards
	Bad_Table, // a table byte with a value no encoder writes
}

// The link fragment (without the `#`) for `shared`.
encode :: proc(shared: Shared, allocator := context.allocator) -> string {
	title := clip_utf8(shared.title, MAX_TITLE_BYTES)
	bytes := make([dynamic]u8, 0, 2 + len(title) + len(shared.boards) * BOARD_BYTES, context.temp_allocator)
	append(&bytes, 1 if shared.analyse else 0, u8(len(title)))
	append(&bytes, title)
	for board in shared.boards {
		deal: [PACKED_DEAL_BYTES]u8
		pack_deal(board.deal, deal[:])
		append(&bytes, ..deal[:])
		par, has_par := board.par.?
		has_target := board.known != ALL_SEATS && board.target > 0
		has_par = has_par && board.known == ALL_SEATS
		append(&bytes, pack_table(board.table, board.known) | (0x80 if has_par || has_target else 0))
		if has_par {
			par_caption.pack(&bytes, par)
		} else if has_target {
			append(&bytes, u8(clamp(board.target, 1, 13)))
		}
	}
	text := base64.encode(bytes[:], base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	return strings.concatenate({VERSION_PREFIX, text}, allocator)
}

// The inverse of `encode`. Everything returned is allocated with `allocator`; free it with `destroy`.
decode :: proc(fragment: string, allocator := context.allocator) -> (shared: Shared, err: Decode_Error) {
	if !strings.has_prefix(fragment, VERSION_PREFIX) {
		return {}, .Not_A_Share
	}
	bytes, berr := base64.decode(
		fragment[len(VERSION_PREFIX):],
		base64.DEC_URL_TABLE,
		allocator = context.temp_allocator,
		options = {.No_Padding},
	)
	if berr != nil {
		return {}, .Bad_Text
	}
	if len(bytes) < 2 || len(bytes) < 2 + int(bytes[1]) {
		return {}, .Truncated
	}
	title_end := 2 + int(bytes[1])
	rest := bytes[title_end:]
	if bytes[0] > 1 {
		return {}, .Bad_Table
	}
	boards := make([dynamic]Board, allocator)
	for len(rest) > 0 {
		if len(rest) < BOARD_BYTES {
			delete(boards)
			return {}, .Truncated
		}
		board: Board
		ok: bool
		if board.deal, ok = unpack_deal(rest); !ok {
			delete(boards)
			return {}, .Bad_Deal
		}
		table := rest[PACKED_DEAL_BYTES]
		if board.table, board.known, ok = unpack_table(table & 0x7F); !ok {
			delete(boards)
			return {}, .Bad_Table
		}
		rest = rest[BOARD_BYTES:]
		if table & 0x80 != 0 && board.known == ALL_SEATS {
			par, used, perr := par_caption.unpack(rest)
			if perr != .None {
				delete(boards)
				return {}, .Truncated if perr == .Truncated else .Bad_Table
			}
			board.par = par
			rest = rest[used:]
		} else if table & 0x80 != 0 {
			if len(rest) < 1 {
				delete(boards)
				return {}, .Truncated
			}
			if rest[0] < 1 || rest[0] > 13 {
				delete(boards)
				return {}, .Bad_Table
			}
			board.target = int(rest[0])
			rest = rest[1:]
		}
		append(&boards, board)
	}
	return {
			title = strings.clone(string(bytes[2:title_end]), allocator),
			analyse = bytes[0] & 1 != 0,
			boards = boards[:],
		},
		.None
}

destroy :: proc(shared: Shared, allocator := context.allocator) {
	delete(shared.title, allocator)
	delete(shared.boards, allocator)
}

// The card page for `shared`: what the generator writes for these boards (`norn.render_deals`, prologue, one
// board a line, epilogue), plus `combo`'s analysis after each full deal when `analyse` is set - as a
// `-cards` page has it, without the suit book's line names. A 2-hand board gets its hands only: the analysed
// advisor's own data (sampling, exact grids) comes from DDS, which the player does not have.
render :: proc(builder: ^strings.Builder, shared: Shared) {
	render_start(builder, shared.title)
	for board in shared.boards {
		render_board(builder, board, shared.analyse)
	}
	render_end(builder)
}

// `render` in parts - start, each board, end - so a caller can build a page a board at a time (the player,
// to show progress while the analysis runs).
render_start :: proc(builder: ^strings.Builder, title: string) {
	norn.render_page_prologue(builder, .Html_Cards, title)
}

render_end :: proc(builder: ^strings.Builder) {
	norn.render_page_epilogue(builder, .Html_Cards)
}

// One board of the page: its compass, its par caption when it has one, then `combo`'s analysis when asked for
// and the deal is whole - the order a `--par` run writes them in (`sim_hooks.dd_and_combo_annotate`). A 2-hand
// board with a target gets the analysed advisor's CCA block instead (`analyse/page.odin`): which pair is known,
// the target, and `combo` over that pair - without the advisor's sampled figures, which need the solver.
render_board :: proc(builder: ^strings.Builder, board: Board, analyse: bool) {
	norn.render_deal_html_cards_at(builder, board.deal, board.table, board.known)
	if board.known != ALL_SEATS {
		if analyse && board.target > 0 {
			fmt.sbprintf(
				builder,
				`<div class="cca-meta" data-known="%s" hidden></div>`,
				"ew" if board.known == EAST_WEST else "ns",
			)
			fmt.sbprintf(builder, "\n<div class=\"par\" data-target=\"%d\" hidden></div>\n", board.target)
			combo.annotate(builder, pair_deal(board), .Html_Cards)
		}
		strings.write_byte(builder, '\n')
		return
	}
	if par, has_par := board.par.?; has_par {
		ds := norn.summarize_deal(board.deal)
		par_caption.write_html_caption(builder, &par.tricks, &par.par, par.have, ds, cards = true)
	}
	if analyse && board.known == ALL_SEATS {
		combo.annotate(builder, board.deal, .Html_Cards)
	}
	strings.write_byte(builder, '\n')
}

// A deal is 52 two-bit seat numbers, one per card in norn's card order (suit*13 + rank): card `c` is bits
// `(c % 4) * 2` of byte `c / 4`. Exactly 13 bytes.
pack_deal :: proc(deal: norn.Deal, out: []u8) {
	for i in 0 ..< PACKED_DEAL_BYTES {
		out[i] = 0
	}
	for seat in norn.Seat {
		for card in deal[seat] {
			c := int(card)
			out[c / 4] |= u8(seat) << uint((c % 4) * 2)
		}
	}
}

// The inverse; `ok` is false unless every seat gets exactly 13 cards. Each hand comes back in card order,
// not the order it was dealt in - the renderer sorts, so a page cannot tell.
unpack_deal :: proc(bytes: []u8) -> (deal: norn.Deal, ok: bool) {
	if len(bytes) < PACKED_DEAL_BYTES {
		return
	}
	filled: [norn.Seat]int
	for c in 0 ..< norn.DECK_SIZE {
		seat := norn.Seat((bytes[c / 4] >> uint((c % 4) * 2)) & 3)
		if filled[seat] == norn.HAND_SIZE {
			return
		}
		deal[seat][filled[seat]] = norn.Card(c)
		filled[seat] += 1
	}
	return deal, true
}

@(private)
NO_DEALER :: 4

@(private)
pack_table :: proc(table: norn.Table, known: bit_set[norn.Seat]) -> u8 {
	dealer := u8(NO_DEALER)
	if seat, has := table.dealer.?; has {
		dealer = u8(seat)
	}
	sides: u8
	switch known {
	case NORTH_SOUTH:
		sides = 1
	case EAST_WEST:
		sides = 2
	}
	return u8(table.vulnerability) | dealer << 2 | sides << 5
}

@(private)
unpack_table :: proc(b: u8) -> (table: norn.Table, known: bit_set[norn.Seat], ok: bool) {
	dealer := (b >> 2) & 7
	sides := (b >> 5) & 3
	if dealer > NO_DEALER || sides > 2 || b & 0x80 != 0 {
		return
	}
	table.vulnerability = norn.Vulnerability(b & 3)
	if dealer != NO_DEALER {
		table.dealer = norn.Seat(dealer)
	}
	switch sides {
	case 0:
		known = ALL_SEATS
	case 1:
		known = NORTH_SOUTH
	case 2:
		known = EAST_WEST
	}
	return table, known, true
}

// `text` cut to at most `limit` bytes without splitting a character.
@(private)
clip_utf8 :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {
		return text
	}
	end := limit
	for end > 0 && text[end] & 0xC0 == 0x80 {
		end -= 1
	}
	return text[:end]
}

// The deal `combo` analyses for a 2-hand board: the known pair as N/S AND as E/W, as the advisor builds it
// (`analyse.synth_deal`), so the panel's other side is the same pair rather than defenders nobody knows.
@(private)
pair_deal :: proc(board: Board) -> norn.Deal {
	a, b: norn.Seat = .North, .South
	if board.known == EAST_WEST {
		a, b = .East, .West
	}
	synth: norn.Deal
	synth[.North], synth[.South] = board.deal[a], board.deal[b]
	synth[.East], synth[.West] = board.deal[a], board.deal[b]
	return synth
}
