package analyse

/*
	analyse — the single-deal advisor, as a library.

	This is the reusable half of the `analyse_deal` program: read a deal, pick a mode from how much of it
	is known, and produce the text report and/or the interactive card page. `analyse_deal.odin` is the
	thin CLI `main` over it (the same relationship `sim.odin` has to `norn:cli`), and the sciter
	workbench (`workbench.odin`) drives the same procs in-process, rendering the report into a window
	instead of a terminal.

	Why a package and not a single-file program: a `-file` `package main` cannot be imported, so nothing
	else could reuse the reader, the sampler or the report, and none of it could carry `@(test)`
	assertions. Splitting the driver off costs one indirection and buys both.

	TWO MODES, chosen per board by `board_fully_known`:

	  1. DECLARER + DUMMY (the two defender hands given as `-`). The naive card-combination analysis for
	     the KNOWN partnership: the double-dummy trick census (the ceiling) and the achievable
	     single-dummy line summary. The defenders' 26 cards stay unknown and `norn:combo` enumerates every
	     E/W split, so no solver is needed for that part; `--sample` adds the honest whole-hand make-%
	     (DDS over sampled layouts) and the misguess-tax achievable rung.
	  2. COMPLETE FOUR-HAND DEAL. The EXACT double-dummy result instead of a sampled one
	     (`report_full_deal` / `render_full_deal_body`): `deal_solve.annotate`'s par + makeable census for
	     the real deal, `combo.annotate` for BOTH partnerships, and an exact-DD contract grid on the page.

	Analysis comes from three libraries; this package is the reader, the text report and the page
	assembly: `norn:norn` (deal model, card-page renderer), `norn:combo` (per-suit card-combination
	engine), `deal_solve` (the DDS boundary: par/census, sampling, tax, grids).

	NOT this package's business, deliberately, because it is per-application lifecycle rather than
	analysis: registering `suit_book` as combo's published table (`combo.set_suit_book`), `combo.shutdown`,
	and reading stdin when no deal was given. Each driver owns those — see `analyse_deal.odin`'s `run`.
	DDS init/shutdown IS handled here (`run` knows which boards need a solver).

	All output goes through a `Sink`, never to a fixed handle, which is what lets the GUI capture a run.
*/

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import "../deal_solve"

// The program name every diagnostic is prefixed with. A constant rather than a Sink field: the CLI's
// stderr lines are load-bearing (tools/ocr_analyse.py and the golden test read this program's output),
// so the prefix must not vary by caller.
PROGRAM :: "analyse_deal"

// Where a run's output goes. `out` takes the report; `err` takes diagnostics — a per-board warning, a
// sampling failure, the "wrote <path>" confirmation — the things a terminal sends to stderr. A GUI
// passes the same writer twice and gets them interleaved in one pane, which is what you want on screen.
Sink :: struct {
	out: io.Writer,
	err: io.Writer,
}

// The Sink a command-line driver wants: report on stdout, diagnostics on stderr.
stdio_sink :: proc() -> Sink {
	return Sink{out = os.to_writer(os.stdout), err = os.to_writer(os.stderr)}
}

// A Sink that appends everything — report and diagnostics both — to one builder. For the GUI, and for
// tests that assert on report text.
builder_sink :: proc(b: ^strings.Builder) -> Sink {
	w := strings.to_writer(b)
	return Sink{out = w, err = w}
}

// How a run ended. The values match `analyse_deal.odin`'s `Exit` (and `norn:cli`'s EXIT_* convention):
// a usage/CLI error is distinct from a runtime failure, because callers script against them.
Result :: enum int {
	Ok            = 0,
	Runtime_Error = 1,
	Usage_Error   = 2,
}

// Analyse `args` and write the result to `sink`: the card page when `args.html_path` is set, else one
// text report per board. Everything after argument parsing, including the DDS lifecycle — so a caller
// that built `Args` by hand (the GUI) gets exactly the CLI's behaviour without repeating any of it.
//
// The caller registers the suit book and calls `combo.shutdown` (see this package's doc comment).
run :: proc(sink: Sink, args: ^Args) -> Result {
	if strings.trim_space(args.text) == "" {
		fmt.wprintfln(sink.err, "%s: no deal input (pass a PBN/LIN string, --file, or pipe via stdin)", PROGRAM)
		return .Usage_Error
	}
	// Resolve the input to boards. PBN input may hold several `[Deal]` tags (a hand-ocr session, a
	// `.pbn` file) — one board each; LIN input (a bridge-site URL or bare `md|` record) is one board.
	// Multiple boards render as one carousel page / a text report per board.
	boards, berr := resolve_boards(args.text)
	defer delete(boards)
	if berr != "" {
		fmt.wprintfln(sink.err, "%s: %s", PROGRAM, berr)
		return .Runtime_Error
	}
	if len(boards) == 0 {
		fmt.wprintfln(sink.err, "%s: no deal found in the input", PROGRAM)
		return .Runtime_Error
	}
	multi := len(boards) > 1
	// Constraints name specific seats/cards of ONE board, so they are meaningless across a set.
	if multi && (len(args.constraints) > 0 || len(args.held) > 0) {
		fmt.wprintfln(
			sink.err,
			"%s: --void/--len/--lead condition a specific board, so they need a SINGLE board input",
			PROGRAM,
		)
		return .Runtime_Error
	}

	// --contract applies to every board (empty -> auto-pick per board). Parse it once, fail fast.
	contract: deal_solve.Contract
	has_contract := false
	if args.contract != "" {
		c, c_ok := deal_solve.parse_contract(args.contract)
		if !c_ok {
			fmt.wprintfln(
				sink.err,
				"%s: could not parse --contract %q (expected e.g. 4H, 3NT)",
				PROGRAM,
				args.contract,
			)
			return .Runtime_Error
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
		if werr := write_html(args.html_path, boards[:], args, contract, has_contract, sink); werr != "" {
			fmt.wprintfln(sink.err, "%s: %s", PROGRAM, werr)
			return .Runtime_Error
		}
		fmt.wprintfln(sink.err, "wrote %s (%d board%s)", args.html_path, len(boards), "" if len(boards) == 1 else "s")
		return .Ok
	}

	for board, i in boards {
		if i > 0 {
			fmt.wprintfln(sink.out, "\n%s", strings.repeat("=", 74, context.temp_allocator))
		}
		if multi {
			fmt.wprintfln(sink.out, "Board %d of %d\n", i + 1, len(boards))
		}
		report_board(sink, board, args, contract, has_contract)
	}
	return .Ok
}
