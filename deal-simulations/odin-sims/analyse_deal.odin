package main

/*
	analyse_deal — the single-deal advisor driver (was `pbn_analyse`; renamed because it reads LIN too and
	handles complete deals, not just PBN and not just two hands).

	A single-file (`-file`) consumer program, separate from `sim.odin` (the deal generator): `sim` invents
	deals from a scenario predicate, this one analyses a deal you already have. It reads a deal, picks a
	mode from how much of it is known, and reports — as text and/or the interactive card page.

	This file is ONLY the command-line driver: the argument surface, the process exit codes, and the
	per-application library lifecycle. All the analysis, the reader, the text report and the page assembly
	live in the local `analyse` package (see `analyse/analyse.odin`, which documents the two modes and the
	libraries behind them) — the same relationship `sim.odin` has to `norn:cli`. `workbench.odin` drives
	that package in-process too, which is why it is a package and not this file.

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
	  -h / --help            Print the flag list (generated from the `Cli` struct) and exit 0.

	Build/run (from the odin-sims dir): see the justfile `analyse-deal` recipe, e.g.
	  just analyse-deal '[Deal "N:AKQ.. ... - -"]'
	  just analyse-deal 'https://play.intobridge.com/hand?lin=...'   (a pasted bridge-site hand URL)
	The raw form:
	  odin run analyse_deal.odin -file -collection:norn=C:/Users/Enerqi/dev/norn -- --target 9 '<PBN>'
*/

import "core:fmt"
import "core:os"

import "analyse"
import "norn:combo"
import "suit_book"

// Process exit codes. 0 = success; 2 for a usage/CLI error and 1 for a runtime failure — the same
// convention `norn:cli` answers the shell with (see cli/app.odin's EXIT_* constants), kept as a
// distinct type here so every `return` in `run` names its meaning. `int`-backed, so handing it to
// `os.exit` is a free conversion, and so `analyse.Result` (which carries the same values) converts.
// The VALUES are load-bearing: tools/ocr_analyse.py and tests/golden_sim_json.py shell out to this
// program and read them.
Exit :: enum int {
	Ok            = 0,
	Runtime_Error = 1,
	Usage_Error   = 2,
}

main :: proc() {
	os.exit(int(run()))
}

run :: proc() -> Exit {
	defer combo.shutdown() // free combo's worker pool if the HTML annotate spun it up (no-op otherwise)
	// This project's published suit-combination table; combo is engine-only until it is registered (see
	// combo/book.odin). Its key index is freed by the `combo.shutdown` above, via the provider.
	combo.set_suit_book(suit_book.provider())

	sink := analyse.stdio_sink()

	args, arg_err := analyse.parse_args(os.args[1:])
	defer analyse.args_free(&args)
	if arg_err != "" {
		fmt.eprintfln("%s: %s", analyse.PROGRAM, arg_err)
		analyse.write_usage(sink.err)
		return .Usage_Error
	}
	if args.help {
		analyse.write_usage(sink.out)
		return .Ok
	}

	return Exit(analyse.run(sink, &args))
}
