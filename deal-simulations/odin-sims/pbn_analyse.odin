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
	  --void <seat>:<suit>   Defender-shape inference: that defender holds NO cards in the suit (from the
	                         bidding / a show-out). Repeatable. e.g. --void E:S. Only samples consistent
	                         layouts are kept, so the make-% conditions on what you know.
	  --len <seat>:<suit>:<n|n-m|n+>
	                         Defender suit-length inference: exactly n, the range n..m, or n+ cards.
	                         Repeatable. e.g. --len W:H:6 (West has six hearts), --len E:C:0-1.
	  --lead <seat>:<card>   The opening lead / a seen card: that defender holds the exact card (rank-first,
	                         e.g. W:KH = West holds/led the king of hearts). Conditions the make-% on the
	                         card's location — the classic "finesse works iff the king is onside" swing.
	                         Repeatable. Alias: --card.
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
	defer delete(args.constraints)
	defer delete(args.held)
	if arg_err != "" {
		fmt.eprintln("pbn_analyse:", arg_err)
		fmt.eprintln(
			"usage: pbn_analyse [--file <path>] [--target <n>] [--html <out.html>]",
		)
		fmt.eprintln(
			"                   [--sample <deals> [--contract <e.g. 4H>] [--seed <n>]]",
		)
		fmt.eprintln(
			"                   [--void <seat>:<suit>] [--len <seat>:<suit>:<n|n-m|n+>] [--lead <seat>:<card>]",
		)
		fmt.eprintln("                   ['<PBN deal tag>']")
		return 2
	}
	if strings.trim_space(args.text) == "" {
		fmt.eprintln("pbn_analyse: no PBN input (pass a string, --file, or pipe via stdin)")
		return 2
	}
	// Parse ALL [Deal] tags in the input (a hand-ocr session can hold several); a single bare `N:...`
	// value is one board. Multiple boards render as one carousel page / a text report per board.
	boards, berr := parse_boards(args.text)
	defer delete(boards)
	if berr != .None {
		fmt.eprintfln("pbn_analyse: could not parse PBN deal: %v", berr)
		return 1
	}
	if len(boards) == 0 {
		fmt.eprintln("pbn_analyse: no [Deal] tag found in the input")
		return 1
	}
	multi := len(boards) > 1
	// Constraints name specific seats/cards of ONE board, so they are meaningless across a set.
	if multi && (len(args.constraints) > 0 || len(args.held) > 0) {
		fmt.eprintln(
			"pbn_analyse: --void/--len/--lead condition a specific board, so they need a SINGLE board input",
		)
		return 1
	}

	// --contract applies to every board (empty -> auto-pick per board). Parse it once, fail fast.
	contract: dd.Contract
	has_contract := false
	if args.contract != "" {
		c, c_ok := dd.parse_contract(args.contract)
		if !c_ok {
			fmt.eprintfln("pbn_analyse: could not parse --contract %q (expected e.g. 4H, 3NT)", args.contract)
			return 1
		}
		contract, has_contract = c, true
	}

	// DDS lifecycle: init once around all boards' sampling. The shutdown defer must sit at RUN scope (not
	// inside the if-block, or it would fire immediately after init — before any board samples).
	sampling := args.sample > 0
	if sampling {
		dd.init()
	}
	defer {
		if sampling {
			dd.shutdown()
		}
	}

	if args.html_path != "" {
		if werr := write_html(args.html_path, boards[:], &args, contract, has_contract); werr != "" {
			fmt.eprintln("pbn_analyse:", werr)
			return 1
		}
		fmt.eprintfln("wrote %s (%d board%s)", args.html_path, len(boards), "" if len(boards) == 1 else "s")
		return 0
	}

	for board, i in boards {
		if i > 0 {
			fmt.printfln("\n%s", strings.repeat("=", 74, context.temp_allocator))
		}
		if multi {
			fmt.printfln("Board %d of %d\n", i + 1, len(boards))
		}
		report_board(board, &args, contract, has_contract)
	}
	return 0
}

// One board's DDS-sample results (empty when --sample is off or the board is not a 2-hand advisor input).
// `leads` is heap-allocated (~118 KB — kept off the stack); the caller frees it with `board_sample_free`.
Board_Sample :: struct {
	have:     bool,
	grid:     dd.Grid_Result,
	leads:    ^dd.Lead_Grids,
	contract: dd.Contract,
	auto:     bool, // contract was auto-picked (no --contract)
}

// Release a Board_Sample's heap grids (no-op when sampling was off).
board_sample_free :: proc(bs: ^Board_Sample) {
	if bs.leads != nil {
		free(bs.leads)
		bs.leads = nil
	}
}

// Sample one board if --sample is on: validate any constraints against THIS board's defenders, run the
// lead grids, and resolve the contract (explicit or auto). Returns have=false with "" when sampling is
// off; a non-empty error message on a hard failure.
sample_board :: proc(
	board: norn.Parsed_Board,
	side: bit_set[norn.Seat],
	args: ^Args,
	contract: dd.Contract,
	has_contract: bool,
) -> (
	bs: Board_Sample,
	err: string,
) {
	if args.sample <= 0 {
		return {}, ""
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
	cons := dd.Sample_Constraints{shape = args.constraints[:], held = args.held[:]}
	lg := new(dd.Lead_Grids)
	if !dd.sample_lead_grids(board, side, args.sample, lg, args.seed, cons) {
		free(lg)
		return {}, "DDS sampling failed — the constraints are too rare or impossible for these hands (could not draw enough consistent deals)"
	}
	bs.leads = lg
	bs.grid = lg.base
	bs.have = true
	if has_contract {
		bs.contract = contract
	} else {
		bc, bc_ok := dd.best_contract(bs.grid)
		if !bc_ok {
			return {}, "could not pick a contract from the sample"
		}
		bs.contract, bs.auto = bc, true
	}
	return bs, ""
}

// Text report for one board: the combo census + SD summary, and (with --sample) the simulated verdict.
report_board :: proc(
	board: norn.Parsed_Board,
	args: ^Args,
	contract: dd.Contract,
	has_contract: bool,
) {
	a, side, ok := combo.analyse_parsed_board(board)
	if !ok {
		fmt.eprintln(
			"pbn_analyse: not a 2-hand advisor board — need exactly one fully-known partnership (declarer +",
		)
		fmt.eprintln("             dummy), the two defenders written '-'.")
		return
	}
	sd, _, _ := combo.sd_bundle_parsed_board(board)

	bs, serr := sample_board(board, side, args, contract, has_contract)
	defer board_sample_free(&bs)
	if serr != "" {
		fmt.eprintln("pbn_analyse:", serr)
	}

	print_report(&a, &sd, side, args.target)
	if bs.have {
		sample := dd.result_for(bs.grid, bs.contract)
		print_sample_verdict(&a, &sd, &sample, bs.auto)
		if len(args.constraints) > 0 || len(args.held) > 0 {
			fmt.print("  (sampled only layouts where")
			first := true
			for con in args.constraints {
				fmt.printf(
					"%s %v %s %d-%d",
					" " if first else ",",
					con.seat,
					suit_word(con.suit),
					con.min,
					con.max,
				)
				first = false
			}
			for h in args.held {
				fmt.printf("%s %v holds %s", " " if first else ",", h.seat, card_word(h.card))
				first = false
			}
			fmt.println(")")
		}
	}
}

// Parse every `[Deal]` tag in `text` into a board (a hand-ocr session may carry several). Each `[Deal`
// occurrence is parsed from its position (parse_pbn_deal reads the first tag it finds). With NO `[Deal`
// tag the whole input is treated as a single bare `N:...` value. Returns the first parse error hit.
parse_boards :: proc(text: string) -> (boards: [dynamic]norn.Parsed_Board, err: norn.Pbn_Parse_Error) {
	idx := strings.index(text, "[Deal")
	if idx < 0 {
		b, e := norn.parse_pbn_deal(text)
		if e != .None {
			return nil, e
		}
		append(&boards, b)
		return boards, .None
	}
	for idx >= 0 {
		b, e := norn.parse_pbn_deal(text[idx:])
		if e != .None {
			delete(boards)
			return nil, e
		}
		append(&boards, b)
		next := strings.index(text[idx + 5:], "[Deal")
		if next < 0 {
			break
		}
		idx = idx + 5 + next
	}
	return boards, .None
}

// Is `card` held by one of the board's KNOWN seats (declarer or dummy)? Such a card cannot be a
// defender's lead. (A known hand has 13 real cards; unspecified seats hold none of the real deck here.)
is_known_card :: proc(board: norn.Parsed_Board, card: norn.Card) -> bool {
	for seat in board.known {
		for c in board.deal[seat] {
			if c == card {
				return true
			}
		}
	}
	return false
}

// Readable card label, rank-first: "KH", "TS". (norn.Card prints as a raw number under %v.)
card_word :: proc(c: norn.Card) -> string {
	return fmt.tprintf("%c%c", norn.rank_char(norn.card_rank(c)), norn.suit_letter(norn.card_suit(c)))
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
	text:        string,
	target:      int,
	html_path:   string,
	sample:      int,
	contract:    string,
	seed:        u64,
	constraints: [dynamic]dd.Card_Constraint, // defender-shape inferences from --void / --len
	held:        [dynamic]dd.Held_Card,       // specific-card locations from --lead / --card
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
		case "--void":
			if i + 1 >= len(args) {
				return out, "--void needs a <seat>:<suit>, e.g. E:S"
			}
			c, c_ok := parse_void_spec(args[i + 1])
			if !c_ok {
				return out, fmt.tprintf("--void %q is not <seat>:<suit> (seat E/W or N/S, suit S/H/D/C)", args[i + 1])
			}
			append(&out.constraints, c)
			i += 2
		case "--len":
			if i + 1 >= len(args) {
				return out, "--len needs a <seat>:<suit>:<n|n-m|n+>, e.g. W:H:6"
			}
			c, c_ok := parse_len_spec(args[i + 1])
			if !c_ok {
				return out, fmt.tprintf("--len %q is not <seat>:<suit>:<n|n-m|n+>", args[i + 1])
			}
			append(&out.constraints, c)
			i += 2
		case "--lead", "--card":
			if i + 1 >= len(args) {
				return out, "--lead needs a <seat>:<card>, e.g. W:KH"
			}
			h, h_ok := parse_lead_spec(args[i + 1])
			if !h_ok {
				return out, fmt.tprintf("--lead %q is not <seat>:<card> (card rank-first, e.g. KH, TS)", args[i + 1])
			}
			append(&out.held, h)
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

// Parse a `--void <seat>:<suit>` spec into a Card_Constraint (that seat holds ZERO of the suit).
parse_void_spec :: proc(s: string) -> (c: dd.Card_Constraint, ok: bool) {
	parts := strings.split(strings.trim_space(s), ":", context.temp_allocator)
	if len(parts) != 2 {
		return {}, false
	}
	seat, suit, sk := seat_suit(parts[0], parts[1])
	if !sk {
		return {}, false
	}
	return dd.Card_Constraint{seat = seat, suit = suit, min = 0, max = 0}, true
}

// Parse a `--len <seat>:<suit>:<spec>` where <spec> is `n` (exactly n), `n-m` (n..m), or `n+` (n..13).
parse_len_spec :: proc(s: string) -> (c: dd.Card_Constraint, ok: bool) {
	parts := strings.split(strings.trim_space(s), ":", context.temp_allocator)
	if len(parts) != 3 {
		return {}, false
	}
	seat, suit, sk := seat_suit(parts[0], parts[1])
	if !sk {
		return {}, false
	}
	spec := parts[2]
	lo, hi: int
	if strings.has_suffix(spec, "+") {
		n, n_ok := strconv.parse_int(spec[:len(spec) - 1])
		if !n_ok {
			return {}, false
		}
		lo, hi = n, 13
	} else if idx := strings.index_byte(spec, '-'); idx >= 0 {
		a, a_ok := strconv.parse_int(spec[:idx])
		b, b_ok := strconv.parse_int(spec[idx + 1:])
		if !a_ok || !b_ok {
			return {}, false
		}
		lo, hi = a, b
	} else {
		n, n_ok := strconv.parse_int(spec)
		if !n_ok {
			return {}, false
		}
		lo, hi = n, n
	}
	if lo < 0 || hi > 13 || lo > hi {
		return {}, false
	}
	return dd.Card_Constraint{seat = seat, suit = suit, min = lo, max = hi}, true
}

// Parse a `--lead <seat>:<card>` spec into a Held_Card (that defender holds/led the card). The card is
// rank-first (norn convention): "KH" = king of hearts, "TS" = ten of spades.
parse_lead_spec :: proc(s: string) -> (h: dd.Held_Card, ok: bool) {
	parts := strings.split(strings.trim_space(s), ":", context.temp_allocator)
	if len(parts) != 2 || len(parts[0]) != 1 {
		return {}, false
	}
	seat, seat_ok := norn.seat_from_letter(parts[0][0])
	card, card_ok := norn.parse_card(parts[1])
	if !seat_ok || !card_ok {
		return {}, false
	}
	return dd.Held_Card{seat = seat, card = card}, true
}

// Resolve a seat letter (N/E/S/W) and a suit letter (S/H/D/C) to their norn enums.
seat_suit :: proc(seat_s, suit_s: string) -> (seat: norn.Seat, suit: norn.Suit, ok: bool) {
	if len(seat_s) != 1 || len(suit_s) != 1 {
		return {}, {}, false
	}
	st, st_ok := norn.seat_from_letter(seat_s[0])
	su, su_ok := norn.suit_from_letter(suit_s[0])
	if !st_ok || !su_ok {
		return {}, {}, false
	}
	return st, su, true
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
// Write the interactive card page for ALL `boards` (one carousel). One page shell wraps every board; each
// board renders its compass + hidden `.par` (target/sim/leads bakes) + `.combo` blob (see
// render_board_body). A board that is not a valid 2-hand input gets a small note and the run continues.
// Returns "" on success, else an error message.
write_html :: proc(
	path: string,
	boards: []norn.Parsed_Board,
	args: ^Args,
	contract: dd.Contract,
	has_contract: bool,
) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	title := "Two-hand advisor (declarer + dummy)"
	norn.render_page_prologue(&b, .Html_Cards, title)
	for board in boards {
		render_board_body(&b, board, args, contract, has_contract)
	}
	norn.render_page_epilogue(&b, .Html_Cards)

	if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); werr != nil {
		return fmt.tprintf("could not write %q: %v", path, werr)
	}
	return ""
}

// Render ONE board into the page builder `b`: the declarer+dummy compass (defenders face-down), a hidden
// `.par` div carrying the CCA slider target and — when --sample is on — the `data-sim` contract grid and
// `data-sim-leads` opening-lead sub-grids, then the `.combo` analysis blob. combo.annotate reads a full
// Deal, so it is fed the known pair duplicated into both sides (synth_deal). A non-2-hand board writes a
// note instead. Prints (does not fail the page) on a per-board sampling error.
render_board_body :: proc(
	b: ^strings.Builder,
	board: norn.Parsed_Board,
	args: ^Args,
	contract: dd.Contract,
	has_contract: bool,
) {
	_, side, ok := combo.analyse_parsed_board(board)
	if !ok {
		strings.write_string(b, `<div class="par">Not a 2-hand board (need declarer + dummy, defenders '-').</div>`)
		return
	}
	sd, _, _ := combo.sd_bundle_parsed_board(board)

	bs, serr := sample_board(board, side, args, contract, has_contract)
	defer board_sample_free(&bs)
	if serr != "" {
		fmt.eprintln("pbn_analyse:", serr)
	}

	norn.render_deal_html_cards(b, board.deal, false, board.known)

	// Seed the CCA target slider. Prefer the contract level (level+6 tricks) when sampling, else the
	// user's --target, else a sensible default = the achievable single-dummy expected total.
	tgt := args.target
	if bs.have && tgt <= 0 {
		tgt = clamp(bs.contract.level + 6, 1, 13)
	}
	if tgt <= 0 {
		tgt = clamp(int(combo.expected_tricks(sd.totsd) + 0.5), 1, 13)
	}
	strings.write_string(b, "\n<div class=\"par\"")
	fmt.sbprintf(b, " data-target=\"%d\"", tgt)
	if bs.have {
		strings.write_string(b, " data-sim='")
		write_sim_json(b, &bs.grid, bs.contract)
		strings.write_string(b, "'")
		strings.write_string(b, " data-sim-leads='")
		write_leads_json(b, bs.leads, side)
		strings.write_string(b, "'")
	}
	strings.write_string(b, " hidden></div>\n")

	combo.annotate(b, synth_deal(board, side), .Html_Cards)
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
	write_g_object(b, sim.hist, sim.n)
	strings.write_byte(b, '}')
}

// Write the `g` object — the five per-strain NORMALISED trick distributions p[k] (k=0..13) — for a
// histogram grid divided by sample count `n`. Shared by the contract grid and the lead sub-grids.
write_g_object :: proc(b: ^strings.Builder, hist: [dd.Strain][14]int, n: int) {
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
write_leads_json :: proc(b: ^strings.Builder, leads: ^dd.Lead_Grids, side: bit_set[norn.Seat]) {
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
