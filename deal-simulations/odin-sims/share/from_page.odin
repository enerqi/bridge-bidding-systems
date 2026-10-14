package share

import "core:encoding/base64"
import "core:strings"
import "norn:norn"
import "../par_caption"
import "../replay"
import "../sampled"

// The boards of a card page, read back out of the page itself: what makes ANY page shareable - a file on disk,
// an analysed page held in memory - without regenerating it or keeping its deals anywhere else.
//
// Every board's `.compass` carries its BBO handviewer query in `data-hv` (the page's `BBO link` button reads it):
// the known hands, the vulnerability, and a dealer. That dealer is a stand-in for a board drawn with none (north,
// which the viewer needs), so the dealer is taken from the seat the page MARKS as dealer (`is-dealer`) and is
// "none" when no seat is. A 2-hand deal names only its two hands; the other 26 cards are dealt to the missing
// seats in card order, which the page never shows.
//
// `title` is the page's `<title>`. `ok` is false for a page with no boards, or a board this cannot read.
boards_from_page :: proc(page: string, allocator := context.allocator) -> (title: string, boards: []Board, ok: bool) {
	COMPASS :: `<div class="compass" data-hv="`
	found := make([dynamic]Board, allocator)
	rest := page
	for {
		at := strings.index(rest, COMPASS)
		if at < 0 {
			break
		}
		rest = rest[at + len(COMPASS):]
		quote := strings.index_byte(rest, '"')
		if quote < 0 {
			delete(found)
			return
		}
		query := rest[:quote]
		// The board's own markup: up to the next board.
		block := rest
		if next := strings.index(rest, COMPASS); next >= 0 {
			block = rest[:next]
		}
		board, board_ok := board_from_query(query, block)
		if !board_ok {
			delete(found)
			return
		}
		append(&found, board)
	}
	if len(found) == 0 {
		delete(found)
		return
	}
	return page_title(page), found[:], true
}

// One board from its handviewer query (`&amp;`-separated, as the attribute carries it) and its markup.
@(private)
board_from_query :: proc(query, block: string) -> (board: Board, ok: bool) {
	held: [norn.DECK_SIZE]bool
	query := query
	vulnerability_seen := false
	for field in strings.split_iterator(&query, "&amp;") {
		if len(field) < 2 || field[1] != '=' {
			return
		}
		value := field[2:]
		switch field[0] {
		case 'n', 'e', 's', 'w':
			seat, _ := norn.seat_from_letter(field[0])
			if !read_hand(value, &board.deal[seat], &held) {
				return
			}
			board.known += {seat}
		case 'v':
			switch value {
			case "-":
				board.table.vulnerability = .None
			case "n":
				board.table.vulnerability = .North_South
			case "e":
				board.table.vulnerability = .East_West
			case "b":
				board.table.vulnerability = .Both
			case:
				return
			}
			vulnerability_seen = true
		}
	}
	if !vulnerability_seen || (board.known != ALL_SEATS && board.known != NORTH_SOUTH && board.known != EAST_WEST) {
		return
	}
	// The missing hands, from the cards nobody holds, in card order.
	next := 0
	for seat in norn.Seat {
		if seat in board.known {
			continue
		}
		for i in 0 ..< norn.HAND_SIZE {
			for held[next] {
				next += 1
			}
			board.deal[seat][i] = norn.Card(next)
			held[next] = true
		}
	}
	board.table.dealer = marked_dealer(block)
	if board.known == ALL_SEATS {
		board.par = read_par(block)
		board.play = read_play(block, board.deal)
	} else {
		board.target = read_target(block)
		if board.target > 0 {
			board.contract = read_contract(block)
			board.constraints = read_constraints(block)
		}
	}
	return board, true
}

// A board's par, from the numbers its caption carries (`data-par`, written by `par_caption`). Nothing when the
// board has no par caption, or one this cannot read - an older page has the caption without the numbers - and the
// link then carries the board without it rather than a wrong number.
@(private)
read_par :: proc(block: string) -> Maybe(Board_Par) {
	ATTRIBUTE :: ` data-par="`
	at := strings.index(block, ATTRIBUTE)
	if at < 0 {
		return nil
	}
	rest := block[at + len(ATTRIBUTE):]
	end := strings.index_byte(rest, '"')
	if end < 0 {
		return nil
	}
	bytes, err := base64.decode(
		rest[:end],
		base64.DEC_URL_TABLE,
		allocator = context.temp_allocator,
		options = {.No_Padding},
	)
	if err != nil {
		return nil
	}
	par, used, perr := par_caption.unpack(bytes)
	if perr != .None || used != len(bytes) {
		return nil
	}
	return par
}

// A whole deal's recorded play, from the bytes its `.play` element carries (`data-pack`, written by `replay`).
// Nothing when the board has no play or one this cannot read (a page written before the bytes were): the link
// then carries the board without it.
@(private)
read_play :: proc(block: string, deal: norn.Deal) -> Maybe(Board_Play) {
	ATTRIBUTE :: ` data-pack="`
	at := strings.index(block, ATTRIBUTE)
	if at < 0 {
		return nil
	}
	rest := block[at + len(ATTRIBUTE):]
	end := strings.index_byte(rest, '"')
	if end < 0 {
		return nil
	}
	bytes, err := base64.decode(
		rest[:end],
		base64.DEC_URL_TABLE,
		allocator = context.temp_allocator,
		options = {.No_Padding},
	)
	if err != nil {
		return nil
	}
	contract, play, used, ok := replay.unpack_play(bytes, deal)
	if !ok || used != len(bytes) {
		return nil
	}
	return Board_Play{contract, play}
}

// A 2-hand board's CCA target: the advisor's `.par` div's `data-target`, or 0 when there is none.
@(private)
read_target :: proc(block: string) -> int {
	ATTRIBUTE :: `<div class="par" data-target="`
	at := strings.index(block, ATTRIBUTE)
	if at < 0 {
		return 0
	}
	n := 0
	for c in transmute([]u8)block[at + len(ATTRIBUTE):] {
		if c < '0' || c > '9' {
			break
		}
		n = n * 10 + int(c - '0')
	}
	return n if n >= 1 && n <= 13 else 0
}

// A 2-hand board's named contract: its `.par` div's `data-contract` (`sampled.write_contract_key`), else none.
@(private)
read_contract :: proc(block: string) -> Maybe(sampled.Contract) {
	if c, ok := sampled.parse_contract_key(par_attribute(block, ` data-contract="`)); ok {
		return c
	}
	return nil
}

// A 2-hand board's defender inferences: its `.par` div's `data-held` and `data-shape`
// (`sampled.write_advisor_par`), else none - and none if either does not read.
@(private)
read_constraints :: proc(block: string) -> sampled.Board_Constraints {
	held, shape := par_attribute(block, ` data-held="`), par_attribute(block, ` data-shape="`)
	if bc, ok := sampled.parse_board_constraints(held, shape); ok {
		return bc
	}
	return {}
}

// An attribute's value on a 2-hand board's `.par` div (`attribute` is ` name="`), or "".
@(private)
par_attribute :: proc(block: string, attribute: string) -> string {
	PAR :: `<div class="par" data-target="`
	at := strings.index(block, PAR)
	if at < 0 {
		return ""
	}
	tag := block[at:]
	if end := strings.index_byte(tag, '>'); end >= 0 {
		tag = tag[:end]
	}
	from := strings.index(tag, attribute)
	if from < 0 {
		return ""
	}
	value := tag[from + len(attribute):]
	if quote := strings.index_byte(value, '"'); quote >= 0 {
		return value[:quote]
	}
	return ""
}

// One hand's `s<ranks>h<ranks>d<ranks>c<ranks>` into `hand`; false unless it is 13 cards nobody else holds.
@(private)
read_hand :: proc(text: string, hand: ^norn.Hand, held: ^[norn.DECK_SIZE]bool) -> bool {
	suit: Maybe(norn.Suit)
	count := 0
	for i in 0 ..< len(text) {
		c := text[i]
		if s, is_suit := norn.suit_from_letter(c); is_suit && c >= 'a' {
			suit = s
			continue
		}
		rank, is_rank := norn.rank_from_char(c)
		current, has_suit := suit.?
		if !is_rank || !has_suit || count == norn.HAND_SIZE {
			return false
		}
		card := norn.make_card(current, rank)
		if held[card] {
			return false
		}
		held[card] = true
		hand[count] = card
		count += 1
	}
	return count == norn.HAND_SIZE
}

// The seat a board's markup marks as dealer, or none.
@(private)
marked_dealer :: proc(block: string) -> Maybe(norn.Seat) {
	at := strings.index(block, " is-dealer")
	if at < 0 {
		return nil
	}
	SEAT_CLASS :: `class="seat seat-`
	start := strings.last_index(block[:at], SEAT_CLASS)
	if start < 0 || start + len(SEAT_CLASS) >= len(block) {
		return nil
	}
	seat, ok := norn.seat_from_letter(block[start + len(SEAT_CLASS)])
	if !ok {
		return nil
	}
	return seat
}

@(private)
page_title :: proc(page: string) -> string {
	open := strings.index(page, "<title>")
	if open < 0 {
		return ""
	}
	rest := page[open + len("<title>"):]
	close := strings.index(rest, "</title>")
	if close < 0 {
		return ""
	}
	return strings.trim_space(rest[:close])
}
