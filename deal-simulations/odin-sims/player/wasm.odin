#+build js
// The shared-deals PLAYER: norn compiled to js_wasm32, rendering the card page a link carries (`share`).
// `page.js` (in `player.html`) is the only caller: it hands over the fragment, steps through the boards so it
// can show progress while the card-combination analysis runs (~100ms a board), then takes the page.
package main

import "base:runtime"
import "core:strings"
import "norn:norn"
import "../par_caption"
import "../replay"
import "../sampled"
import "../share"

@(private)
global_context: runtime.Context

// The page being built. Lives until the next `pl_open`; the host copies it out at once.
page: strings.Builder
shared: share.Shared
next_board: int

main :: proc() {
	global_context = context
	page = strings.builder_make(0, 512 * 1024)
}

// Somewhere to write `size` bytes (the fragment). Temp memory: valid until `pl_open` returns.
@(export)
pl_alloc :: proc "c" (size: i32) -> rawptr {
	context = global_context
	free_all(context.temp_allocator)
	bytes, _ := make([]u8, int(size), context.temp_allocator)
	return raw_data(bytes)
}

// Read a link's fragment (without the `#`) and start its page. Returns the number of boards, or minus the
// `share.Decode_Error` when it is not a link this player can read.
@(export)
pl_open :: proc "c" (data: [^]u8, size: i32) -> i32 {
	context = global_context
	share.destroy(shared)
	err: share.Decode_Error
	// On the heap: `combo.annotate` frees all temp memory after each board.
	shared, err = share.decode(string(data[:size]))
	if err != .None {
		shared = {}
		return -i32(err)
	}
	next_board = 0
	strings.builder_reset(&page)
	share.render_start(&page, shared.title)
	return i32(len(shared.boards))
}

// 1 when the link asks for the card-combination analysis (the slow part), else 0.
@(export)
pl_analyse :: proc "c" () -> i32 {
	return 1 if shared.analyse else 0
}

// Render the next board. Returns how many are left.
@(export)
pl_step :: proc "c" () -> i32 {
	context = global_context
	if next_board < len(shared.boards) {
		share.render_board(&page, shared.boards[next_board], shared.analyse)
		next_board += 1
	}
	return i32(len(shared.boards) - next_board)
}

// Finish the page (after the last `pl_step`) and return its length; `pl_result` points at it.
@(export)
pl_finish :: proc "c" () -> i32 {
	context = global_context
	share.render_end(&page)
	return i32(strings.builder_len(page))
}

@(export)
pl_result :: proc "c" () -> rawptr {
	return raw_data(page.buf)
}

// THE PAGE AT ONCE, ANALYSIS AFTER. The whole page WITHOUT `combo`'s analysis (milliseconds), returned like
// `pl_finish`; then `pl_analysis(i)` for each board, in whatever order the reader needs them, and the page adds
// each one (`ncAddAnalysis`). `pl_board_end(i)` is where board `i`'s analysis goes in this page - the newline
// that ends the board - which is what lets `check.mjs` hold the pieces to the page `pl_step` builds.
board_ends: [dynamic]i32
// Where each board's recorded play starts (its `board_end` when it has none): the part the play's costs replace.
play_starts: [dynamic]i32
// Where each 2-hand board's `.par` starts (its play start when it has none): the part the sampling replaces.
par_starts: [dynamic]i32

@(export)
pl_plain :: proc "c" () -> i32 {
	context = global_context
	strings.builder_reset(&page)
	clear(&board_ends)
	clear(&play_starts)
	clear(&par_starts)
	share.render_start(&page, shared.title)
	for board in shared.boards {
		start := strings.builder_len(page)
		share.render_board_head(&page, board, shared.analyse)
		head_end := strings.builder_len(page)
		// The head ends with a 2-hand board's `.par` when it has one.
		par := strings.last_index(string(page.buf[start:head_end]), "\n<div class=\"par\" data-target=")
		append(&par_starts, i32(start + par if par >= 0 && board.known != share.ALL_SEATS else head_end))
		append(&play_starts, i32(head_end))
		share.render_board_play(&page, board)
		append(&board_ends, i32(strings.builder_len(page)))
		strings.write_byte(&page, '\n')
	}
	share.render_end(&page)
	return i32(strings.builder_len(page))
}

@(export)
pl_board_end :: proc "c" (board: i32) -> i32 {
	return board_ends[board] if 0 <= board && int(board) < len(board_ends) else -1
}

@(export)
pl_play_start :: proc "c" (board: i32) -> i32 {
	return play_starts[board] if 0 <= board && int(board) < len(play_starts) else -1
}

// Board `board`'s analysis (the `.combo` element, or nothing), into its own buffer: `pl_piece` points at it.
piece: strings.Builder

@(export)
pl_analysis :: proc "c" (board: i32) -> i32 {
	context = global_context
	strings.builder_reset(&piece)
	if shared.analyse && 0 <= board && int(board) < len(shared.boards) {
		share.render_board_analysis(&piece, shared.boards[board])
	}
	return i32(strings.builder_len(piece))
}

@(export)
pl_piece :: proc "c" () -> rawptr {
	return raw_data(piece.buf)
}

// THE DOUBLE-DUMMY EXPLORER, solved in the reader's browser. DDS is a module of its own (`dds/`, C++ built with
// zig), which this one cannot link, so the page passes the numbers between them: `pl_table_deal(i)` is board
// `i` in DDS's `ddTableDeal` layout (nil unless the whole deal is known), the page has DDS solve it, writes the
// 20 results into `pl_tricks()` (DDS's `resTable`: strain S,H,D,C,NT x hand N,E,S,W), and `pl_exact(i)` writes
// the board's `.sim-exact` element into `piece` - by `par_caption.write_exact_sim`, which the native advisor
// page writes it with too. A board without a recorded play names no contract, so its picker starts at N/S's best.
table_deal: [4][4]u32
tricks_in: [20]i32

@(export)
pl_table_deal :: proc "c" (board: i32) -> rawptr {
	context = global_context
	if board < 0 || int(board) >= len(shared.boards) || shared.boards[board].known != share.ALL_SEATS {
		return nil
	}
	ds := norn.summarize_deal(shared.boards[board].deal)
	for seat in norn.Seat {
		for suit in norn.Suit {
			// DDS orders suits spades first; ranks sit from bit 2 (the deuce) up.
			table_deal[int(seat)][3 - int(suit)] = u32(norn.suit_mask(ds[seat], suit)) << 2
		}
	}
	return &table_deal
}

@(export)
pl_tricks :: proc "c" () -> rawptr {
	return &tricks_in
}

@(export)
pl_exact :: proc "c" (board: i32) -> i32 {
	context = global_context
	strings.builder_reset(&piece)
	if board < 0 || int(board) >= len(shared.boards) || shared.boards[board].known != share.ALL_SEATS {
		return 0
	}
	tricks: par_caption.Tricks
	for strain in par_caption.Strain {
		for hand in par_caption.Hand {
			tricks[strain][hand] = int(tricks_in[int(strain) * 4 + int(hand)])
		}
	}
	// A board played at the table names its contract, which the picker then starts at, as the advisor's does.
	named: Maybe(par_caption.Named_Contract)
	if p, has := shared.boards[board].play.?; has {
		named = par_caption.Named_Contract{p.contract.level, exact_strain(p.contract.strain)}
	}
	strings.write_string(&piece, `<div class="sim-exact" hidden data-sim='`)
	par_caption.write_exact_sim(&piece, &tricks, named)
	strings.write_string(&piece, `'></div>`)
	return i32(strings.builder_len(piece))
}

// norn's contract strain as the explorer's.
@(private)
exact_strain :: proc(strain: norn.Contract_Strain) -> par_caption.Strain {
	switch strain {
	case .Spades:
		return .Spades
	case .Hearts:
		return .Hearts
	case .Diamonds:
		return .Diamonds
	case .Clubs:
		return .Clubs
	case .NoTrumps:
		return .NT
	}
	return .NT
}

// WHAT EACH CARD OF A RECORDED PLAY COST, solved in the reader's browser: the page asks `pl_play_positions(i)`
// for every position of board `i`'s play (`replay.positions`, DDS's `deal` struct each, 96 bytes, at
// `pl_positions()`), has DDS solve each one (`SolveBoard`, every card scored), writes the answers into
// `pl_futures()` (DDS's `futureTricks`, 216 bytes each) and `pl_play(i)` writes the board's `.play` element with
// the costs into `piece` - `replay`'s reading and writing, the native advisor's too. 0 when the answers make no
// sense, and the page keeps the play it has.
positions: replay.Positions
futures: [norn.DECK_SIZE + 1]replay.Dds_Future

@(export)
pl_play_positions :: proc "c" (board: i32) -> i32 {
	context = global_context
	positions = {}
	if board < 0 || int(board) >= len(shared.boards) || shared.boards[board].known != share.ALL_SEATS {
		return 0
	}
	p, has := shared.boards[board].play.?
	if !has || p.play.count == 0 {
		return 0
	}
	positions = replay.positions(shared.boards[board].deal, p.contract, p.play)
	return i32(positions.count)
}

@(export)
pl_positions :: proc "c" () -> rawptr {
	return &positions.deals
}

@(export)
pl_futures :: proc "c" () -> rawptr {
	return &futures
}

@(export)
pl_play :: proc "c" (board: i32) -> i32 {
	context = global_context
	strings.builder_reset(&piece)
	if pl_play_positions(board) == 0 {
		return 0
	}
	p := shared.boards[board].play.?
	cost, ok := replay.costs(&positions, futures[:positions.count], p.play)
	if !ok {
		return 0
	}
	share.render_board_play(&piece, shared.boards[board], cost)
	return i32(strings.builder_len(piece))
}

// THE 2-HAND ADVISOR'S SAMPLING, in the reader's browser: the unseen 26 cards dealt to the defenders up to `cap`
// times (`sampled.generate_layouts`), every layout solved double dummy by the page's DDS workers, and the board's
// `.par` element written from the solved batch (`sampled.advise` + `write_advisor_par`, the advisor's page's
// writers). The page drives it a round at a time so the solving can be spread over several workers and its
// progress shown:
//
//	pl_sample_start(i, cap)            layouts for board i; how many (0 when the board is not a sampled one)
//	pl_sample_deals(from, count)       those layouts in DDS's `ddTableDeal` layout, 16 u32 each
//	pl_sample_tables()                 where the page writes a round's answers (DDS's `ddTableResults`, 80 bytes)
//	pl_sample_round(count)             take them; 1 when the sampling has resolved (or reached the cap)
//	pl_sample_finish(i)                the `.par` element into `piece`, its length
//
// The contract read is the one the link names for the board (`v3.`), else the grid's best (`best_contract`), as
// the advisor picks it when given none; the defender inferences the link names (`v3.`: the record's opening
// lead, a `--lead`, a `--void`/`--len`) hold in every layout, as they did in the advisor's. The layouts are not the native advisor's - `rand` is another sequence on
// wasm32 - so the figures are the same statistics, not the same digits; `pl_sample_load` gives the player the
// native advisor's own layouts instead, which is how `check.mjs` holds the rest to it.
Sampling :: struct {
	board:   int,
	side:    bit_set[norn.Seat],
	a, b:    norn.Seat,
	cap:     int,
	layouts: [dynamic]norn.Deal,
	tables:  [dynamic]sampled.Table,
	grid:    sampled.Grid_Result,
	gating:  sampled.Contract,
	named:   bool, // `gating` is the board's named contract, not the grid's best so far
	cons:    sampled.Board_Constraints, // the defender inferences the link names
}
sampling: Sampling
sample_deals: [sampled.ROUND][4][4]u32
sample_tables: [sampled.ROUND]sampled.Table

// Board `board` as the advisor reads it, and its known side; ok=false unless it is a 2-hand board the page
// analyses (it has a `.par` to put the sampling on).
@(private)
advisor_board :: proc(board: i32) -> (b: norn.Board, side: bit_set[norn.Seat], ok: bool) {
	if !shared.analyse || board < 0 || int(board) >= len(shared.boards) {
		return
	}
	sb := shared.boards[board]
	if sb.known == share.ALL_SEATS || sb.target <= 0 {
		return
	}
	return norn.Board{deal = sb.deal, known = sb.known}, sb.known, true
}

@(private)
sample_begin :: proc(board: i32, cap: i32) -> (pd: norn.Predeal, ok: bool) {
	b, side, is_advisor := advisor_board(board)
	if !is_advisor || cap <= 0 {
		return
	}
	pd, sampling.a, sampling.b, ok = sampled.predeal_side(b, side)
	if !ok {
		return
	}
	sampling.board, sampling.side, sampling.cap = int(board), side, int(cap)
	sampling.grid, sampling.gating, sampling.named = {}, {}, false
	if c, has := shared.boards[board].contract.?; has {
		sampling.gating, sampling.named = c, true
	}
	sampling.cons = shared.boards[board].constraints
	clear(&sampling.tables)
	resize(&sampling.layouts, int(cap))
	return pd, true
}

@(export)
pl_sample_start :: proc "c" (board: i32, cap: i32) -> i32 {
	context = global_context
	pd, ok := sample_begin(board, cap)
	if !ok || !sampled.generate_layouts(pd, 0, sampled.sample_constraints(&sampling.cons), sampling.layouts[:]) {
		clear(&sampling.layouts)
		return 0
	}
	return i32(len(sampling.layouts))
}

// For `check.mjs`: sample board `board` from `count` given layouts (13 bytes each, `share.pack_deal`) instead
// of drawing them, the adaptive stop still judged against `cap`.
@(export)
pl_sample_load :: proc "c" (board: i32, packed: [^]u8, count: i32, cap: i32) -> i32 {
	context = global_context
	if _, ok := sample_begin(board, cap); !ok {
		return 0
	}
	resize(&sampling.layouts, int(count))
	for i in 0 ..< int(count) {
		deal, ok := share.unpack_deal(packed[i * share.PACKED_DEAL_BYTES:(i + 1) * share.PACKED_DEAL_BYTES])
		if !ok {
			clear(&sampling.layouts)
			return 0
		}
		sampling.layouts[i] = deal
	}
	return count
}

@(export)
pl_sample_deals :: proc "c" (from: i32, count: i32) -> rawptr {
	context = global_context
	if from < 0 || count < 0 || count > sampled.ROUND || int(from + count) > len(sampling.layouts) {
		return nil
	}
	for i in 0 ..< int(count) {
		ds := norn.summarize_deal(sampling.layouts[int(from) + i])
		for seat in norn.Seat {
			for suit in norn.Suit {
				sample_deals[i][int(seat)][3 - int(suit)] = u32(norn.suit_mask(ds[seat], suit)) << 2
			}
		}
	}
	return &sample_deals
}

@(export)
pl_sample_tables :: proc "c" () -> rawptr {
	return &sample_tables
}

@(export)
pl_sample_round :: proc "c" (count: i32) -> i32 {
	context = global_context
	if count <= 0 || count > sampled.ROUND {
		return 1
	}
	start := len(sampling.tables)
	append(&sampling.tables, ..sample_tables[:count])
	sampled.tally(&sampling.grid, sampling.tables[start:], sampling.a, sampling.b)
	stop := sampled.adaptive_stop(sampling.grid, &sampling.gating, sampling.named, sampling.cap)
	return 1 if stop || len(sampling.tables) >= len(sampling.layouts) else 0
}

@(export)
pl_sample_finish :: proc "c" (board: i32) -> i32 {
	context = global_context
	strings.builder_reset(&piece)
	b, side, ok := advisor_board(board)
	n := len(sampling.tables)
	if !ok || int(board) != sampling.board || n == 0 {
		return 0
	}
	s := sampled.Solved_Sample {
		layouts = sampling.layouts[:n],
		tables  = sampling.tables[:],
		side    = side,
		a       = sampling.a,
		b       = sampling.b,
		n       = n,
	}
	adv := sampled.advise(b, &s, sampling.gating, sampling.named, sampling.gating)
	defer sampled.advice_free(&adv)
	sb := shared.boards[board]
	sampled.write_advisor_par(&piece, sb.target, side, &adv, sb.contract, sb.constraints)
	return i32(strings.builder_len(piece))
}

// Where board `board`'s `.par` starts in the plain page (`pl_play_start` when it has none): the part the
// sampling replaces, up to `pl_play_start`.
@(export)
pl_par_start :: proc "c" (board: i32) -> i32 {
	return par_starts[board] if 0 <= board && int(board) < len(par_starts) else -1
}
