# `cmd.exe` starts in ~9ms and is always available. just launches a shell per recipe line.
#  - alternatives: `nu -c` ~41ms, `powershell -NoLogo -NoProfile -Command` ~143ms
#  - cost: poor language for a multi-line recipe, hence `[script]` -> python for anything with logic
[windows]
set shell := ["cmd.exe", "/c"]
[unix]
set shell := ["bash", "-c"]
set minimum-version := "1.49.0"  # user-defined functions (1.49); also [group] 1.27, join() 1.37, f-strings 1.44, set lazy 1.47
set unstable  # user-defined functions, [script]
set lazy
# `python` alone is not a reliable cross-platform lookup (cf. python/python3/python3.x)
# uv resolves/downloads on every platform and --no-project means no pyproject.toml / local .venv lookup
# just recipes opt in with the bare `[script]` attribute (no interpreter argument)
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]

import '.just/toolchain.just'
import '.just/editor.just'
import '.just/generate.just'
import '.just/analyse.just'
import '.just/markup.just'
import '.just/workbench.just'
import '.just/bench.just'

# `home_directory()` hands back a NATIVE path (`C:\Users\Enerqi`) and every sibling-checkout variable
# below wants forward slashes, so the normalisation happens ONCE here. Neither of just's path helpers
# does this job: `/` only joins (leaving the left operand native) and `join` emits native separators by
# design. Forward slashes matter twice: Odin's `-collection:` wants them, and these paths are written
# verbatim into the generated ols.json, where `\` would be an invalid JSON string escape.
home := replace(home_directory(), "\\", "/")

# This project is a CONSUMER of the norn library: norn provides the hand-generation engine (`norn:norn`)
# and the scenario CLI framework (`norn:cli`); everything here is this specific bidding system.
# `norn_home` feeds BOTH the `-collection` flag AND the generated ols.json (`just ols-config`) - ols.json
# has no env-var expansion of its own.
norn_home := env_var_or_default("NORN_HOME", home / "dev/norn")
norn := "-collection:norn=" + norn_home

# The DDS double-dummy solver bindings, used only by the local `deal_solve` package. Its lib/dds.lib
# (Windows) / lib/dds.a (Unix) must be built first - see odin-dds `just build-lib`.
dds_home := env_var_or_default("DDS_HOME", home / "dev/odin-dds")
dds := "-collection:dds=" + dds_home

# The Sciter.JS bindings the desktop workbench renders its UI with. Unlike norn and dds this is a RUNTIME
# dependency too: Sciter is dynamic-link-only, so the engine library has to be findable when the exe
# starts - hence the exported SCITER_LIB below, so nothing has to be copied beside the exe.
sciter_home := env_var_or_default("SCITER_HOME", home / "dev/odin-sciter")
sciter := "-collection:sciter=" + sciter_home
# `export` so every recipe's environment carries it - `sciter_app.load_engine` reads SCITER_LIB, and an
# inline `VAR=x cmd` prefix is not valid in cmd.exe.
export SCITER_LIB := sciter_home + (if os() == "windows" { "/lib/windows/x64" } else if os() == "macos" { "/lib/macosx" } else { "/lib/linux/x64" })

# bridge-markup is the Odin implementation of BML, used by the workbench's BML editor: it parses SOURCE
# TEXT (the reference python renders a FILE, so a live preview of an unsaved buffer has nothing to hand
# it) and keeps no module-level state. Build-time only - a static library.
markup_home := env_var_or_default("MARKUP_HOME", home / "dev/bridge-markup")
markup := "-collection:markup=" + markup_home

# Only the `inspector` recipe needs this: odin-sciter vendors the ENGINE but not the SDK's tools.
sciter_sdk_dir := env_var_or_default("SCITER_SDK_DIR", home / "dev/sciter-js-sdk")

sim_name := "sim.exe"
analyse_name := "analyse_deal.exe"
workbench_name := "workbench.exe"
bml2html_name := "bml2html.exe"
test_main_name := "test-bidding.exe"

# `join`, not the `/` operator: `/` always emits a forward slash, and cmd.exe rejects a forward-slash
# path in *command* position ("'target' is not recognized") even quoted. Odin takes either in `-out:`,
# but `sim-norebuild` invokes the binary directly, so it needs the native separator `join` gives.
target_path(dir, name) := join("target", dir, name)

# Which linker Odin hands the object files to: `default` (Odin picks - MSVC `link.exe` on Windows),
# `lld`, `radlink` (Windows only, bundled) or `mold` (Linux only). Odin has no build cache and relinks
# every time, and this project links the DDS static library on top, which makes the link the slower half.
# An env var rather than a recipe argument because `odin` errors on a repeated flag, so a `-linker:` in a
# recipe's *args would collide:  ODIN_LINKER=lld just sim --scenario 1c-any   (-lto needs lld on Windows)
#
# THIS PROJECT CANNOT USE radlink, hence `default` where the skeleton and norn use radlink. radlink dies
# linking sim.odin with a bare `0xc000001d` (illegal instruction) crash of its own - "Version: 0.9.24" -
# emitting sim.obj and no exe, at EVERY optimization level including -debug. Trigger is linking live
# `core:debug/trace` code; norn's own CLI does the same and links fine, so the DDS static library appears
# to be the other half. `default` and `lld` measured identically (~3.9s full `-o:speed`). Shared factor
# with the other radlink casualty in this family: sibling odin-num-format also pins `default`, there
# because radlink LINKS cleanly and the binary dies at startup the same way - its Rust staticlib needs
# `dbghelp.lib`, and `core:debug/trace` is a dbghelp consumer too, so dbghelp-in-the-link + a static
# non-Odin library is the shape to suspect, not DDS or Rust.
linker := env_var_or_default("ODIN_LINKER", "default")

# Where the batch `gen-all*` / `gen-some` recipes write per-scenario HTML; also a trailing recipe
# argument, e.g. `just gen-all 48 ./out/`. `export`ed because the workbench has no recipe argument to
# take it from: it pre-fills its output-directory field from this variable.
export DEALS_OUTPUT_DIR := env_var_or_default("DEALS_OUTPUT_DIR", "w:/deals/")
deals_output_dir := DEALS_OUTPUT_DIR

# Where the single-scenario `gen-one*` recipes write <SCENARIO>.html: the directory just was invoked from
# (NOT this justfile's directory), so a scratch run lands where you typed it. `_native` + `replace`
# because the plain builtin hands back a /c/... path on Windows.
scratch_dir := env_var_or_default("DEALS_SCRATCH_DIR", replace(invocation_directory_native(), "\\", "/"))

# DDS's transposition tables, capped. Left to itself (`SetMaxThreads(0)`) DDS sizes them from the core
# count: measured on 24 cores that is 172MB at init and a 542MB PEAK during a real `--dd` run, held for the
# life of the process - which is most of why a workbench session that has generated anything sits near 1GB.
# `deal_solve.init` reads this and calls `SetResources` instead. The curve (`just dds-timing`, 24 deals of
# slam-makes-dd): 256MB is 4-6% slower than uncapped at 85MB peak, 128MB the same speed at 72MB, 48-64MB
# ~20% slower, 32MB *slower and* smaller, and 16MB kills the solver outright - hence deal_solve's 32MB floor.
# 256 is the deliberate choice here: the memory that matters is the several hundred MB, and this keeps the
# solve time indistinguishable from uncapped. Set the variable in the environment to override, including
# to nothing to get DDS's own sizing back.
export DDS_MAX_MB := env_var_or_default("DDS_MAX_MB", "256")

# hand-ocr is a SEPARATE sibling repo (image -> PBN/LIN; uv/Python). `export` re-exports it so the
# `ocr-analyse` recipe's `ocr_analyse.py` reads the SAME value - one place across just and Python.
export HAND_OCR_DIR := env_var_or_default("HAND_OCR_DIR", home / "dev/bridge-hand-ocr")


# ============================================================= qa =========

# `{{odinfmt_bin}}`, never a bare `odinfmt` - pins the binary (see .just/toolchain.just) for consistency.
# ---
# odinfmt every odin file under this directory or subdirectories
[group('qa')]
format: ensure-odinfmt
	"{{odinfmt_bin}}" -w .

# Lints the local library packages with -no-entry-point plus the single-file programs. `deal_solve`,
# `analyse`, `sim`, `analyse_deal` and the benches pull in `dds` (the DDS boundary); `bidding` and
# `suit_book` do not. The card-combination ENGINE lives in norn (`norn:combo`) - lint it there. The
# benches are listed because nothing else type-checks them. `-vet-tabs` is the only compiler-side
# enforcement of .editorconfig's `indent_style = tab`; it is not implied by `-strict-style`.
# ---
# type check + vet + strict style (every local package and single-file program)
[group('qa')]
lint *args:
	odin check bidding {{norn}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check suit_book {{norn}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check outline -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check deal_solve {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check analyse {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check sim.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check analyse_deal.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check sim_hooks {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check workbench.odin -file {{norn}} {{dds}} {{sciter}} {{markup}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check page_check.odin -file {{norn}} {{dds}} {{sciter}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check bml2html.odin -file {{markup}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check bench.odin -file {{norn}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check bench_e2e.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}


# =================================================== housekeeping =========

# Every build recipe depends on this, so its cost is a tax on every iteration: one shell command, not one
# per directory, because on Windows the shell launch dwarfs the work. Odin does not create the output
# directory (the linker fails with LNK1104), so this cannot be dropped.
# ---
# ensure the build artifacts directory exists
[group('housekeeping')]
[unix]
@mktarget_dirs:
	mkdir -p target/debug target/fast_debug target/release_debug target/release target/release_nochecks

# `if not exist` rather than swallowing md's "already exists" with `2>nul`, so a genuine failure still
# sets a non-zero exit. The loop variable is a single `%d`, NOT the `%%d` a .bat file would use.
# ---
# ensure the build artifacts directory exists
[group('housekeeping')]
[windows]
@mktarget_dirs:
	for %d in (debug fast_debug release_debug release release_nochecks) do @if not exist target\%d md target\%d || exit /b 1

# delete build artifacts
[group('housekeeping')]
[unix]
clean:
	rm -rf target
	just mktarget_dirs

# cmd's `rm -rf` is `rmdir /s /q`, guarded by `if exist` because rmdir exits non-zero on a missing path.
# ---
# delete build artifacts
[group('housekeeping')]
[windows]
clean:
	if exist target rmdir /s /q target
	just mktarget_dirs


# ============================================================ sim =========
#
# Build tiers for the deal generator. `-keep-executable` leaves the binary in place (odin run deletes it
# by default) so `sim-norebuild` can re-run it - Odin has no build cache, so `just sim` always rebuilds.

# run the deal generator (release). Pass CLI args through, e.g. `just sim --scenario 1c-any -n 12`.
[group('sim')]
sim *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -keep-executable -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", sim_name) }} -- {{args}}

# run the deal generator (release) WITHOUT recompiling
[group('sim')]
sim-norebuild *args:
	{{ target_path("release", sim_name) }} {{args}}

# `-debug` implies `-o:none`: fastest to compile, friendliest to step through, and the only profile with
# the tracking allocator on by default (see sim.odin's TRACKING_ALLOCATOR note).
# ---
# run the deal generator (debug build)
[group('sim')]
sim-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("debug", sim_name) }} -- {{args}}

# `-o:minimal` is one rung above `-debug`'s `-o:none`: still quick to compile and mostly faithful to step
# through, but fast enough at runtime to make a `--count 48` export bearable.
# ---
# run the deal generator with debug info and light optimizations
[group('sim')]
sim-fast-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -o:minimal -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("fast_debug", sim_name) }} -- {{args}}

# Release codegen with debug info retained: for profiling, and for bugs that only appear under
# optimization. Slowest to compile, and the debugger jumps around inlined/reordered code.
# ---
# run the deal generator with full optimizations AND debug info
[group('sim')]
sim-release-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -o:speed -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("release_debug", sim_name) }} -- {{args}}

# `sim` plus every runtime safety check compiled out: `-no-bounds-check`, `-disable-assert` and
# `-no-type-assert`. Those checks turn a memory-corrupting bug into a clean panic, so a fault here is
# undefined behaviour rather than a readable message - benchmark against `just sim` before believing it
# is faster, and keep the checked build in your test matrix.
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
# memory) or `thread` (data races - the interesting one here, since the generator and the combo analyser
# both pool threads). Only `address` is widely supported; `memory` and `thread` need a clang-ish
# toolchain. ON WINDOWS `address` CATCHES STACK ERRORS BUT NOT HEAP ERRORS - Odin allocates through
# `HeapAlloc`, which ASan does not intercept, so a clean run there says nothing about your heap.
#
# `sanitize` and `test-sanitize` deliberately omit `-linker:{{linker}}` - do not "fix" the inconsistency.
# A sanitizer interposes on the runtime and not every linker cooperates: `radlink` links an ASan binary
# that dies on startup with a bare `0xc000001d` and no usable stack, while `-linker:default` runs it.
# Usage:  just sanitize   or   just sanitize thread --scenario 1c-any --count 8
# ---
# run the deal generator under a sanitizer (address | memory | thread)
[group('sim')]
sanitize kind="address" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{sim_name}}") }} -- {{args}}


# =========================================================== test =========
#
# The workbench's own tests (`test-workbench`, `page-check`, `wb-cli-parity`) live in .just/workbench.just.

# run the bidding-system unit tests
[group('test')]
test *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# Filtering is a `core:testing` define, not a compiler flag - there is no `-test-name:`. NAME takes a
# comma-separated list and the package prefix is optional, so `bidding.my_test`, `my_test` and `one,two`
# all work:  just test1 my_test
# ---
# run one named bidding-system test (comma-separated for several)
[group('test')]
test1 name *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -define:ODIN_TEST_NAMES={{name}} -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# Covers the baked table itself: every entry round-trips through its own engine key, the card-validity
# gate rejects odds-equivalent-but-wrong-honour hits, and `zz_book_diff` prints the book-vs-engine
# percentage diff. The ENGINE's own tests live in norn (`just test-combo` there).
# ---
# run the published suit-combination table (suit_book) unit tests + the book-vs-engine diff
[group('test')]
test-suit-book *args: mktarget_dirs
	odin test suit_book {{norn}} -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-suit-book.exe") }} {{args}}

# The window's remembered choices: a `key=value` file the HOST writes (Sciter has no cookies and no
# localStorage; its `@storage` lives in the document's runtime, which is the wrong side of the boundary for
# the application's own settings - see prefs/prefs.odin). Every test round-trips through a real file, because
# a preference that only survives while the window is open is not a preference.
# ---
# run the preferences-file unit tests (round trip, change, missing file, unknown lines)
[group('test')]
test-prefs *args: mktarget_dirs
	odin test prefs -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-prefs.exe") }} {{args}}

# The notes' HEADINGS as a searchable list - the model behind the editor's CTRL+R "go to heading" palette:
# parsing headings out of the source, scoring a typed query against a name (subsequence, word-start and
# prefix bonuses) and ranking the corpus with the open file first. No engine in any of it, which is why the
# ranking's judgement calls are testable at all.
# ---
# run the heading-palette unit tests (heading parsing, fuzzy scoring, ranking)
[group('test')]
test-outline *args: mktarget_dirs
	odin test outline -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-outline.exe") }} {{args}}

# The preview's SECTION WINDOW: which section a caret row is in (counted in the .bml source) and the slice of
# the rendered page that shows it. Both halves are string work with no engine in them, which is the point -
# the invariant is that the two counts agree, and that is testable here rather than through a document.
# ---
# run the preview section-window unit tests (caret row -> section, html slicing)
[group('test')]
test-preview *args: mktarget_dirs
	odin test preview -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-preview.exe") }} {{args}}

# Forced single-threaded: DDS shares process-global transposition tables and is NOT reentrant, so
# concurrent test procs would corrupt each other's solves.
# ---
# run the double-dummy / DDS-sampling unit tests (links the DDS solver via the dds collection)
[group('test')]
test-deal-solve *args: mktarget_dirs
	odin test deal_solve {{norn}} {{dds}} -debug -microarch:native -define:ODIN_TEST_THREADS=1 -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-deal-solve.exe") }} {{args}}

# The deal READER, the flag surface and the text report - the solver-free half of the advisor. Also
# single-threaded: the package links DDS, same reason as `test-deal-solve`.
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
