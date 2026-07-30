package main

/*
	analyse_deal — the single-deal advisor driver (was `pbn_analyse`; renamed because it reads LIN too and
	handles complete deals, not just PBN and not just two hands).

	A single-file (`-file`) consumer program, separate from `sim.odin` (the deal generator): `sim` invents
	deals from a scenario predicate, this one analyses a deal you already have. It reads a deal, picks a
	mode from how much of it is known, and reports — as text and/or the interactive card page.

	TWO MODES, chosen per board by `board_fully_known`:

	  1. DECLARER + DUMMY (the two defender hands given as `-`). The naive card-combination analysis for
	     the KNOWN partnership: the double-dummy trick census (the ceiling) and the achievable
	     single-dummy line summary. The defenders' 26 cards stay unknown and `norn:combo` enumerates every
	     E/W split, so no solver is needed for that part; `--sample` adds the honest whole-hand make-%
	     (DDS over sampled layouts) and the misguess-tax achievable rung.
	  2. COMPLETE FOUR-HAND DEAL. The EXACT double-dummy result instead of a sampled one
	     (`report_full_deal` / `render_full_deal_body`): `deal_solve.annotate`'s par + makeable census for
	     the real deal, `combo.annotate` for BOTH partnerships, and an exact-DD contract grid on the page.

	Analysis comes from three libraries; this file is the driver, the text report and the page assembly:
	`norn:norn` (deal model, card-page renderer), `norn:combo` (per-suit card-combination engine),
	`deal_solve` (the DDS boundary: par/census, sampling, tax, grids), with `suit_book` registered as
	combo's published suit-combination table.

	Input (in priority order):
	  1. `--file <path>` / `-f <path>` — read the deal from a file (the whole file is scanned for a
	     `[Deal "..."]` tag).
	  2. positional args — joined with spaces and parsed as the deal string.
	  3. otherwise — read the deal from stdin (so `hand-ocr ... | analyse_deal` works).

	The deal string may be PBN (a `[Deal "..."]` tag or a bare `N:...` value) OR a LIN deal from a
	bridge site: paste a whole BBO / IntoBridge hand URL (`...?lin=pn|...|md|...`) — the `lin=` query
	parameter is extracted and percent-decoded — or a bare LIN record (`...md|...`). The `md|` deal is
	read; the auction and play are ignored. LIN input is always one whole board.

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

	Build/run (from the odin-sims dir): see the justfile `analyse-deal` recipe, e.g.
	  just analyse-deal '[Deal "N:AKQ.. ... - -"]'
	  just analyse-deal 'https://play.intobridge.com/hand?lin=...'   (a pasted bridge-site hand URL)
	The raw form:
	  odin run analyse_deal.odin -file -collection:norn=C:/Users/Enerqi/dev/norn -- --target 9 '<PBN>'
*/

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "deal_solve"
import "norn:combo"
import "norn:norn"
import "suit_book"

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	defer combo.shutdown() // free combo's worker pool if the HTML annotate spun it up (no-op otherwise)
	// This project's published suit-combination table; combo is engine-only until it is registered (see
	// combo/book.odin). Its key index is freed by the `combo.shutdown` above, via the provider.
	combo.set_suit_book(suit_book.provider())

	args, arg_err := parse_args(os.args[1:])
	defer delete(args.constraints)
	defer delete(args.held)
	if arg_err != "" {
		fmt.eprintln("analyse_deal:", arg_err)
		fmt.eprintln("usage: analyse_deal [--file <path>] [--target <n>] [--html <out.html>]")
		fmt.eprintln("                   [--sample <deals> [--contract <e.g. 4H>] [--seed <n>]]")
		fmt.eprintln(
			"                   [--void <seat>:<suit>] [--len <seat>:<suit>:<n|n-m|n+>] [--lead <seat>:<card>]",
		)
		fmt.eprintln("                   ['<PBN deal tag | LIN record | bridge-site hand URL>']")
		return 2
	}
	if strings.trim_space(args.text) == "" {
		fmt.eprintln("analyse_deal: no deal input (pass a PBN/LIN string, --file, or pipe via stdin)")
		return 2
	}
	// Resolve the input to boards. PBN input may hold several `[Deal]` tags (a hand-ocr session, a
	// `.pbn` file) — one board each; LIN input (a bridge-site URL or bare `md|` record) is one board.
	// Multiple boards render as one carousel page / a text report per board.
	boards, berr := resolve_boards(args.text)
	defer delete(boards)
	if berr != "" {
		fmt.eprintln("analyse_deal:", berr)
		return 1
	}
	if len(boards) == 0 {
		fmt.eprintln("analyse_deal: no deal found in the input")
		return 1
	}
	multi := len(boards) > 1
	// Constraints name specific seats/cards of ONE board, so they are meaningless across a set.
	if multi && (len(args.constraints) > 0 || len(args.held) > 0) {
		fmt.eprintln("analyse_deal: --void/--len/--lead condition a specific board, so they need a SINGLE board input")
		return 1
	}

	// --contract applies to every board (empty -> auto-pick per board). Parse it once, fail fast.
	contract: deal_solve.Contract
	has_contract := false
	if args.contract != "" {
		c, c_ok := deal_solve.parse_contract(args.contract)
		if !c_ok {
			fmt.eprintfln("analyse_deal: could not parse --contract %q (expected e.g. 4H, 3NT)", args.contract)
			return 1
		}
		contract, has_contract = c, true
	}

	// DDS lifecycle: init once if ANY board needs the solver — either --sample (2-hand advisor) OR a
	// fully-known 4-hand deal (exact double-dummy via deal_solve.annotate). The shutdown defer must sit at RUN scope
	// (not inside the if-block, or it would fire immediately after init — before any board solves).
	needs_dds := args.sample > 0
	if !needs_dds {
		for board in boards {
			if board_fully_known(board) {
				needs_dds = true
				break
			}
		}
	}
	if needs_dds {
		deal_solve.init()
	}
	defer {
		if needs_dds {
			deal_solve.shutdown()
		}
	}

	if args.html_path != "" {
		if werr := write_html(args.html_path, boards[:], &args, contract, has_contract); werr != "" {
			fmt.eprintln("analyse_deal:", werr)
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

// Text report for one board: the combo census + SD summary, and (with --sample) the simulated verdict.
// True iff all four hands are present — a complete deal, not the declarer+dummy (2-hand) advisor input.
// Such a board takes the EXACT double-dummy path (deal_solve.annotate solves the actual deal) rather than the
// DDS-sampling advisor (which models the unknown defenders).
board_fully_known :: proc(board: norn.Board) -> bool {
	return board.known == {.North, .East, .South, .West}
}

// Text report for a fully-known 4-hand deal: the layout, then the EXACT double-dummy verdict (par +
// NS-makeable, from deal_solve.annotate solving the actual deal — no sampling, no ceiling/achievable gap), then the
// per-partnership combo (CCA) census. Uses the temp allocator; the whole block prints at once.
report_full_deal :: proc(board: norn.Board) {
	b := strings.builder_make(context.temp_allocator)
	norn.render_deal_pretty(&b, board.deal)
	deal_solve.annotate(&b, board.deal, .Pretty)
	combo.annotate(&b, board.deal, .Pretty)
	fmt.println(strings.to_string(b))
}

report_board :: proc(board: norn.Board, args: ^Args, contract: deal_solve.Contract, has_contract: bool) {
	a, side, ok := combo.analyse_board(board)
	if !ok {
		if board_fully_known(board) {
			report_full_deal(board)
			return
		}
		fmt.eprintln(
			"analyse_deal: not a 2-hand advisor board — need exactly one fully-known partnership (declarer +",
		)
		fmt.eprintln("             dummy), the two defenders written '-'.")
		return
	}
	sd, _, _ := combo.sd_bundle_board(board)
	advice, _, _ := combo.suit_combo_advice_board(board)
	defer for ad in advice {
		delete(ad.cands)
	}

	bs, serr := sample_board(board, side, args, contract, has_contract)
	defer board_sample_free(&bs)
	if serr != "" {
		fmt.eprintln("analyse_deal:", serr)
	}

	// If sampling ran, the whole-hand simulated E[total] is the honest cross-check for the naive
	// census — thread it into the caveat so the over-count is named right where the warning lives.
	sim_total: Maybe(f64)
	sample: deal_solve.Sample_Result
	if bs.have {
		sample = deal_solve.result_for(bs.grid, bs.contract)
		sim_total = sample.mean_tricks
	}

	print_report(&a, &sd, advice, side, args.target, sim_total)
	if bs.have {
		print_sample_verdict(&a, &sd, &sample, bs.auto, bs.tax, bs.tax_ok, bs.leads, side, bs.contract)
		if len(args.constraints) > 0 || len(args.held) > 0 {
			fmt.print("  (sampled only layouts where")
			first := true
			for con in args.constraints {
				fmt.printf("%s %v %s %d-%d", " " if first else ",", con.seat, suit_word(con.suit), con.min, con.max)
				first = false
			}
			for h in args.held {
				fmt.printf("%s %v holds %s", " " if first else ",", h.seat, deal_solve.card_word(h.card))
				first = false
			}
			fmt.println(")")
		}
	}
}

// Resolve raw input text to boards, dispatching on format. LIN input — a bridge-site hand URL
// (`...?lin=...`) or a bare LIN record (`...md|...`) — is routed to the LIN reader; everything else is
// treated as PBN. Returns an error MESSAGE ("" == ok) rather than a typed error, since the two readers
// have distinct error enums. LIN yields exactly one board; PBN may yield several.
resolve_boards :: proc(text: string) -> (boards: [dynamic]norn.Board, errmsg: string) {
	is_url_lin := strings.contains(text, "lin=")
	// A bare LIN record has an `md|` token and no `[Deal "` tag (which would mark it as PBN).
	is_bare_lin := !is_url_lin && strings.contains(text, "md|") && !strings.contains(text, DEAL_TAG)

	if is_url_lin || is_bare_lin {
		lin_str := text
		if is_url_lin {
			lin_str = lin_query_param(text, context.temp_allocator)
		}
		b, e := norn.parse_lin_deal(lin_str)
		if e != .None {
			return nil, fmt.tprintf("could not parse LIN deal: %v", e)
		}
		append(&boards, b)
		return boards, ""
	}

	b, e := parse_boards(text)
	if e != .None {
		return nil, fmt.tprintf("could not parse PBN deal: %v", e)
	}
	return b, ""
}

// Extract the `lin=` query-parameter value from a URL (or any string containing `lin=`) and
// percent-decode it. The value runs to the next `&` (start of the next query parameter) or the end of
// the string — LIN's own `|` separators are part of the value, not query delimiters. Returns "" when
// there is no `lin=` (which parse_lin_deal then reports as a missing `md` tag). Allocates on `alloc`.
lin_query_param :: proc(text: string, alloc := context.allocator) -> string {
	li := strings.index(text, "lin=")
	if li < 0 {
		return ""
	}
	rest := text[li + len("lin="):]
	if amp := strings.index_byte(rest, '&'); amp >= 0 {
		rest = rest[:amp]
	}
	return url_decode(rest, alloc)
}

// Percent-decode a URL query value: `%XX` -> the byte, `+` -> space, everything else verbatim. A `%`
// not followed by two hex digits is passed through literally (real LIN URLs are well-formed; this just
// avoids losing data on a malformed one). Allocates the result on `alloc`.
url_decode :: proc(s: string, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			hi, hi_ok := hex_nibble(s[i + 1])
			lo, lo_ok := hex_nibble(s[i + 2])
			if hi_ok && lo_ok {
				strings.write_byte(&b, hi << 4 | lo)
				i += 3
				continue
			}
		}
		if c == '+' {
			strings.write_byte(&b, ' ')
		} else {
			strings.write_byte(&b, c)
		}
		i += 1
	}
	return strings.to_string(b)
}

// Value of a single hex digit (0-9, a-f, A-F). ok = false on any other byte.
hex_nibble :: proc(c: u8) -> (v: u8, ok: bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// The `[Deal` tag opener, including the space + quote that START its value: `[Deal "`. Matching this
// (rather than bare `[Deal`) is what keeps a standard `.pbn` file's `[Dealer "..."]` and `[Declarer
// "..."]` tags — which share the `[Deal` prefix — from being mistaken for deals.
@(private = "file")
DEAL_TAG :: `[Deal "`

// Parse every `[Deal "..."]` tag in `text` into a board (a hand-ocr session or a `.pbn` file may carry
// several). Each occurrence is parsed from its position (parse_pbn_deal reads the first tag it finds), so
// all other PBN tags ([Board]/[Dealer]/[Vulnerable]/...) are ignored. With NO `[Deal "` tag the whole input
// is treated as a single bare `N:...` value. Returns the first parse error hit.
parse_boards :: proc(text: string) -> (boards: [dynamic]norn.Board, err: norn.Pbn_Parse_Error) {
	idx := strings.index(text, DEAL_TAG)
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
		next := strings.index(text[idx + len(DEAL_TAG):], DEAL_TAG)
		if next < 0 {
			break
		}
		idx = idx + len(DEAL_TAG) + next
	}
	return boards, .None
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

// The green "honest verdict" rung: the whole-hand simulated make-%, plus a reconciliation strip showing
// the ceiling -> blind -> simulated tax as the gap between the three E[total] numbers.
print_sample_verdict :: proc(
	a: ^combo.Deal_Analysis,
	sd: ^combo.Sd_Bundle,
	s: ^deal_solve.Sample_Result,
	auto_contract: bool,
	tax: deal_solve.Tax_Result,
	tax_ok: bool,
	leads: ^deal_solve.Lead_Grids,
	side: bit_set[norn.Seat],
	contract: deal_solve.Contract,
) {
	label := deal_solve.contract_label(deal_solve.Contract{level = s.level, strain = s.strain}) // temp-allocated
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
	// D. Worst opening lead: the defender card that beats the contract most often, over the already-sampled
	// lead sub-grids. Only surfaced when it costs something material vs the baseline (a killing lead worth
	// warning about); a rare lead's sub-sample `n` is shown so its wider ± is honest.
	if leads != nil {
		if card, wpct, wn, base_pct, ok := deal_solve.worst_lead(leads, contract, side); ok && base_pct - wpct >= 3 {
			fmt.printfln(
				"  Worst opening lead: %s -> %.0f%% (vs %.0f%% average, %d deals) — plan for it.",
				deal_solve.card_word(card),
				wpct,
				base_pct,
				wn,
			)
		}
	}
	// The achievable (misguess-tax) rung: the ceiling docked by the dominant blind two-way guess. Only
	// shown when the estimator ran AND found a guess to tax; a guess-free board's achievable == ceiling,
	// so the extra line would just repeat the headline.
	if tax_ok && tax.n_pivots > 0 {
		fmt.printfln(
			"  achievable (blind play) %.0f%%   ·   taxed %.0f pts by the %s guess",
			tax.achievable_pct,
			tax.tax_pts,
			deal_solve.card_word(tax.pivots[0].card),
		)
	}
	fmt.println("  reconciliation:")
	fmt.printfln("    naive ceiling %.2f (DD census)", combo.expected_tricks(a.total))
	fmt.printfln("    naive blind   %.2f (SD census)", combo.expected_tricks(sd.totsd))
	fmt.printfln("    simulated     %.2f (DDS whole-hand)", s.mean_tricks)
	fmt.println("  (per-layout double-dummy census: a ceiling that already bakes in entries/squeezes/tempo per")
	fmt.println("   solve — far tighter than combo's per-suit sums; achievable docks it for the blind guess.")
	fmt.println("   See COMBO_ANALYSER.md Track 2.)")
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
	constraints: [dynamic]deal_solve.Card_Constraint, // defender-shape inferences from --void / --len
	held:        [dynamic]deal_solve.Held_Card, // specific-card locations from --lead / --card
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
parse_void_spec :: proc(s: string) -> (c: deal_solve.Card_Constraint, ok: bool) {
	parts := strings.split(strings.trim_space(s), ":", context.temp_allocator)
	if len(parts) != 2 {
		return {}, false
	}
	seat, suit, sk := seat_suit(parts[0], parts[1])
	if !sk {
		return {}, false
	}
	return deal_solve.Card_Constraint{seat = seat, suit = suit, min = 0, max = 0}, true
}

// Parse a `--len <seat>:<suit>:<spec>` where <spec> is `n` (exactly n), `n-m` (n..m), or `n+` (n..13).
parse_len_spec :: proc(s: string) -> (c: deal_solve.Card_Constraint, ok: bool) {
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
	return deal_solve.Card_Constraint{seat = seat, suit = suit, min = lo, max = hi}, true
}

// Parse a `--lead <seat>:<card>` spec into a Held_Card (that defender holds/led the card). The card is
// rank-first (norn convention): "KH" = king of hearts, "TS" = ten of spades.
parse_lead_spec :: proc(s: string) -> (h: deal_solve.Held_Card, ok: bool) {
	parts := strings.split(strings.trim_space(s), ":", context.temp_allocator)
	if len(parts) != 2 || len(parts[0]) != 1 {
		return {}, false
	}
	seat, seat_ok := norn.seat_from_letter(parts[0][0])
	card, card_ok := norn.parse_card(parts[1])
	if !seat_ok || !card_ok {
		return {}, false
	}
	return deal_solve.Held_Card{seat = seat, card = card}, true
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

// Read all of stdin into a string (for `hand-ocr ... | analyse_deal`). Best-effort: stops at EOF or any
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

// A. Winner/loser count + trick gap (aids plan A). Guaranteed top tricks = the sum of each suit's
// recommended-line FLOOR (`combo.sure_tricks` — the tricks every E/W split concedes); the gap to `target`
// is what must be DEVELOPED. Develop-from suits are those whose best line AVERAGES more than its floor (a
// finesse/duck that gains when it works), ranked by that surplus. Pure combo data (floor + best-line
// mean), no DDS — a canonical winner/loser teaching count layered on the census.
print_winner_count :: proc(sd: ^combo.Sd_Bundle, target: int) {
	letters := [4]string{"S", "H", "D", "C"} // Sd_Bundle order is S H D C
	floors: [4]int
	means: [4]f64
	guaranteed := 0
	for i in 0 ..< 4 {
		floors[i] = combo.sure_tricks(sd.best_marg[i].p)
		means[i] = combo.expected_tricks(sd.best_marg[i].p)
		guaranteed += floors[i]
	}

	fmt.printf("\nTop tricks (guaranteed): %d  (", guaranteed)
	for i in 0 ..< 4 {
		fmt.printf("%s%s%d", " " if i > 0 else "", letters[i], floors[i])
	}
	fmt.println(")")

	// No contract level in view (no --target / annotator) → just the count above; there is no gap to size.
	if target < 1 || target > 13 {
		return
	}
	gap := target - guaranteed
	if gap <= 0 {
		fmt.printfln("  Need %d → already guaranteed; cash your top tricks.", target)
		return
	}

	// Rank the develop-from suits by surplus (best-line mean over its guaranteed floor), descending.
	order := [4]int{0, 1, 2, 3}
	for i in 1 ..< 4 {
		j := i
		for j > 0 && (means[order[j]] - f64(floors[order[j]])) > (means[order[j - 1]] - f64(floors[order[j - 1]])) {
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		}
	}

	fmt.printf("  Need %d → develop %d more.", target, gap)
	any := false
	for oi in order {
		surplus := means[oi] - f64(floors[oi])
		if surplus < 0.05 {
			continue // no meaningful extra available by developing this suit
		}
		fmt.printf("%s %s %s (+%.1f)", " Sources:" if !any else " ·", letters[oi], sd.best_name[oi], surplus)
		any = true
	}
	if !any {
		fmt.print("  No suit develops extra tricks — the gap needs tempo/entries the naive model can't see.")
	}
	fmt.println()
}

// B. Suit-combination odds per line (aids plan B). For each suit that carries a real DECISION (a named
// pattern, or candidate lines whose means genuinely differ), list the distinct lines with their
// decision-relevant odds: E[tricks] and the chance of REACHING the extra trick over the line's guaranteed
// floor. The pattern note (combo `combination_note`) names the standard combination and mirrors the blind
// two-way guess the misguess tax prices. Pure combo data — no DDS.
print_combination_odds :: proc(advice: [4]combo.Suit_Combo_Advice) {
	letters := [4]string{"S", "H", "D", "C"} // DISPLAY_SUITS / Sd_Bundle order
	header := false
	for i in 0 ..< 4 {
		ad := advice[i]
		if !combination_is_decision(ad) {
			continue // a solid/void suit or one with a single dominant line — nothing to weigh up
		}
		if !header {
			fmt.println("\nSuit combinations (per-line odds — the guess each line hinges on):")
			header = true
		}
		fmt.printf("  %s", letters[i])
		if ad.note != "" {
			fmt.printf("   [%s]", ad.note)
		}
		fmt.println()

		// Emit each DISTINCT candidate once, highest mean first. Duplicate distributions (finesse ==
		// finesse-other on a one-way holding) collapse to a single line. cands is tiny (<= N_CANDIDATE_LINES),
		// so the repeated linear scans cost nothing. `pivotal` = the extra trick over this line's guaranteed
		// floor (what it is playing FOR); its reach % is the odds the line hinges on.
		done: [combo.N_CANDIDATE_LINES]bool
		emitted: [combo.N_CANDIDATE_LINES]bool
		for _ in 0 ..< len(ad.cands) {
			pick := -1
			for ls, j in ad.cands {
				if done[j] {
					continue
				}
				if pick < 0 || ls.mean > ad.cands[pick].mean {
					pick = j
				}
			}
			if pick < 0 {
				break
			}
			done[pick] = true
			ls := ad.cands[pick]
			dup := false
			for j in 0 ..< len(ad.cands) {
				if emitted[j] && abs(ad.cands[j].mean - ls.mean) < 1e-3 && ad.cands[j].floor == ls.floor {
					dup = true
					break
				}
			}
			if dup {
				continue // a near-identical line is already shown for this suit
			}
			emitted[pick] = true
			piv := ls.floor + 1
			if piv <= ls.dist.max_tricks && combo.p_reach(ls.dist.p, piv) < 0.999 {
				fmt.printfln(
					"      %-16s E %.2f  ·  %.0f%% to reach %d",
					ls.name,
					ls.mean,
					100 * combo.p_reach(ls.dist.p, piv),
					piv,
				)
			} else {
				fmt.printfln("      %-16s E %.2f  ·  guaranteed %d", ls.name, ls.mean, ls.floor)
			}
		}
	}
}

// A suit is worth a combination block when it names a standard pattern OR its candidate lines' means
// genuinely differ (a real choice between lines) — not a solid runner or a void where every line coincides.
combination_is_decision :: proc(ad: combo.Suit_Combo_Advice) -> bool {
	if ad.note != "" {
		return true
	}
	lo, hi := 99.0, -1.0
	for ls in ad.cands {
		lo = min(lo, ls.mean)
		hi = max(hi, ls.mean)
	}
	return hi - lo > 0.10
}

// C. Safety play / min-variance line (aids plan C). Where a suit's best line BY MEAN differs from its best
// line BY FLOOR — the high-mean line risks tricks the safety line locks in — show the trade. C3: if the
// tricks guaranteed ELSEWHERE plus this suit's safety floor already meet `target`, say so — you don't need
// the overtrick, so take the safety line. Pure combo data.
print_safety :: proc(advice: [4]combo.Suit_Combo_Advice, target: int) {
	letters := [4]string{"S", "H", "D", "C"}
	// Total guaranteed across suits from the best-by-mean lines (same basis as the winner count).
	total_floor := 0
	for i in 0 ..< 4 {
		ad := advice[i]
		total_floor += ad.cands[ad.best_mean_idx].floor
	}
	header := false
	for i in 0 ..< 4 {
		ad := advice[i]
		mean_line := ad.cands[ad.best_mean_idx]
		floor_line := ad.cands[ad.best_floor_idx]
		if ad.best_mean_idx == ad.best_floor_idx || floor_line.floor <= mean_line.floor {
			continue // no distinct safety line, or it guarantees no more than the max-mean line
		}
		// GATE (aids plan C): the cheap candidate-line floors are pessimistic — the generic finesse plays
		// mechanically and can throw a trick optimal play would keep (e.g. AKJ98: `finesse` floors at 1,
		// but cashing A K then finessing floors at 2). That is NOT a real safety trade. Verify with the
		// OPTIMAL blind-line search: only a genuine trade when even the mean-maximising line's own floor
		// falls short of the safety floor. When the exact search overflows we can't verify, so stay silent.
		opt, exact := combo.sd_optimal_distribution(ad.north_holding, ad.south_holding)
		opt_floor := combo.sure_tricks(opt.p)
		if !exact || opt_floor >= floor_line.floor {
			continue // optimal play already secures the safety floor (or unverifiable) — no real trade
		}
		if !header {
			fmt.println("\nSafety plays (most tricks vs guaranteed floor):")
			header = true
		}
		fmt.printfln(
			"  %s  max: %s (E %.2f, but %d if it loses)  ·  safety: %s (guaranteed %d)",
			letters[i],
			mean_line.name,
			mean_line.mean,
			opt_floor, // honest downside: the best max-expectation line's guaranteed floor, not the mechanical one
			floor_line.name,
			floor_line.floor,
		)
		if target >= 1 && target <= 13 {
			elsewhere := total_floor - mean_line.floor
			if elsewhere + floor_line.floor >= target {
				fmt.printfln(
					"       -> %d guaranteed elsewhere + %d here = %d >= %d: take the safety line, you don't need the overtrick.",
					elsewhere,
					floor_line.floor,
					elsewhere + floor_line.floor,
					target,
				)
			}
		}
	}
}

// A cheap "where do I start" sketch (PROTOTYPE). Rank the four suits by their single-dummy expected
// tricks (trick-source strength) and tag each recommended line's role — cash / finesse-guess /
// duck-develop — then point trick 1 at the strongest suit that must be DEVELOPED, since finesses and
// ducks want to happen early (while entries and trump control hold) whereas sure winners can wait.
//
// This is a per-suit HEURISTIC built entirely from combo data (no DDS solves). It is NOT a sound
// whole-hand line: a correct blind plan is the PIMC problem — expensive, and it undershoots (Monte-
// Carlo single-dummy suffers strategy fusion; see COMBO_ANALYSER.md), so the honest whole-hand number
// stays the simulated verdict. Read this as a starting pointer, not a play engine.
print_priority_sketch :: proc(sd: ^combo.Sd_Bundle) {
	letters := [4]string{"S", "H", "D", "C"} // Sd_Bundle order is S H D C
	means: [4]f64
	for i in 0 ..< 4 {
		means[i] = combo.expected_tricks(sd.best_marg[i].p)
	}
	// Order the suit indices by expected tricks, descending (insertion sort; only four elements).
	order := [4]int{0, 1, 2, 3}
	for i in 1 ..< 4 {
		j := i
		for j > 0 && means[order[j]] > means[order[j - 1]] {
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		}
	}

	fmt.println("\nSuit-priority sketch (naive heuristic — where to start, not a whole-hand plan):")
	develop_best := -1
	develop_best_mean := -1.0
	for oi in order {
		role, develop := line_role(sd.best_name[oi])
		fmt.printfln("  %s  ~%.1f tricks   %-17s (%s)", letters[oi], means[oi], role, sd.best_name[oi])
		if develop && means[oi] > develop_best_mean {
			develop_best, develop_best_mean = oi, means[oi]
		}
	}
	if develop_best >= 0 {
		fmt.printfln(
			"  Trick 1: start %s — it must be developed (finesse/duck), so do it early while entries hold;",
			letters[develop_best],
		)
		fmt.println("           cash your solid winners later.")
	} else {
		fmt.println("  Trick 1: cash your winners top-down — no suit needs an early guess.")
	}
	fmt.println("  (Naive per-suit ordering; the honest whole-hand number is the simulated verdict.)")
}

// Classify a combo single-dummy line name into a human role phrase and whether it needs DEVELOPING
// (a finesse to guess or a duck to concede — do early) vs a solid cash (can wait).
line_role :: proc(name: string) -> (role: string, develop: bool) {
	switch {
	case strings.has_prefix(name, "finesse"):
		return "finesse - guess", true
	case strings.has_prefix(name, "duck"), name == "ducking":
		return "develop by duck", true
	case name == "top-down":
		return "cash top winners", false
	}
	return name, false
}

// F. Entry / timing warnings (LEARNER_AIDS_PLAN.md F) — a CRUDE, clearly-flagged heuristic. The naive
// model assumes FREE ENTRIES; this partly walks that back by warning when a suit's recommended finesse
// must be led from one hand more than once (a REPEATED finesse) but that hand has too few outside
// entries to get back there for each attempt. It is NOT a real entry analysis (that needs the whole-hand
// play): the entry count under-reads (high cards only, no ruffing/long-card entries), so the check is
// conservative and printed under a loud HEURISTIC banner. Combo geometry only — no DDS.
print_entry_warnings :: proc(sd: ^combo.Sd_Bundle, advice: [4]combo.Suit_Combo_Advice, side: bit_set[norn.Seat]) {
	letters := [4]string{"S", "H", "D", "C"} // Sd_Bundle / advice order is S H D C
	ns := side == combo.NS_SIDE
	seat_name := [2]string{ns ? "North" : "East", ns ? "South" : "West"} // [SEAT_N slot, SEAT_S slot]
	north_suits, south_suits: [4]u16
	for i in 0 ..< 4 {
		north_suits[i] = advice[i].north_holding
		south_suits[i] = advice[i].south_holding
	}

	header := false
	for i in 0 ..< 4 {
		if !strings.has_prefix(sd.best_name[i], "finesse") {
			continue // only a finesse creates a repeated-lead entry demand; cashes lead from anywhere
		}
		n, s := advice[i].north_holding, advice[i].south_holding
		needed := combo.finesse_leads_needed(n, s)
		if needed < 2 {
			continue // a single finesse rarely has an entry problem; only flag a REPEATED finesse
		}
		lead_seat := combo.finesse_leading_seat(n, s)
		hand_suits := north_suits if lead_seat == combo.SEAT_N else south_suits
		entries := combo.sure_side_entries(hand_suits, i)
		if entries >= needed - 1 {
			continue // enough outside entries to return to the leading hand for each repeat
		}
		if !header {
			fmt.println("\nEntry / timing check (HEURISTIC — the naive model assumes free entries):")
			header = true
		}
		who := seat_name[0] if lead_seat == combo.SEAT_N else seat_name[1]
		fmt.printfln(
			"  %s  the finesse is led from %s and wants ~%d leads there, but %s has only %d outside entr%s — repeating it may fail (an entry problem the free-entry model ignores).",
			letters[i],
			who,
			needed,
			who,
			entries,
			"y" if entries == 1 else "ies",
		)
	}
}

// Print the census table plus a single-dummy summary for the analysed partnership. When `sim_total`
// is set (sampling ran), the caveat names the whole-hand simulated E[total] as the honest cross-check
// and the gap below the naive blind sum — instead of the "no DDS par to cross-check" wording, which
// only holds when sampling is off.
print_report :: proc(
	a: ^combo.Deal_Analysis,
	sd: ^combo.Sd_Bundle,
	advice: [4]combo.Suit_Combo_Advice,
	side: bit_set[norn.Seat],
	target: int,
	sim_total: Maybe(f64) = nil,
) {
	side_name := side == combo.NS_SIDE ? "N/S" : "E/W"
	fmt.printfln("Card-combination analysis for %s (declarer + dummy); defenders unknown.\n", side_name)

	// Double-dummy census table (the trick ceiling). format_analysis allocates from context.allocator.
	table := combo.format_analysis(a, target)
	defer delete(table)
	fmt.println("Double-dummy census (naive per-suit ceiling):")
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
	print_winner_count(sd, target)
	print_combination_odds(advice)
	print_safety(advice, target)
	print_priority_sketch(sd)
	print_entry_warnings(sd, advice, side)

	fmt.println("\nNote: the naive model assumes free entries and independent suits, so totals are an upper")
	if st, ok := sim_total.?; ok {
		blind := combo.expected_tricks(sd.totsd)
		fmt.println("bound (no tempo race, no squeezes/endplays). The whole-hand DDS simulation below is the")
		fmt.printfln(
			"honest cross-check: %.2f tricks vs this naive %.2f blind sum — the %.2f-trick gap is the over-count.",
			st,
			blind,
			blind - st,
		)
	} else {
		fmt.println("bound (no tempo race, no squeezes/endplays). With only two hands there is no DDS par to")
		fmt.println("cross-check it against. See COMBO_ANALYSER.md.")
	}
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
	boards: []norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// Title reflects the input: all full 4-hand deals -> exact double-dummy analysis; all 2-hand -> the
	// advisor; a mix -> a neutral label.
	n_full := 0
	for board in boards {
		if board_fully_known(board) {
			n_full += 1
		}
	}
	title := "Two-hand advisor (declarer + dummy)"
	if n_full == len(boards) {
		title = "Bridge deal analysis (double-dummy + CCA)"
	} else if n_full > 0 {
		title = "Bridge deal analysis"
	}
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

// Render a fully-known 4-hand deal into the page builder `b`: all four hands face-up, then the EXACT
// double-dummy caption (`deal_solve.annotate` Html_Cards: the `.par` div with par + NS-makeable + the CCA slider's
// `data-target`, from ONE solve of the actual deal), then the per-partnership combo (CCA) census for BOTH
// sides (`combo.annotate` on the real deal). No `data-sim`: with the deal known, double-dummy is the exact
// verdict — there is no sampling ceiling to show and no misguess-tax rung (that models unknown defenders).
// This is exactly the sim card-page flow (deal_solve.annotate then combo.annotate) for a board fed as PBN.
render_full_deal_body :: proc(
	b: ^strings.Builder,
	board: norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
) {
	norn.render_deal_html_cards(b, board.deal, false, board.known)
	deal_solve.annotate(b, board.deal, .Html_Cards)
	// Exact double-dummy grids (one per side) so the card page's contract picker + trick slider come alive
	// on the known deal (spikes at each strain's DD tricks; the band relabels to "double-dummy (exact)").
	// Carried on its own hidden element — deal_solve.annotate owns the `.par` div — which render.odin reads as the
	// board's data-sim source. With `--sample` we ALSO bake the BLIND advisor per side (sample_board ignores
	// the known defenders and randomises the other 26, i.e. "play it as if you can't see all four hands"),
	// so the page can toggle exact ↔ blind for either partnership. solve_table is cached (deal_solve.annotate's).
	if ns_grid, ew_grid, ok := deal_solve.exact_grids(board.deal); ok {
		strings.write_string(b, `<div class="sim-exact" hidden data-sim='`)
		deal_solve.write_exact_sim_json(b, &ns_grid, &ew_grid, board)
		strings.write_string(b, `'`)
		if args.sample > 0 {
			strings.write_string(b, ` data-sim-blind='`)
			write_blind_sides_json(b, board, args, contract, has_contract)
			strings.write_string(b, `'`)
		}
		strings.write_string(b, `></div>`)
	}
	strings.write_string(b, `<div class="cca-meta" data-known="all" hidden></div>`)
	combo.annotate(b, board.deal, .Html_Cards)
}

// Bake the BLIND (DDS-sampled) advisor grids for BOTH partnerships of a known deal: `{"ns":<sim>,"ew":<sim>}`
// where each `<sim>` is the same shape write_sim_json emits for a 2-hand board (n/lvl/strain/g plus the
// misguess-tax ach/taxpts/pvt AND the nested opening-lead sub-grids, so each side drives its own lead picker
// in Blind mode). sample_board treats the named side as declarer+dummy and randomises the
// other 26 cards, so this is exactly "how would this side fare playing blind". A side that fails to sample
// is emitted as null.
write_blind_sides_json :: proc(
	b: ^strings.Builder,
	board: norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
) {
	// The recorded opening lead pre-selects the picker, but only on the side it defends against (its leader is
	// one of that side's defenders). ns_lseat/ew_lseat stay 0 (unset) otherwise, and for a board with no lead.
	ns_lseat, ew_lseat: u8 = 0, 0
	ns_lword, ew_lword: string = "", ""
	if lead, has := board.opening_lead.?; has {
		if lead.leader not_in combo.NS_SIDE { 	// leader is E/W -> a defender for N/S
			ns_lseat, ns_lword = deal_solve.seat_letter(lead.leader), deal_solve.card_word(lead.card)
		}
		if lead.leader not_in combo.EW_SIDE { 	// leader is N/S -> a defender for E/W
			ew_lseat, ew_lword = deal_solve.seat_letter(lead.leader), deal_solve.card_word(lead.card)
		}
	}

	strings.write_byte(b, '{')
	bs_ns, _ := sample_board(board, combo.NS_SIDE, args, contract, has_contract)
	defer board_sample_free(&bs_ns)
	strings.write_string(b, `"ns":`)
	if bs_ns.have {
		deal_solve.write_sim_json(
			b,
			&bs_ns.grid,
			bs_ns.contract,
			bs_ns.tax,
			bs_ns.tax_ok,
			bs_ns.leads,
			combo.NS_SIDE,
			ns_lseat,
			ns_lword,
			bs_ns.lead_tax,
		)
	} else {
		strings.write_string(b, "null")
	}
	bs_ew, _ := sample_board(board, combo.EW_SIDE, args, contract, has_contract)
	defer board_sample_free(&bs_ew)
	strings.write_string(b, `,"ew":`)
	if bs_ew.have {
		deal_solve.write_sim_json(
			b,
			&bs_ew.grid,
			bs_ew.contract,
			bs_ew.tax,
			bs_ew.tax_ok,
			bs_ew.leads,
			combo.EW_SIDE,
			ew_lseat,
			ew_lword,
			bs_ew.lead_tax,
		)
	} else {
		strings.write_string(b, "null")
	}
	strings.write_byte(b, '}')
}

// Render ONE board into the page builder `b`: the declarer+dummy compass (defenders face-down), a hidden
// `.par` div carrying the CCA slider target and — when --sample is on — the `data-sim` contract grid and
// `data-sim-leads` opening-lead sub-grids, then the `.combo` analysis blob. combo.annotate reads a full
// Deal, so it is fed the known pair duplicated into both sides (synth_deal). A non-2-hand board writes a
// note instead. Prints (does not fail the page) on a per-board sampling error.
render_board_body :: proc(
	b: ^strings.Builder,
	board: norn.Board,
	args: ^Args,
	contract: deal_solve.Contract,
	has_contract: bool,
) {
	_, side, ok := combo.analyse_board(board)
	if !ok {
		if board_fully_known(board) {
			render_full_deal_body(b, board, args, contract, has_contract)
			return
		}
		strings.write_string(b, `<div class="par">Not a 2-hand board (need declarer + dummy, defenders '-').</div>`)
		return
	}
	sd, _, _ := combo.sd_bundle_board(board)

	bs, serr := sample_board(board, side, args, contract, has_contract)
	defer board_sample_free(&bs)
	if serr != "" {
		fmt.eprintln("analyse_deal:", serr)
	}

	norn.render_deal_html_cards(b, board.deal, false, board.known)
	// The real known side, so the CCA panel locks its toggle here (the other side is this pair duplicated).
	fmt.sbprintf(b, `<div class="cca-meta" data-known="%s" hidden></div>`, deal_solve.side_key(side))

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
		deal_solve.write_sim_json(b, &bs.grid, bs.contract, bs.tax, bs.tax_ok)
		strings.write_string(b, "'")
		strings.write_string(b, " data-sim-leads='")
		deal_solve.write_leads_json(b, bs.leads, side, bs.lead_tax)
		strings.write_string(b, "'")
		// Per-suit blind two-way GUESS notes (Option C1 narration): the misguess-tax pivots keyed by suit,
		// merged client-side into that suit's line tooltip. Only when a guess actually COSTS something at
		// this contract (a cushioned/non-pivotal guess has nothing to narrate).
		if bs.tax_ok && deal_solve.tax_has_narratable_guess(bs.tax) {
			strings.write_string(b, " data-sim-guess='")
			deal_solve.write_sim_guess_json(b, side, bs.tax)
			strings.write_string(b, "'")
		}
	}
	strings.write_string(b, " hidden></div>\n")

	combo.annotate(b, synth_deal(board, side), .Html_Cards)
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
