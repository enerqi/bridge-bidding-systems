package replay

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

import "norn:norn"

// The board's recorded play as the hidden `.play` element the card page replays it from: the play itself
// (`data-play`, with the per-card costs when `cost` has them) and its bytes for a share link (`data-pack`).
write_play_element :: proc(
	b: ^strings.Builder,
	deal: norn.Deal,
	contract: norn.Contract,
	play: norn.Play,
	cost: Maybe(Play_Cost),
) {
	strings.write_string(b, `<div class="play" hidden data-play='`)
	write_play_json(b, deal, contract, play, cost)
	strings.write_string(b, `' data-pack="`)
	packed := make([dynamic]u8, context.temp_allocator)
	pack_play(&packed, deal, contract, play)
	strings.write_string(b, base64.encode(packed[:], base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding}))
	strings.write_string(b, `"></div>`)
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

A solved play that stops before the last card goes on to the end double dummy (`Play_Cost.out`): then `c`,
`by` and `win` run to the last card, and `rec` is how many of them the record has. `dd`, `cost` and `best`
still cover the record's cards only.
*/
write_play_json :: proc(
	b: ^strings.Builder,
	deal: norn.Deal,
	contract: norn.Contract,
	play: norn.Play,
	cost: Maybe(Play_Cost),
) {
	// The record's cards, then the play-out's.
	shown := play
	recorded := play.count
	if c, solved := cost.?; solved {
		for k in 0 ..< c.out_count {
			shown.cards[shown.count] = c.out[k]
			shown.count += 1
		}
	}
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
	for i in 0 ..< shown.count {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, `"%s"`, card_word(shown.cards[i]))
	}
	walk := norn.play_tricks(deal, contract, shown)
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
	if shown.count > recorded {
		fmt.sbprintf(b, `,"rec":%d`, recorded)
	}
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

/*
A play as BYTES, for a share link (`share`, format `v2.`) - the deal itself travels beside it:

	byte 0     the cards played (1-52) in bits 0-5; bit 6 a result follows, bit 7 a bad card follows
	byte 1     the contract: level-1 in bits 0-2, the strain in bits 3-5 (DDS's order: S H D C NT), the
	           declarer in bits 6-7 (N E S W)
	then       each card as a 4-bit index into the cards its player still holds, in card order (low
	           nibble first, a byte for two cards): ~26 bytes for a whole play
	then       the result (the declaring side's tricks, 0-13) when bit 6 says so, and the bad card's kind
	           (`norn.Play_Error`) and its place in the record when bit 7 does

A board without a play is one zero byte, which `share` writes itself. `unpack_play` replays every card, so a
link cannot carry a play that is not one.
*/
pack_play :: proc(out: ^[dynamic]u8, deal: norn.Deal, contract: norn.Contract, play: norn.Play) {
	_, has_result := play.result.?
	append(
		out,
		u8(play.count) | (0x40 if has_result else 0) | (0x80 if play.error != .None else 0),
		u8(contract.level - 1) | u8(dds_strain(contract.strain)) << 3 | u8(contract.declarer) << 6,
	)
	walk := norn.play_walk_start(deal, contract)
	nibble: u8
	for i in 0 ..< play.count {
		seat, _ := norn.play_walk_next_seat(&walk).?
		index: u8
		for c in 0 ..< int(play.cards[i]) {
			if walk.remaining[seat] & (u64(1) << u64(c)) != 0 {
				index += 1
			}
		}
		if i % 2 == 0 {
			nibble = index
		} else {
			append(out, nibble | index << 4)
		}
		_ = norn.play_walk_card(&walk, play.cards[i])
	}
	if play.count % 2 == 1 {
		append(out, nibble)
	}
	if res, has := play.result.?; has {
		append(out, u8(clamp(res, 0, norn.PLAY_TRICKS)))
	}
	if play.error != .None {
		append(out, u8(play.error), u8(clamp(play.error_index, 0, 255)))
	}
}

// The inverse of `pack_play`, for `deal`: `used` is how many bytes it read. ok=false on bytes no encoder
// writes, or a card its player does not hold or may not play.
unpack_play :: proc(bytes: []u8, deal: norn.Deal) -> (contract: norn.Contract, play: norn.Play, used: int, ok: bool) {
	if len(bytes) < 2 {
		return
	}
	play.count = int(bytes[0] & 0x3F)
	has_result, has_error := bytes[0] & 0x40 != 0, bytes[0] & 0x80 != 0
	level, strain := int(bytes[1] & 7) + 1, int(bytes[1] >> 3) & 7
	if play.count < 1 || play.count > norn.DECK_SIZE || level > 7 || strain > 4 {
		return
	}
	strains := [5]norn.Contract_Strain{.Spades, .Hearts, .Diamonds, .Clubs, .NoTrumps}
	contract = {level = level, strain = strains[strain], declarer = norn.Seat(bytes[1] >> 6)}
	used = 2 + (play.count + 1) / 2
	if len(bytes) < used {
		return
	}
	walk := norn.play_walk_start(deal, contract)
	for i in 0 ..< play.count {
		index := int(bytes[2 + i / 2] >> (4 * uint(i % 2))) & 15
		seat, more := norn.play_walk_next_seat(&walk).?
		if !more {
			return
		}
		card := -1
		for c in 0 ..< norn.DECK_SIZE {
			if walk.remaining[seat] & (u64(1) << u64(c)) != 0 {
				if index == 0 {
					card = c
					break
				}
				index -= 1
			}
		}
		if card < 0 || norn.play_walk_card(&walk, norn.Card(card)) != .None {
			return
		}
		play.cards[i] = norn.Card(card)
	}
	if has_result {
		if len(bytes) < used + 1 || int(bytes[used]) > norn.PLAY_TRICKS {
			return
		}
		play.result = int(bytes[used])
		used += 1
	}
	if has_error {
		if len(bytes) < used + 2 || bytes[used] == 0 || int(bytes[used]) > int(max(norn.Play_Error)) {
			return
		}
		play.error = norn.Play_Error(bytes[used])
		play.error_index = int(bytes[used + 1])
		used += 2
	}
	return contract, play, used, true
}

// Readable card label, rank-first: "KH", "TS". (norn.Card prints as a raw number under %v.)
card_word :: proc(c: norn.Card) -> string {
	return fmt.tprintf("%c%c", norn.rank_char(norn.card_rank(c)), norn.suit_letter(norn.card_suit(c)))
}

// Uppercase seat letter for a norn.Seat.
seat_letter :: proc(s: norn.Seat) -> u8 {
	switch s {
	case .North:
		return 'N'
	case .East:
		return 'E'
	case .South:
		return 'S'
	case .West:
		return 'W'
	}
	return '?'
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
