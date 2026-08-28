package main

/*
	mem_check — where the workbench's memory actually goes.

	  just mem-check                 # the whole curve: 6, 12, 24, 48 boards, then the notes
	  just mem-check 48              # one board count
	  just mem-check 48 -keep        # keep each document loaded instead of replacing it

	WHY THIS EXISTS. A workbench session with a 48-deal card page and the notes preview open sits at ~990MB
	working set, against ~120MB for a freshly opened window (both measured with `Get-Process`). Neither
	number says WHAT is holding it: our own data is small (a 48-deal page is ~260KB of html, and `sim.exe`
	generating the same 48 deals peaks at 89MB), so the growth is on the engine's side of the boundary and
	could be the DOM, the script heap, the graphics layer, or nothing being released when a document is
	replaced. Guessing which is how a performance session goes wrong.

	So this walks the same path the application walks - generate a page, load it into an engine view, render
	the notes - and prints the process's working set at each step, with the deltas. Every number is one call
	to `GetProcessMemoryInfo`, the same counter Task Manager's "Memory" column reports, so it is comparable
	with what a person sees when they wonder why the app is big.

	WHAT IT CANNOT SEE, and this matters: a WINDOWLESS view paints into a pixel buffer, so the GPU backend
	(DX12/Vulkan by default in a real window) is not in these numbers. Whatever the graphics layer commits
	is the difference between this program's total and the real window's, and that subtraction is the point
	of measuring here rather than only in the window.

	A PROGRAM RATHER THAN A TEST, for the same measured reason as `page_check`: loading the card page into
	the engine from an Odin test-runner thread crashes inside the engine, while the identical calls on a
	main thread are fine.
*/

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import "bidding"
import dds "dds:."
import "deal_solve"
import bml "markup:."
import "norn:cli"
import "norn:combo"
import "perf"
import "preview"
import sa "sciter:sciter_app"
import "sim_hooks"
import "suit_book"

main :: proc() {
	// The curve, not one number: per-board cost is the thing a total cannot tell you.
	all_counts := [?]int{6, 12, 24, 48}
	counts := all_counts[:]
	keep := false
	one_count := 0
	// `-dds-mb N` sizes DDS's transposition tables instead of letting it pick from the core count. The
	// default is the measurement everybody starts from: 172MB on a 24-core machine, allocated by
	// `SetMaxThreads(0)` and held until shutdown.
	dds_mb := 0
	for arg in os.args[1:] {
		switch arg {
		case "-keep":
			keep = true
		case "-dds-mb":
			dds_mb = -1 // the next argument is the value
		case:
			if dds_mb == -1 {
				n, ok := strconv.parse_int(arg)
				if !ok || n <= 0 {
					fmt.eprintfln("mem_check: -dds-mb wants a positive number, got %q", arg)
					os.exit(2)
				}
				dds_mb = n
				continue
			}
			if n, ok := strconv.parse_int(arg); ok && n > 0 {
				one_count = n
			} else {
				fmt.eprintfln("mem_check: unknown argument %q", arg)
				os.exit(2)
			}
		}
	}
	if one_count > 0 {
		counts = []int{one_count}
	}

	report: perf.Report
	perf.report_begin(&report, "stage")

	// The book the card page's combo tips are baked against - what the workbench and `sim.exe` both install.
	combo.set_suit_book(suit_book.provider())
	defer combo.shutdown()
	perf.mark(&report, "suit book installed")

	// DDS is the obvious suspect and the cheapest to rule in or out: `SetMaxThreads(0)` sizes a
	// transposition table per thread from the core count, and nothing frees it until `shutdown`.
	if dds_mb > 0 {
		dds.SetResources(i32(dds_mb))
		perf.mark(&report, fmt.tprintf("DDS tables capped at %d MB", dds_mb))
	} else {
		deal_solve.init()
		perf.mark(&report, "deal_solve.init (DDS tables, uncapped)")
	}

	if !sa.load_engine() {
		fmt.eprintln("mem_check: the Sciter engine is not loadable - set SCITER_LIB")
		os.exit(1)
	}
	perf.mark(&report, "sciter engine loaded")

	view, verr := sa.create_windowless({width = 1120, height = 780})
	if verr != nil {
		fmt.eprintln("mem_check: could not create a windowless view:", verr)
		os.exit(1)
	}
	// The same media var the workbench sets, so the card page takes its desktop branch here too.
	{
		on := sa.value_from(true)
		defer sa.value_clear(&on)
		vars: sa.Value
		defer sa.value_clear(&vars)
		sa.value_set(&vars, "sciter", &on)
		_ = sa.set_media_vars(view.window, &vars)
	}
	pump(&view)
	perf.mark(&report, "windowless view created")

	scratch := os.get_env("TEMP", context.allocator)
	if scratch == "" {
		scratch = "."
	}

	for count in counts {
		page, page_ok := generate_card_page(scratch, count)
		if !page_ok {
			os.exit(1)
		}
		perf.mark(&report, fmt.tprintf("%d-board page generated (%d KB)", count, len(page) / 1024))

		if sa.load_html(view.window, page, "file://mem-check/cards.html") != nil {
			fmt.eprintln("mem_check: the engine refused the page")
			os.exit(1)
		}
		pump(&view)
		delete(page)
		perf.mark(&report, fmt.tprintf("%d-board page LOADED", count))

		if !keep {
			// Replacing the document is the question everyone asks about a long session: does the engine
			// give it back? A blank document between the counts makes each row a steady state rather than
			// a running total, and the row after the last one answers the release question directly.
			_ = sa.load_html(view.window, "<html><body>blank</body></html>", "file://mem-check/blank.html")
			pump(&view)
			perf.mark(&report, "  ... replaced with a blank page")
		}
	}

	// The other half of the reported session: the notes, rendered in process and loaded as a second
	// document. Same engine, a much bigger DOM of much simpler elements.
	// One CHAPTER and then the whole assembled document. The editor previews whatever is open, so both are
	// real cases, and they are very different documents: thirteen chapters of prose against one.
	for name in ([]string{"nt-bidding.bml", "bidding-system.bml"}) {
		html, rendered := render_notes(name)
		if !rendered {
			continue
		}
		perf.mark(&report, fmt.tprintf("%s rendered (%d KB)", name, len(html) / 1024))

		// FOLDED - what the workbench's preview loads now: every heading, one section open, the other bodies
		// replaced by an ellipsis. The outline is what makes it usable; the ellipses are what make it cheap.
		sections_all := preview.section_count(html)
		folded := preview.fold_document(html, sections_all / 2, allocator = context.temp_allocator)
		if sa.load_html(view.window, folded, "file://mem-check/notes.html") == nil {
			pump(&view)
			perf.mark(
				&report,
				fmt.tprintf(
					"  ... FOLDED, section %d of %d open (%d KB)",
					sections_all / 2 + 1,
					sections_all,
					len(folded) / 1024,
				),
			)
		}
		_ = sa.load_html(view.window, "<html><body>blank</body></html>", "file://mem-check/blank.html")
		pump(&view)

		// The same page CUT DOWN to one section, which the preview used before folding replaced it. Kept as
		// the comparison: a slice is cheaper and tells you nothing about where you are.
		// A MIDDLE section rather than the first: the first section of a document is its title and a
		// paragraph, and quoting that as the saving would flatter the lever.
		sections := preview.section_count(html)
		one := preview.slice_sections(html, sections / 2, 0, context.temp_allocator)
		if sa.load_html(view.window, one, "file://mem-check/notes.html") == nil {
			pump(&view)
			perf.mark(
				&report,
				fmt.tprintf("  ... section %d of %d (%d KB)", sections / 2 + 1, sections, len(one) / 1024),
			)
		}
		// The WORST case as well as the typical one: the biggest single section in the document.
		biggest, biggest_at := 0, 0
		for i in 0 ..< sections {
			if size := len(preview.slice_sections(html, i, 0, context.temp_allocator)); size > biggest {
				biggest, biggest_at = size, i
			}
		}
		fmt.printfln("      (%s: %d sections, biggest is section %d)", name, sections, biggest_at + 1)
		worst := preview.slice_sections(html, biggest_at, 0, context.temp_allocator)
		if sa.load_html(view.window, worst, "file://mem-check/notes.html") == nil {
			pump(&view)
			perf.mark(&report, fmt.tprintf("  ... its BIGGEST section (%d KB)", len(worst) / 1024))
		}
		_ = sa.load_html(view.window, "<html><body>blank</body></html>", "file://mem-check/blank.html")
		pump(&view)

		if sa.load_html(view.window, html, "file://mem-check/notes.html") == nil {
			pump(&view)
			perf.mark(&report, fmt.tprintf("  ... %s LOADED", name))
			// The same document a second time. A steady state means the engine reuses what it has; growth
			// means something is kept per load, which is what a long editing session would compound.
			if sa.load_html(view.window, html, "file://mem-check/notes.html") == nil {
				pump(&view)
				perf.mark(&report, "  ... the SAME page loaded again")
			}
		}
		delete(html)
		if !keep {
			_ = sa.load_html(view.window, "<html><body>blank</body></html>", "file://mem-check/blank.html")
			pump(&view)
			perf.mark(&report, "  ... replaced with a blank page")
		}
	}

	deal_solve.shutdown()
	perf.mark(&report, "deal_solve.shutdown (DDS freed)")

	perf.report_end(&report)
	fmt.println(
		"note: a windowless view paints to a pixel buffer, so the GPU backend a real window uses is NOT in these numbers",
	)
}

// A scenario page the size the report is about, through the same `cli.run` the workbench's generate button
// uses (including the double-dummy hooks, which is what the published pages carry).
generate_card_page :: proc(dir: string, count: int) -> (page: string, ok: bool) {
	path, jerr := filepath.join({dir, fmt.tprintf("mem-check-%d.html", count)}, context.allocator)
	if jerr != nil {
		fmt.eprintln("mem_check: could not compose an output path")
		return "", false
	}
	defer delete(path)

	argv := []string {
		"-S",
		"2c-opener",
		"-n",
		fmt.tprintf("%d", count),
		"-f",
		"html-cards",
		"--dd",
		"--fixed-table",
		"--seed",
		"7",
		"-o",
		path,
	}
	opts, parsed, message := cli.parse_args(argv)
	if !parsed {
		fmt.eprintln("mem_check:", message)
		return "", false
	}
	hooks := sim_hooks.make_hooks()
	defer sim_hooks.free_hooks(&hooks)
	gen := sim_hooks.gen_hooks(&hooks)
	opts.dd_filters = gen.dd_filters
	opts.dd_annotators = gen.dd_annotators
	if run_ok, run_message := cli.run(bidding.registry, opts); !run_ok {
		fmt.eprintln("mem_check:", run_message)
		return "", false
	}

	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("mem_check: could not read back %s: %v", path, rerr)
		return "", false
	}
	os.remove(path)
	return string(data), true
}

// `bidding-system.bml` rendered the way the editor's preview renders it: in process, from source text.
render_notes :: proc(file: string) -> (html: string, ok: bool) {
	dir := notes_dir()
	if dir == "" {
		fmt.println("(no .bml corpus found - skipping the notes half)")
		return "", false
	}
	path, _ := filepath.join({dir, file}, context.temp_allocator)
	source, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		fmt.printfln("(could not read %s: %v)", path, rerr)
		return "", false
	}
	g_notes_dir = dir
	doc := bml.parse(string(source), {resolve_include = notes_include})
	defer bml.destroy(doc)
	return bml.render_html(doc), true
}

g_notes_dir: string

notes_include :: proc(name: string, user: rawptr, allocator := context.allocator) -> (text: string, ok: bool) {
	path, jerr := filepath.join({g_notes_dir, name}, context.temp_allocator)
	if jerr != nil {
		return "", false
	}
	data, rerr := os.read_entire_file_from_path(path, allocator)
	return string(data), rerr == nil
}

// The corpus is two directories above this one when run from `odin-sims`; walk up rather than assume, the
// way the workbench does.
notes_dir :: proc() -> string {
	dir := os.get_env("BML_DOCS_DIRECTORY", context.temp_allocator)
	if dir != "" {
		return dir
	}
	here, aerr := filepath.abs(".", context.temp_allocator)
	if aerr != nil {
		return ""
	}
	for _ in 0 ..< 8 {
		probe, jerr := filepath.join({here, "bidding-system.bml"}, context.temp_allocator)
		if jerr == nil && os.exists(probe) {
			return here
		}
		parent := filepath.dir(here)
		if parent == here {
			break
		}
		here = parent
	}
	return ""
}

// Layout, style resolution and the script that runs on load. Eight frames is what the workbench's own tests
// settled on for a document to be fully up.
pump :: proc(view: ^sa.Windowless_View) {
	for i in 0 ..< 8 {
		sa.windowless_heartbeat(view, time.Duration(i) * 16 * time.Millisecond)
		sa.paint_windowless(view)
	}
}
