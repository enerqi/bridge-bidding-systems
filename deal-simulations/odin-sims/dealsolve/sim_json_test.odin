package dealsolve

/*
	sim_json_test.odin — the `data-sim*` JSON contract (sim_json.odin), unit-tested.

	These build the result structs BY HAND — no solving, no sampling — so they run in microseconds and pin
	the format itself: what keys appear, and (more valuable) exactly WHEN the optional ones do. The gates
	are the part a refactor breaks silently, because the card page treats a missing key as "no such rung"
	and shows nothing rather than failing:

	  * `ach`/`taxpts`/`pvt`  — only with a tax result that found a pivot.
	  * `leads`               — only when the caller passes lead grids.
	  * a lead's `tax`        — only above LEAD_TAX_MIN_N (a thin sub-sample is too noisy to bake).
	  * `data-sim-guess` suits — only where the guess costs >= 1% (a cushioned guess has no story).

	`tests/golden_sim_json.py` still pins the whole page end-to-end against a committed fixture; that
	catches drift in what the PROGRAM bakes, these catch drift in the writers themselves.
*/

import "core:strings"
import "core:testing"

import "norn:norn"

// A grid with all `n` layouts taking exactly `tricks` tricks in every strain: p[tricks] = 1.0000, rest 0.
@(private = "file")
flat_grid :: proc(n, tricks: int) -> Grid_Result {
	g := Grid_Result {
		n = n,
	}
	for st in Strain {
		g.hist[st][tricks] = n
	}
	return g
}

@(test)
test_sim_json_shape :: proc(t: ^testing.T) {
	g := flat_grid(120, 9)
	b := strings.builder_make(context.temp_allocator)
	write_sim_json(&b, &g, Contract{level = 3, strain = .NT}, {}, false)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"n":120`), out)
	testing.expect(t, strings.contains(out, `"lvl":3`), out)
	testing.expect(t, strings.contains(out, `"strain":"nt"`), out)
	// the five per-strain normalised distributions, and the mass where we put it
	for key in ([5]string{`"s":[`, `"h":[`, `"d":[`, `"c":[`, `"nt":[`}) {
		testing.expect(t, strings.contains(out, key), key)
	}
	testing.expect(t, strings.contains(out, "1.0000"), out) // p[9] = 120/120
	// no tax result was passed, so the achievable rung must be absent entirely
	testing.expect(t, !strings.contains(out, `"ach"`), out)
	testing.expect(t, !strings.contains(out, `"leads"`), out)
}

@(test)
test_sim_json_bakes_achievable_only_with_a_pivot :: proc(t: ^testing.T) {
	g := flat_grid(200, 9)
	tax := Tax_Result {
		level          = 3,
		strain         = .NT,
		ceiling_pct    = 71,
		achievable_pct = 36,
		tax_pts        = 35,
		n_pivots       = 1,
	}
	tax.pivots[0] = {
		card       = norn.make_card(.Spades, .Queen),
		achievable = 36,
	}

	b := strings.builder_make(context.temp_allocator)
	write_sim_json(&b, &g, Contract{level = 3, strain = .NT}, tax, true)
	with_tax := strings.to_string(b)
	testing.expect(t, strings.contains(with_tax, `"ach":36.0`), with_tax)
	testing.expect(t, strings.contains(with_tax, `"taxpts":35.0`), with_tax)
	testing.expect(t, strings.contains(with_tax, `"pvt":"QS"`), with_tax)

	// tax_ok=false (no tax computed for this contract) must suppress the whole rung, pivots or not
	b2 := strings.builder_make(context.temp_allocator)
	write_sim_json(&b2, &g, Contract{level = 3, strain = .NT}, tax, false)
	testing.expect(t, !strings.contains(strings.to_string(b2), `"ach"`), strings.to_string(b2))

	// a tax result that found NO guess is not a rung either — achievable == ceiling, nothing to say
	no_pivot := tax
	no_pivot.n_pivots = 0
	b3 := strings.builder_make(context.temp_allocator)
	write_sim_json(&b3, &g, Contract{level = 3, strain = .NT}, no_pivot, true)
	testing.expect(t, !strings.contains(strings.to_string(b3), `"ach"`), strings.to_string(b3))
}

@(test)
test_leads_json_gates_thin_sub_samples :: proc(t: ^testing.T) {
	lg := new(Lead_Grids, context.temp_allocator)
	lg.n = 400
	lg.base = flat_grid(400, 9)
	fat := norn.make_card(.Spades, .King) // a healthy sub-sample: tax is honest, bake it
	thin := norn.make_card(.Clubs, .Six) // below LEAD_TAX_MIN_N: make-% still baked, tax withheld
	lg.seat[.East][int(fat)] = {
		n = 210,
	}
	lg.seat[.East][int(fat)].hist[Strain.NT][9] = 210
	lg.seat[.East][int(thin)] = {
		n = LEAD_TAX_MIN_N - 1,
	}
	lg.seat[.East][int(thin)].hist[Strain.NT][9] = LEAD_TAX_MIN_N - 1

	lt := new(Lead_Tax, context.temp_allocator)
	lt.seat[.East][int(fat)] = {
		n       = 210,
		taxpts  = 12.5,
		pvt     = norn.make_card(.Spades, .Queen),
		has_pvt = true,
	}
	lt.seat[.East][int(thin)] = {
		n       = LEAD_TAX_MIN_N - 1,
		taxpts  = 33,
		pvt     = norn.make_card(.Spades, .Queen),
		has_pvt = true,
	}

	b := strings.builder_make(context.temp_allocator)
	write_leads_json(&b, lg, bit_set[norn.Seat]{.North, .South}, lt)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"n":400`), out)
	testing.expect(t, strings.contains(out, `"E":`), out)
	testing.expect(t, !strings.contains(out, `"N":`), out) // declarer's own side never leads
	testing.expect(t, strings.contains(out, `"KS":`), out)
	testing.expect(t, strings.contains(out, `"tax":12.5`), out) // fat sub-sample: tax baked
	testing.expect(t, strings.contains(out, `"6C":`), out) // thin one still carries its make-%
	testing.expect(t, !strings.contains(out, `"tax":33.0`), out) // ...but not its noisy tax
}

@(test)
test_sim_guess_json_drops_cushioned_guesses :: proc(t: ^testing.T) {
	tax := Tax_Result {
		ceiling_pct    = 71,
		achievable_pct = 36,
		n_pivots       = 3,
	}
	tax.pivots[0] = {
		card       = norn.make_card(.Spades, .Queen),
		achievable = 36,
	} 	// costs 35 -> narrated
	tax.pivots[1] = {
		card       = norn.make_card(.Spades, .Ten),
		achievable = 60,
	} 	// same suit, dominated -> dropped
	tax.pivots[2] = {
		card       = norn.make_card(.Hearts, .Jack),
		achievable = 70.5,
	} 	// costs 0.5 -> cushioned, dropped

	testing.expect(t, tax_has_narratable_guess(tax))

	b := strings.builder_make(context.temp_allocator)
	write_sim_guess_json(&b, EW_SIDE, tax)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `"side":"ew"`), out)
	testing.expect(t, strings.contains(out, `"s":`), out)
	testing.expect(t, strings.contains(out, `"card":"QS"`), out)
	testing.expect(t, strings.contains(out, `"tax":35`), out)
	testing.expect(t, !strings.contains(out, `"TS"`), out) // one pivot per suit, the dominant one
	testing.expect(t, !strings.contains(out, `"h":`), out) // the 0.5% guess is not a story

	// every guess cushioned -> the caller must not emit the attribute at all
	cushioned := Tax_Result {
		ceiling_pct = 71,
		n_pivots    = 1,
	}
	cushioned.pivots[0] = {
		card       = norn.make_card(.Hearts, .Jack),
		achievable = 70.5,
	}
	testing.expect(t, !tax_has_narratable_guess(cushioned))
}
