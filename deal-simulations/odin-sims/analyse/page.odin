package analyse

/*
	page.odin — the interactive card page (part of package `analyse`; see analyse.odin).

	Assembly only: the page shell and the per-board bakes come from `norn:norn` (renderer), `deal_solve`
	(the sim/exact JSON) and `norn:combo` (the CCA blob). `write_html` writes a file; a caller that wants
	the page in memory — the workbench, hosting it in a window — uses `render_page` instead.
*/

import "core:fmt"
import "core:os"
import "core:strings"

import "../deal_solve"
import "../replay"
import "../sampled"
import "norn:combo"
import "norn:norn"

// Write a self-contained interactive card page for the 2-hand board: the declarer+dummy compass with
// the defenders face-down, plus the norn card page's CCA overlay. Reuses the full page shell
// (`render_page_prologue`/`_epilogue`) and `combo.annotate` unchanged: the combo blob is emitted from a
// SYNTHESISED deal that duplicates the known pair into BOTH partnerships, so the page's N/S<->E/W
// toggle shows the known-side analysis whichever way it is flipped (there is only one known side). The
// slider target is seeded via a hidden `.par[data-target]` (no DDS par exists with two hands).
//
// Write the interactive card page for ALL `boards` (one carousel). One page shell wraps every board; each
// board renders its compass + hidden `.par` (target/sim/leads bakes) + `.combo` blob (see
// render_board_body). A board that is not a valid 2-hand input gets a small note and the run continues.
// Returns "" on success, else an error message.
write_html :: proc(
	path: string,
	boards: []norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
	sink: Sink,
) -> string {
	page := render_page(boards, args, contract, has_contract, sink)
	defer delete(page)

	if werr := os.write_entire_file(path, transmute([]u8)page); werr != nil {
		return fmt.tprintf("could not write %q: %v", path, werr)
	}
	return ""
}

// The card page for `boards` as a string (caller-owned, on `context.allocator`). The half of `write_html`
// that does not touch the filesystem — for a host that loads the page directly.
render_page :: proc(
	boards: []norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
	sink: Sink,
) -> string {
	b := strings.builder_make()

	// Title reflects the input: all full 4-hand deals -> exact double-dummy analysis; all 2-hand -> the
	// advisor; a mix -> a neutral label.
	n_full := 0
	for board in boards {
		if board_fully_known(board) {
			n_full += 1
		}
	}
	title := "Two-hand advisor (declarer + dummy)"
	if n_full == len(boards) {
		title = "Bridge deal analysis (double-dummy + CCA)"
	} else if n_full > 0 {
		title = "Bridge deal analysis"
	}
	// A match record names itself: the event, the stage and the two teams, when every board is from it.
	if match := match_title(boards); match != "" {
		title = match
	}
	norn.render_page_prologue(&b, .Html_Cards, title)
	// Each board with a contract and all four hands is judged against double dummy as it is drawn (its table is
	// the one just solved for the caption, its play's cost the one just baked), for the page's match table.
	judged := make([dynamic]Judged)
	defer delete(judged)
	skipped, slide := 0, 0
	for board, i in boards {
		report_progress(sink, i, len(boards))
		drawn, cost := render_board_body(&b, board, args, contract, has_contract, sink)
		judge: if board.contract != nil && board_fully_known(board) {
			tricks, par_ns, have_par, ok := deal_solve.board_par(board.deal, board.conditions.vulnerability)
			if !ok {
				skipped += 1
				break judge
			}
			par: Maybe(int)
			if have_par {
				par = par_ns
			}
			append(&judged, Judged{judge_board(board, "", tricks, par, cost), i, slide})
		} else {
			skipped += 1
		}
		if drawn {
			slide += 1
		}
	}
	// A table of one board says nothing the board does not.
	if len(judged) >= 2 {
		write_match_element(&b, boards, judged[:], skipped)
	}
	report_progress(sink, len(boards), len(boards))
	norn.render_page_epilogue(&b, .Html_Cards)
	return strings.to_string(b)
}

// Render a fully-known 4-hand deal into the page builder `b`: all four hands face-up, then the EXACT
// double-dummy caption (`deal_solve.annotate` Html_Cards: the `.par` div with par + NS-makeable + the CCA slider's
// `data-target`, from ONE solve of the actual deal), then the per-partnership combo (CCA) census for BOTH
// sides (`combo.annotate` on the real deal). No `data-sim`: with the deal known, double-dummy is the exact
// verdict — there is no sampling ceiling to show and no misguess-tax rung (that models unknown defenders).
// This is exactly the sim card-page flow (deal_solve.annotate then combo.annotate) for a board fed as PBN.
render_full_deal_body :: proc(
	b: ^strings.Builder,
	board: norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
) -> (
	cost: Maybe(deal_solve.Play_Cost),
) {
	// At the record's dealer and vulnerability (`conditions`), which the par is worked out at too.
	norn.render_deal_html_cards_at(b, board.deal, board.conditions, board.known)
	write_table_element(b, board.table) // after the compass: the page groups a board's elements from it
	deal_solve.annotate(b, board.deal, .Html_Cards, board.conditions.vulnerability)
	// Exact double-dummy grids (one per side) so the card page's contract picker + trick slider come alive
	// on the known deal (spikes at each strain's DD tricks; the band relabels to "double-dummy (exact)").
	// Carried on its own hidden element — deal_solve.annotate owns the `.par` div — which render.odin reads as the
	// board's data-sim source. With `--sample` we ALSO bake the BLIND advisor per side (sample_board ignores
	// the known defenders and randomises the other 26, i.e. "play it as if you can't see all four hands"),
	// so the page can toggle exact ↔ blind for either partnership. solve_table is cached (deal_solve.annotate's).
	if ns_grid, ew_grid, ok := deal_solve.exact_grids(board.deal); ok {
		strings.write_string(b, `<div class="sim-exact" hidden data-sim='`)
		deal_solve.write_exact_sim_json(b, &ns_grid, &ew_grid, board)
		strings.write_string(b, `'`)
		if args.sample > 0 {
			strings.write_string(b, ` data-sim-blind='`)
			write_blind_sides_json(b, board, args, contract, has_contract)
			strings.write_string(b, `'`)
		}
		strings.write_string(b, `></div>`)
	}
	strings.write_string(b, `<div class="cca-meta" data-known="all" hidden></div>`)
	cost = write_play_element(b, board)
	combo.annotate(b, board.deal, .Html_Cards)
	return
}

// The board's recorded play as the hidden `.play` element the card page replays it from, every card solved
// double dummy (see deal_solve/play_cost.odin). Nothing for a board with no play or no contract. A failed
// solve still writes the play, without the per-card numbers. The element carries the play's bytes too
// (`data-pack`), which is what puts it in a share link. Returns the costs, for the match table.
write_play_element :: proc(b: ^strings.Builder, board: norn.Board) -> (cost: Maybe(deal_solve.Play_Cost)) {
	contract, has_contract := board.contract.?
	play, has_play := board.play.?
	if !has_contract || !has_play || play.count == 0 {
		return
	}
	if c, ok := deal_solve.play_cost(board.deal, contract, play); ok {
		cost = c
	}
	replay.write_play_element(b, board.deal, contract, play, cost)
	return
}

// Bake the BLIND (DDS-sampled) advisor grids for BOTH partnerships of a known deal: `{"ns":<sim>,"ew":<sim>}`
// where each `<sim>` is the same shape write_sim_json emits for a 2-hand board (n/lvl/strain/g plus the
// misguess-tax ach/taxpts/pvt AND the nested opening-lead sub-grids, so each side drives its own lead picker
// in Blind mode). sample_board treats the named side as declarer+dummy and randomises the
// other 26 cards, so this is exactly "how would this side fare playing blind". A side that fails to sample
// is emitted as null.
write_blind_sides_json :: proc(
	b: ^strings.Builder,
	board: norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
) {
	// The recorded opening lead pre-selects the picker, but only on the side it defends against (its leader is
	// one of that side's defenders). ns_lseat/ew_lseat stay 0 (unset) otherwise, and for a board with no lead.
	ns_lseat, ew_lseat: u8 = 0, 0
	ns_lword, ew_lword: string = "", ""
	if lead, has := board.opening_lead.?; has {
		if lead.leader not_in combo.NS_SIDE { 	// leader is E/W -> a defender for N/S
			ns_lseat, ns_lword = deal_solve.seat_letter(lead.leader), deal_solve.card_word(lead.card)
		}
		if lead.leader not_in combo.EW_SIDE { 	// leader is N/S -> a defender for E/W
			ew_lseat, ew_lword = deal_solve.seat_letter(lead.leader), deal_solve.card_word(lead.card)
		}
	}

	strings.write_byte(b, '{')
	bs_ns, _ := sample_board(board, combo.NS_SIDE, args, contract, has_contract)
	defer board_sample_free(&bs_ns)
	strings.write_string(b, `"ns":`)
	if bs_ns.have {
		deal_solve.write_sim_json(
			b,
			&bs_ns.grid,
			bs_ns.contract,
			bs_ns.tax,
			bs_ns.tax_ok,
			bs_ns.leads,
			combo.NS_SIDE,
			ns_lseat,
			ns_lword,
			bs_ns.lead_tax,
		)
	} else {
		strings.write_string(b, "null")
	}
	bs_ew, _ := sample_board(board, combo.EW_SIDE, args, contract, has_contract)
	defer board_sample_free(&bs_ew)
	strings.write_string(b, `,"ew":`)
	if bs_ew.have {
		deal_solve.write_sim_json(
			b,
			&bs_ew.grid,
			bs_ew.contract,
			bs_ew.tax,
			bs_ew.tax_ok,
			bs_ew.leads,
			combo.EW_SIDE,
			ew_lseat,
			ew_lword,
			bs_ew.lead_tax,
		)
	} else {
		strings.write_string(b, "null")
	}
	strings.write_byte(b, '}')
}

// Render ONE board into the page builder `b`: the declarer+dummy compass (defenders face-down), a hidden
// `.par` div carrying the CCA slider target and — when --sample is on — the `data-sim` contract grid and
// `data-sim-leads` opening-lead sub-grids, then the `.combo` analysis blob. combo.annotate reads a full
// Deal, so it is fed the known pair duplicated into both sides (synth_deal). A non-2-hand board writes a
// note instead. Reports (does not fail the page) a per-board sampling error to `sink.err`. `drawn` says whether
// the board has a slide on the page (a note has none); `cost` is its play's, for a four-hand board with one.
render_board_body :: proc(
	b: ^strings.Builder,
	board: norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
	sink: Sink,
) -> (
	drawn: bool,
	cost: Maybe(deal_solve.Play_Cost),
) {
	_, side, ok := combo.analyse_board(board)
	if !ok {
		if board_fully_known(board) {
			return true, render_full_deal_body(b, board, args, contract, has_contract)
		}
		strings.write_string(b, `<div class="par">Not a 2-hand board (need declarer + dummy, defenders '-').</div>`)
		return
	}
	drawn = true
	sd, _, _ := combo.sd_bundle_board(board)

	bs, serr := sample_board(board, side, args, contract, has_contract)
	defer board_sample_free(&bs)
	if serr != "" {
		fmt.wprintfln(sink.err, "%s: %s", PROGRAM, serr)
	}

	norn.render_deal_html_cards_at(b, board.deal, board.conditions, board.known)
	write_table_element(b, board.table) // after the compass: the page groups a board's elements from it
	// The real known side, so the CCA panel locks its toggle here (the other side is this pair duplicated).
	fmt.sbprintf(b, `<div class="cca-meta" data-known="%s" hidden></div>`, deal_solve.side_key(side))

	named: Maybe(deal_solve.Contract)
	if c, has := sampled.named_contract(board, side, contract, has_contract); has {
		named = c
	}
	// Seed the CCA target slider. Prefer the contract level (level+6 tricks) when sampling or when the board
	// names one, else the user's --target, else a sensible default = the achievable single-dummy expected total.
	tgt := args.target
	if bs.have && tgt <= 0 {
		tgt = clamp(bs.contract.level + 6, 1, 13)
	}
	if c, has := named.?; has && tgt <= 0 {
		tgt = clamp(c.level + 6, 1, 13)
	}
	if tgt <= 0 {
		tgt = clamp(int(combo.expected_tricks(sd.totsd) + 0.5), 1, 13)
	}
	// The `.par` carries the target, the named contract and the defender inferences the sampling is conditioned
	// on (all of which a share link carries) and, when sampled, the grid, the lead sub-grids and the per-suit
	// blind two-way GUESS notes (only when a guess costs something at this contract) - written by `sampled`, as
	// the shared-deals player writes it. `parse_args` holds the inferences to what fits.
	cons, _ := sampled.board_constraints({shape = args.constraints[:], held = held_cards(board, args)})
	sampled.write_advisor_par(b, tgt, side, &bs, named, cons)

	combo.annotate(b, synth_deal(board, side), .Html_Cards)
	return
}

// The board's identity, for the page: a hidden `.board-table` the script reads to label the board ("Board 13 ·
// Open") and to put the players' names by their seats. Nothing for a board whose record names none of it.
//
//	{"n":13,"room":"Open","players":{"N":"BG PIT","E":"WEWEN","S":"JONI","W":"ANDRI"}}
write_table_element :: proc(b: ^strings.Builder, table: norn.Board_Table) {
	named := false
	for name in table.players {
		named = named || name != ""
	}
	if table.number == 0 && table.room == .Unknown && !named {
		return
	}
	strings.write_string(b, `<div class="board-table" hidden data-table='`)
	strings.write_byte(b, '{')
	fmt.sbprintf(b, `"n":%d`, table.number)
	if table.room != .Unknown {
		fmt.sbprintf(b, `,"room":"%v"`, table.room)
	}
	if named {
		strings.write_string(b, `,"players":{`)
		for seat, i in norn.Seat {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, `"%c":`, deal_solve.seat_letter(seat))
			write_attr_json_string(b, table.players[seat])
		}
		strings.write_byte(b, '}')
	}
	strings.write_string(b, `}'></div>`)
}

// A JSON string that is safe inside a SINGLE-quoted HTML attribute: JSON's own escapes, plus `'`, `&` and `<`
// as character references (the attribute is decoded before the script parses it). Names come from the record.
write_attr_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\'':
			strings.write_string(b, "&#39;")
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case:
			if r < 0x20 {
				fmt.sbprintf(b, `\u%04x`, r)
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}

// "PORPROV SUMBAR X16 2026 · RR1-2 · KAB TANAH DATAR v KOTA PADANG", when every board shares one event; "" when
// the boards name none, or several. Plain text: the page shell escapes nothing, so `<` and `&` are dropped.
match_title :: proc(boards: []norn.Board) -> string {
	if len(boards) == 0 || boards[0].table.event == "" {
		return ""
	}
	first := boards[0].table
	for board in boards[1:] {
		if board.table.event != first.event || board.table.stage != first.stage {
			return ""
		}
	}
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, first.event)
	if first.stage != "" {
		append(&parts, first.stage)
	}
	if first.teams[0] != "" && first.teams[1] != "" {
		append(&parts, fmt.tprintf("%s v %s", collapse_spaces(first.teams[0]), collapse_spaces(first.teams[1])))
	}
	title := strings.join(parts[:], " \u00b7 ", context.temp_allocator)
	title, _ = strings.remove_all(title, "<", context.temp_allocator)
	title, _ = strings.remove_all(title, "&", context.temp_allocator)
	return title
}

// "Board 13, open room" for the text report; "" when the record says neither.
table_heading :: proc(table: norn.Board_Table) -> string {
	switch {
	case table.number > 0 && table.room != .Unknown:
		return fmt.tprintf("board %d, %s room", table.number, table.room == .Open ? "open" : "closed")
	case table.number > 0:
		return fmt.tprintf("board %d", table.number)
	}
	return ""
}

// Runs of spaces as one ("KOTA  PADANG" as the operator typed it).
@(private)
collapse_spaces :: proc(s: string) -> string {
	fields := strings.fields(s, context.temp_allocator)
	return strings.join(fields, " ", context.temp_allocator)
}
