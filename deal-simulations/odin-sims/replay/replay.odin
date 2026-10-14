/*
replay — a recorded play as the card page replays it, and what each card of it cost, WITHOUT the solver.

The card page steps through a board's recorded play from a hidden `.play` element (`write_play_element`), and
when every position of the play has been solved double dummy it also shows what each card cost. The solving is
DDS's; everything around it is here, with no engine in it, so the native advisor (`deal_solve.play_cost`, one
batched DDS call) and the shared-deals player (DDS compiled to wasm, one `SolveBoard` a position in a Web
Worker) build the same positions, read the same answers and write the same element:

	positions(deal, contract, play)   every position before a card, as DDS's `deal` struct (`Dds_Deal`)
	costs(&positions, futures, play)  DDS's answer for each (`Dds_Future`) -> `Play_Cost`
	write_play_element / _json        the element, with the costs when there are some

A play also travels in a share LINK (`share`, format `v2.`): `pack_play` / `unpack_play` are its bytes, and the
element carries them (`data-pack`) so a page's own Share button can put them in a link without redoing this.
*/
package replay

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

// DDS's `deal` struct, field for field (96 bytes): what `SolveBoard` takes. Suits are DDS's (0 spades .. 3
// clubs), strains too (4 notrumps), hands N E S W, and a holding has rank r (2..14) as bit r.
Dds_Deal :: struct {
	trump:              i32,
	first:              i32,
	current_trick_suit: [3]i32,
	current_trick_rank: [3]i32,
	remain_cards:       [4][4]u32,
}

// DDS's `futureTricks` (216 bytes): `SolveBoard`'s answer, every legal card with its score when asked for all.
Dds_Future :: struct {
	nodes:  i32,
	cards:  i32,
	suit:   [13]i32,
	rank:   [13]i32,
	equals: [13]u32,
	score:  [13]i32,
}

#assert(size_of(Dds_Deal) == 96)
#assert(size_of(Dds_Future) == 216)

// How every position is asked: the best score (`target` -1), all cards with their scores (`solutions` 3), and
// the transposition table reused but a forced card still searched (`mode` 1): skipping it would leave its score
// unset, and a forced card is still a position whose value the trajectory needs.
DDS_TARGET :: -1
DDS_SOLUTIONS :: 3
DDS_MODE :: 1

// One position to solve: DDS's deal, plus what turns its answer into the declaring side's total.
Position :: struct {
	seat:         norn.Seat, // on play
	declarer_won: int, // finished tricks the declaring side has won
	tricks_left:  int, // including the trick in progress
}

Positions :: struct {
	declarer:    norn.Seat,
	count:       int, // positions to solve: the play's cards + 1, or the cards alone when all 52 were played
	deals:       [norn.DECK_SIZE + 1]Dds_Deal,
	at:          [norn.DECK_SIZE + 1]Position,
	// The declaring side's tricks once all 52 cards are played (no position after the last card to solve).
	final_value: int,
}

// Every position of `play`, before each card and after the last (unless the play ran to the end).
positions :: proc(deal: norn.Deal, contract: norn.Contract, play: norn.Play) -> (out: Positions) {
	out.declarer = contract.declarer
	walk := norn.play_walk_start(deal, contract)
	trump := dds_strain(contract.strain)
	for p in 0 ..= play.count {
		seat, more := norn.play_walk_next_seat(&walk).?
		if !more {
			break
		}
		dl := &out.deals[out.count]
		dl.trump = trump
		in_trick := 0
		leader := seat
		if walk.trick_count > 0 {
			last := walk.tricks[walk.trick_count - 1]
			if last.count < norn.SEAT_COUNT {
				in_trick, leader = last.count, last.leader
				for k in 0 ..< in_trick {
					dl.current_trick_suit[k] = i32(3 - int(norn.card_suit(last.cards[k])))
					dl.current_trick_rank[k] = i32(norn.card_rank(last.cards[k])) + 2
				}
			}
		}
		dl.first = i32(leader)
		for s in norn.Seat {
			for suit in norn.Suit {
				mask: u32
				for rank in norn.Rank {
					if walk.remaining[s] & (u64(1) << u64(norn.make_card(suit, rank))) != 0 {
						mask |= u32(1) << (u32(rank) + 2)
					}
				}
				dl.remain_cards[int(s)][3 - int(suit)] = mask
			}
		}
		out.at[out.count] = {seat, walk.declarer_tricks, norn.PLAY_TRICKS - (walk.trick_count - (in_trick > 0 ? 1 : 0))}
		out.count += 1
		if p < play.count {
			err := norn.play_walk_card(&walk, play.cards[p])
			assert(err == .None, "replay.positions: an accepted play was rejected on replay")
		}
	}
	out.final_value = walk.declarer_tricks
	return
}

// The costs from DDS's answers, one a position (`futures[:positions.count]`). ok=false when an answer cannot
// be right: no cards, or the card played not among the legal ones.
costs :: proc(positions: ^Positions, futures: []Dds_Future, play: norn.Play) -> (cost: Play_Cost, ok: bool) {
	cost.count = play.count
	if positions.count < play.count + 1 {
		cost.value[play.count] = i8(positions.final_value)
	}
	if len(futures) < positions.count {
		return {}, false
	}
	for p in 0 ..< positions.count {
		fut := &futures[p]
		pos := positions.at[p]
		// The declaring side is the declarer's: the declarer and the dummy, two seats apart.
		declaring := int(pos.seat) % 2 == int(positions.declarer) % 2
		max_score := i32(-1)
		for i in 0 ..< int(fut.cards) {
			max_score = max(max_score, fut.score[i])
		}
		if fut.cards <= 0 || fut.cards > 13 || max_score < 0 {
			return {}, false
		}
		side := int(max_score)
		cost.value[p] = i8(pos.declarer_won + (side if declaring else pos.tricks_left - side))
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

// The cards of one `Dds_Future` entry: the card itself plus its equivalents (`equals` holds the lower ranks
// that play the same), as a norn card bitmask.
@(private = "file")
future_cards :: proc(fut: ^Dds_Future, i: int) -> (cards: u64) {
	suit := norn.Suit(3 - int(fut.suit[i]))
	ranks := fut.equals[i] | u32(1) << u32(fut.rank[i])
	for rank in norn.Rank {
		if ranks & (u32(1) << (u32(rank) + 2)) != 0 {
			cards |= u64(1) << u64(norn.make_card(suit, rank))
		}
	}
	return cards
}

// norn's contract strain as DDS's (0 spades, 1 hearts, 2 diamonds, 3 clubs, 4 notrumps).
dds_strain :: proc(strain: norn.Contract_Strain) -> i32 {
	switch strain {
	case .Spades:
		return 0
	case .Hearts:
		return 1
	case .Diamonds:
		return 2
	case .Clubs:
		return 3
	case .NoTrumps:
		return 4
	}
	return 4
}
