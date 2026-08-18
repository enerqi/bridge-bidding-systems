package analyse

/*
	board.odin — per-board facts and the DDS sampling step (part of package `analyse`; see analyse.odin).

	`sample_board` is the one expensive proc here: it solves the sampled layouts ONCE and derives the
	lead grids and the misguess tax as filters over that single batch.
*/

import "core:fmt"

import "../deal_solve"
import "norn:combo"
import "norn:norn"

// One board's DDS-sample results (empty when --sample is off or the board is not a 2-hand advisor input).
// `leads` is heap-allocated (~118 KB — kept off the stack); the caller frees it with `board_sample_free`.
Board_Sample :: struct {
	have:     bool,
	grid:     deal_solve.Grid_Result,
	leads:    ^deal_solve.Lead_Grids,
	contract: deal_solve.Contract,
	auto:     bool, // contract was auto-picked (no --contract)
	tax:      deal_solve.Tax_Result, // the misguess-tax achievable-SD estimate for `contract` (valid iff tax_ok)
	tax_ok:   bool,
	lead_tax: ^deal_solve.Lead_Tax, // per-opening-lead conditioned tax for `contract` (heap; freed with the sample)
}

// Release a Board_Sample's heap grids (no-op when sampling was off).
board_sample_free :: proc(bs: ^Board_Sample) {
	if bs.leads != nil {
		free(bs.leads)
		bs.leads = nil
	}
	if bs.lead_tax != nil {
		free(bs.lead_tax)
		bs.lead_tax = nil
	}
}

// Sample one board if --sample is on: validate any constraints against THIS board's defenders, run the
// lead grids, and resolve the contract (explicit or auto). Returns have=false with "" when sampling is
// off; a non-empty error message on a hard failure.
sample_board :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
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
	// (has_contract is already true then). auto stays false: this is the real contract, not a guess.
	contract, has_contract := contract, has_contract
	if !has_contract {
		if c, decl, ok := deal_solve.board_contract(board); ok && decl in side {
			contract, has_contract = c, true
		}
	}
	defenders := bit_set[norn.Seat]{.North, .East, .South, .West} - side
	for con in args.constraints {
		if con.seat not_in defenders {
			return {}, fmt.tprintf("--void/--len seat %v is a known hand, not a defender", con.seat)
		}
	}
	for h in args.held {
		if h.seat not_in defenders {
			return {}, fmt.tprintf("--lead seat %v is a known hand, not a defender", h.seat)
		}
		if is_known_card(board, h.card) {
			return {}, "--lead card is already in a known hand (only defenders' unknown cards can be led)"
		}
	}
	cons := deal_solve.Sample_Constraints {
		shape = args.constraints[:],
		held  = args.held[:],
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
	lg := new(deal_solve.Lead_Grids)
	deal_solve.lead_grids_from_sample(&s, lg)
	bs.leads = lg
	bs.grid = lg.base
	bs.have = true
	if has_contract {
		bs.contract = contract
	} else {
		bs.contract, bs.auto = gating, true
	}
	// Achievable single-dummy (the misguess-tax 4th rung) for the resolved contract — a FILTER over the SAME
	// solved batch as the lead grids (no extra solves). A failure just drops the achievable rung — the ceiling
	// verdict still stands.
	bs.tax, bs.tax_ok = deal_solve.tax_from_sample(board, &s, bs.contract)
	// Per-opening-lead conditioned tax for the resolved contract — another FILTER over the same solved batch
	// (no extra solves). Lets the card page show a coupled, lead-conditioned achievable when a lead is picked
	// (a lead that reveals the trapped honour resolves its guess → tax 0). Heap-held like `leads`.
	lt := new(deal_solve.Lead_Tax)
	deal_solve.lead_tax_from_sample(board, &s, bs.contract, lt)
	bs.lead_tax = lt
	return bs, ""
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
