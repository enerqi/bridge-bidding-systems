# `cmd.exe` starts in ~9ms and is always available. just launches a shell per recipe line.
#  - alternatives: `nu -c` ~41ms, `powershell -NoLogo -NoProfile -Command` ~143ms
#  - cost: poor language for a multi-line recipe, hence `[script]` -> python for anything with logic
set windows-shell := ["cmd.exe", "/c"]
set shell := ["bash", "-c"]
set unstable  # [script] feature - https://github.com/casey/just/issues/1479
set lazy

# `python` alone is not a reliable cross-platform lookup (cf. python/python3/python3.x).
# uv resolves/downloads on every platform; --no-project means no pyproject.toml / local .venv lookup.
# Recipes opt in with the bare `[script]` attribute (no interpreter argument).
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]

# Newest just feature used below is user-defined functions (1.49), for `target_path`. Older ones it
# also needs: `[group]` 1.27, `join()` 1.37, f-strings 1.44, `set lazy` 1.47. Without this an old just
# reports a plain syntax error, which reads like a corrupt justfile rather than an out-of-date tool.
set minimum-version := "1.49.0"

# `home_directory()` hands back a NATIVE path -- `C:\Users\Enerqi` on Windows -- and every sibling-checkout
# variable below wants forward slashes, so the normalisation happens ONCE here instead of at each use.
#
# Neither of just's path helpers does this job, measured rather than assumed:
#
#     home_directory()                      C:\Users\Enerqi
#     replace(home_directory(), "\\", "/")  C:/Users/Enerqi          <- this
#     home_directory() / "dev/norn"         C:\Users\Enerqi/dev/norn   (mixed: `/` only joins)
#     join(home_directory(), "dev", "norn") C:\Users\Enerqi\dev\norn   (all native, by design)
#
# The `/` operator inserts a forward slash BETWEEN components and leaves the left operand alone, and
# `join` deliberately emits the NATIVE separator -- which is why `target_path` below uses it. Forward
# slashes matter twice here: Odin's `-collection:` wants them, and these paths are written verbatim into
# the generated ols.json, where a `\` would be an invalid JSON string escape.
home := replace(home_directory(), "\\", "/")

# This project is a CONSUMER of the norn library: norn provides the hand-generation engine (`norn:norn`)
# and the reusable scenario CLI framework (`norn:cli`); everything here (`bidding` + `sim.odin`) is this
# specific bidding system.
#
# `norn_home` is the single source of truth for where the norn checkout lives: NORN_HOME if set, else
# `<home>/dev/norn`. It feeds BOTH the `-collection` build flag AND the generated ols.json (see
# `ols-config`) -- ols.json has no env-var expansion of its own, so it is regenerated from this rather
# than hand-edited.
norn_home := env_var_or_default("NORN_HOME", home / "dev/norn")
norn := "-collection:norn=" + norn_home

# odin-dds provides the DDS double-dummy solver bindings, used only by the local `deal_solve` package
# (the norn->DDS boundary). DDS_HOME mirrors norn_home. Its lib/dds.lib (Windows) / lib/dds.a (Unix)
# must be built first -- see odin-dds `just build-lib`.
dds_home := env_var_or_default("DDS_HOME", home / "dev/odin-dds")
dds := "-collection:dds=" + dds_home

# odin-sciter provides the Sciter.JS bindings the desktop workbench renders its UI with. SCITER_HOME
# mirrors norn_home. Unlike norn and dds this is a RUNTIME dependency as well as a build one: Sciter is
# dynamic-link-only, so the engine library has to be findable when the exe starts -- hence the exported
# SCITER_LIB below, naming the directory holding it in that checkout, so nothing has to be copied beside
# the exe.
sciter_home := env_var_or_default("SCITER_HOME", home / "dev/odin-sciter")
sciter := "-collection:sciter=" + sciter_home
# `export` so every recipe's environment carries it -- `sciter_app.load_engine` reads SCITER_LIB, and an
# inline `VAR=x cmd` prefix is not valid in cmd.exe (the Windows shell these recipes run in).
export SCITER_LIB := sciter_home + (if os() == "windows" { "/lib/windows/x64" } else if os() == "macos" { "/lib/macosx" } else { "/lib/linux/x64" })

sim_name := "sim.exe"
analyse_name := "analyse_deal.exe"
workbench_name := "workbench.exe"
test_main_name := "test-bidding.exe"

# `join`, not the `/` operator: `/` always emits a forward slash, and cmd.exe rejects a forward-slash
# path in *command* position ("'target' is not recognized") even quoted. Odin takes either in `-out:`,
# but `sim-norebuild` invokes the binary directly, so it needs the native separator `join` gives.
target_path(dir, name) := join("target", dir, name)

# Which linker Odin hands the object files to. `-linker:` takes `default` (Odin picks - MSVC `link.exe`
# on Windows), `lld`, `radlink` (Windows only, bundled with Odin) and `mold` (Linux only, not bundled).
# Odin has no build cache and relinks every time, and this project links the DDS static library on top
# of its own code, which makes the link the slower half of a rebuild.
#
# Override for one command without editing this file (an env var rather than a recipe argument because
# `odin` errors on a repeated flag, so a `-linker:` in a recipe's *args would collide):
#
#     ODIN_LINKER=lld just sim --scenario 1c-any   # -lto on Windows *requires* -linker:lld
#
# See the odin-lang-skeleton justfile for the full per-value notes.
#
# THIS PROJECT CANNOT USE radlink, hence `default` where the skeleton and norn use radlink. radlink dies
# linking sim.odin with a bare `0xc000001d` (illegal instruction) crash of its own -- "--- Fatal
# Exception --- ... Version: 0.9.24" -- emitting sim.obj and no exe, at EVERY optimization level
# including -debug. Trigger is linking live `core:debug/trace` code (either `register_segfault_handler`
# or assigning `trace.assertion_failure_proc` is enough); norn's own CLI does the same and links fine,
# so the DDS static library appears to be the other half. `default` and `lld` both link it and measured
# identically (~3.9s for a full `-o:speed` build), so pinning `default` -- the incremental one Odin
# would pick anyway -- costs nothing here.
#
# Shared factor with the other radlink casualty in this family: sibling odin-num-format also pins
# `default`, there because radlink LINKS cleanly and the binary dies at startup with the same
# `0xc000001d`. Its Rust staticlib needs `dbghelp.lib`, and `core:debug/trace` is a dbghelp consumer
# too -- so dbghelp-in-the-link + a static non-Odin library is the shape to suspect, not DDS or Rust.
linker := env_var_or_default("ODIN_LINKER", "default")

# Where the batch `gen-all*` / `gen-some` recipes write per-scenario HTML: DEALS_OUTPUT_DIR if set, else
# the w: web-server volume. Also a trailing recipe argument, e.g. `just gen-all 48 ./out/`.
#
# `export`ed because the workbench has no recipe argument to take it from: it pre-fills its output-directory
# field from this variable, so the window opens pointing where `gen-all` would write. Re-exporting the same
# name is a no-op when it was already set in the environment.
export DEALS_OUTPUT_DIR := env_var_or_default("DEALS_OUTPUT_DIR", "w:/deals/")
deals_output_dir := DEALS_OUTPUT_DIR

# Where the single-scenario `gen-one*` recipes write <SCENARIO>.html: the directory just was invoked
# from (NOT this justfile's directory, which just would otherwise chdir to), so a scratch run lands
# where you typed it. `_native` + `replace` because the plain builtin hands back a /c/... path on
# Windows. Overridable per-recipe too, and via DEALS_SCRATCH_DIR.
scratch_dir := env_var_or_default("DEALS_SCRATCH_DIR", replace(invocation_directory_native(), "\\", "/"))

# hand-ocr is a SEPARATE sibling repo (image -> PBN/LIN; uv/Python), at HAND_OCR_DIR. `export` re-exports
# it so the `ocr-analyse` recipe's `ocr_analyse.py` reads the SAME value (just variables are not env
# vars otherwise) -- the path lives in one place across just and Python.
export HAND_OCR_DIR := env_var_or_default("HAND_OCR_DIR", home / "dev/bridge-hand-ocr")


# ============================================================ dev =========

# Every build recipe depends on this, so its cost is a tax on every iteration: one shell command, not
# one per directory, because on Windows the shell launch dwarfs the work. Odin does not create the
# output directory (the linker fails with LNK1104), so this cannot be dropped.
# ---
# ensure the build artifacts directory exists
[group('dev')]
[unix]
@mktarget_dirs:
	mkdir -p target/debug target/fast_debug target/release_debug target/release target/release_nochecks

# `if not exist` rather than swallowing md's "already exists" with `2>nul`, so a genuine failure still
# sets a non-zero exit. The loop variable is a single `%d`, NOT the `%%d` a .bat file would use:
# doubling is escaping for batch *files*, and `cmd /c` takes a command *line*.
# ---
# ensure the build artifacts directory exists
[group('dev')]
[windows]
@mktarget_dirs:
	for %d in (debug fast_debug release_debug release release_nochecks) do @if not exist target\%d md target\%d || exit /b 1

# odinfmt every odin file under this directory or subdirectories
[group('dev')]
format:
	odinfmt -w .

# Lints the local library packages with -no-entry-point plus the single-file programs. `deal_solve`,
# `analyse`, `sim`, `analyse_deal` and the benches pull in `dds` (the DDS boundary); `bidding` and
# `suit_book` do not (`suit_book` is this project's published suit-combination table, plugged into
# `norn:combo`'s book hook). The card-combination ENGINE lives in norn (`norn:combo`) -- lint it there.
# The benches are listed because nothing else type-checks them. `-vet-tabs` is the only compiler-side
# enforcement of .editorconfig's `indent_style = tab`; it is not implied by `-strict-style`.
# ---
# type check + vet + strict style (bidding, suit_book, deal_solve, analyse, sim_hooks, sim.odin, analyse_deal.odin, workbench.odin, benches)
[group('dev')]
lint *args:
	odin check bidding {{norn}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check suit_book {{norn}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check deal_solve {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check analyse {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check sim.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check analyse_deal.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check sim_hooks {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check workbench.odin -file {{norn}} {{dds}} {{sciter}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check bench.odin -file {{norn}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check bench_e2e.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}

# ols.json is machine-specific (absolute paths) and gitignored -- regenerate after cloning or when
# NORN_HOME / DDS_HOME change:  NORN_HOME=/path/to/norn DDS_HOME=/path/to/odin-dds just ols-config
#
# Read before write: ols.json also holds editor settings (checker_path, odin_command, ...) and only the
# collection list is ours to rewrite.
# ---
# (re)generate ols.json so the editor's language server resolves the `norn:` and `dds:` collections
[group('dev')]
[script]
ols-config:
	import json, os, sys

	config = {}
	if os.path.exists("ols.json"):
		with open("ols.json", encoding="utf-8") as f:
			try:
				config = json.load(f)
			except ValueError as err:
				sys.exit("ols.json is not valid JSON - fix or delete it first: " + str(err))
		if not isinstance(config, dict):
			sys.exit("ols.json does not hold a JSON object - fix or delete it first")

	config.setdefault(
		"$schema", "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json"
	)
	config["collections"] = [
		{"name": "norn", "path": r"{{norn_home}}"},
		{"name": "dds", "path": r"{{dds_home}}"},
	]
	with open("ols.json", "w", encoding="utf-8", newline="\n") as f:
		f.write(json.dumps(config, indent=4) + "\n")
	print("wrote ols.json -> norn collection at {{norn_home}}, dds at {{dds_home}}")

# delete build artifacts
[group('dev')]
[unix]
clean:
	rm -rf target
	just mktarget_dirs

# cmd's `rm -rf` is `rmdir /s /q`, guarded by `if exist` because rmdir prints "The system cannot find
# the file specified" and exits non-zero on a missing path, which would fail the recipe on an
# already-clean tree.
# ---
# delete build artifacts
[group('dev')]
[windows]
clean:
	if exist target rmdir /s /q target
	just mktarget_dirs


# ====================================================== workbench =========
#
# The desktop app: the generator and the deal advisor in one window, running IN-PROCESS (no subprocess,
# no temp file). UI in HTML/CSS rendered by Sciter through the odin-sciter bindings.
#
# Sciter is dynamic-link-only, so the engine is a RUNTIME dependency too: the exported `SCITER_LIB` (see
# the variable near the top) points `sciter_app.load_engine` at the library in the odin-sciter checkout,
# so nothing has to be copied beside the exe. If the load fails it prints every path it tried. The bindings also refuse to load an engine
# whose version does not match the headers they were generated from, so a stale checkout says so instead
# of crashing somewhere unrelated.
#
# `ui/*.htm` + `ui/*.css` are `#load`ed INTO the binary, so a built exe needs no asset directory -- but
# they are read at COMPILE time, which means an edit to either needs this recipe again, not just a
# restart.

# run the desktop workbench (release)
[group('workbench')]
workbench *args: mktarget_dirs
	odin run workbench.odin -file {{norn}} {{dds}} {{sciter}} -keep-executable -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", workbench_name) }} -- {{args}}

# `-debug` for a steppable build with the tracking allocator's leak report at exit; also what to run when
# attaching the SDK's `inspector` (the window is created with .ENABLE_DEBUG either way).
# ---
# run the desktop workbench (debug)
[group('workbench')]
workbench-debug *args: mktarget_dirs
	odin run workbench.odin -file {{norn}} {{dds}} {{sciter}} -keep-executable -debug -linker:{{linker}} -out:{{ target_path("debug", workbench_name) }} -- {{args}}

# run the last-built workbench WITHOUT recompiling (Odin has no build cache, so `just workbench` always
# rebuilds). Same env: the engine still has to be findable.
[group('workbench')]
workbench-norebuild *args:
	{{ target_path("release", workbench_name) }} {{args}}


# ============================================================ sim =========
#
# Build tiers for the deal generator. `-keep-executable` leaves the binary in place (odin run deletes it
# by default) so `sim-norebuild` can re-run it -- Odin has no build cache, so a plain `just sim` always
# rebuilds.

# run the deal generator (release). Pass CLI args through, e.g. `just sim --scenario 1c-any -n 12`.
[group('sim')]
sim *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -keep-executable -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", sim_name) }} -- {{args}}

# run the deal generator (release) WITHOUT recompiling. Pass CLI args through, e.g. `just sim-norebuild --scenario 1c-any -n 12`.
[group('sim')]
sim-norebuild *args:
	{{ target_path("release", sim_name) }} {{args}}

# `-debug` implies `-o:none`: fastest to compile, friendliest to step through, and the only profile with
# the tracking allocator on by default (see sim.odin's TRACKING_ALLOCATOR note) - the release profiles
# below deliberately measure without it.
# ---
# run the deal generator (debug build). Pass CLI args through, e.g. `just sim-debug --scenario 1c-any -n 12`.
[group('sim')]
sim-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("debug", sim_name) }} -- {{args}}

# `-o:minimal` is one rung above `-debug`'s `-o:none`: still quick to compile and mostly faithful to
# step through, but fast enough at runtime to make a `--count 48` export bearable.
# ---
# run the deal generator with debug info and light optimizations
[group('sim')]
sim-fast-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -o:minimal -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("fast_debug", sim_name) }} -- {{args}}

# Release codegen with debug info retained: for profiling, and for bugs that only appear under
# optimization (a rejection-sampling generator across a thread pool has room for those). Slowest to
# compile, and the debugger jumps around inlined/reordered code.
# ---
# run the deal generator with full optimizations AND debug info
[group('sim')]
sim-release-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -o:speed -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("release_debug", sim_name) }} -- {{args}}

# `sim` plus every runtime safety check compiled out: `-no-bounds-check` (indexing), `-disable-assert`
# (`assert`) and `-no-type-assert` (union/any assertions). Those checks turn a memory-corrupting bug
# into a clean panic, so a fault here is undefined behaviour rather than a readable message -- benchmark
# against `just sim` before believing it is faster, and keep the checked build in your test matrix.
# ---
# run the deal generator with optimizations and ALL runtime safety checks removed
[group('sim')]
sim-nochecks *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -o:speed -no-bounds-check -disable-assert -no-type-assert -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("release_nochecks", sim_name) }} -- {{args}}

# build the sim deal generator (release)
[group('sim')]
build *args: mktarget_dirs
	odin build sim.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", sim_name) }} {{args}}

# KIND is `address` (default, ASan: out-of-bounds + use-after-free), `memory` (reads of uninitialized
# memory) or `thread` (data races -- the interesting one here, since the generator and the combo
# analyser both pool threads). Only `address` is widely supported; `memory` and `thread` need a
# clang-ish toolchain and are unavailable on some platforms (notably Windows/MSVC).
#
# ON WINDOWS `address` CATCHES STACK ERRORS BUT NOT HEAP ERRORS - Odin allocates through `HeapAlloc`,
# which ASan does not intercept, so a clean run there says nothing about your heap.
#
# `sanitize` and `test-sanitize` deliberately omit `-linker:{{linker}}` -- do not "fix" the
# inconsistency. A sanitizer interposes on the runtime and not every linker cooperates: `radlink` links
# an ASan binary that dies on startup with a bare `0xc000001d` illegal-instruction exception and no
# usable stack, while `-linker:default` runs it. Link speed is worth nothing on a diagnostic run anyway.
# Usage:  just sanitize   or   just sanitize thread --scenario 1c-any --count 8
# ---
# run the deal generator under a sanitizer (address | memory | thread)
[group('sim')]
sanitize kind="address" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{sim_name}}") }} -- {{args}}


# ======================================================== generate =========
#
# Convenience wrappers over `sim` / `sim-norebuild` (these used to live in the repo-root justfile as the
# `*-norn` family; the root reaches them as a just module, e.g. `just sims gen-all 48`).
#
# NAMING: gen-all = every registered scenario, gen-some = a named subset, gen-one = one scenario.
# Suffixes stack in this order: [-cards][-dd] for the format/solver variants, -norebuild to skip the
# compile and reuse the last release build.
#
# BATCH: every scenario -> <DIR>/<scenario>.html, DIR defaulting to deals_output_dir.
# SINGLE: one scenario -> <DIR>/<SCENARIO>.html, DIR defaulting to scratch_dir (where you invoked just).
# -dd adds the per-scenario double-dummy annotate/filter (registered in sim.odin; DD scenarios export
# serially since the solver is not reentrant, the rest still pool). -cards swaps the BBO iframe pages
# for self-rendered offline card carousels (prev/next, seat toggle, par toggle).

# generate ALL scenarios (COUNT deals each) -> DIR/<scenario>.html
[group('generate')]
gen-all COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}}

# generate ALL scenarios WITH double-dummy annotations -> DIR/<scenario>.html
[group('generate')]
gen-all-dd COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --dd

# generate ALL scenarios as offline card carousels -> DIR/<scenario>.html
[group('generate')]
gen-all-cards COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --format html-cards

# generate ALL scenarios as offline card carousels WITH double-dummy par captions
[group('generate')]
gen-all-cards-dd COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --format html-cards --dd

# generate ALL scenarios WITHOUT recompiling (reuses the last release build)
[group('generate')]
gen-all-norebuild COUNT="48" DIR=deals_output_dir:
	just sim-norebuild --html-dir {{DIR}} --count {{COUNT}}

# generate a SUBSET; NAMES is comma-separated, e.g. `just gen-some 1c-any,2c-opener 100`
[group('generate')]
gen-some NAMES COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --scenario {{NAMES}} --count {{COUNT}}

# COUNT deals for ONE scenario -> DIR/<SCENARIO>.html
[group('generate')]
gen-one SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario WITH double-dummy annotations -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-dd SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html --dd

# COUNT deals for ONE scenario as an offline card carousel -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-cards SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario as an offline card carousel with double-dummy par -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-cards-dd SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html --dd

# COUNT deals for ONE scenario WITHOUT recompiling -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-norebuild SCENARIO COUNT="48" DIR=scratch_dir:
	just sim-norebuild --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html

# list the scenarios compiled into the sim
[group('generate')]
scenarios:
	just sim-debug --list


# ========================================================= analyse =========

# Read a deal and print the combo analysis (double-dummy census + achievable single-dummy) for the known
# partnership. The deal may be a PBN [Deal] tag / bare N:... value, a bridge-site hand URL (BBO or
# IntoBridge `...?lin=...`), or a bare LIN `md|...` record. `--sample <deals>` adds the DDS-sampling
# whole-hand make-% verdict; `--contract 4H` is OPTIONAL (best contract auto-picked if omitted);
# `--html <out>` writes the interactive card page (green verdict band + contract picker when sampling).
#
# The DEAL comes FIRST; optional flags follow it. Single-quote the deal so YOUR shell hands it to just
# in one piece -- a LIN URL's `|` pipes, `!` alerts, `%` escapes and bare-PBN spaces all need it.
# e.g. just analyse-deal 'https://play.intobridge.com/hand?lin=...'
# e.g. just analyse-deal 'N:Q865.J983..T7654 J.KT7.AJ8642.K32 AKT73.Q.KQ7.AQJ9 942.A6542.T953.8'
# e.g. just analyse-deal 'N:... - ... -' --sample 400 --contract 3NT --html out.html
#
# `[script]` rather than a shell line, and it BUILDS then RUNS the exe rather than using `odin run`.
# Both halves are about the deal string surviving intact: just's `quote()` emits POSIX quoting that
# cmd.exe does not understand, whereas python's `subprocess` takes an argv list and spawns no shell;
# and `odin run` re-spawns the built exe, whose Windows MSVCRT argument re-parse used to strip the
# literal double quotes out of the `[Deal "..."]` tag form. `--file <path>` / stdin (a .pbn with SEVERAL
# [Deal] tags -> one carousel page, or `hand-ocr ... | analyse_deal`) want the exe directly:
# target/release/analyse_deal.exe --file <path>.
# ---
# single-deal advisor: declarer+dummy (defenders `-`) OR a complete 4-hand deal (exact DD), from PBN / LIN URL -> combo analysis (+ optional --sample verdict / --html card page)
[group('analyse')]
[script]
analyse-deal deal *flags: mktarget_dirs
	import os, subprocess, sys

	exe = os.path.join("target", "release", "{{analyse_name}}")
	build = [
		"odin", "build", "analyse_deal.odin", "-file", r"{{norn}}", r"{{dds}}",
		"-o:speed", "-microarch:native", "-linker:{{linker}}", "-out:" + exe,
	]
	rc = subprocess.run(build).returncode
	if rc != 0:
		raise SystemExit(rc)

	# The deal is a SINGLE argv element, so no shell ever sees its `|`, `!`, `%` or spaces. Triple
	# single quotes because the `[Deal "..."]` form contains double quotes; nothing in PBN, LIN or a
	# hand URL contains an apostrophe.
	argv = [exe] + r'''{{flags}}'''.split() + [r'''{{deal}}''']
	raise SystemExit(subprocess.run(argv).returncode)

# Bridges to the sibling hand-ocr repo (uv) at HAND_OCR_DIR. declarer+dummy uses '-' for the unknown
# hands; a full 4-hand diagram emits all four. A real image needs hand-ocr's vision extra there:
# (cd "$HAND_OCR_DIR" && just sync-vision). <image> may be `--clipboard` to read straight from the OS
# clipboard (screenshot, no temp file).
# e.g. `just ocr-pbn hand.png` ; `just ocr-pbn hand.png --first E` ; `just ocr-pbn --clipboard`
# ---
# OCR a bridge hand-diagram IMAGE to a PBN [Deal] tag, printed to stdout
[group('analyse')]
ocr-pbn image *args:
	uv run --project {{HAND_OCR_DIR}} python {{HAND_OCR_DIR}}/hand-ocr.py {{image}} --format pbn {{args}}

# image -> PBN -> analyse_deal with the DDS-sampling advisor + CCA/DD features. Writes
# <image-basename>.html (override with --html); samples 400 deals (override with --sample). Extra flags
# pass through to analyse_deal (e.g. --contract 3NT). `--demo` runs hand-ocr's sample deal end to end
# (plumbing check, no vision deps needed); <image> may be `--clipboard`.
# e.g. `just ocr-analyse hand.png` ; `just ocr-analyse hand.png --contract 3NT --seed 7`
# ---
# OCR a hand-diagram IMAGE straight to the interactive card page
[group('analyse')]
ocr-analyse image *args: mktarget_dirs
	odin build analyse_deal.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", analyse_name) }}
	uv run --no-project python tools/ocr_analyse.py {{image}} {{args}}

# same as `ocr-analyse`; requires a prior build of analyse_deal.exe
# ---
# OCR a hand-diagram IMAGE straight to the interactive card page without recompiling analyse_deal.exe
[group('analyse')]
ocr-analyse-norebuild image *args:
	uv run --no-project python tools/ocr_analyse.py {{image}} {{args}}


# ============================================================ test =========

# run the bidding-system unit tests
[group('test')]
test *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# Filtering is a `core:testing` define, not a compiler flag - there is no `-test-name:`, and a stale
# spelling of one fails with `Unknown flag: 'test-name'` before anything builds. NAME takes a
# comma-separated list and the package prefix is optional, so `bidding.my_test`, `my_test` and
# `one,two` all work:
#     just test1 my_test
# ---
# run one named bidding-system test (comma-separated for several)
[group('test')]
test1 name *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -define:ODIN_TEST_NAMES={{name}} -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# Covers the baked table itself: every entry round-trips through its own engine key, the card-validity
# gate rejects odds-equivalent-but-wrong-honour hits, and `zz_book_diff` prints the book-vs-engine
# percentage diff. The card-combination ENGINE's own tests live in norn (`just test-combo` there).
# ---
# run the published suit-combination table (suit_book) unit tests + the book-vs-engine diff
[group('test')]
test-suit-book *args: mktarget_dirs
	odin test suit_book {{norn}} -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-suit-book.exe") }} {{args}}

# Forced single-threaded: DDS shares process-global transposition tables and is NOT reentrant, so
# concurrent test procs would corrupt each other's solves.
# ---
# run the double-dummy / DDS-sampling unit tests (links the DDS solver via the dds collection)
[group('test')]
test-deal-solve *args: mktarget_dirs
	odin test deal_solve {{norn}} {{dds}} -debug -microarch:native -define:ODIN_TEST_THREADS=1 -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-deal-solve.exe") }} {{args}}

# The workbench's document, tested in a WINDOWLESS engine view (no desktop needed). Covers the seam
# between the document and the host: every id the host reads exists, the scenario list is a projection of
# the registry, and — the one that matters — the argv its controls compose is accepted by the REAL parsers
# (`cli.parse_args`, `analyse.parse_args`) with the values the controls named. One test also runs a small
# seeded generation, which `wb-cli-parity` then diffs against the same run through sim.exe.
# ---
# run the desktop workbench's document + argv tests (needs the Sciter engine, not a display)
[group('test')]
test-workbench *args: mktarget_dirs
	odin test workbench.odin -file {{norn}} {{dds}} {{sciter}} -debug -define:ODIN_TEST_THREADS=1 -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-workbench.exe") }} {{args}}

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

# The deal READER, the flag surface and the text report — the solver-free half of the advisor. Also
# single-threaded: the package links DDS (its sampling path does), and one test proc reaching a solve
# concurrently with another would corrupt it, same as `test-deal-solve`.
# ---
# run the analyse library's unit tests (input formats, --void/--len/--lead specs, report writer)
[group('test')]
test-analyse *args: mktarget_dirs
	odin test analyse {{norn}} {{dds}} -debug -microarch:native -define:ODIN_TEST_THREADS=1 -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-analyse.exe") }} {{args}}

# Builds analyse_deal, runs it on a fixed board+seed, and diffs the emitted `data-sim='...'` against
# tests/golden/. Guards write_sim_json (incl. the misguess-tax ach/taxpts/pvt rung) from drifting out of
# sync with render.odin's simBand parser.
# ---
# golden test for the card page's data-sim JSON contract
[group('test')]
test-golden: mktarget_dirs
	odin build analyse_deal.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", analyse_name) }}
	uv run --no-project python tests/golden_sim_json.py

# see `sanitize` for the kinds, platform support, the Windows heap caveat and why no linker is pinned.
# ---
# run the bidding-system tests under a sanitizer (address | memory | thread)
[group('test')]
test-sanitize kind="address" *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{test_main_name}}") }} {{args}}


# =========================================================== bench =========

# Frequency test every scenario by default, or `-S name[,name]` to restrict the subset. With --dd the
# rate also counts each scenario's double-dummy filter (filtered scenarios run serially).
# e.g. `just freq` (1M, -all), `just freq 5000000`, `just freq 1000000 -S 1c-any,2c-opener`.
# ---
# measure each scenario's acceptance frequency over N deals (no deals emitted)
[group('bench')]
freq trials="1000000" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", sim_name) }} -- --frequency {{trials}} {{args}}

# Override counts: just bench '-define:COUNT_SUIT=5000' '-define:COUNT_DEAL=500'
# ---
# benchmark the combo package (Phase 1, Phase 2 lines/optimal, annotate end-to-end)
[group('bench')]
bench *args: mktarget_dirs
	odin run bench.odin -file {{norn}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "bench.exe") }} {{args}}

# The compute behind `sim -S slam-makes-dd --count 48 --format html-cards --dd`, minus the file write.
# Links DDS like sim. Knobs via -define:
#   just bench-e2e                                   (slam-makes-dd, count 48, 3 iters)
#   just bench-e2e '-define:E2E_COUNT=24' '-define:E2E_ITERS=5'
#   just bench-e2e '-define:COMBO_THREADS=false'     (time the serial combo path)
# ---
# END-TO-END benchmark of ONE scenario's full pipeline (generate + DD filter + deal_solve/combo annotate + render)
[group('bench')]
bench-e2e *args: mktarget_dirs
	odin run bench_e2e.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "bench-e2e.exe") }} {{args}}
