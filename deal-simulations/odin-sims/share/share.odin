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
// `v2.` (2026-10-13) is the same, plus ONE MORE PART after each board: its recorded play (`replay.pack_play`:
// the contract and each card as a 4-bit index into its player's hand, ~30 bytes for a whole play), or a zero
// byte for a board without one. Only a set with a play in it is written as `v2.`; every other link is still
// `v1.`, byte for byte what it was.
//
// `v3.` (2026-10-13) is `v2.` plus, after a 2-hand board's target byte, what its sampling is to be read for and
// conditioned on, so a reader's sampling reads that contract over the layouts the advisor's page dealt:
//   1 byte     the CONTRACT: bits 0-2 the level (0 = none named), bits 3-5 the strain (`par_caption.Strain`:
//              spades, hearts, diamonds, clubs, notrumps)
//   1 byte     how many defender inferences follow: bits 0-3 held cards, bits 4-7 suit lengths
//   1 byte     each HELD CARD (the record's opening lead, a `--lead`): bits 0-5 the card plus one in norn's card
//              order, bits 6-7 the seat holding it
//   2 bytes    each SUIT LENGTH (a `--void`, a `--len`): bits 0-1 the seat, bits 2-3 the suit (norn's order:
//              clubs, diamonds, hearts, spades), bits 4-7 the fewest cards; then the most cards
// Written only when some 2-hand board has a contract or an inference. Every inference names a defender, and a
// held card is one no known hand holds; anything else is refused.
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
import "../replay"
import "../sampled"

// Where this project publishes the player (`just sims publish-player`): the address links open unless the
// program writing them is told another (the workbench's `share.player` setting, `SHARE_PLAYER` for `sim`).
PUBLISHED_PLAYER :: "https://bridge-workbench.netlify.app/player.html"

// Is `address` something a link can start with: a web address, or a `file:` one (this computer only)?
// Anything else - a bare path, a typo'd scheme - would make links that open nothing.
usable_player_address :: proc(address: string) -> bool {
	for scheme in ([]string{"https://", "http://", "file:///"}) {
		if len(address) > len(scheme) && strings.equal_fold(address[:len(scheme)], scheme) {
			return true
		}
	}
	return false
}

// What a link starts with. A different format gets a different version; an old player refuses it by name
// rather than misreading it.
VERSION_PREFIX :: "v1."
// The format with each board's recorded play (see the top).
VERSION_2_PREFIX :: "v2."
// That, with each 2-hand board's contract (see the top).
VERSION_3_PREFIX :: "v3."

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
	// A whole deal's recorded play, for the card page's replay bar (`v2.` links only).
	play:   Maybe(Board_Play),
	// A 2-hand deal's named contract (the advisor's `.par` div, `data-contract`), for the reader's sampling
	// (`v3.` links only; needs a `target`).
	contract: Maybe(sampled.Contract),
	// A 2-hand deal's defender inferences (`data-held`, `data-shape`), which the reader's sampling is conditioned
	// on (`v3.` links only; needs a `target`).
	constraints: sampled.Board_Constraints,
}

// A recorded play and the contract it was played in (`replay`).
Board_Play :: struct {
	contract: norn.Contract,
	play:     norn.Play,
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
	Not_A_Share, // no `v1.`/`v2.`/`v3.` prefix: not a link of this kind, or a newer format
	Bad_Text, // not base64url
	Truncated, // the bytes stop part-way through the header or a board
	Bad_Deal, // a seat with other than 13 cards
	Bad_Table, // a table byte with a value no encoder writes
	Bad_Play, // a recorded play that is not one (`v2.`)
}

// The link fragment (without the `#`) for `shared`.
encode :: proc(shared: Shared, allocator := context.allocator) -> string {
	title := clip_utf8(shared.title, MAX_TITLE_BYTES)
	with_play, with_contract := false, false
	for board in shared.boards {
		if _, has := board.play.?; has && board.known == ALL_SEATS {
			with_play = true
		}
		_, has_contract := board.contract.?
		has_inference := board.constraints.held_count > 0 || board.constraints.shape_count > 0
		if (has_contract || has_inference) && board.known != ALL_SEATS && board.target > 0 {
			with_contract = true
		}
	}
	with_play ||= with_contract // `v3.` has `v2.`'s play parts too
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
			if with_contract {
				append(&bytes, pack_contract(board.contract))
				pack_constraints(&bytes, board.constraints)
			}
		}
		if with_play {
			if p, has := board.play.?; has && board.known == ALL_SEATS && p.play.count > 0 {
				replay.pack_play(&bytes, board.deal, p.contract, p.play)
			} else {
				append(&bytes, 0)
			}
		}
	}
	text := base64.encode(bytes[:], base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	version := VERSION_3_PREFIX if with_contract else VERSION_2_PREFIX if with_play else VERSION_PREFIX
	return strings.concatenate({version, text}, allocator)
}

// The inverse of `encode`. Everything returned is allocated with `allocator`; free it with `destroy`.
decode :: proc(fragment: string, allocator := context.allocator) -> (shared: Shared, err: Decode_Error) {
	with_contract := strings.has_prefix(fragment, VERSION_3_PREFIX)
	with_play := with_contract || strings.has_prefix(fragment, VERSION_2_PREFIX)
	if !with_play && !strings.has_prefix(fragment, VERSION_PREFIX) {
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
			if with_contract {
				if len(rest) < 1 {
					delete(boards)
					return {}, .Truncated
				}
				if board.contract, ok = unpack_contract(rest[0]); !ok {
					delete(boards)
					return {}, .Bad_Table
				}
				used, cerr := unpack_constraints(rest[1:], &board)
				if cerr != .None {
					delete(boards)
					return {}, cerr
				}
				rest = rest[1 + used:]
			}
		}
		if with_play {
			if len(rest) < 1 {
				delete(boards)
				return {}, .Truncated
			}
			if rest[0] == 0 {
				rest = rest[1:]
			} else {
				contract, play, used, play_ok := replay.unpack_play(rest, board.deal)
				if !play_ok || board.known != ALL_SEATS {
					delete(boards)
					return {}, .Bad_Play
				}
				board.play = Board_Play{contract, play}
				rest = rest[used:]
			}
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
	render_board_shell(builder, board, analyse)
	if analyse {
		render_board_analysis(builder, board)
	}
	strings.write_byte(builder, '\n')
}

// `render_board` without `combo`'s analysis (and without the newline that ends a board): everything that costs
// nothing. The player shows a page of these at once and adds each board's analysis as it is computed, so the
// two halves are cut where the analysis starts and together are exactly `render_board`.
render_board_shell :: proc(builder: ^strings.Builder, board: Board, analyse: bool) {
	render_board_head(builder, board, analyse)
	render_board_play(builder, board)
}

// The shell up to its recorded play: where the player cuts it, to swap the play for one with its costs.
render_board_head :: proc(builder: ^strings.Builder, board: Board, analyse: bool) {
	norn.render_deal_html_cards_at(builder, board.deal, board.table, board.known)
	if board.known != ALL_SEATS {
		if analyse && board.target > 0 {
			fmt.sbprintf(
				builder,
				`<div class="cca-meta" data-known="%s" hidden></div>`,
				"ew" if board.known == EAST_WEST else "ns",
			)
			sampled.write_advisor_par(builder, board.target, board.known, nil, board.contract, board.constraints)
		}
		return
	}
	if par, has_par := board.par.?; has_par {
		ds := norn.summarize_deal(board.deal)
		par_caption.write_html_caption(builder, &par.tricks, &par.par, par.have, ds, cards = true)
	}
}

// A whole deal's recorded play, as the `.play` element the page replays it from (the last part of the shell,
// so the player can swap it for one with the costs). `cost` is what each card cost, when it has been worked out:
// the advisor's DDS, or the player's DDS in wasm when the reader asks.
render_board_play :: proc(builder: ^strings.Builder, board: Board, cost: Maybe(replay.Play_Cost) = nil) {
	if p, has := board.play.?; has && board.known == ALL_SEATS && p.play.count > 0 {
		replay.write_play_element(builder, board.deal, p.contract, p.play, cost)
	}
}

// `combo`'s analysis of one board (the `.combo` element), for a link that asks for it: nothing for a 2-hand
// board without a target, which the advisor did not analyse either. The slow part, ~0.1s a board in a browser.
render_board_analysis :: proc(builder: ^strings.Builder, board: Board) {
	if board.known == ALL_SEATS {
		combo.annotate(builder, board.deal, .Html_Cards)
	} else if board.target > 0 {
		combo.annotate(builder, pair_deal(board), .Html_Cards)
	}
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

// A 2-hand board's contract byte (`v3.`): 0 for none.
@(private)
pack_contract :: proc(contract: Maybe(sampled.Contract)) -> u8 {
	c, has := contract.?
	if !has {
		return 0
	}
	return u8(clamp(c.level, 1, 7)) | u8(c.strain) << 3
}

// The inverse; ok=false for a byte no encoder writes.
@(private)
unpack_contract :: proc(b: u8) -> (contract: Maybe(sampled.Contract), ok: bool) {
	level, strain := int(b & 7), int(b >> 3)
	if b == 0 {
		return nil, true
	}
	if level == 0 || strain > int(max(sampled.Strain)) {
		return nil, false
	}
	return sampled.Contract{level, sampled.Strain(strain)}, true
}

// A 2-hand board's defender inferences (`v3.`, see the top): the count byte, then each held card, then each
// suit length.
@(private)
pack_constraints :: proc(bytes: ^[dynamic]u8, cons: sampled.Board_Constraints) {
	append(bytes, u8(cons.held_count) | u8(cons.shape_count) << 4)
	for i in 0 ..< cons.held_count {
		h := cons.held[i]
		append(bytes, u8(int(h.card) + 1) | u8(h.seat) << 6)
	}
	for i in 0 ..< cons.shape_count {
		c := cons.shape[i]
		append(bytes, u8(c.seat) | u8(c.suit) << 2 | u8(clamp(c.min, 0, 13)) << 4, u8(clamp(c.max, 0, 13)))
	}
}

// The inverse, into `board.constraints` (`board`'s deal and known hands already read): how many bytes it used.
// A held card with no card, on a known seat, or that a known hand holds, or a length on a known seat or with
// bounds out of order, is `.Bad_Table`.
@(private)
unpack_constraints :: proc(rest: []u8, board: ^Board) -> (used: int, err: Decode_Error) {
	if len(rest) < 1 {
		return 0, .Truncated
	}
	held_count, shape_count := int(rest[0] & 0xF), int(rest[0] >> 4)
	used = 1 + held_count + 2 * shape_count
	if len(rest) < used {
		return 0, .Truncated
	}
	cons := &board.constraints
	for b in rest[1:][:held_count] {
		c := int(b & 0x3F) - 1
		seat := norn.Seat(b >> 6)
		if c < 0 || c >= norn.DECK_SIZE || seat in board.known {
			return 0, .Bad_Table
		}
		card := norn.Card(c)
		for known in board.known {
			for held in board.deal[known] {
				if held == card {
					return 0, .Bad_Table
				}
			}
		}
		cons.held[cons.held_count] = {seat, card}
		cons.held_count += 1
	}
	shapes := rest[1 + held_count:][:2 * shape_count]
	for i := 0; i < len(shapes); i += 2 {
		seat, suit := norn.Seat(shapes[i] & 3), norn.Suit(shapes[i] >> 2 & 3)
		least, most := int(shapes[i] >> 4), int(shapes[i + 1])
		if seat in board.known || least > most || most > 13 {
			return 0, .Bad_Table
		}
		cons.shape[cons.shape_count] = {seat, suit, least, most}
		cons.shape_count += 1
	}
	return used, .None
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
