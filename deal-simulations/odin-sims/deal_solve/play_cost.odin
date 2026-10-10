package deal_solve

/*
	play_cost — what each card of a recorded play cost, double dummy.

	A record's play (`norn.Play`, read from LIN `pc|` or PBN `[Play]`) says what was played; this says what
	it was WORTH. Before every card the position is solved for every legal card, so for each card played we
	know the declaring side's double-dummy total from there on, whether the card dropped a trick against the
	best card available, and which cards were best. That is what makes a replay instructive rather than a
	slideshow: "trick 3, East's ♦6 cost a trick — the ♦K kept it".

	One position per card, all solved in ONE batched call (`SolveAllBoardsBin`, which spreads them over DDS's
	threads) — a whole board is at most 52 positions, under the batch's 200. Mode `.Auto`, not the
	`.Auto_Skip_Single` used elsewhere: skipping leaves a forced card's score unset (-2), and a forced card
	is still a position whose value the trajectory needs.

	Numbers are always the DECLARING side's total tricks for the board (tricks already won + what double
	dummy gives from here), so the trajectory reads the same whichever side is on play: a declarer card that
	costs lowers it, a defender card that costs raises it.
*/

import "core:fmt"
import "core:strings"

import dds "dds:."
import "norn:norn"

Play_Cost :: struct {
	count: int, // cards analysed: the play's accepted cards
	// value[i] is the declaring side's double-dummy total with best play from the position BEFORE card i;
	// value[count] is the position after the last card (the claim is judged against it).
	value: [norn.DECK_SIZE + 1]i8,
	// cost[i]: tricks card i gave away against the best card its player had (0 for a best card).
	cost:  [norn.DECK_SIZE]i8,
	// best[i]: the cards (bit int(card)) that would have kept value[i] — set for every card, read where
	// cost[i] > 0.
	best:  [norn.DECK_SIZE]u64,
}

// Solve every position of `play`. ok=false when DDS refuses the batch (it never should for a valid play).
play_cost :: proc(deal: norn.Deal, contract: norn.Contract, play: norn.Play) -> (cost: Play_Cost, ok: bool) {
	cost.count = play.count
	boards := new(dds.Boards)
	defer free(boards)
	solved := new(dds.Solved_Boards)
	defer free(solved)

	// Walk the play once, recording each position's deal and who is on play.
	Position :: struct {
		seat:         norn.Seat, // on play
		declarer_won: int, // finished tricks the declaring side has won
		tricks_left:  int, // including the trick in progress
	}
	positions: [norn.DECK_SIZE]Position
	walk := norn.play_walk_start(deal, contract)
	trump := strain_to_dds(contract.strain)
	solve_count := 0
	for p in 0 ..= play.count {
		seat, more := norn.play_walk_next_seat(&walk).?
		if !more {
			break // all 52 played: value[52] is the tricks taken, set below
		}
		dl := &boards.deals[solve_count]
		dl.trump = trump
		in_trick := 0
		leader := seat
		if walk.trick_count > 0 {
			last := walk.tricks[walk.trick_count - 1]
			if last.count < norn.SEAT_COUNT {
				in_trick, leader = last.count, last.leader
				for k in 0 ..< in_trick {
					dl.currentTrickSuit[k] = dds.Suit(3 - int(norn.card_suit(last.cards[k])))
					dl.currentTrickRank[k] = i32(norn.card_rank(last.cards[k])) + 2
				}
			}
		}
		dl.first = dds.Hand(int(leader))
		for s in norn.Seat {
			for suit in norn.Suit {
				mask: u32
				for rank in norn.Rank {
					if walk.remaining[s] & (u64(1) << u64(norn.make_card(suit, rank))) != 0 {
						mask |= u32(1) << (u32(rank) + 2)
					}
				}
				dl.remainCards[dds.Hand(int(s))][dds.Suit(3 - int(suit))] = transmute(dds.Holding)mask
			}
		}
		boards.target[solve_count] = dds.TARGET_FIND_MAX
		boards.solutions[solve_count] = .All
		boards.mode[solve_count] = .Auto
		positions[solve_count] = {
			seat,
			walk.declarer_tricks,
			norn.PLAY_TRICKS - (walk.trick_count - (in_trick > 0 ? 1 : 0)),
		}
		solve_count += 1

		if p < play.count {
			err := norn.play_walk_card(&walk, play.cards[p])
			assert(err == .None, "play_cost: an accepted play was rejected on replay")
		}
	}
	if solve_count < play.count + 1 {
		cost.value[play.count] = i8(walk.declarer_tricks)
	}

	boards.noOfBoards = i32(solve_count)
	if dds.SolveAllBoardsBin(boards, solved) != .NO_FAULT {
		return {}, false
	}

	for p in 0 ..< solve_count {
		fut := &solved.solvedBoard[p]
		pos := positions[p]
		declaring := int(pos.seat) % 2 == int(contract.declarer) % 2
		total :: proc(pos: Position, declaring: bool, score: i32) -> i8 {
			side := int(score)
			return i8(pos.declarer_won + (side if declaring else pos.tricks_left - side))
		}
		max_score := i32(-1)
		for i in 0 ..< int(fut.cards) {
			max_score = max(max_score, fut.score[i])
		}
		if fut.cards == 0 || max_score < 0 {
			return {}, false
		}
		cost.value[p] = total(pos, declaring, max_score)
		if p == play.count {
			continue // the position after the last card: no card to judge
		}
		played := play.cards[p]
		played_score := i32(-1)
		for i in 0 ..< int(fut.cards) {
			cards := future_cards(fut, i)
			if fut.score[i] == max_score {
				cost.best[p] |= cards
			}
			if cards & (u64(1) << u64(played)) != 0 {
				played_score = fut.score[i]
			}
		}
		if played_score < 0 {
			return {}, false // the played card is not among DDS's legal cards: the walk and DDS disagree
		}
		cost.cost[p] = i8(max_score - played_score)
	}
	return cost, true
}

// The cards of one `Future_Tricks` entry: the card itself plus its equivalents (`equals` holds the lower
// ranks that play the same), as a norn card bitmask.
@(private = "file")
future_cards :: proc(fut: ^dds.Future_Tricks, i: int) -> (cards: u64) {
	suit := norn.Suit(3 - int(fut.suit[i]))
	ranks := transmute(u32)fut.equals[i] | u32(1) << u32(fut.rank[i])
	for rank in norn.Rank {
		if ranks & (u32(1) << (u32(rank) + 2)) != 0 {
			cards |= u64(1) << u64(norn.make_card(suit, rank))
		}
	}
	return cards
}

// norn's contract strain as DDS's (the two enums order their variants differently).
strain_to_dds :: proc(strain: norn.Contract_Strain) -> dds.Strain {
	switch strain {
	case .Clubs:
		return .Clubs
	case .Diamonds:
		return .Diamonds
	case .Hearts:
		return .Hearts
	case .Spades:
		return .Spades
	case .NoTrumps:
		return .NT
	}
	return .NT
}

/*
The `data-play` JSON the card page replays a board from. One object:

	{"dec":"W","con":"2D","hands":{"N":"T86.KQ.A2.AKQJ32",...},
	 "c":["4S","5S",...],"by":"NESW...","win":"WWSN...",
	 "dd":[8,8,...],"cost":[0,0,...],"best":{"8":["KD","8C",...]},
	 "res":7,"err":"Revoke","erri":12}

`c` the cards in order (rank then suit, as `card_word`), `by` who played each, `win` the winner of each
FINISHED trick, `hands` the deal as PBN `S.H.D.C` per seat so the page can shrink the hands as cards go.
`dd` (count+1 values, see `Play_Cost.value`), `cost` and `best` (only for cards that cost something) are
present only when the play was solved; `res` only when the record states one; `err`/`erri` only when the
record's play was cut at a bad card (`erri` = position of that card in the record).
*/
write_play_json :: proc(
	b: ^strings.Builder,
	deal: norn.Deal,
	contract: norn.Contract,
	play: norn.Play,
	cost: Maybe(Play_Cost),
) {
	strings.write_byte(b, '{') // never in a format string: `{` is an argument reference to fmt
	fmt.sbprintf(
		b,
		`"dec":"%c","con":"%d%s"`,
		seat_letter(contract.declarer),
		contract.level,
		contract_strain_word(contract.strain),
	)
	strings.write_string(b, `,"hands":{`)
	for seat, i in norn.Seat {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, `"%c":"`, seat_letter(seat))
		norn.write_hand_pbn(b, deal[seat])
		strings.write_byte(b, '"')
	}
	strings.write_string(b, `},"c":[`)
	for i in 0 ..< play.count {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, `"%s"`, card_word(play.cards[i]))
	}
	walk := norn.play_tricks(deal, contract, play)
	strings.write_string(b, `],"by":"`)
	for t in 0 ..< walk.trick_count {
		trick := walk.tricks[t]
		for k in 0 ..< trick.count {
			strings.write_byte(b, seat_letter(norn.seat_after(trick.leader, k)))
		}
	}
	strings.write_string(b, `","win":"`)
	for t in 0 ..< walk.trick_count {
		if winner, done := walk.tricks[t].winner.?; done {
			strings.write_byte(b, seat_letter(winner))
		}
	}
	strings.write_byte(b, '"')
	if c, solved := cost.?; solved {
		strings.write_string(b, `,"dd":[`)
		for i in 0 ..= c.count {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%d", c.value[i])
		}
		strings.write_string(b, `],"cost":[`)
		for i in 0 ..< c.count {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%d", c.cost[i])
		}
		strings.write_string(b, `],"best":{`)
		first := true
		for i in 0 ..< c.count {
			if c.cost[i] <= 0 {
				continue
			}
			if !first {
				strings.write_byte(b, ',')
			}
			first = false
			fmt.sbprintf(b, `"%d":[`, i)
			n := 0
			for card in 0 ..< norn.DECK_SIZE {
				if c.best[i] & (u64(1) << u64(card)) != 0 {
					if n > 0 {
						strings.write_byte(b, ',')
					}
					fmt.sbprintf(b, `"%s"`, card_word(norn.Card(card)))
					n += 1
				}
			}
			strings.write_byte(b, ']')
		}
		strings.write_byte(b, '}')
	}
	if res, has := play.result.?; has {
		fmt.sbprintf(b, `,"res":%d`, res)
	}
	if play.error != .None {
		fmt.sbprintf(b, `,"err":"%v","erri":%d`, play.error, play.error_index)
	}
	strings.write_byte(b, '}')
}

// "S" / "H" / "D" / "C" / "NT" for a contract strain, as contracts are written.
contract_strain_word :: proc(strain: norn.Contract_Strain) -> string {
	switch strain {
	case .Clubs:
		return "C"
	case .Diamonds:
		return "D"
	case .Hearts:
		return "H"
	case .Spades:
		return "S"
	case .NoTrumps:
		return "NT"
	}
	return "NT"
}
