package analyse

/*
	args.odin — the command line, and the seat/suit/card specs (part of package `analyse`; see analyse.odin).

	The GUI uses this too, and on purpose: it composes an argv slice from its controls and parses it here,
	so the flag surface, the validation and the error strings cannot drift between the window and the
	terminal. `allow_stdin = false` is the one thing it changes.
*/

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"

import "../deal_solve"
import "norn:norn"

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
	help:        bool, // -h / --help was given: the caller prints the usage and exits 0
	text_owned:  bool, // `text` is heap-allocated and `args_free` should free it (see parse_args)
}

// Free an Args' owned memory. `text` is freed only when `text_owned` is set, which `parse_args` does and
// a hand-built `Args` does not: every one of parse_args' three input routes allocates (`strings.join`
// allocates even for a single positional), but a caller that assigns a borrowed literal to `text` must
// not have it freed underneath them.
args_free :: proc(args: ^Args) {
	delete(args.constraints)
	delete(args.held)
	args.constraints = nil
	args.held = nil
	if args.text_owned {
		delete(args.text)
		args.text, args.text_owned = "", false
	}
}

// The raw command line, as `core:flags` fills it in from this struct's run-time type info and tags. The
// FIELD NAMES are the flag names (parsed UNIX-style, so `--sample 400`, `--sample=400` and `-sample 400`
// all work); the one-letter fields are the short aliases, hidden from the usage text and folded into
// their long forms by `parse_args`. `core:flags` also writes the usage from the `usage` tags, so it
// cannot drift from the flag list the way a hand-written usage string does.
//
// The seat/suit/card specs arrive as raw strings and go through the existing `parse_*_spec` procs
// afterwards, rather than through `flags.register_type_setter`: that hook is a package-level GLOBAL, and
// the programs that link this also link `norn:cli`, which would then share it.
Cli :: struct {
	file:     string `usage:"read the deal from this file (the whole file is scanned for a [Deal] tag)"`,
	html:     string `usage:"write the interactive card page here"`,
	target:   int `usage:"highlight the P(>= n) make column (0 = no highlight)"`,
	sample:   int `usage:"DDS-sample this many layouts for the whole-hand make-% (0 = off; 200-500 is plenty)"`,
	contract: string `usage:"contract to score under --sample, e.g. 4H, 3NT (default: auto-pick the best)"`,
	seed:     u64 `usage:"seed the --sample RNG (reproducible)"`,
	void:     [dynamic]string `usage:"<seat>:<suit> — that defender is void, e.g. E:S. Repeatable"`,
	len:      [dynamic]string `usage:"<seat>:<suit>:<n|n-m|n+> — defender suit length, e.g. W:H:6. Repeatable"`,
	lead:     [dynamic]string `usage:"<seat>:<card> — that defender holds/led it, e.g. W:KH (rank-first). Repeatable"`,
	card:     [dynamic]string `args:"hidden"`, // alias for --lead
	f:        string `args:"hidden"`, // alias for --file
	o:        string `args:"hidden"`, // alias for --html
	t:        int `args:"hidden"`, // alias for --target
	s:        int `args:"hidden"`, // alias for --sample
	c:        string `args:"hidden"`, // alias for --contract
	overflow: [dynamic]string `usage:"the deal: a PBN [Deal] tag or bare N:... value, a LIN record, or a bridge-site hand URL"`,
}

// PBN writes an UNKNOWN hand as a bare `-` (`N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -`), which is the
// normal shape of a two-hand advisor input — but `core:flags` reads any token starting with `-` as a
// flag, and an UNQUOTED deal reaches us as several tokens. Swap those lone dashes for a sentinel before
// parsing and back afterwards, so an unquoted two-hand deal keeps working as it did under the
// hand-rolled parser. (Every scripted caller quotes the deal into one argument; humans often don't.)
VOID_HAND :: "-"
VOID_HAND_SENTINEL :: "\x00void-hand"

// Split the argv tail into an `Args` and an error message ("" == ok). `--file` wins over positionals;
// positionals win over stdin (resolved here when neither is given). A `-h` sets `out.help` and returns
// at once — notably WITHOUT touching stdin, so `analyse_deal -h` does not hang waiting for input.
//
// `allow_stdin = false` leaves `out.text` empty instead of reading stdin, for a caller with no terminal
// behind it (the GUI). `run` then reports the empty input as a usage error rather than blocking forever.
parse_args :: proc(argv: []string, allow_stdin := true) -> (out: Args, err: string) {
	patched := make([]string, len(argv), context.temp_allocator)
	for arg, i in argv {
		patched[i] = VOID_HAND_SENTINEL if arg == VOID_HAND else arg
	}

	cli: Cli
	defer {
		delete(cli.void)
		delete(cli.len)
		delete(cli.lead)
		delete(cli.card)
		delete(cli.overflow)
	}

	if parse_err := flags.parse(&cli, patched, .Unix); parse_err != nil {
		if _, is_help := parse_err.(flags.Help_Request); is_help {
			out.help = true
			return out, ""
		}
		return out, flags_error_message(parse_err)
	}

	// Fold the short aliases into their long forms. 0 / "" is both the zero value and the "off" value
	// for every one of these, so an unset alias is indistinguishable from one set to its default — and
	// that is exactly the behaviour we want.
	if cli.f != "" {
		cli.file = cli.f
	}
	if cli.o != "" {
		cli.html = cli.o
	}
	if cli.t != 0 {
		cli.target = cli.t
	}
	if cli.s != 0 {
		cli.sample = cli.s
	}
	if cli.c != "" {
		cli.contract = cli.c
	}
	if cli.sample < 0 {
		return out, fmt.tprintf("--sample %d is not a positive number", cli.sample)
	}
	out.html_path, out.target, out.sample, out.contract, out.seed =
		cli.html, cli.target, cli.sample, cli.contract, cli.seed

	// The repeatable seat/suit/card specs. --void and --len both produce shape bounds and land in the
	// same `constraints` list; it is an unordered AND filter (see deal_solve's `constraints_satisfied`),
	// so splitting them across two flags loses nothing.
	for spec in cli.void {
		c, c_ok := parse_void_spec(spec)
		if !c_ok {
			return out, fmt.tprintf("--void %q is not <seat>:<suit> (seat E/W or N/S, suit S/H/D/C)", spec)
		}
		append(&out.constraints, c)
	}
	for spec in cli.len {
		c, c_ok := parse_len_spec(spec)
		if !c_ok {
			return out, fmt.tprintf("--len %q is not <seat>:<suit>:<n|n-m|n+>", spec)
		}
		append(&out.constraints, c)
	}
	append(&cli.lead, ..cli.card[:]) // --card is an alias, so the two lists are one
	for spec in cli.lead {
		h, h_ok := parse_lead_spec(spec)
		if !h_ok {
			return out, fmt.tprintf("--lead %q is not <seat>:<card> (card rank-first, e.g. KH, TS)", spec)
		}
		append(&out.held, h)
	}

	if cli.file != "" {
		data, read_err := os.read_entire_file_from_path(cli.file, context.allocator)
		if read_err != nil {
			return out, fmt.tprintf("could not read file %q: %v", cli.file, read_err)
		}
		out.text, out.text_owned = string(data), true
		return out, ""
	}
	if len(cli.overflow) > 0 {
		for &token in cli.overflow {
			if token == VOID_HAND_SENTINEL {
				token = VOID_HAND
			}
		}
		out.text, out.text_owned = strings.join(cli.overflow[:], " "), true
		return out, ""
	}
	if allow_stdin {
		out.text, out.text_owned = read_stdin(), true
	}
	return out, ""
}

// Flatten a `core:flags` error to the one-line message the caller prints. (`flags.print_errors` would
// write it for us, but it formats for its own `parse_or_exit` and prints usage itself; the driver owns both.)
flags_error_message :: proc(err: flags.Error) -> string {
	switch e in err {
	case flags.Parse_Error:
		return e.message if e.message != "" else fmt.tprintf("%v", e.reason)
	case flags.Validation_Error:
		return e.message
	case flags.Open_File_Error:
		return fmt.tprintf("could not open %q: %v", e.filename, e.errno)
	case flags.Help_Request:
	}
	return "bad command line"
}

// The flag list, generated by `core:flags` from `Cli`'s tags. Only the input precedence — which is
// positional/stdin behaviour rather than a flag — is written by hand.
write_usage :: proc(w: io.Writer) {
	flags.write_usage(w, Cli, PROGRAM, .Unix)
	fmt.wprintln(w, "\nThe deal is read from --file, else the positional argument(s), else stdin.")
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
