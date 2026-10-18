package analyse

/*
	rooms.odin — the two rooms of a team match compared, board by board (part of package `analyse`; the
	judging is match.odin's).

	A board played in both rooms (the same number, an Open and a Closed record, the same deal) is one swing:
	the open room's North-South score against the closed room's, in IMPs, to the team sitting North-South in
	the OPEN room. That is the first team a vugraph record names (BBO's convention: the first team sits
	North-South in the open room) or a PBN's home team. The swing is split in two:

	  - the BIDDING's share: the swing the two contracts make when both are played double dummy;
	  - the PLAY's share: the rest (the swing at the table less the bidding's), which is what the two tables'
	    cards, leads and claims did to it.

	Both are IMPs, and IMPs do not add: the play's share is the difference of two IMP figures, not the IMPs of
	a difference in points. It answers "how much of this swing would have happened anyway".
*/

import "core:fmt"
import "core:io"
import "core:strings"

import "../deal_solve"
import "norn:norn"

// One board of a team match, both rooms judged.
Room_Pair :: struct {
	number:       int,
	open, closed: int, // indexes into the judged boards
	open_ns:      Maybe(int), // the open room's North-South score, when the record gives a result
	closed_ns:    Maybe(int),
	swing:        Maybe(int), // IMPs to the open room's North-South, when both rooms have a result
	bid_swing:    int, // IMPs the two contracts swing, both played double dummy
}

// The verdicts alone, in a temp-allocated slice.
judged_verdicts :: proc(judged: []Judged) -> []Board_Verdict {
	verdicts := make([]Board_Verdict, len(judged), context.temp_allocator)
	for j, i in judged {
		verdicts[i] = j.verdict
	}
	return verdicts
}

// Points from North-South's side: a verdict's points are the declaring side's.
@(private = "file")
ns_points :: proc(v: Board_Verdict, points: int) -> int {
	return points if v.contract.declarer == .North || v.contract.declarer == .South else -points
}

// Every board judged in both rooms, in the order of their open-room records. A Closed record whose deal is not
// the Open one's (a mislabelled record) is not its pair.
pair_rooms :: proc(boards: []norn.Board, judged: []Judged, allocator := context.temp_allocator) -> []Room_Pair {
	pairs := make([dynamic]Room_Pair, allocator)
	for open, a in judged {
		table := boards[open.board].table
		if table.room != .Open || table.number == 0 {
			continue
		}
		for closed, c in judged {
			other := boards[closed.board].table
			if other.room != .Closed || other.number != table.number || boards[closed.board].deal != boards[open.board].deal {
				continue
			}
			p := Room_Pair {
				number = table.number,
				open   = a,
				closed = c,
			}
			ov, cv := open.verdict, closed.verdict
			o_score, o_dd := verdict_scores(ov)
			c_score, c_dd := verdict_scores(cv)
			p.bid_swing = norn.imps(ns_points(ov, o_dd) - ns_points(cv, c_dd))
			if s, has := o_score.?; has {
				p.open_ns = ns_points(ov, s)
			}
			if s, has := c_score.?; has {
				p.closed_ns = ns_points(cv, s)
			}
			if o, has := p.open_ns.?; has {
				if c2, has2 := p.closed_ns.?; has2 {
					p.swing = norn.imps(o - c2)
				}
			}
			append(&pairs, p)
			break
		}
	}
	return pairs[:]
}

// The swings summed for each team: [0] is the team North-South in the open room, [1] the other.
Room_Totals :: struct {
	boards:  int, // pairs with a swing
	imps:    [2]int,
	bidding: [2]int,
	play:    [2]int,
}

tally_rooms :: proc(pairs: []Room_Pair) -> (t: Room_Totals) {
	add :: proc(to: ^[2]int, n: int) {
		if n > 0 {
			to[0] += n
		} else {
			to[1] -= n
		}
	}
	for p in pairs {
		swing, has := p.swing.?
		if !has {
			continue
		}
		t.boards += 1
		add(&t.imps, swing)
		add(&t.bidding, p.bid_swing)
		add(&t.play, swing - p.bid_swing)
	}
	return
}

// The two teams' names: the record's, or which seats the first sat in when it names none.
team_names :: proc(boards: []norn.Board, pairs: []Room_Pair, judged: []Judged) -> [2]string {
	names := [2]string{"open room N-S", "open room E-W"}
	if len(pairs) == 0 {
		return names
	}
	teams := boards[judged[pairs[0].open].board].table.teams
	if teams[0] != "" && teams[1] != "" {
		names = {collapse_spaces(teams[0]), collapse_spaces(teams[1])}
	}
	return names
}

// The rooms section of the text report: a line a board, then each team's IMPs split into bidding and play.
// Nothing when no board was judged in both rooms.
write_rooms_text :: proc(w: io.Writer, boards: []norn.Board, judged: []Judged) {
	pairs := pair_rooms(boards, judged)
	if len(pairs) == 0 {
		return
	}
	names := team_names(boards, pairs, judged)
	fmt.wprintfln(w, "\nThe two rooms, in IMPs to %s (North-South in the open room):\n", names[0])
	fmt.wprintln(w, "board  open       closed     open NS  closed NS  swing  bidding  play")
	for p in pairs {
		swing, play := "-", "-"
		if s, has := p.swing.?; has {
			swing, play = signed(s), signed(s - p.bid_swing)
		}
		fmt.wprintfln(
			w,
			"%-6d %-10s %-10s %7s %10s %6s %8s %5s",
			p.number,
			contract_text(judged[p.open].verdict.contract),
			contract_text(judged[p.closed].verdict.contract),
			maybe_number(p.open_ns),
			maybe_number(p.closed_ns),
			swing,
			signed(p.bid_swing),
			play,
		)
	}
	fmt.wprintln(w)
	write_rooms_totals(w, tally_rooms(pairs), names)
}

@(private = "file")
write_rooms_totals :: proc(w: io.Writer, t: Room_Totals, names: [2]string) {
	if t.boards == 0 {
		fmt.wprintln(w, "No board has a result in both rooms.")
		return
	}
	fmt.wprintfln(
		w,
		"%s %d, %s %d IMPs over %d board%s: the bidding %d-%d (both contracts played double dummy), the play %d-%d.",
		names[0],
		t.imps[0],
		names[1],
		t.imps[1],
		t.boards,
		"" if t.boards == 1 else "s",
		t.bidding[0],
		t.bidding[1],
		t.play[0],
		t.play[1],
	)
}

// The rooms section of the card page's match table: a row a board, each room's contract opening that room's
// board at its first costly card. Nothing when no board was judged in both rooms.
write_rooms_element :: proc(b: ^strings.Builder, boards: []norn.Board, judged: []Judged) {
	pairs := pair_rooms(boards, judged)
	if len(pairs) == 0 {
		return
	}
	names := team_names(boards, pairs, judged)
	fmt.sbprintf(
		b,
		`<h3>The two rooms, in IMPs to %s (North-South in the open room)</h3><table class="rooms"><thead><tr>`,
		html_text(names[0]),
	)
	HEADINGS :: [?][2]string {
		{"board", ""},
		{"open", "The open room's contract: click to open its board"},
		{"closed", "The closed room's contract: click to open its board"},
		{"open NS", "North-South's score in the open room"},
		{"closed NS", "North-South's score in the closed room"},
		{"swing", "IMPs to the open room's North-South"},
		{"bidding", "The swing the two contracts make, both played double dummy"},
		{"play", "The rest of the swing: what the play did to it"},
	}
	for heading, i in HEADINGS {
		class := ` class="l"` if i <= 2 else ""
		if heading[1] == "" {
			fmt.sbprintf(b, `<th%s>%s</th>`, class, heading[0])
		} else {
			fmt.sbprintf(b, `<th%s title="%s">%s</th>`, class, heading[1], heading[0])
		}
	}
	strings.write_string(b, `</tr></thead><tbody>`)
	tone :: proc(n: int) -> string {
		return "" if n == 0 else ("pos" if n > 0 else "neg")
	}
	room :: proc(b: ^strings.Builder, j: Judged) {
		step := 0
		if first, has := j.verdict.first_cost.?; has {
			step = first + 1
		}
		fmt.sbprintf(b, `<td class="l" data-board="%d" data-step="%d">%s</td>`, j.slide, step, contract_html(j.verdict.contract))
	}
	for p in pairs {
		fmt.sbprintf(b, `<tr><td class="l">%d</td>`, p.number)
		room(b, judged[p.open])
		room(b, judged[p.closed])
		fmt.sbprintf(b, `<td>%s</td><td>%s</td>`, maybe_number(p.open_ns), maybe_number(p.closed_ns))
		if s, has := p.swing.?; has {
			fmt.sbprintf(b, `<td class="%s">%s</td>`, tone(s), signed(s))
			fmt.sbprintf(b, `<td class="%s">%s</td>`, tone(p.bid_swing), signed(p.bid_swing))
			fmt.sbprintf(b, `<td class="%s">%s</td>`, tone(s - p.bid_swing), signed(s - p.bid_swing))
		} else {
			fmt.sbprintf(b, `<td>-</td><td class="%s">%s</td><td>-</td>`, tone(p.bid_swing), signed(p.bid_swing))
		}
		strings.write_string(b, `</tr>`)
	}
	strings.write_string(b, `</tbody></table><pre class="match-sum">`)
	sum := strings.builder_make(context.temp_allocator)
	write_rooms_totals(strings.to_writer(&sum), tally_rooms(pairs), names)
	strings.write_string(b, html_text(strings.to_string(sum)))
	strings.write_string(b, `</pre>`)
}

// "4♠X N" for the page, the suit as the card page draws its glyphs.
contract_html :: proc(c: norn.Contract) -> string {
	STRAIN_HTML :: [norn.Contract_Strain]string {
		.Clubs    = `<span class="ssym c">&clubs;</span>`,
		.Diamonds = `<span class="ssym d">&diams;</span>`,
		.Hearts   = `<span class="ssym h">&hearts;</span>`,
		.Spades   = `<span class="ssym s">&spades;</span>`,
		.NoTrumps = "NT",
	}
	DOUBLING :: [norn.Doubling]string {
		.None      = "",
		.Doubled   = "X",
		.Redoubled = "XX",
	}
	strain_html, doubling := STRAIN_HTML, DOUBLING
	return fmt.tprintf("%d%s%s %c", c.level, strain_html[c.strain], doubling[c.doubling], deal_solve.seat_letter(c.declarer))
}

// Text from a record (a team's name) made safe as HTML text.
@(private = "file")
html_text :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	out, _ = strings.replace_all(out, "<", "&lt;", context.temp_allocator)
	return out
}
