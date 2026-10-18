package analyse

/*
	match.odin — a whole set of boards judged against double dummy, one line a board plus totals
	(`--table text|csv`; part of package `analyse`, see analyse.odin).

	The input is what the carousel reads: a vugraph `.lin` segment, a PBN of many games, or one record. Each
	board that names its contract and gives all four hands gets:

	  - the tricks the record says declarer took, against the tricks double dummy gives that contract;
	  - when the record has the play, where those tricks went: what the opening lead cost, the tricks the
	    declaring side's cards gave away, the tricks the defenders' cards gave away (each card judged against
	    the best card its player held, `deal_solve.play_cost`), and what a claim gave away against double dummy
	    from where it was made;
	  - the score, against par: the RESULT against par, and the CONTRACT against par when it is played double
	    dummy - which is the bidding's share, with the play taken out.

	So, for a played board, `tricks = dd - declarer + defence + claim`: the three columns account for every
	trick between double dummy and the table. A record cut short by a bad card stops the play there, and the
	claim column then holds whatever the rest of the board did.

	The totals say the same over the set, overall and by kind of contract. They are only as good as the
	records: vugraph operators type the play live, and a claim's trick count is the record's word, not the
	truth (see `norn.Play`).

	Every number is the DECLARING side's: a score is what declarer's side scored, par is par from that side's
	seat. The judging (`judge_board`, `tally_match`) is pure, so it is tested without the solver.
*/

import "core:fmt"
import "core:io"
import "core:strings"

import "../deal_solve"
import "../par_caption"
import "norn:norn"

// One board, judged. Fields that need the play are meaningful only when `has_play` is set, and `result` only
// when the record gives one (a claim, a `[Result]`, or a play to the last card).
Board_Verdict :: struct {
	label:         string, // "13 Open", or the board's place in the input when the record has no number
	contract:      norn.Contract,
	vulnerable:    bool, // the declaring side
	dd_tricks:     int, // double dummy, from the deal's first position
	result:        Maybe(int), // the tricks the declaring side took, by the record
	has_par:       bool,
	par:           int, // par, from the declaring side's seat
	has_play:      bool,
	lead_cost:     int,
	declarer_lost: int, // tricks the declaring side's cards gave away
	defence_gave:  int, // tricks the defenders' cards gave away
	first_cost:    Maybe(int), // the first card that cost a trick, its index in the play
	first_seat:    norn.Seat,
	first_card:    norn.Card,
	claim:         Maybe(int), // result - double dummy where the play stops; needs a result
}

// What the score was, and what the contract would have scored played double dummy.
verdict_scores :: proc(v: Board_Verdict) -> (score: Maybe(int), dd_score: int) {
	dd_score = norn.contract_score(v.contract, v.dd_tricks, v.vulnerable)
	if result, has := v.result.?; has {
		score = norn.contract_score(v.contract, result, v.vulnerable)
	}
	return
}

// Judge one board from its double-dummy numbers. `cost` is `deal_solve.play_cost` of the record's play, nil
// when there is none or the solver failed it.
judge_board :: proc(
	board: norn.Board,
	label: string,
	tricks: par_caption.Tricks,
	par_ns: Maybe(int),
	cost: Maybe(deal_solve.Play_Cost),
) -> (
	v: Board_Verdict,
) {
	contract := board.contract.?
	v.label = label
	v.contract = contract
	north_south := contract.declarer == .North || contract.declarer == .South
	switch board.conditions.vulnerability {
	case .None:
	case .North_South:
		v.vulnerable = north_south
	case .East_West:
		v.vulnerable = !north_south
	case .Both:
		v.vulnerable = true
	}
	strain := par_caption.Strain(deal_solve.strain_to_dds(contract.strain))
	v.dd_tricks = tricks[strain][par_caption.Hand(int(contract.declarer))]
	if par, has := par_ns.?; has {
		v.has_par = true
		v.par = par if north_south else -par
	}

	play, has_play := board.play.?
	if !has_play {
		return
	}
	if result, has := play.result.?; has {
		v.result = result
	} else if play.count == norn.DECK_SIZE {
		walk := norn.play_tricks(board.deal, contract, play)
		v.result = walk.declarer_tricks
	}
	c, has_cost := cost.?
	if !has_cost || play.count == 0 {
		return
	}
	v.has_play = true
	v.lead_cost = int(c.cost[0])
	walk := norn.play_walk_start(board.deal, contract)
	for i in 0 ..< c.count {
		seat := norn.play_walk_next_seat(&walk).?
		_ = norn.play_walk_card(&walk, play.cards[i])
		lost := int(c.cost[i])
		if lost <= 0 {
			continue
		}
		if int(seat) % 2 == int(contract.declarer) % 2 {
			v.declarer_lost += lost
		} else {
			v.defence_gave += lost
		}
		if v.first_cost == nil {
			v.first_cost, v.first_seat, v.first_card = i, seat, play.cards[i]
		}
	}
	if result, has := v.result.?; has {
		v.claim = result - int(c.value[c.count])
	}
	return
}

// The kinds of contract the totals are split by. A board is in `All`, one of the three levels, and one of
// the two strains.
Contract_Kind :: enum {
	All,
	Partscore,
	Game,
	Slam,
	Notrumps,
	Suit,
}

CONTRACT_KIND_NAMES :: [Contract_Kind]string {
	.All       = "all",
	.Partscore = "partscore",
	.Game      = "game",
	.Slam      = "slam",
	.Notrumps  = "notrumps",
	.Suit      = "suit",
}

contract_kinds :: proc(c: norn.Contract) -> (kinds: bit_set[Contract_Kind]) {
	kinds = {.All, .Notrumps if c.strain == .NoTrumps else .Suit}
	game_level := 3
	switch c.strain {
	case .Clubs, .Diamonds:
		game_level = 5
	case .Hearts, .Spades:
		game_level = 4
	case .NoTrumps:
	}
	switch {
	case c.level >= 6:
		kinds += {.Slam}
	case c.level >= game_level:
		kinds += {.Game}
	case:
		kinds += {.Partscore}
	}
	return
}

// The sums over a set of boards (one kind of contract). Means are taken over the boards that have the number.
Tally :: struct {
	boards:        int,
	with_result:   int,
	tricks_vs_dd:  int, // sum of result - dd
	under, on, over: int, // boards below, on and above double dummy
	with_play:     int,
	costly_leads:  int, // leads that cost a trick
	lead_cost:     int,
	declarer_lost: int,
	declarer_boards: int, // boards where the declaring side's cards lost a trick
	defence_gave:  int,
	defence_boards: int,
	claim:         int, // sum of claims against double dummy
	with_claim:    int,
	with_par:      int,
	contract_imps: int, // the contract played double dummy, against par
	at_par:        int, // boards whose contract scores par played double dummy
	result_imps:   int, // the result against par (needs a result too)
	with_both:     int,
}

tally_match :: proc(verdicts: []Board_Verdict) -> (totals: [Contract_Kind]Tally) {
	for v in verdicts {
		score, dd_score := verdict_scores(v)
		for kind in contract_kinds(v.contract) {
			t := &totals[kind]
			t.boards += 1
			if result, has := v.result.?; has {
				t.with_result += 1
				diff := result - v.dd_tricks
				t.tricks_vs_dd += diff
				switch {
				case diff < 0:
					t.under += 1
				case diff == 0:
					t.on += 1
				case:
					t.over += 1
				}
			}
			if v.has_play {
				t.with_play += 1
				t.lead_cost += v.lead_cost
				if v.lead_cost > 0 {
					t.costly_leads += 1
				}
				t.declarer_lost += v.declarer_lost
				t.defence_gave += v.defence_gave
				if v.declarer_lost > 0 {
					t.declarer_boards += 1
				}
				if v.defence_gave > 0 {
					t.defence_boards += 1
				}
			}
			if claim, has := v.claim.?; has {
				t.with_claim += 1
				t.claim += claim
			}
			if v.has_par {
				t.with_par += 1
				imps := norn.imps(dd_score - v.par)
				t.contract_imps += imps
				if imps == 0 {
					t.at_par += 1
				}
				if s, has := score.?; has {
					t.with_both += 1
					t.result_imps += norn.imps(s - v.par)
				}
			}
		}
	}
	return
}

// Judge every board that can be: named contract, all four hands. The tables are solved in one batch first
// (`deal_solve.prepare_tables`), then each board's play position by position. `skipped` counts the rest.
// The verdicts' labels are temp-allocated. No slides: `slide` is -1.
judge_match :: proc(sink: Sink, boards: []norn.Board) -> (judged: [dynamic]Judged, skipped: int) {
	deals := make([dynamic]norn.Deal, 0, len(boards), context.temp_allocator)
	for board in boards {
		if board.contract != nil && board_fully_known(board) {
			append(&deals, board.deal)
		}
	}
	if !deal_solve.prepare_tables(deals[:]) {
		fmt.wprintfln(sink.err, "%s: the batch solve failed - solving the boards one at a time", PROGRAM)
	}
	for board, i in boards {
		report_progress(sink, i, len(boards))
		contract, has_contract := board.contract.?
		if !has_contract || !board_fully_known(board) {
			skipped += 1
			continue
		}
		tricks, par_ns, have_par, ok := deal_solve.board_par(board.deal, board.conditions.vulnerability)
		if !ok {
			fmt.wprintfln(sink.err, "%s: board %d: the solver failed", PROGRAM, i + 1)
			skipped += 1
			continue
		}
		par: Maybe(int)
		if have_par {
			par = par_ns
		}
		cost: Maybe(deal_solve.Play_Cost)
		if play, has := board.play.?; has && play.count > 0 {
			if c, solved := deal_solve.play_cost(board.deal, contract, play); solved {
				cost = c
			}
		}
		append(&judged, Judged{judge_board(board, board_label(board, i), tricks, par, cost), i, -1})
	}
	report_progress(sink, len(boards), len(boards))
	return
}

// "13 Open" / "13 Closed" / "13", or the board's place in the input when the record has no number.
board_label :: proc(board: norn.Board, index: int) -> string {
	number := board.table.number if board.table.number > 0 else index + 1
	switch board.table.room {
	case .Open:
		return fmt.tprintf("%d Open", number)
	case .Closed:
		return fmt.tprintf("%d Closed", number)
	case .Unknown:
	}
	return fmt.tprintf("%d", number)
}

// "4SX N", "3NT E".
contract_text :: proc(c: norn.Contract) -> string {
	DOUBLING := [norn.Doubling]string {
		.None      = "",
		.Doubled   = "X",
		.Redoubled = "XX",
	}
	return fmt.tprintf(
		"%d%s%s %c",
		c.level,
		deal_solve.contract_strain_word(c.strain),
		DOUBLING[c.doubling],
		deal_solve.seat_letter(c.declarer),
	)
}

// The whole report for a set of boards: `format` is "text" (a table plus the totals) or "csv" (one row a
// board, for a spreadsheet).
report_match :: proc(sink: Sink, boards: []norn.Board, format: string) {
	judged, skipped := judge_match(sink, boards)
	defer delete(judged)
	verdicts := judged_verdicts(judged[:])
	if format == "csv" {
		write_match_csv(sink.out, verdicts)
	} else {
		write_match_text(sink.out, verdicts, skipped, match_title(boards))
		write_rooms_text(sink.out, boards, judged[:])
	}
}

@(private)
signed :: proc(n: int) -> string {
	return fmt.tprintf("%+d", n) if n != 0 else "0"
}

@(private)
maybe_number :: proc(n: Maybe(int), sign := false) -> string {
	v, has := n.?
	if !has {
		return "-"
	}
	return signed(v) if sign else fmt.tprintf("%d", v)
}

@(private = "file")
first_cost_text :: proc(v: Board_Verdict) -> string {
	i, has := v.first_cost.?
	if !has {
		return ""
	}
	return fmt.tprintf(
		"trick %d %c %s",
		i / norn.SEAT_COUNT + 1,
		deal_solve.seat_letter(v.first_seat),
		deal_solve.card_word(v.first_card),
	)
}

write_match_csv :: proc(w: io.Writer, verdicts: []Board_Verdict) {
	fmt.wprintln(
		w,
		"board,contract,vulnerable,tricks,dd,tricks_vs_dd,lead_cost,declarer_lost,defence_gave,claim,score,dd_score,par,result_imps,contract_imps,first_cost",
	)
	for v in verdicts {
		score, dd_score := verdict_scores(v)
		result_vs_dd: Maybe(int)
		if r, has := v.result.?; has {
			result_vs_dd = r - v.dd_tricks
		}
		play_cols := ",,"
		if v.has_play {
			play_cols = fmt.tprintf("%d,%d,%d", v.lead_cost, v.declarer_lost, v.defence_gave)
		}
		par_cols := ",,"
		if v.has_par {
			result_imps := ""
			if s, has := score.?; has {
				result_imps = fmt.tprintf("%d", norn.imps(s - v.par))
			}
			par_cols = fmt.tprintf("%d,%s,%d", v.par, result_imps, norn.imps(dd_score - v.par))
		}
		fmt.wprintfln(
			w,
			"%s,%s,%s,%s,%d,%s,%s,%s,%s,%d,%s,%s",
			v.label,
			contract_text(v.contract),
			"yes" if v.vulnerable else "no",
			csv_number(v.result),
			v.dd_tricks,
			csv_number(result_vs_dd),
			play_cols,
			csv_number(v.claim),
			csv_number(score),
			dd_score,
			par_cols,
			first_cost_text(v),
		)
	}
}

@(private = "file")
csv_number :: proc(n: Maybe(int)) -> string {
	v, has := n.?
	return fmt.tprintf("%d", v) if has else ""
}

write_match_text :: proc(w: io.Writer, verdicts: []Board_Verdict, skipped: int, title: string) {
	if title != "" {
		fmt.wprintfln(w, "%s\n", title)
	}
	fmt.wprintln(
		w,
		"board       contract  tricks  dd  vs dd  lead  decl  def  claim   score    par  imps  bid  first card to cost",
	)
	for v in verdicts {
		score, dd_score := verdict_scores(v)
		result_vs_dd: Maybe(int)
		if r, has := v.result.?; has {
			result_vs_dd = r - v.dd_tricks
		}
		lead, decl, def := "-", "-", "-"
		if v.has_play {
			lead, decl, def = fmt.tprintf("%d", v.lead_cost), fmt.tprintf("%d", v.declarer_lost), fmt.tprintf("%d", v.defence_gave)
		}
		par, result_imps, contract_imps := "-", "-", "-"
		if v.has_par {
			par = fmt.tprintf("%d", v.par)
			contract_imps = signed(norn.imps(dd_score - v.par))
			if s, has := score.?; has {
				result_imps = signed(norn.imps(s - v.par))
			}
		}
		fmt.wprintfln(
			w,
			"%-11s %-9s %6s %3s %6s %5s %5s %4s %6s %7s %6s %5s %4s%s",
			v.label,
			contract_text(v.contract),
			maybe_number(v.result),
			maybe_number(v.dd_tricks),
			maybe_number(result_vs_dd, sign = true),
			lead,
			decl,
			def,
			maybe_number(v.claim, sign = true),
			maybe_number(score),
			par,
			result_imps,
			contract_imps,
			"" if v.first_cost == nil else fmt.tprintf("  %s", first_cost_text(v)),
		)
	}
	fmt.wprintln(w)
	write_match_totals(w, tally_match(verdicts), skipped)
}

// The legend and the totals under the table.
write_match_totals :: proc(w: io.Writer, totals: [Contract_Kind]Tally, skipped: int) {
	all := totals[.All]
	fmt.wprintf(w, "%d board%s judged", all.boards, "" if all.boards == 1 else "s")
	if skipped > 0 {
		fmt.wprintf(w, "; %d skipped (no contract, or not all four hands)", skipped)
	}
	fmt.wprintln(w, ".")
	fmt.wprintln(
		w,
		"Columns, all from the declaring side: tricks taken against double dummy; what the lead, declarer's\n" +
		"cards and the defenders' cards gave away; a claim against double dummy where it was made; the score\n" +
		"and par; IMPs of the result against par (imps) and of the contract played double dummy (bid).",
	)
	if all.boards == 0 {
		return
	}
	fmt.wprintln(w)
	if all.with_result > 0 {
		fmt.wprintfln(
			w,
			"Tricks against double dummy (%d boards with a result): %s a board; under on %d, on %d, over on %d.",
			all.with_result,
			mean(all.tricks_vs_dd, all.with_result),
			all.under,
			all.on,
			all.over,
		)
	}
	if all.with_play > 0 {
		fmt.wprintfln(
			w,
			"Of %d played boards: declarer's cards gave away %d trick%s (on %d boards), the defenders' %d (on %d boards).",
			all.with_play,
			all.declarer_lost,
			"" if all.declarer_lost == 1 else "s",
			all.declarer_boards,
			all.defence_gave,
			all.defence_boards,
		)
		fmt.wprintfln(
			w,
			"Opening leads: %d of %d cost a trick (%d%%), %d trick%s in all.",
			all.costly_leads,
			all.with_play,
			all.costly_leads * 100 / all.with_play,
			all.lead_cost,
			"" if all.lead_cost == 1 else "s",
		)
	}
	if all.with_claim > 0 && all.claim != 0 {
		fmt.wprintfln(w, "Claims and the play after the record stops: %s trick(s) against double dummy in all.", signed(all.claim))
	}
	if all.with_par > 0 {
		fmt.wprintfln(
			w,
			"Contracts against par, played double dummy: %s IMPs a board; at par on %d of %d.",
			mean(all.contract_imps, all.with_par),
			all.at_par,
			all.with_par,
		)
	}
	if all.with_both > 0 {
		fmt.wprintfln(w, "Results against par: %s IMPs a board.", mean(all.result_imps, all.with_both))
	}

	fmt.wprintln(w, "\nBy contract      boards  vs dd  lead cost  decl lost  def gave  bid imps  result imps")
	names := CONTRACT_KIND_NAMES
	for kind in Contract_Kind {
		t := totals[kind]
		if t.boards == 0 {
			continue
		}
		fmt.wprintfln(
			w,
			"  %-14s %6s %6s %10s %10s %9s %9s %12s",
			names[kind],
			maybe_number(t.boards),
			mean(t.tricks_vs_dd, t.with_result),
			mean(t.lead_cost, t.with_play, sign = false),
			mean(t.declarer_lost, t.with_play, sign = false),
			mean(t.defence_gave, t.with_play, sign = false),
			mean(t.contract_imps, t.with_par),
			mean(t.result_imps, t.with_both),
		)
	}
	fmt.wprintln(w, "(means a board)")
}

// A board judged: its verdict, which board of the input it is, and which slide of the card page shows it (a
// board the page cannot draw has no slide, so the two can differ; -1 off the page).
Judged :: struct {
	verdict: Board_Verdict,
	board:   int,
	slide:   int,
}

// The match table as a hidden `.match-table` element of the card page, which the page's `Table` button opens:
// one row a board (the text report's columns), each naming the slide it opens and the step of the play to open
// it at (just after the first card that cost a trick, else the start), then the totals as the text report
// writes them. Written after the boards; the page's script takes it out of the carousel before grouping slides.
write_match_element :: proc(b: ^strings.Builder, boards: []norn.Board, judged: []Judged, skipped: int) {
	cell :: proc(b: ^strings.Builder, text: string, class := "") {
		if class == "" {
			fmt.sbprintf(b, `<td>%s</td>`, text)
		} else {
			fmt.sbprintf(b, `<td class="%s">%s</td>`, class, text)
		}
	}
	// Red for what cost the declaring side, green for what it gained.
	tone :: proc(n: int, good_when_positive := true) -> string {
		if n == 0 {
			return ""
		}
		return "pos" if (n > 0) == good_when_positive else "neg"
	}
	HEADINGS :: [?][2]string {
		{"board", ""},
		{"contract", "The contract and its declarer"},
		{"tricks", "Tricks the declaring side took, by the record"},
		{"dd", "Tricks the contract makes double dummy"},
		{"vs dd", "Tricks taken against double dummy"},
		{"lead", "Tricks the opening lead gave away"},
		{"decl", "Tricks the declaring side's cards gave away"},
		{"def", "Tricks the defenders' cards gave away"},
		{"claim", "A claim against double dummy, where it was made"},
		{"score", "The declaring side's score"},
		{"par", "Par, from the declaring side's seat"},
		{"imps", "IMPs of the result against par"},
		{"bid", "IMPs of the contract, played double dummy, against par: the bidding's share"},
		{"first card to cost", "The first card that gave a trick away; the row opens the play there"},
	}

	strings.write_string(b, `<div class="match-table" hidden><table class="boards"><thead><tr>`)
	for heading, i in HEADINGS {
		class := ` class="l"` if i == 0 || i == 1 || i == len(HEADINGS) - 1 else ""
		if heading[1] == "" {
			fmt.sbprintf(b, `<th%s>%s</th>`, class, heading[0])
		} else {
			fmt.sbprintf(b, `<th%s title="%s">%s</th>`, class, heading[1], heading[0])
		}
	}
	strings.write_string(b, `</tr></thead><tbody>`)
	verdicts := make([]Board_Verdict, len(judged))
	defer delete(verdicts)
	for j, k in judged {
		v := j.verdict
		v.label = board_label(boards[j.board], j.board)
		verdicts[k] = v
		step := 0
		if first, has := v.first_cost.?; has {
			step = first + 1
		}
		fmt.sbprintf(b, `<tr data-board="%d" data-step="%d">`, j.slide, step)
		cell(b, v.label, "l")
		cell(b, contract_html(v.contract), "l")
		score, dd_score := verdict_scores(v)
		cell(b, maybe_number(v.result))
		cell(b, fmt.tprintf("%d", v.dd_tricks))
		if r, has := v.result.?; has {
			cell(b, signed(r - v.dd_tricks), tone(r - v.dd_tricks))
		} else {
			cell(b, "-")
		}
		if v.has_play {
			cell(b, fmt.tprintf("%d", v.lead_cost), tone(v.lead_cost, false))
			cell(b, fmt.tprintf("%d", v.declarer_lost), tone(v.declarer_lost, false))
			cell(b, fmt.tprintf("%d", v.defence_gave), tone(v.defence_gave))
		} else {
			cell(b, "-")
			cell(b, "-")
			cell(b, "-")
		}
		claim, has_claim := v.claim.?
		cell(b, maybe_number(v.claim, sign = true), tone(claim) if has_claim else "")
		cell(b, maybe_number(score))
		if v.has_par {
			cell(b, fmt.tprintf("%d", v.par))
			if s, has := score.?; has {
				imps := norn.imps(s - v.par)
				cell(b, signed(imps), tone(imps))
			} else {
				cell(b, "-")
			}
			bid := norn.imps(dd_score - v.par)
			cell(b, signed(bid), tone(bid))
		} else {
			cell(b, "-")
			cell(b, "-")
			cell(b, "-")
		}
		cell(b, first_cost_text(v), "l")
		strings.write_string(b, `</tr>`)
	}
	strings.write_string(b, `</tbody></table><pre class="match-sum">`)
	write_match_totals(strings.to_writer(b), tally_match(verdicts), skipped)
	strings.write_string(b, `</pre>`)
	write_rooms_element(b, boards, judged)
	strings.write_string(b, `</div>`)
}

@(private = "file")
mean :: proc(sum, n: int, sign := true) -> string {
	if n == 0 {
		return "-"
	}
	return fmt.tprintf("%+.2f" if sign else "%.2f", f64(sum) / f64(n))
}
