package deal_solve

/*
	sim_json — the `data-sim*` JSON contract for the card page.

	The offline card page's JS (norn's `render.odin` / `html_cards_*.tmpl`: `simBand` and friends) reads the
	sampled/exact trick data out of `data-sim`, `data-sim-leads` and `data-sim-guess` attributes. The
	numbers in them are this package's results — `Grid_Result`, `Tax_Result`, `Lead_Grids`, `Lead_Tax`,
	`Contract` — so their SERIALISATION lives here, next to the code that computes them, rather than in
	whichever program happens to write a page. That keeps one producer for the format (both `sim` and
	`analyse_deal` bake the same shape) and makes the contract unit-testable without building an exe; the
	golden test (`tests/golden_sim_json.py`) then guards the whole page end-to-end on top.

	Everything here only WRITES: no solving, no sampling. The caller does the DDS work (see sample.odin /
	tax.odin), then hands the results over for baking. Attribute hosts are SINGLE-quoted in the HTML, so
	these writers emit double quotes and never need escaping.

	One fmt gotcha throughout: `{` in a format string is an argument reference to Odin's fmt (see the
	PBN-comment note in deal_solve.odin), so object braces are written literally with `write_byte`.
*/

import "core:strings"

import "norn:norn"
import "../par_caption"
import "../replay"
import "../sampled"

// Readable card label, rank-first: "KH", "TS" (`replay`'s, which the play element shares).
card_word :: replay.card_word

// Bake the EXACT double-dummy grids (one per partnership) as a `data-sim` blob with `exact:true`, so the
// verdict band shows "double-dummy (exact): N♠ makes/fails" (no sampled ±, no guess tax) and FOLLOWS the
// N/S↔E/W toggle. The writing is `par_caption.write_exact_sim`'s, from the trick table (so the shared-deals
// player writes the same element); this reads each side's spike back out of its grid, and passes the contract
// the record names (what was played at the table) to be preselected.
write_exact_sim_json :: proc(b: ^strings.Builder, ns_grid, ew_grid: ^Grid_Result, board: norn.Board) {
	spike :: proc(grid: ^Grid_Result, st: Strain) -> int {
		for k := 13; k >= 0; k -= 1 {
			if grid.hist[st][k] > 0 {
				return k
			}
		}
		return 0
	}
	tricks: par_caption.Tricks
	for st in Strain {
		tricks[par_caption.Strain(st)][.North] = spike(ns_grid, st)
		tricks[par_caption.Strain(st)][.East] = spike(ew_grid, st)
	}
	named: Maybe(par_caption.Named_Contract)
	if c, _, ok := board_contract(board); ok {
		named = par_caption.Named_Contract{level = c.level, strain = par_caption.Strain(c.strain)}
	}
	par_caption.write_exact_sim(b, &tricks, named)
}

// Uppercase seat letter for a norn.Seat (the lead-blob JSON keys).
seat_letter :: replay.seat_letter

// The page's sampled-board JSON is `sampled`'s, shared with the shared-deals player.
board_contract :: sampled.board_contract
write_sim_json :: sampled.write_sim_json
tax_has_narratable_guess :: sampled.tax_has_narratable_guess
write_sim_guess_json :: sampled.write_sim_guess_json
write_g_object :: sampled.write_g_object
LEAD_TAX_MIN_N :: sampled.LEAD_TAX_MIN_N
write_leads_json :: sampled.write_leads_json
side_key :: sampled.side_key
suit_key :: sampled.suit_key
strain_key :: sampled.strain_key

// The East-West partnership as a seat set (local, so this package needs no `norn:combo`).
@(private)
EW_SIDE :: bit_set[norn.Seat]{.East, .West}
