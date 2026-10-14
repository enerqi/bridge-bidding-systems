package analyse

/*
	board.odin — per-board facts and the DDS sampling step (part of package `analyse`; see analyse.odin).

	`sample_board` is the one expensive proc here: it solves the sampled layouts ONCE and derives the
	lead grids and the misguess tax as filters over that single batch.
*/

import "core:fmt"

import "../deal_solve"
import "../sampled"
import "norn:combo"
import "norn:norn"

// One board's DDS-sample results (empty when --sample is off or the board is not a 2-hand advisor input):
// `sampled.Advice`, shared with the shared-deals player. Free with `board_sample_free`.
Board_Sample :: sampled.Advice
board_sample_free :: sampled.advice_free

// Sample one board if --sample is on: validate any constraints against THIS board's defenders, run the
// lead grids, and resolve the contract (explicit or auto). Returns have=false with "" when sampling is
// off; a non-empty error message on a hard failure.
sample_board :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	args: ^Args,
	asked: deal_solve.Contract,
	has_asked: bool,
) -> (
	bs: Board_Sample,
	err: string,
) {
	if args.sample <= 0 {
		return {}, ""
	}
	// When no --contract was given, fall back to the contract the board itself names (LIN auction / PBN
	// [Contract]) — but only if its declarer is on the side being analysed, so a board where the OTHER
	// pair declares still auto-picks THIS side's best contract. An explicit --contract still overrides
	// (has_asked is true then). auto stays false: this is the real contract, not a guess.
	contract, has_contract := sampled.named_contract(board, side, asked, has_asked)
	defenders := bit_set[norn.Seat]{.North, .East, .South, .West} - side
	for con in args.constraints {
		if con.seat not_in defenders {
			return {}, fmt.tprintf("--void/--len seat %v is a known hand, not a defender", con.seat)
		}
	}
	held := held_cards(board, args)
	for h in held {
		if h.seat not_in defenders {
			return {}, fmt.tprintf("--lead seat %v is a known hand, not a defender", h.seat)
		}
		if is_known_card(board, h.card) {
			return {}, "--lead card is already in a known hand (only defenders' unknown cards can be led)"
		}
	}
	cons := deal_solve.Sample_Constraints {
		shape = args.constraints[:],
		held  = held,
	}
	// Solve the sampled layouts ONCE, with adaptive early-stop: `args.sample` is a CAP — sampling stops as soon
	// as the picked contract's make-% is statistically resolved (lopsided boards stop short; knife-edge boards
	// run the full cap). The lead grids and the misguess tax are then pure FILTERS over that one solved batch
	// (they otherwise each draw+solve the identical seeded layouts), so a board pays for its samples once, not
	// twice. `gating` is the contract that gated the stop — the auto-pick when the caller gave none.
	s, gating, sok := deal_solve.solve_sample_adaptive(
		board,
		side,
		args.sample,
		args.seed,
		cons,
		contract,
		has_contract,
	)
	if !sok {
		return {},
			"DDS sampling failed — the constraints are too rare or impossible for these hands (could not draw enough consistent deals)"
	}
	defer deal_solve.solved_sample_free(&s)
	// The lead grids, the misguess tax and the per-lead tax are FILTERS over that one solved batch (no extra
	// solves), for the named contract or else `gating`, the one the sampling stopped on.
	bs = sampled.advise(board, &s, contract, has_contract, gating)
	return bs, ""
}

// The defenders' cards the sampling is conditioned on: `--lead`, plus, on a 2-hand board, the opening lead its
// record gives (`norn.Board.opening_lead`: a PBN `[Play]` section) - the one card of a defender's hand the
// record shows - unless a `--lead` already names that card. Temp memory.
held_cards :: proc(board: norn.Board, args: ^Args) -> []deal_solve.Held_Card {
	held := make([dynamic]deal_solve.Held_Card, 0, len(args.held) + 1, context.temp_allocator)
	append(&held, ..args.held[:])
	if lead, has := recorded_lead(board, args); has {
		append(&held, deal_solve.Held_Card{seat = lead.leader, card = lead.card})
	}
	return held[:]
}

// A 2-hand board's recorded opening lead, when it conditions the sampling (see `held_cards`).
recorded_lead :: proc(board: norn.Board, args: ^Args) -> (lead: norn.Opening_Lead, ok: bool) {
	if board_fully_known(board) {
		return
	}
	lead = board.opening_lead.? or_return
	for h in args.held {
		if h.card == lead.card {
			return
		}
	}
	return lead, true
}

// True iff all four hands are present — a complete deal, not the declarer+dummy (2-hand) advisor input.
// Such a board takes the EXACT double-dummy path (deal_solve.annotate solves the actual deal) rather than the
// DDS-sampling advisor (which models the unknown defenders).
board_fully_known :: proc(board: norn.Board) -> bool {
	return board.known == {.North, .East, .South, .West}
}

// Is `card` held by one of the board's KNOWN seats (declarer or dummy)? Such a card cannot be a
// defender's lead. (A known hand has 13 real cards; unspecified seats hold none of the real deck here.)
is_known_card :: proc(board: norn.Board, card: norn.Card) -> bool {
	for seat in board.known {
		for c in board.deal[seat] {
			if c == card {
				return true
			}
		}
	}
	return false
}

// Suit name for the constraint note.
suit_word :: proc(s: norn.Suit) -> string {
	switch s {
	case .Spades:
		return "spades"
	case .Hearts:
		return "hearts"
	case .Diamonds:
		return "diamonds"
	case .Clubs:
		return "clubs"
	}
	return "?"
}

// A full `norn.Deal` carrying the known partnership's two hands in BOTH partnership slots, so
// `combo.annotate` emits the same (known-side) analysis for its N/S and E/W blobs. The defenders'
// real (unknown) cards never enter here — the compass draws them face-down from `board.known` instead.
synth_deal :: proc(board: norn.Board, side: bit_set[norn.Seat]) -> norn.Deal {
	a, b: norn.Seat = .North, .South
	if side == combo.EW_SIDE {
		a, b = .East, .West
	}
	ha, hb := board.deal[a], board.deal[b]
	synth: norn.Deal
	synth[.North], synth[.South] = ha, hb
	synth[.East], synth[.West] = ha, hb
	return synth
}
