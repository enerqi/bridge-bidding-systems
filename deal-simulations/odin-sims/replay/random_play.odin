#+build !js
package replay

import "core:math/rand"

import "norn:norn"

// A legal play of `cards` cards (1-52) of `deal` in `contract`, every card picked at random from those its player
// may play: test data for what reads, packs and costs a recorded play (`share`'s tests, the player's reference
// pages), where a real record would have to be found for every shape wanted.
random_play :: proc(deal: norn.Deal, contract: norn.Contract, cards: int) -> (play: norn.Play) {
	walk := norn.play_walk_start(deal, contract)
	for play.count < clamp(cards, 1, norn.DECK_SIZE) {
		seat, more := norn.play_walk_next_seat(&walk).?
		if !more {
			break
		}
		held: [norn.HAND_SIZE]norn.Card
		n := 0
		for c in 0 ..< norn.DECK_SIZE {
			if walk.remaining[seat] & (u64(1) << u64(c)) != 0 {
				held[n] = norn.Card(c)
				n += 1
			}
		}
		// A card that does not follow suit is refused while one that does is held: draw until one is taken.
		for {
			card := held[rand.int_max(n)]
			if norn.play_walk_card(&walk, card) == .None {
				play.cards[play.count] = card
				play.count += 1
				break
			}
		}
	}
	return play
}
