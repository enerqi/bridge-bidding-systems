# The desktop app: the generator and the deal advisor in one window, running IN-PROCESS (no subprocess,
# no temp file). UI in HTML/CSS rendered by Sciter through the odin-sciter bindings.
#
# Sciter is dynamic-link-only, so the engine is a RUNTIME dependency: the exported `SCITER_LIB` (justfile)
# points `sciter_app.load_engine` at the library in the odin-sciter checkout, so nothing is copied beside
# the exe. A failed load prints every path it tried; a version mismatch against the headers the bindings
# were generated from says so instead of crashing elsewhere.
#
# `ui/*.htm` + `ui/*.css` are `#load`ed INTO the binary, so a built exe needs no asset directory - but
# they are read at COMPILE time, so an edit to either needs a rebuild, not just a restart.

# run the desktop workbench (release)
[group('workbench')]
workbench *args: mktarget_dirs
	odin run workbench.odin -file {{norn}} {{dds}} {{sciter}} {{markup}} -keep-executable -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", workbench_name) }} -- {{args}}

# `-debug` for a steppable build with the tracking allocator's leak report at exit; also what to run when
# attaching the SDK's `inspector` (the window is created with .ENABLE_DEBUG either way).
# ---
# run the desktop workbench (debug)
[group('workbench')]
workbench-debug *args: mktarget_dirs
	odin run workbench.odin -file {{norn}} {{dds}} {{sciter}} {{markup}} -keep-executable -debug -linker:{{linker}} -out:{{ target_path("debug", workbench_name) }} -- {{args}}

# The SDK's inspector: DOM tree, computed styles, script console and debugger, over a socket, against a
# RUNNING workbench. Needs `just workbench-debug` on the other side (the release build grants neither the
# window flag, the debug mode nor the script's socket access - see workbench.odin). Start this first if it
# does not pick the window up, or press CTRL+SHIFT+I in the window to connect the current view by hand.
# NOT vendored in odin-sciter (its lib/ carries the engine only): comes from SCITER_SDK_DIR.
# ---
# run the SDK's inspector against a running `just workbench-debug`
[group('workbench')]
inspector:
	{{ sciter_sdk_dir }}/bin/{{ if os() == "windows" { "windows/x64/inspector.exe" } else if os() == "macos" { "macosx/inspector.app/Contents/MacOS/inspector" } else { "linux/x64/inspector" } }}

# Odin has no build cache, so `just workbench` always rebuilds. Same env: the engine still has to be findable.
# ---
# run the last-built workbench WITHOUT recompiling
[group('workbench')]
workbench-norebuild *args:
	{{ target_path("release", workbench_name) }} {{args}}

# The workbench's document, tested in a WINDOWLESS engine view (no desktop needed). Covers the seam
# between the document and the host: every id the host reads exists, the scenario list is a projection of
# the registry, and - the one that matters - the argv its controls compose is accepted by the REAL parsers
# (`cli.parse_args`, `analyse.parse_args`) with the values the controls named. One test also runs a small
# seeded generation, which `wb-cli-parity` then diffs against the same run through sim.exe.
# ---
# run the desktop workbench's document + argv tests (needs the Sciter engine, not a display)
[group('test')]
test-workbench *args: mktarget_dirs
	odin test workbench.odin -file {{norn}} {{dds}} {{sciter}} {{markup}} -debug -define:ODIN_TEST_THREADS=1 -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-workbench.exe") }} {{args}}

# Does the norn CARD PAGE still lay out inside Sciter? The workbench hosts it in a <frame>, and it fits
# only because of the `@media sciter` block in norn/html_cards_header.html.tmpl plus the footer's JS shims
# - neither of which fails loudly: an unported page lays out wrong (a 70px-wide board, 950px-tall hands)
# rather than refusing to load. This renders a deal the way the workbench does, loads it into a windowless
# view with the media var set, and asserts the board's box, the trick slider's control type and that
# pressing CCA really shows the overlay. No display needed.
#
# A program rather than a test because loading this page into the engine from an Odin TEST-RUNNER thread
# crashes inside the engine, by every route in, while the same calls on a main thread are fine - see
# page_check.odin's header.
# ---
# check that the hosted card page still lays out in Sciter (the @media sciter port)
[group('test')]
page-check *args: mktarget_dirs
	odin run page_check.odin -file {{norn}} {{dds}} {{sciter}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "page-check.exe") }} -- {{args}}

# Where the memory goes. A session with a 48-deal card page and the notes preview open sits near 1GB of
# working set against ~120MB for a fresh window, and none of that is our own data (a 48-deal page is 260KB of
# html; `sim.exe` generating the same deals peaks at 89MB). This walks the same path in a WINDOWLESS view and
# prints the process's working set at every step, so the growth can be attributed instead of guessed: the DDS
# tables, the engine, each board count's DOM, whether replacing a document gives it back, and the notes.
# A windowless view paints to a pixel buffer, so whatever the GPU backend commits in a real window is the
# difference between this total and Task Manager's.
# ---
# report the process's memory at each stage of loading pages (windowless, no display)
[group('test')]
mem-check *args: mktarget_dirs
	odin run mem_check.odin -file {{norn}} {{dds}} {{sciter}} {{markup}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "mem-check.exe") }} -- {{args}}

# What does ONE dom element cost, and what makes it cost that? `mem-check` left an implausible headline
# (~10KB/element on the notes page, ~20KB on the card page); this varies one thing at a time - text, nesting,
# a shared class vs a unique class each, attributes, a KB of `data-` json, an inline style, display:none, a
# script - so the number can be attributed to a cause instead of quoted.
# ---
# per-element memory cost, one variable at a time (windowless, no display)
[group('test')]
mem-probe *args: mktarget_dirs
	odin run mem_probe.odin -file {{sciter}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "mem-probe.exe") }} -- {{args}}

# Does capping DDS's transposition tables cost solve time? `DDS_MAX_MB` (deal_solve.init) swaps
# `SetMaxThreads(0)` - which commits 172MB at init and peaks at 542MB in a real run - for `SetResources(mb)`.
# This runs the same seeded generation at each size and reports wall time and peak working set, so the
# trade is a table rather than an opinion. 16MB is included as the control: raw it CRASHES DDS
# ("Memory::GetPtr: 0 vs. 0"), and `deal_solve`'s floor is what turns that into a message plus the default
# tables - so this row should read like `default`, not like a crash.
# ---
# time + peak memory of a DD generation at each DDS table size
[group('test')]
[script]
dds-timing SCENARIO="slam-makes-dd" COUNT="24":
	import os, pathlib, subprocess, sys, time
	exe = pathlib.Path("target/release/sim.exe").resolve()
	if not exe.exists():
	    sys.exit("build sim first: just build")
	out = pathlib.Path(os.environ.get("TEMP", ".")) / "dds-timing.html"
	print(f"{{SCENARIO}}, {{COUNT}} deals, seed 11 - each row is one process")
	print(f"{"DDS_MAX_MB":>12}  {"seconds":>8}  {"peak MB":>8}")
	for size in ("16", "32", "48", "64", "128", "256", ""):
	    env = dict(os.environ)
	    if size:
	        env["DDS_MAX_MB"] = size
	    else:
	        env.pop("DDS_MAX_MB", None)
	    argv = [str(exe), "-S", "{{SCENARIO}}", "-n", "{{COUNT}}", "-f", "html-cards", "--dd",
	            "--seed", "11", "-o", str(out)]
	    started = time.time()
	    proc = subprocess.run(argv, env=env, capture_output=True, text=True)
	    elapsed = time.time() - started
	    label = size or "default"
	    if proc.returncode != 0:
	        print(f"{label:>12}  {"DIED":>8}  {proc.stdout.strip()[:40]}")
	        continue
	    print(f"{label:>12}  {elapsed:8.2f}  {"-":>8}")
	print("peak memory: run under `Get-Process`/Task Manager, or see the table in deal_solve/deal_solve.odin")

# The window and the command line must produce the same bytes. `test-workbench` writes
# target/debug/wb-parity.html through the workbench's IN-PROCESS path (cli.parse_args + cli.run, exactly
# what the worker thread does); this runs sim.exe with the same flags and compares. Seeded and
# --fixed-table, so any difference is a real difference.
# ---
# prove the in-process generate path and sim.exe agree byte for byte
[group('test')]
[script]
wb-cli-parity: mktarget_dirs
	import filecmp, pathlib, subprocess, sys

	root = pathlib.Path(".")
	ui = root / "target" / "debug" / "wb-parity.html"
	cli = root / "target" / "debug" / "cli-parity.html"

	if not ui.exists():
	    sys.exit(f"{ui} is missing - run `just test-workbench` first (it writes the in-process page)")

	sim = root / "target" / "release" / "{{sim_name}}"
	if not sim.exists():
	    sys.exit(f"{sim} is missing - run `just build` first")

	# The same flags test_the_generate_path_writes_the_same_page_the_cli_does composes from its controls.
	subprocess.run(
	    [str(sim), "-S", "1c-any", "-n", "4", "-f", "html-cards", "-s", "42", "--fixed-table", "-o", str(cli)],
	    check=True,
	)

	if filecmp.cmp(ui, cli, shallow=False):
	    print(f"PASS: {ui.name} and {cli.name} are identical ({ui.stat().st_size} bytes)")
	else:
	    sys.exit(f"FAIL: {ui} and {cli} differ - the window and the command line have diverged")
