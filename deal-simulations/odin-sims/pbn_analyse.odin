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
import "norn:norn"

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	defer combo.shutdown() // free combo's worker pool if the HTML annotate spun it up (no-op otherwise)

	text, target, html_path, arg_err := parse_args(os.args[1:])
	if arg_err != "" {
		fmt.eprintln("pbn_analyse:", arg_err)
		fmt.eprintln(
			"usage: pbn_analyse [--file <path>] [--target <n>] [--html <out.html>] ['<PBN deal tag>']",
		)
		return 2
	}
	if strings.trim_space(text) == "" {
		fmt.eprintln("pbn_analyse: no PBN input (pass a string, --file, or pipe via stdin)")
		return 2
	}

	board, perr := norn.parse_pbn_deal(text)
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

	if html_path != "" {
		if werr := write_html_page(html_path, board, &sd, side, target); werr != "" {
			fmt.eprintln("pbn_analyse:", werr)
			return 1
		}
		fmt.eprintfln("wrote %s", html_path)
		return 0
	}

	print_report(&a, &sd, side, target)
	return 0
}

// Split the argv tail into the PBN text, the make target, and an error message ("" == ok). `--file`
// wins over positionals; positionals win over stdin (resolved by the caller when `text` is empty).
parse_args :: proc(
	args: []string,
) -> (
	text: string,
	target: int,
	html_path: string,
	err: string,
) {
	file_path: string
	positionals: [dynamic]string
	defer delete(positionals)

	i := 0
	for i < len(args) {
		arg := args[i]
		switch arg {
		case "--file", "-f":
			if i + 1 >= len(args) {
				return "", 0, "", "--file needs a path"
			}
			file_path = args[i + 1]
			i += 2
		case "--html", "-o":
			if i + 1 >= len(args) {
				return "", 0, "", "--html needs an output path"
			}
			html_path = args[i + 1]
			i += 2
		case "--target", "-t":
			if i + 1 >= len(args) {
				return "", 0, "", "--target needs a number"
			}
			n, n_ok := strconv.parse_int(args[i + 1])
			if !n_ok {
				return "", 0, "", fmt.tprintf("--target %q is not a number", args[i + 1])
			}
			target = n
			i += 2
		case:
			append(&positionals, arg)
			i += 1
		}
	}

	if file_path != "" {
		data, read_err := os.read_entire_file_from_path(file_path, context.allocator)
		if read_err != nil {
			return "", 0, "", fmt.tprintf("could not read file %q: %v", file_path, read_err)
		}
		return string(data), target, html_path, ""
	}
	if len(positionals) > 0 {
		return strings.join(positionals[:], " "), target, html_path, ""
	}
	return read_stdin(), target, html_path, ""
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
// slider target is seeded via a hidden `.par[data-target]` (no DDS par exists with two hands). Returns
// "" on success, else an error message.
write_html_page :: proc(
	path: string,
	board: norn.Parsed_Board,
	sd: ^combo.Sd_Bundle,
	side: bit_set[norn.Seat],
	target: int,
) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	norn.render_page_prologue(&b, .Html_Cards, "Two-hand advisor (declarer + dummy)")
	norn.render_deal_html_cards(&b, board.deal, false, board.known)

	// Seed the CCA target slider. Prefer the user's --target; else a sensible default = the achievable
	// single-dummy expected total, rounded and clamped to a real trick count.
	tgt := target
	if tgt <= 0 {
		tgt = clamp(int(combo.expected_tricks(sd.totsd) + 0.5), 1, 13)
	}
	fmt.sbprintf(&b, "\n<div class=\"par\" data-target=\"%d\" hidden></div>\n", tgt)

	// The `.combo` blob (per-suit census + single-dummy + adaptive curve). combo.annotate reads a full
	// Deal; feed it the known pair duplicated into both sides (see the proc doc).
	combo.annotate(&b, synth_deal(board, side), .Html_Cards)

	norn.render_page_epilogue(&b, .Html_Cards)

	if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); werr != nil {
		return fmt.tprintf("could not write %q: %v", path, werr)
	}
	return ""
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
