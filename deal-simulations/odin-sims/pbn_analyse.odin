package main

/*
	pbn_analyse — the 2-hand (declarer + dummy) card-combination advisor driver.

	A single-file (`-file`) consumer program, separate from `sim.odin` (the deal generator). It reads a
	PBN `[Deal]` tag — as produced by the hand-ocr tool — and prints the naive card-combination analysis
	for the KNOWN partnership: the double-dummy trick census (the ceiling) and the achievable
	single-dummy line summary. No full deal and no DDS are needed — the defenders' 26 cards stay unknown
	(combo enumerates every E/W split), which is exactly the declarer+dummy situation.

	Input (in priority order):
	  1. `--file <path>` / `-f <path>` — read the PBN from a file (the whole file is scanned for a
	     `[Deal "..."]` tag).
	  2. positional args — joined with spaces and parsed as the PBN string / bare `N:...` value.
	  3. otherwise — read the PBN from stdin (so `hand-ocr ... | pbn_analyse` works).

	Options:
	  --target <n> / -t <n>  Highlight the P(>= n) make column (default 0 = no highlight). No DDS par is
	                         available with two hands, so the target is the user's contract level, not
	                         a computed par.
	  --sample <deals>       Turn on the DDS-sampling whole-hand make-% verdict: deal the unknown 26 cards
	                         many times (each split at its a-priori odds), solve each layout double-dummy,
	                         and report the honest make-% (the anchor combo lacks solo). ~200-500 is plenty.
	  --contract <e.g. 4H>   The contract to score under --sample. OPTIONAL: if omitted, the best contract
	                         (max expected score over the sample) is auto-picked. With --html it is the
	                         contract picker's default; the viewer can change strain/level live.
	  --seed <n>             Seed the sample RNG (reproducible; default 0).
	  --html <out.html>      Write the interactive card page (declarer + dummy shown, defenders face-down,
	                         CCA overlay). With --sample the page also bakes the sampled grid for its green
	                         whole-hand verdict + contract picker.

	Build/run (from the odin-sims dir): see the justfile `analyse-pbn` recipe, e.g.
	  just analyse-pbn '[Deal "N:AKQ.. ... - -"]'
	The raw form:
	  odin run pbn_analyse.odin -file -collection:norn=C:/Users/Enerqi/dev/norn -- --target 9 '<PBN>'
*/

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "combo"
import "dd"
import "norn:norn"

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	defer combo.shutdown() // free combo's worker pool if the HTML annotate spun it up (no-op otherwise)

	args, arg_err := parse_args(os.args[1:])
	if arg_err != "" {
		fmt.eprintln("pbn_analyse:", arg_err)
		fmt.eprintln(
			"usage: pbn_analyse [--file <path>] [--target <n>] [--html <out.html>]",
		)
		fmt.eprintln(
			"                   [--sample <deals> [--contract <e.g. 4H>] [--seed <n>]] ['<PBN deal tag>']",
		)
		return 2
	}
	if strings.trim_space(args.text) == "" {
		fmt.eprintln("pbn_analyse: no PBN input (pass a string, --file, or pipe via stdin)")
		return 2
	}
	board, perr := norn.parse_pbn_deal(args.text)
	if perr != .None {
		fmt.eprintfln("pbn_analyse: could not parse PBN deal: %v", perr)
		return 1
	}

	a, side, ok := combo.analyse_parsed_board(board)
	if !ok {
		fmt.eprintln(
			"pbn_analyse: need exactly one fully-known partnership (declarer + dummy) — a 2-hand",
		)
		fmt.eprintln(
			"             PBN with the two defenders written '-'. A full 4-hand deal is not a 2-hand advisor input.",
		)
		return 1
	}
	sd, _, _ := combo.sd_bundle_parsed_board(board)

	// Optional DDS-sampling whole-hand verdict (the honest make-%). Needs a strain, so it fires only
	// when --sample and --contract are both given. We sample the FULL contract grid (one DDS solve per
	// layout gives every strain/level), so the CLI verdict reads one contract off it and the html bake
	// carries the whole grid for the page's contract picker. `have_sample` gates the report + bake.
	grid: dd.Grid_Result
	contract: dd.Contract
	have_sample := false
	auto_contract := false
	if args.sample > 0 {
		// Parse an explicit --contract first (fail fast before spending solves); an empty --contract is
		// resolved AFTER sampling by picking the best contract off the grid.
		if args.contract != "" {
			c, c_ok := dd.parse_contract(args.contract)
			if !c_ok {
				fmt.eprintfln("pbn_analyse: could not parse --contract %q (expected e.g. 4H, 3NT)", args.contract)
				return 1
			}
			contract = c
		}
		dd.init()
		defer dd.shutdown()
		g, s_ok := dd.sample_grid(board, side, args.sample, args.seed)
		if !s_ok {
			fmt.eprintln("pbn_analyse: DDS sampling failed")
			return 1
		}
		grid, have_sample = g, true
		if args.contract == "" {
			bc, bc_ok := dd.best_contract(grid)
			if !bc_ok {
				fmt.eprintln("pbn_analyse: could not pick a contract from the sample")
				return 1
			}
			contract, auto_contract = bc, true
		}
	}

	if args.html_path != "" {
		sim: ^dd.Grid_Result = &grid if have_sample else nil
		if werr := write_html_page(args.html_path, board, &sd, side, args.target, sim, contract);
		   werr != "" {
			fmt.eprintln("pbn_analyse:", werr)
			return 1
		}
		fmt.eprintfln("wrote %s", args.html_path)
		return 0
	}

	print_report(&a, &sd, side, args.target)
	if have_sample {
		sample := dd.result_for(grid, contract)
		print_sample_verdict(&a, &sd, &sample, auto_contract)
	}
	return 0
}

// The green "honest verdict" rung: the whole-hand simulated make-%, plus a reconciliation strip showing
// the ceiling -> blind -> simulated tax as the gap between the three E[total] numbers.
print_sample_verdict :: proc(
	a: ^combo.Deal_Analysis,
	sd: ^combo.Sd_Bundle,
	s: ^dd.Sample_Result,
	auto_contract: bool,
) {
	label := dd.contract_label(dd.Contract{level = s.level, strain = s.strain}) // temp-allocated
	fmt.println("\nWhole-hand (simulated) — the honest whole-deal verdict:")
	if auto_contract {
		fmt.printfln("  (no --contract given; auto-picked %s = best expected score over the sample)", label)
	}
	fmt.printfln(
		"  %s makes %.0f%% (+/-%.0f%%, %d deals)   ·   E[tricks] simulated %.2f",
		label,
		s.make_pct,
		s.stderr_pct,
		s.n,
		s.mean_tricks,
	)
	fmt.printfln(
		"  reconciliation:  ceiling %.2f (combo DD)  >  blind %.2f (combo SD)  >  simulated %.2f (DDS whole-hand)",
		combo.expected_tricks(a.total),
		combo.expected_tricks(sd.totsd),
		s.mean_tricks,
	)
	fmt.println(
		"  (per-layout double-dummy census: a ceiling that already bakes in entries/squeezes/tempo per",
	)
	fmt.println("   solve — far tighter than combo's per-suit sums. See COMBO_ANALYSER.md Track 2.)")
}

// Parsed command line: the PBN text plus the analysis options. `sample` > 0 turns on the DDS-sampling
// whole-hand verdict (which needs a `contract`, e.g. "4H"); `target` highlights a make column in the
// combo census.
Args :: struct {
	text:      string,
	target:    int,
	html_path: string,
	sample:    int,
	contract:  string,
	seed:      u64,
}

// Split the argv tail into an `Args` and an error message ("" == ok). `--file` wins over positionals;
// positionals win over stdin (resolved by the caller when `text` is empty).
parse_args :: proc(args: []string) -> (out: Args, err: string) {
	file_path: string
	positionals: [dynamic]string
	defer delete(positionals)

	i := 0
	for i < len(args) {
		arg := args[i]
		switch arg {
		case "--file", "-f":
			if i + 1 >= len(args) {
				return out, "--file needs a path"
			}
			file_path = args[i + 1]
			i += 2
		case "--html", "-o":
			if i + 1 >= len(args) {
				return out, "--html needs an output path"
			}
			out.html_path = args[i + 1]
			i += 2
		case "--target", "-t":
			if i + 1 >= len(args) {
				return out, "--target needs a number"
			}
			n, n_ok := strconv.parse_int(args[i + 1])
			if !n_ok {
				return out, fmt.tprintf("--target %q is not a number", args[i + 1])
			}
			out.target = n
			i += 2
		case "--sample", "-s":
			if i + 1 >= len(args) {
				return out, "--sample needs a deal count"
			}
			n, n_ok := strconv.parse_int(args[i + 1])
			if !n_ok || n <= 0 {
				return out, fmt.tprintf("--sample %q is not a positive number", args[i + 1])
			}
			out.sample = n
			i += 2
		case "--contract", "-c":
			if i + 1 >= len(args) {
				return out, "--contract needs a contract, e.g. 4H"
			}
			out.contract = args[i + 1]
			i += 2
		case "--seed":
			if i + 1 >= len(args) {
				return out, "--seed needs a number"
			}
			n, n_ok := strconv.parse_u64(args[i + 1])
			if !n_ok {
				return out, fmt.tprintf("--seed %q is not a number", args[i + 1])
			}
			out.seed = n
			i += 2
		case:
			append(&positionals, arg)
			i += 1
		}
	}

	if file_path != "" {
		data, read_err := os.read_entire_file_from_path(file_path, context.allocator)
		if read_err != nil {
			return out, fmt.tprintf("could not read file %q: %v", file_path, read_err)
		}
		out.text = string(data)
		return out, ""
	}
	if len(positionals) > 0 {
		out.text = strings.join(positionals[:], " ")
		return out, ""
	}
	out.text = read_stdin()
	return out, ""
}

// Read all of stdin into a string (for `hand-ocr ... | pbn_analyse`). Best-effort: stops at EOF or any
// read error, returning whatever was gathered.
read_stdin :: proc() -> string {
	sb: strings.Builder
	buf: [4096]u8
	for {
		n, _ := os.read(os.stdin, buf[:])
		if n > 0 {
			strings.write_bytes(&sb, buf[:n])
		}
		if n <= 0 { 	// EOF (0) or an error (< 0): stop, return what we have
			break
		}
	}
	return strings.to_string(sb)
}

// Print the census table plus a single-dummy summary for the analysed partnership.
print_report :: proc(a: ^combo.Deal_Analysis, sd: ^combo.Sd_Bundle, side: bit_set[norn.Seat], target: int) {
	side_name := side == combo.NS_SIDE ? "N/S" : "E/W"
	fmt.printfln("Card-combination analysis for %s (declarer + dummy); defenders unknown.\n", side_name)

	// Double-dummy census table (the trick ceiling). format_analysis allocates from context.allocator.
	table := combo.format_analysis(a, target)
	defer delete(table)
	fmt.println("Double-dummy census (per-layout optimum ceiling):")
	fmt.println(table)

	// Headline make chances at the target, DD ceiling vs SD achievable.
	dd_make := combo.p_at_least(a.total, target)
	sd_make := sd.atl[clamp(target, 0, len(sd.atl) - 1)]
	fmt.printfln(
		"\nP(>= %d tricks):  DD ceiling %.1f%%   ·   SD achievable %.1f%%",
		target,
		dd_make * 100,
		sd_make * 100,
	)
	fmt.printfln(
		"E[total tricks]:  DD %.2f   ·   SD %.2f",
		combo.expected_tricks(a.total),
		combo.expected_tricks(sd.totsd),
	)

	// Per-suit recommended single-dummy line (best-by-mean) + its expected tricks.
	fmt.println("\nRecommended single-dummy line, per suit:")
	suits := [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs} // Sd_Bundle order is S H D C
	letters := [4]string{"S", "H", "D", "C"}
	for suit, idx in suits {
		fmt.printfln(
			"  %s  %-14s  E[tricks] DD %.2f · SD %.2f",
			letters[idx],
			sd.best_name[idx],
			combo.expected_tricks(a.suits[suit].p),
			combo.expected_tricks(sd.best_marg[idx].p),
		)
	}
	fmt.println(
		"\nNote: the naive model assumes free entries and independent suits, so totals are an upper",
	)
	fmt.println(
		"bound (no tempo race, no squeezes/endplays). With only two hands there is no DDS par to",
	)
	fmt.println("cross-check it against. See COMBO_ANALYSER.md.")
}

// Write a self-contained interactive card page for the 2-hand board: the declarer+dummy compass with
// the defenders face-down, plus the norn card page's CCA overlay. Reuses the full page shell
// (`render_page_prologue`/`_epilogue`) and `combo.annotate` unchanged: the combo blob is emitted from a
// SYNTHESISED deal that duplicates the known pair into BOTH partnerships, so the page's N/S<->E/W
// toggle shows the known-side analysis whichever way it is flipped (there is only one known side). The
// slider target is seeded via a hidden `.par[data-target]` (no DDS par exists with two hands).
//
// When `sim` is non-nil (--sample given), the same hidden `.par` div also carries a `data-sim` blob: the
// full DDS-sampled contract grid (per-strain trick distributions + sample count), which the card page's
// contract picker reads to show the green whole-hand make-% verdict for any strain/level. `contract` is
// the driver's --contract, baked as the picker's default. Returns "" on success, else an error message.
write_html_page :: proc(
	path: string,
	board: norn.Parsed_Board,
	sd: ^combo.Sd_Bundle,
	side: bit_set[norn.Seat],
	target: int,
	sim: ^dd.Grid_Result,
	contract: dd.Contract,
) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	norn.render_page_prologue(&b, .Html_Cards, "Two-hand advisor (declarer + dummy)")
	norn.render_deal_html_cards(&b, board.deal, false, board.known)

	// Seed the CCA target slider. Prefer the contract level (level+6 tricks) when sampling, else the
	// user's --target, else a sensible default = the achievable single-dummy expected total.
	tgt := target
	if sim != nil && tgt <= 0 {
		tgt = clamp(contract.level + 6, 1, 13)
	}
	if tgt <= 0 {
		tgt = clamp(int(combo.expected_tricks(sd.totsd) + 0.5), 1, 13)
	}
	strings.write_string(&b, "\n<div class=\"par\"")
	fmt.sbprintf(&b, " data-target=\"%d\"", tgt)
	if sim != nil {
		strings.write_string(&b, " data-sim='")
		write_sim_json(&b, sim, contract)
		strings.write_string(&b, "'")
	}
	strings.write_string(&b, " hidden></div>\n")

	// The `.combo` blob (per-suit census + single-dummy + adaptive curve). combo.annotate reads a full
	// Deal; feed it the known pair duplicated into both sides (see the proc doc).
	combo.annotate(&b, synth_deal(board, side), .Html_Cards)

	norn.render_page_epilogue(&b, .Html_Cards)

	if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); werr != nil {
		return fmt.tprintf("could not write %q: %v", path, werr)
	}
	return ""
}

// Bake the DDS-sampled contract grid as JSON for the card page's contract picker:
//   {"n":400,"lvl":4,"strain":"h","g":{"s":[p0..p13],"h":[..],"d":[..],"c":[..],"nt":[..]}}
// Each per-strain array is the NORMALISED trick distribution p[k] (k=0..13), so the client reads a
// make-% for (strain, level) as the tail sum at level+6 and stderr from `n`. `lvl`/`strain` preselect
// the picker at the driver's --contract. Single-quoted attribute host (see write_html_page), so the
// JSON uses only double quotes — no escaping needed.
write_sim_json :: proc(b: ^strings.Builder, sim: ^dd.Grid_Result, contract: dd.Contract) {
	// Braces must be written literally — Odin's fmt reads `{` in a format string as an argument
	// reference (see dd.odin's PBN-comment note), so only value fields go through sbprintf.
	strings.write_byte(b, '{')
	fmt.sbprintf(b, `"n":%d,"lvl":%d,"strain":"%s","g":`, sim.n, contract.level, strain_key(contract.strain))
	strings.write_byte(b, '{')
	keyed := [5]struct {
		key:    string,
		strain: dd.Strain,
	}{{"s", .Spades}, {"h", .Hearts}, {"d", .Diamonds}, {"c", .Clubs}, {"nt", .NT}}
	for e, i in keyed {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, `"%s":[`, e.key)
		hist := sim.hist[e.strain]
		for k in 0 ..< 14 {
			if k > 0 {
				strings.write_byte(b, ',')
			}
			// Normalised probability, 4 dp (enough for a %; keeps the blob compact).
			fmt.sbprintf(b, "%.4f", f64(hist[k]) / f64(sim.n))
		}
		strings.write_byte(b, ']')
	}
	strings.write_string(b, "}}")
}

// The card page's lowercase strain key for a dds.Strain.
strain_key :: proc(s: dd.Strain) -> string {
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

// A full `norn.Deal` carrying the known partnership's two hands in BOTH partnership slots, so
// `combo.annotate` emits the same (known-side) analysis for its N/S and E/W blobs. The defenders'
// real (unknown) cards never enter here — the compass draws them face-down from `board.known` instead.
synth_deal :: proc(board: norn.Parsed_Board, side: bit_set[norn.Seat]) -> norn.Deal {
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
