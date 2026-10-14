package sampled

import "core:fmt"
import "core:strings"

import "norn:norn"

// One board's sampled results: the grid, the opening-lead sub-grids, the contract they are read for, its
// misguess tax and the tax under each lead. `leads` and `lead_tax` are heap-allocated (~118 KB and ~7 KB natively
// - too big for a stack frame); free them with `advice_free`.
Advice :: struct {
	have:     bool,
	grid:     Grid_Result,
	leads:    ^Lead_Grids,
	contract: Contract,
	auto:     bool, // the contract was picked from the grid (none was named)
	tax:      Tax_Result, // valid iff tax_ok
	tax_ok:   bool,
	lead_tax: ^Lead_Tax,
}

advice_free :: proc(adv: ^Advice) {
	if adv.leads != nil {
		free(adv.leads)
		adv.leads = nil
	}
	if adv.lead_tax != nil {
		free(adv.lead_tax)
		adv.lead_tax = nil
	}
}

// Everything the page shows for a sampled board, read out of one solved batch (no solving): the lead grids
// (whose base is the board's grid), and for the contract - the one named, else `gating`, the one the sampling
// stopped on - its tax and the tax under each lead.
advise :: proc(
	board: norn.Board,
	s: ^Solved_Sample,
	contract: Contract,
	has_contract: bool,
	gating: Contract,
) -> (
	adv: Advice,
) {
	adv.leads = new(Lead_Grids)
	lead_grids_from_sample(s, adv.leads)
	adv.grid = adv.leads.base
	adv.have = true
	if has_contract {
		adv.contract = contract
	} else {
		adv.contract, adv.auto = gating, true
	}
	adv.tax, adv.tax_ok = tax_from_sample(board, s, adv.contract)
	adv.lead_tax = new(Lead_Tax)
	lead_tax_from_sample(board, s, adv.contract, adv.lead_tax)
	return adv
}

// The contract a 2-hand board is to be read for, when one is NAMED: `contract` when the caller gave one, else
// the one the board itself records (a LIN auction, PBN `[Contract]`/`[Declarer]`) when its declarer is on
// `side` - a board where the OTHER pair declared still has this side's best contract picked from the grid.
named_contract :: proc(
	board: norn.Board,
	side: bit_set[norn.Seat],
	contract: Contract,
	has_contract: bool,
) -> (
	Contract,
	bool,
) {
	if has_contract {
		return contract, true
	}
	if c, decl, ok := board_contract(board); ok && decl in side {
		return c, true
	}
	return {}, false
}

// A contract as the page's attributes name it: the level then the strain's key, `4h`, `3nt`.
write_contract_key :: proc(b: ^strings.Builder, c: Contract) {
	fmt.sbprintf(b, "%d%s", c.level, strain_key(c.strain))
}

// The inverse of `write_contract_key`.
parse_contract_key :: proc(text: string) -> (c: Contract, ok: bool) {
	if len(text) < 2 || text[0] < '1' || text[0] > '7' {
		return
	}
	for strain in Strain {
		if text[1:] == strain_key(strain) {
			return Contract{int(text[0] - '0'), strain}, true
		}
	}
	return
}

// The most of each kind of defender inference a 2-hand board's page names (and a share link carries, in four
// bits): `analyse` refuses more.
MAX_LISTED :: 15

// The defender inferences a 2-hand board's sampling was conditioned on, as its page names them (`data-held`,
// `data-shape`) and a share link carries them, so a reader's sampling deals the same layouts. Fixed-size, so a
// board holding one needs no freeing.
Board_Constraints :: struct {
	held:        [MAX_LISTED]Held_Card,
	held_count:  int,
	shape:       [MAX_LISTED]Card_Constraint,
	shape_count: int,
}

// `cons` as a `Board_Constraints`; ok=false when it has more than MAX_LISTED of either kind.
board_constraints :: proc(cons: Sample_Constraints) -> (bc: Board_Constraints, ok: bool) {
	if len(cons.held) > MAX_LISTED || len(cons.shape) > MAX_LISTED {
		return
	}
	copy(bc.held[:], cons.held)
	copy(bc.shape[:], cons.shape)
	bc.held_count, bc.shape_count = len(cons.held), len(cons.shape)
	return bc, true
}

// The inverse: slices into `bc`, so valid while it is.
sample_constraints :: proc(bc: ^Board_Constraints) -> Sample_Constraints {
	return {shape = bc.shape[:bc.shape_count], held = bc.held[:bc.held_count]}
}

// A defender's card the sampling was conditioned on, as the page names it: the seat, then the card rank-first,
// `W:3S` (`--lead`'s own spelling).
write_held_key :: proc(b: ^strings.Builder, h: Held_Card) {
	fmt.sbprintf(b, "%c:%s", seat_letter(h.seat), card_word(h.card))
}

// The inverse of `write_held_key`.
parse_held_key :: proc(text: string) -> (h: Held_Card, ok: bool) {
	if len(text) != 4 || text[1] != ':' {
		return
	}
	seat := norn.seat_from_letter(text[0]) or_return
	card := norn.parse_card(text[2:]) or_return
	return Held_Card{seat, card}, true
}

// A defender's suit length, as the page names it: the seat, the suit, then the bounds, `E:S:0-0` (a void),
// `W:H:5-13` (five or more) - `--len`'s spelling with both bounds written.
write_shape_key :: proc(b: ^strings.Builder, c: Card_Constraint) {
	fmt.sbprintf(b, "%c:%c:%d-%d", seat_letter(c.seat), norn.suit_letter(c.suit), c.min, c.max)
}

// The inverse of `write_shape_key`; ok=false for bounds outside 0..13 or the wrong way round.
parse_shape_key :: proc(text: string) -> (c: Card_Constraint, ok: bool) {
	if len(text) < 7 || text[1] != ':' || text[3] != ':' {
		return
	}
	c.seat = norn.seat_from_letter(text[0]) or_return
	c.suit = norn.suit_from_letter(text[2]) or_return
	dash := strings.index_byte(text[4:], '-')
	if dash < 0 {
		return
	}
	c.min = parse_count(text[4:][:dash]) or_return
	c.max = parse_count(text[4:][dash + 1:]) or_return
	return c, c.min <= c.max
}

// A card count, 0..13, in decimal.
@(private = "file")
parse_count :: proc(text: string) -> (n: int, ok: bool) {
	if len(text) < 1 || len(text) > 2 {
		return
	}
	for ch in transmute([]u8)text {
		if ch < '0' || ch > '9' {
			return
		}
		n = n * 10 + int(ch - '0')
	}
	return n, n <= 13
}

// The page's lists: keys separated by spaces (`data-held="W:3S E:KH"`). `held` and `shape` are the two
// attributes' values, "" for none. ok=false for a key that does not read or more than MAX_LISTED of a kind.
parse_board_constraints :: proc(held: string, shape: string) -> (bc: Board_Constraints, ok: bool) {
	held_text, shape_text := held, shape
	for key in strings.split_iterator(&held_text, " ") {
		if key == "" {
			continue
		}
		if bc.held_count == MAX_LISTED {
			return
		}
		bc.held[bc.held_count] = parse_held_key(key) or_return
		bc.held_count += 1
	}
	for key in strings.split_iterator(&shape_text, " ") {
		if key == "" {
			continue
		}
		if bc.shape_count == MAX_LISTED {
			return
		}
		bc.shape[bc.shape_count] = parse_shape_key(key) or_return
		bc.shape_count += 1
	}
	return bc, true
}

// A 2-hand advisor board's hidden `.par` element: the CCA slider's starting `target`, the contract when one is
// named (`data-contract`) and the defender inferences the sampling is conditioned on (`data-held`: the record's
// opening lead and any `--lead`; `data-shape`: any `--void`/`--len`) - all of which a share link carries, so the
// reader's sampling reads the same contract over the same layouts - and,
// when the board was sampled, its grid (`data-sim`), its opening-lead sub-grids (`data-sim-leads`) and - when a
// blind two-way guess costs something at this contract - the guess notes (`data-sim-guess`). The advisor's page
// and the shared-deals player write it alike; the player writes it twice, first without the sampling.
write_advisor_par :: proc(
	b: ^strings.Builder,
	target: int,
	side: bit_set[norn.Seat],
	adv: ^Advice = nil,
	contract: Maybe(Contract) = nil,
	cons: Board_Constraints = {},
) {
	fmt.sbprintf(b, "\n<div class=\"par\" data-target=\"%d\"", target)
	if c, has := contract.?; has {
		strings.write_string(b, ` data-contract="`)
		write_contract_key(b, c)
		strings.write_byte(b, '"')
	}
	if cons.held_count > 0 {
		strings.write_string(b, ` data-held="`)
		for i in 0 ..< cons.held_count {
			h := cons.held[i]
			if i > 0 {
				strings.write_byte(b, ' ')
			}
			write_held_key(b, h)
		}
		strings.write_byte(b, '"')
	}
	if cons.shape_count > 0 {
		strings.write_string(b, ` data-shape="`)
		for i in 0 ..< cons.shape_count {
			c := cons.shape[i]
			if i > 0 {
				strings.write_byte(b, ' ')
			}
			write_shape_key(b, c)
		}
		strings.write_byte(b, '"')
	}
	if adv != nil && adv.have {
		strings.write_string(b, " data-sim='")
		write_sim_json(b, &adv.grid, adv.contract, adv.tax, adv.tax_ok)
		strings.write_string(b, "'")
		strings.write_string(b, " data-sim-leads='")
		write_leads_json(b, adv.leads, side, adv.lead_tax)
		strings.write_string(b, "'")
		if adv.tax_ok && tax_has_narratable_guess(adv.tax) {
			strings.write_string(b, " data-sim-guess='")
			write_sim_guess_json(b, side, adv.tax)
			strings.write_string(b, "'")
		}
	}
	strings.write_string(b, " hidden></div>\n")
}
