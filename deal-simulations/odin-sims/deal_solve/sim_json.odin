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

import "core:fmt"
import "core:strings"

import "norn:norn"

// The East-West partnership as a seat set. Local so this package needs no dependency on `norn:combo`
// (which owns the NS_SIDE/EW_SIDE constants the analysis side uses) — the solver boundary stays
// combo-free in both directions.
@(private)
EW_SIDE :: bit_set[norn.Seat]{.East, .West}

// The contract the board itself names (from a LIN `mb|` auction or PBN `[Contract]`/`[Declarer]`) as a
// Contract plus its declaring seat. ok=false when the board named no contract. Maps norn's contract
// strain onto deal_solve's (dds) strain — the two enums order their variants differently, so map by name.
board_contract :: proc(board: norn.Board) -> (c: Contract, declarer: norn.Seat, ok: bool) {
	bc, has := board.contract.?
	if !has {
		return {}, .North, false
	}
	strain: Strain
	switch bc.strain {
	case .Clubs:
		strain = .Clubs
	case .Diamonds:
		strain = .Diamonds
	case .Hearts:
		strain = .Hearts
	case .Spades:
		strain = .Spades
	case .NoTrumps:
		strain = .NT
	}
	return Contract{level = bc.level, strain = strain}, bc.declarer, true
}

// Readable card label, rank-first: "KH", "TS". (norn.Card prints as a raw number under %v.)
card_word :: proc(c: norn.Card) -> string {
	return fmt.tprintf("%c%c", norn.rank_char(norn.card_rank(c)), norn.suit_letter(norn.card_suit(c)))
}

// Bake the EXACT double-dummy grids (one per partnership) as a `data-sim` blob with `exact:true`, so the
// verdict band shows "double-dummy (exact): N♠ makes/fails" (no sampled ±, no guess tax) and FOLLOWS the
// N/S↔E/W toggle — `ns`/`ew` each carry that side's per-strain spike grid. `lvl`/`strain` preselect the
// picker at the contract the deal actually names (from `[Contract]`), else NS's best-making contract
// (most tricks; ties -> NT by iteration order).
write_exact_sim_json :: proc(b: ^strings.Builder, ns_grid, ew_grid: ^Grid_Result, board: norn.Board) {
	best_strain := Strain.NT
	best_tricks := 0
	for st in Strain {
		for k := 13; k >= 0; k -= 1 {
			if ns_grid.hist[st][k] > 0 {
				if k > best_tricks {
					best_tricks = k
					best_strain = st
				}
				break
			}
		}
	}
	lvl := clamp(best_tricks - 6, 1, 7)
	strain := best_strain
	// Prefer the contract the record names (what was played at the table) over the engine's best-making pick.
	if c, _, ok := board_contract(board); ok {
		lvl, strain = c.level, c.strain
	}
	strings.write_byte(b, '{')
	fmt.sbprintf(b, `"n":1,"exact":true,"lvl":%d,"strain":"%s"`, lvl, strain_key(strain))
	strings.write_string(b, `,"ns":`)
	write_g_object(b, ns_grid.hist, ns_grid.n)
	strings.write_string(b, `,"ew":`)
	write_g_object(b, ew_grid.hist, ew_grid.n)
	strings.write_byte(b, '}')
}

// Bake the DDS-sampled contract grid as JSON for the card page's contract picker:
//   {"n":400,"lvl":4,"strain":"h","g":{"s":[p0..p13],"h":[..],"d":[..],"c":[..],"nt":[..]}}
// Each per-strain array is the NORMALISED trick distribution p[k] (k=0..13), so the client reads a
// make-% for (strain, level) as the tail sum at level+6 and stderr from `n`. `lvl`/`strain` preselect
// the picker at the driver's --contract. Single-quoted attribute host (see write_html_page), so the
// JSON uses only double quotes — no escaping needed.
// `leads`/`side` are optional: when non-nil the opening-lead sub-grids are folded in as a nested
// `"leads":{n,seats:{...}}` (the same blob write_leads_json bakes standalone on the 2-hand `.par`). The
// full-deal BLIND bake uses this so each side carries its own lead picker; the 2-hand path leaves it nil
// (it bakes data-sim-leads as a sibling attribute instead) and passes no leads.
write_sim_json :: proc(
	b: ^strings.Builder,
	sim: ^Grid_Result,
	contract: Contract,
	tax: Tax_Result,
	tax_ok: bool,
	leads: ^Lead_Grids = nil,
	side: bit_set[norn.Seat] = {},
	lead_seat: u8 = 0,
	lead_card: string = "",
	lead_tax: ^Lead_Tax = nil,
) {
	// Braces must be written literally — Odin's fmt reads `{` in a format string as an argument
	// reference (see odin's PBN-comment note), so only value fields go through sbprintf.
	strings.write_byte(b, '{')
	fmt.sbprintf(b, `"n":%d,"lvl":%d,"strain":"%s"`, sim.n, contract.level, strain_key(contract.strain))
	// The achievable (misguess-tax) rung for this baked contract: the make-% under blind play plus the
	// dominant two-way guess. Emitted only when a guess was found; the client shows the rung only when the
	// picker sits on this exact (strain, level), since the tax is contract-specific and unconditioned by
	// any opening lead.
	if tax_ok && tax.n_pivots > 0 {
		fmt.sbprintf(
			b,
			`,"ach":%.1f,"taxpts":%.1f,"pvt":"%s"`,
			tax.achievable_pct,
			tax.tax_pts,
			card_word(tax.pivots[0].card),
		)
	}
	strings.write_string(b, `,"g":`)
	write_g_object(b, sim.hist, sim.n)
	if leads != nil {
		strings.write_string(b, `,"leads":`)
		write_leads_json(b, leads, side, lead_tax)
	}
	// The recorded opening lead, pre-selecting the picker (client seeds ccaLead from it until the user picks).
	// Emitted only when the leader is a DEFENDER of this side, keyed like a leads-map entry ("E","3C").
	if lead_seat != 0 && lead_card != "" {
		// Braces literal: fmt reads `{` in a format string as a verb (see write_sim_guess_json / odin note).
		strings.write_string(b, `,"lead":{`)
		fmt.sbprintf(b, `"seat":"%c","card":"%s"`, lead_seat, lead_card)
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, '}')
}

// Bake the per-suit blind two-way GUESS notes for the card page's tooltip merge (Option C1 narration):
//   {"side":"ns","suits":{"s":{"card":"QS","tax":35}}}
// `side` is the declaring partnership (ns/ew) the tax pivots belong to — the client appends the guess
// clause to a suit's line tooltip only while the CCA view shows THAT side. Per suit the DOMINANT pivot
// wins (pivots are sorted dominant-first), so a suit with two guesses (Q and T) narrates the costlier one;
// `tax` is that pivot's MARGINAL cost = the ceiling docked to this guess alone, rounded. Single-quoted
// attribute host, so double quotes only; braces are written literally (fmt reads `{` in a format string
// as an argument reference — see write_sim_json).
// True iff some blind two-way guess costs at least 1% at this contract — i.e. the guess map would carry a
// suit. Gates the `data-sim-guess` attribute so a board whose guesses are all cushioned (non-pivotal) emits
// nothing rather than an empty object.
tax_has_narratable_guess :: proc(tax: Tax_Result) -> bool {
	for i in 0 ..< tax.n_pivots {
		if tax.ceiling_pct - tax.pivots[i].achievable >= 1 {
			return true
		}
	}
	return false
}

write_sim_guess_json :: proc(b: ^strings.Builder, side: bit_set[norn.Seat], tax: Tax_Result) {
	strings.write_byte(b, '{')
	sk := "ns"
	if side == EW_SIDE {
		sk = "ew"
	}
	fmt.sbprintf(b, `"side":"%s",`, sk)
	strings.write_string(b, `"suits":`)
	strings.write_byte(b, '{')
	seen: bit_set[norn.Suit]
	first := true
	for i in 0 ..< tax.n_pivots {
		card := tax.pivots[i].card
		suit := norn.card_suit(card)
		if suit in seen {
			continue // dominant pivot for this suit already emitted
		}
		marg := tax.ceiling_pct - tax.pivots[i].achievable
		if marg < 1 {
			continue // this guess is cushioned at this contract (costs ~0) — no story to tell
		}
		seen += {suit}
		if !first {
			strings.write_byte(b, ',')
		}
		first = false
		fmt.sbprintf(b, `"%s":`, suit_key(suit))
		strings.write_byte(b, '{')
		fmt.sbprintf(b, `"card":"%s","tax":%.0f`, card_word(card), marg)
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, '}') // close suits
	strings.write_byte(b, '}') // close root
}

// Write the `g` object — the five per-strain NORMALISED trick distributions p[k] (k=0..13) — for a
// histogram grid divided by sample count `n`. Shared by the contract grid and the lead sub-grids.
write_g_object :: proc(b: ^strings.Builder, hist: [Strain][14]int, n: int) {
	strings.write_byte(b, '{')
	keyed := [5]struct {
		key:    string,
		strain: Strain,
	}{{"s", .Spades}, {"h", .Hearts}, {"d", .Diamonds}, {"c", .Clubs}, {"nt", .NT}}
	for e, i in keyed {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, `"%s":[`, e.key)
		h := hist[e.strain]
		for k in 0 ..< 14 {
			if k > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%.4f", f64(h[k]) / f64(n))
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, '}')
}

// Bake the opening-lead sub-grids for the page's lead picker:
//   {"n":400,"seats":{"E":{"KS":{"n":210,"g":{...}}, ...},"W":{...}}}
// Per DEFENDER seat (uppercase letter), a map card-label -> {sub-sample n, per-strain distribution g}
// over the layouts where that defender holds the card (== "the opening lead was that card, from that
// defender"). The client reads make-% = g[strain] tail at level+6 and the honest ± from the sub-n. Only
// cards actually seen (n>0) are emitted. Single-quoted attribute host: double quotes only, no escaping.
// Minimum sub-sample for an honest per-lead tax (matches worst_lead's guard): below it the lead-conditioned
// tax is too noisy to bake, and the client falls back to the lead-independent decoupled note.
LEAD_TAX_MIN_N :: 20

write_leads_json :: proc(
	b: ^strings.Builder,
	leads: ^Lead_Grids,
	side: bit_set[norn.Seat],
	lead_tax: ^Lead_Tax = nil,
) {
	defenders := bit_set[norn.Seat]{.North, .East, .South, .West} - side
	strings.write_byte(b, '{')
	fmt.sbprintf(b, `"n":%d,"seats":`, leads.n)
	strings.write_byte(b, '{')
	first_seat := true
	for d in defenders {
		if !first_seat {
			strings.write_byte(b, ',')
		}
		first_seat = false
		fmt.sbprintf(b, `"%c":`, seat_letter(d))
		strings.write_byte(b, '{')
		first_card := true
		for ci in 0 ..< 52 {
			lc := leads.seat[d][ci]
			if lc.n == 0 {
				continue
			}
			if !first_card {
				strings.write_byte(b, ',')
			}
			first_card = false
			fmt.sbprintf(b, `"%s":`, card_word(norn.Card(ci)))
			strings.write_byte(b, '{')
			fmt.sbprintf(b, `"n":%d,"g":`, lc.n)
			write_g_object(b, lc.hist, lc.n)
			// The lead-conditioned guess tax (option (a)): the make-% (from `g`) docked for the two-way guess
			// that survives THIS lead. `tax` may be ~0 — the lead itself located the trapped honour, resolving
			// the guess — which the client shows as "guess resolved", distinct from a thin sub-sample (no entry
			// baked → the client falls back to the lead-independent note). Only for the baked contract.
			if lead_tax != nil {
				lt := lead_tax.seat[d][ci]
				if lt.has_pvt && lt.n >= LEAD_TAX_MIN_N {
					fmt.sbprintf(b, `,"tax":%.1f,"pvt":"%s"`, lt.taxpts, card_word(lt.pvt))
				}
			}
			strings.write_byte(b, '}')
		}
		strings.write_byte(b, '}')
	}
	strings.write_string(b, "}}")
}

// Uppercase seat letter for a norn.Seat (the lead-blob JSON keys).
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

// The card page's side key for the KNOWN partnership: "ns" or "ew". Baked per board so the CCA panel can
// lock its N/S↔E/W toggle to the real known side (a 2-hand board's other side is the known pair duplicated
// + mislabelled — meaningless to show).
side_key :: proc(side: bit_set[norn.Seat]) -> string {
	if side == EW_SIDE {
		return "ew"
	}
	return "ns"
}

// The card page's lowercase suit key for a norn.Suit (the per-suit table row keys s/h/d/c).
suit_key :: proc(s: norn.Suit) -> string {
	switch s {
	case .Spades:
		return "s"
	case .Hearts:
		return "h"
	case .Diamonds:
		return "d"
	case .Clubs:
		return "c"
	}
	return "s"
}

// The card page's lowercase strain key for a dds.Strain.
strain_key :: proc(s: Strain) -> string {
	switch s {
	case .Spades:
		return "s"
	case .Hearts:
		return "h"
	case .Diamonds:
		return "d"
	case .Clubs:
		return "c"
	case .NT:
		return "nt"
	}
	return "nt"
}
