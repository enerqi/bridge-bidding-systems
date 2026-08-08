# `cmd.exe` for one reason: it starts in ~9ms. just launches a shell per recipe line, so startup is a
# fixed tax on every build. Bare `<shell> exit` under hyperfine: cmd ~9ms, `nu -c` ~41ms,
# `powershell -NoLogo -NoProfile -Command` ~143ms (what this file used to set). cmd is also *more*
# portable than the PowerShell it replaces - on every Windows, no install, and no profile to make a
# recipe unreproducible, so the old `-NoProfile` guard is moot. The cost is that it is a poor language
# for a multi-line recipe, which does not bite: every Windows body below is a single command, and
# anything needing logic or careful argument quoting uses `[script("python")]` instead.
set windows-shell := ["cmd.exe", "/c"]
set shell := ["bash", "-c"]
set unstable  # [script("python")] feature - https://github.com/casey/just/issues/1479
set lazy

# Set by the newest just feature used below - currently user-defined functions (1.49), for
# `target_path`. Older features it also needs: `join()` 1.37, f-strings 1.44, `set lazy` 1.47.
# Without this an old just reports a plain syntax error at the offending line, which reads like a
# corrupt justfile rather than an out-of-date tool.
set minimum-version := "1.49.0"

# This project is a CONSUMER of the norn library: norn provides the hand-generation engine
# (`norn:norn`) and the reusable scenario CLI framework (`norn:cli`); everything here (the `bidding`
# package + `sim.odin`) is this specific bidding system. norn is referenced as an Odin collection.
#
# `norn_home` is the single source of truth for where the norn checkout lives: the NORN_HOME
# environment variable if set, else `<home>/dev/norn` (just's `home_directory()` is cross-platform;
# `replace` normalises Windows backslashes to the forward slashes Odin wants). It feeds BOTH the
# `-collection` build flag AND the generated ols.json (see the `ols-config` recipe) — so the
# machine-specific path is set in exactly one place, and ols.json — which has no env-var expansion of
# its own — is regenerated from it rather than hand-edited.
norn_home := env_var_or_default("NORN_HOME", replace(home_directory(), "\\", "/") + "/dev/norn")
norn := "-collection:norn=" + norn_home

# odin-dds provides the DDS double-dummy solver bindings, referenced as the `dds` collection and used
# only by the local `deal_solve` package (the norn->DDS boundary). DDS_HOME overrides the default checkout
# location, mirroring norn_home. Its lib/dds.lib (Windows) / lib/dds.a (Unix) must be built first —
# see odin-dds `just build-lib`.
dds_home := env_var_or_default("DDS_HOME", replace(home_directory(), "\\", "/") + "/dev/odin-dds")
dds := "-collection:dds=" + dds_home
sim_name := "sim.exe"
analyse_name := "analyse_deal.exe"
test_main_name := "test-bidding.exe"

# `join`, not the `/` operator: `/` always emits a forward slash, and cmd.exe rejects a forward-slash
# path in *command* position ("'target' is not recognized") even quoted. Odin takes either in an
# `-out:` argument, but `sim-norebuild` invokes the binary directly, so it needs the native separator
# `join` gives. bash needs no `./` prefix - a path containing a slash is already a path.
target_path(dir, name) := join("target", dir, name)

# Which linker Odin hands the object files to. `-linker:` takes exactly four values: `default` (Odin
# picks - MSVC `link.exe` on Windows), `lld` (Windows and Linux; NOT on a stock macOS, where Odin
# links through Apple's clang and clang ships no lld), `radlink` (Windows only, and bundled with the
# Odin toolchain so it needs no install - which is why it is the Windows default here) and `mold`
# (Linux only, and not bundled - `apt install mold` first). Odin has no build cache and relinks on
# every `just sim`, so the link step is a cost paid on each iteration - and this project links the
# DDS static library on top of its own code, which makes the link the slower half of a rebuild.
#
# Override for a single command without editing this file. It is an env var rather than a recipe
# argument because `odin` errors on a repeated flag, so a `-linker:` passed through a recipe's *args
# would collide with the one the recipe already adds:
#
#     ODIN_LINKER=lld just sim --scenario 1c-any   # -lto on Windows *requires* -linker:lld
#
# See the odin-lang-skeleton justfile for the full per-value notes.
#
# THIS PROJECT CANNOT USE radlink, which is why the Windows default below is `default` rather than the
# `radlink` the skeleton and norn use. radlink dies linking sim.odin with a bare `0xc000001d`
# (illegal instruction) crash of its own — "--- Fatal Exception --- ... Version: 0.9.24" — producing
# sim.obj and no exe, at EVERY optimization level including -debug. It is triggered by linking live
# `core:debug/trace` code (either `register_segfault_handler`, or assigning
# `trace.assertion_failure_proc`, is enough on its own) into this program; norn's own CLI does the same
# thing and links fine, so the DDS static library appears to be the other half of it. `default` and
# `lld` both link it, and measured identically at ~3.9s for a full `-o:speed` build, so pinning
# `default` — the incremental one Odin would pick anyway — costs nothing here.
#
# The one concrete factor shared with the other radlink casualty in this family: sibling project
# odin-num-format also had to pin `default`, because radlink there LINKS cleanly and produces a binary
# that dies at startup with the same `0xc000001d`. Its Rust staticlib requires `dbghelp.lib`
# (`just native-libs-rs` prints it), and `core:debug/trace` is a dbghelp consumer too — so a
# dbghelp-in-the-link + static-non-Odin-library combination is the shape to be suspicious of, in either
# project, rather than anything specific to DDS or to Rust.
linker := env_var_or_default("ODIN_LINKER", "default")

# Where the batch `gen-all*` / `gen-some` recipes write their per-scenario HTML: DEALS_OUTPUT_DIR if set, else the
# w: web-server volume. Every recipe also takes it as a trailing argument, e.g. `just gen-all 48 ./out/`.
deals_output_dir := env_var_or_default("DEALS_OUTPUT_DIR", "w:/deals/")

# Where the single-scenario `gen-one*` recipes write <SCENARIO>.html: the directory just was invoked
# from (NOT this justfile's directory, which just would otherwise chdir to), so a scratch run lands
# where you typed it. `_native` + `replace` because the plain builtin hands back a /c/... path on
# Windows. Overridable per-recipe too, and via DEALS_SCRATCH_DIR.
scratch_dir := env_var_or_default("DEALS_SCRATCH_DIR", replace(invocation_directory_native(), "\\", "/"))

# hand-ocr is a SEPARATE sibling repo (image -> PBN/LIN; uv/Python). HAND_OCR_DIR overrides the default
# checkout location, mirroring norn_home/dds_home. `export` re-exports it as an env var so the `ocr-analyse`
# recipe's `ocr_analyse.py` reads the SAME value (just variables are not environment variables otherwise) --
# the path lives in one place across just and Python.
export HAND_OCR_DIR := env_var_or_default("HAND_OCR_DIR", replace(home_directory(), "\\", "/") + "/dev/bridge-hand-ocr")

# Every build recipe depends on this, so it runs before every build - which makes its cost a tax on
# every iteration. The directories are created all at once rather than one per line because just starts
# a new shell per recipe line and on Windows the shell launch dwarfs the work. odin does not create the
# output directory (the linker fails with LNK1104), so this cannot be dropped.
# ---
# ensure the build artifacts directory exists
[unix]
@mktarget_dirs:
	mkdir -p target/debug target/fast_debug target/release_debug target/release target/release_nochecks

# `if not exist` rather than swallowing md's "already exists" with `2>nul`, so a genuine failure still
# sets a non-zero exit. The loop variable is a single `%d`, NOT the `%%d` a .bat file would use:
# doubling is escaping for batch *files*, and `cmd /c` takes a command *line*.
# ---
# ensure the build artifacts directory exists
[windows]
@mktarget_dirs:
	for %d in (debug fast_debug release_debug release release_nochecks) do @if not exist target\%d md target\%d || exit /b 1

# ols.json is machine-specific (absolute paths) and gitignored — regenerate it after cloning or when
# NORN_HOME / DDS_HOME change:  NORN_HOME=/path/to/norn DDS_HOME=/path/to/odin-dds just ols-config
# ---
# (re)generate ols.json so the editor's language server resolves the `norn:` and `dds:` collections
[script("python")]
ols-config:
	import json
	config = {
		"$schema": "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json",
		"collections": [
			{"name": "norn", "path": r"{{norn_home}}"},
			{"name": "dds", "path": r"{{dds_home}}"},
		],
	}
	with open("ols.json", "w") as f:
		f.write(json.dumps(config, indent=4) + "\n")
	print("wrote ols.json -> norn collection at {{norn_home}}, dds at {{dds_home}}")

# odinfmt every .odin file under this directory (odinfmt walks subdirs itself)
format:
	odinfmt -w .

# lints the local library packages with -no-entry-point plus the single-file programs. `deal_solve`,
# `sim`, `analyse_deal` and the two benches pull in the `dds` collection (the DDS boundary); `bidding`
# and `suit_book` do not (`suit_book` is this project's published suit-combination table, plugged into
# `norn:combo`'s book hook). The card-combination ENGINE itself lives in norn (`norn:combo`) — lint it
# there. The benches are listed too: nothing else type-checks them, so they drift unchecked otherwise.
# `-vet-tabs` is the only compiler-side enforcement of .editorconfig's `indent_style = tab`; it is not
# implied by `-strict-style`.
# ---
# type check + vet + strict style (bidding, suit_book, deal_solve, sim.odin, analyse_deal.odin, benches)
lint *args:
	odin check bidding {{norn}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check suit_book {{norn}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check deal_solve {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check sim.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check analyse_deal.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check bench.odin -file {{norn}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check bench_e2e.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style -vet-tabs {{args}}

# `-keep-executable` leaves the built binary in place (odin run deletes it by default) so
# `sim-norebuild` can execute it again without recompiling - Odin has no build cache, so a plain
# `just sim` always rebuilds.
# ---
# run the deal generator (release). Pass CLI args through, e.g. `just sim --scenario 1c-any -n 12`.
sim *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -keep-executable -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", sim_name) }} -- {{args}}

# run the deal generator (release) WITHOUT recompiling. Pass CLI args through, e.g. `just sim-norebuild --scenario 1c-any -n 12`.
sim-norebuild *args:
	{{ target_path("release", sim_name) }} {{args}}

# `-debug` implies `-o:none`, so this is the fastest to compile and the friendliest to step through.
# It is also the only profile with the tracking allocator on by default (see sim.odin's
# TRACKING_ALLOCATOR note) - the release profiles below deliberately measure without it.
# ---
# run the deal generator (debug build). Pass CLI args through, e.g. `just sim-debug --scenario 1c-any -n 12`.
sim-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("debug", sim_name) }} -- {{args}}

# `-o:minimal` is one rung above the `-debug` default of `-o:none`: still quick to compile and mostly
# faithful to step through, but noticeably faster at runtime - enough to make a `--count 48` export
# bearable while still being a debug build.
# ---
# run the deal generator with debug info and light optimizations
sim-fast-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -o:minimal -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("fast_debug", sim_name) }} -- {{args}}

# Release codegen with debug info retained: what to profile, and what to reach for when a bug only
# appears under optimization (a rejection-sampling generator across a thread pool has plenty of room
# for those). Slowest to compile, and the debugger will jump around inlined/reordered code.
# ---
# run the deal generator with full optimizations AND debug info
sim-release-debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -o:speed -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("release_debug", sim_name) }} -- {{args}}

# `sim` plus every runtime safety check compiled out: `-no-bounds-check` (slice/array indexing),
# `-disable-assert` (the built-in `assert`) and `-no-type-assert` (union/any type assertions). Those
# checks are what turn a memory-corrupting bug into a clean panic, so a fault here is undefined
# behaviour rather than a readable message - benchmark against `just sim` before believing it is
# faster, and keep the checked build in your test matrix.
# ---
# run the deal generator with optimizations and ALL runtime safety checks removed
sim-nochecks *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -o:speed -no-bounds-check -disable-assert -no-type-assert -keep-executable -microarch:native -linker:{{linker}} -out:{{ target_path("release_nochecks", sim_name) }} -- {{args}}

# build the sim deal generator (release)
build *args: mktarget_dirs
	odin build sim.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", sim_name) }} {{args}}

# `address` (ASan) catches out-of-bounds accesses and use-after-free; `memory` catches reads of
# uninitialized memory; `thread` catches data races - the last being the interesting one here, since
# the generator and the combo analyser both pool threads. Only `address` is widely supported; `memory`
# and `thread` need a clang-ish toolchain and are unavailable on some platforms (notably Windows/MSVC).
# Both sanitizer recipes deliberately omit `-linker:{{linker}}`: link speed is worth nothing on a
# diagnostic run, and pinning it actively breaks things. A sanitizer has to interpose on the runtime,
# which not every linker cooperates with - `radlink` (this file's Windows default, and bundled with
# Odin, so it is what you get by accident) links an ASan binary that dies on startup with a bare
# `0xc000001d` illegal-instruction exception and no usable stack, while `-linker:default` runs it.
# Usage:  just sanitize   or   just sanitize thread --scenario 1c-any --count 8
# ---
# run the deal generator under a sanitizer (address | memory | thread)
sanitize kind="address" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -debug -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{sim_name}}") }} -- {{args}}

# same sanitizer options as `sanitize`; see its notes for platform support and the linker note.
# ---
# run the bidding-system tests under a sanitizer (address | memory | thread)
test-sanitize kind="address" *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{test_main_name}}") }} {{args}}

#
# Convenience wrappers over `sim` / `sim-norebuild` (these used to live in the repo-root justfile as
# the `*-norn` family; the root reaches them as a just module, e.g. `just sims gen-all 48`).
#
# NAMING: gen-all = every registered scenario, gen-some = a named subset, gen-one = one scenario.
# Suffixes stack in this order: [-cards][-dd] for the format/solver variants, -norebuild to skip the
# compile and reuse the last release build.
#
# BATCH: every registered scenario -> <DIR>/<scenario>.html, DIR defaulting to deals_output_dir.
# SINGLE: one scenario -> <DIR>/<SCENARIO>.html, DIR defaulting to scratch_dir (where you invoked just).
# Variants: -dd adds the per-scenario double-dummy annotate/filter (scenarios register these in
# sim.odin; DD scenarios export serially since the solver isn't reentrant, the rest still pool);
# -cards swaps the BBO iframe pages for self-rendered offline card carousels (one page per scenario,
# prev/next carousel of text-compass diagrams, seat toggle, par toggle).
#

# generate ALL scenarios (COUNT deals each) -> DIR/<scenario>.html
gen-all COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}}

# generate ALL scenarios WITH double-dummy annotations -> DIR/<scenario>.html
gen-all-dd COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --dd

# generate ALL scenarios as offline card carousels -> DIR/<scenario>.html
gen-all-cards COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --format html-cards

# generate ALL scenarios as offline card carousels WITH double-dummy par captions
gen-all-cards-dd COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --format html-cards --dd

# generate ALL scenarios WITHOUT recompiling (reuses the last release build)
gen-all-norebuild COUNT="48" DIR=deals_output_dir:
	just sim-norebuild --html-dir {{DIR}} --count {{COUNT}}

# generate a SUBSET; NAMES is comma-separated, e.g. `just gen-some 1c-any,2c-opener 100`
gen-some NAMES COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --scenario {{NAMES}} --count {{COUNT}}

# COUNT deals for ONE scenario -> DIR/<SCENARIO>.html
gen-one SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario WITH double-dummy annotations -> DIR/<SCENARIO>.html
gen-one-dd SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html --dd

# COUNT deals for ONE scenario as an offline card carousel -> DIR/<SCENARIO>.html
gen-one-cards SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario as an offline card carousel with double-dummy par -> DIR/<SCENARIO>.html
gen-one-cards-dd SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html --dd

# COUNT deals for ONE scenario WITHOUT recompiling -> DIR/<SCENARIO>.html
gen-one-norebuild SCENARIO COUNT="48" DIR=scratch_dir:
	just sim-norebuild --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html

# list the scenarios compiled into the sim
scenarios:
	just sim-debug --list

# read a deal and print the combo analysis (double-dummy census + achievable single-dummy) for the
# known partnership. The deal may be a PBN [Deal] tag / bare N:... value, a bridge-site hand URL
# (BBO/IntoBridge `...?lin=...`), or a bare LIN `md|...` record. Add `--sample <deals>` for the
# DDS-sampling whole-hand make-% verdict (links DDS); `--contract 4H` is OPTIONAL (best contract
# auto-picked if omitted). `--html <out>` writes the interactive card page (green verdict band +
# contract picker when sampling).
#
# The DEAL comes FIRST; optional flags follow it. Single-quote the deal so YOUR shell hands it to just
# in one piece — a LIN URL's `|` pipes, `!` alerts, `%` escapes and bare-PBN spaces all need it.
# e.g. just analyse-deal 'https://play.intobridge.com/hand?lin=...'                         (paste a hand URL)
# e.g. just analyse-deal 'N:Q865.J983..T7654 J.KT7.AJ8642.K32 AKT73.Q.KQ7.AQJ9 942.A6542.T953.8'
# e.g. just analyse-deal 'N:... - ... -' --sample 400                                       (auto-pick the contract)
# e.g. just analyse-deal 'N:... - ... -' --sample 400 --contract 3NT --html out.html
#
# `[script("python")]` rather than a shell line, and it BUILDS then RUNS the exe rather than using
# `odin run`. Both halves are about the deal string surviving intact. just's `quote()` emits POSIX
# single-quote quoting, which cmd.exe does not understand at all, so the metacharacters above would be
# re-interpreted on Windows; python's `subprocess` takes an argv list and spawns no shell, so there is
# nothing left to quote against. Skipping `odin run` removes the second hazard: it re-spawns the built
# exe, and the Windows MSVCRT argument re-parse used to strip the literal double quotes out of the
# `[Deal "..."]` tag form. Both forms now work here, and `--file <path>` / stdin (a .pbn with SEVERAL
# [Deal] tags -> one carousel page, or `hand-ocr ... | analyse_deal`) still want the exe directly:
# target/release/analyse_deal.exe --file <path>.
# ---
# single-deal advisor: declarer+dummy (defenders `-`) OR a complete 4-hand deal (exact DD), from PBN / LIN URL -> combo analysis (+ optional --sample verdict / --html card page)
[script("python")]
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

# Frequency test every scenario by default, or pass `-S name[,name]` to restrict the subset.
# e.g. `just freq` (1M, -all), `just freq 5000000`, `just freq 1000000 -S 1c-any,2c-opener`.
# With --dd the rate also counts each scenario's double-dummy filter (filtered scenarios run serially).
# ---
# measure each scenario's acceptance frequency over N deals (no deals emitted)
freq trials="1000000" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", sim_name) }} -- --frequency {{trials}} {{args}}

# Override counts: just bench '-define:COUNT_SUIT=5000' '-define:COUNT_DEAL=500'
# ---
# benchmark the combo package (Phase 1, Phase 2 lines/optimal, annotate end-to-end)
bench *args: mktarget_dirs
	odin run bench.odin -file {{norn}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "bench.exe") }} {{args}}

# the compute behind `sim -S slam-makes-dd --count 48 --format html-cards --dd`, minus the file write.
# Links DDS like sim. Knobs via -define, e.g.:
#   just bench-e2e                                   (slam-makes-dd, count 48, 3 iters)
#   just bench-e2e '-define:E2E_COUNT=24' '-define:E2E_ITERS=5'
#   just bench-e2e '-define:COMBO_THREADS=false'     (time the serial combo path)
# ---
# END-TO-END benchmark of ONE scenario's full pipeline (generate + DD filter + deal_solve/combo annotate + render)
bench-e2e *args: mktarget_dirs
	odin run bench_e2e.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "bench-e2e.exe") }} {{args}}

# run the bidding-system unit tests
test *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# Filtering is a `core:testing` define rather than a compiler flag - there is no `-test-name:`, and a
# stale spelling of one fails with `Unknown flag: 'test-name'` before anything builds. NAME takes a
# comma-separated list and the package prefix is optional, so `bidding.my_test`, `my_test` and
# `one,two` all work:
#     just test1 my_test
# ---
# run one named bidding-system test (comma-separated for several)
test1 name *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -define:ODIN_TEST_NAMES={{name}} -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# Covers the baked table itself: every entry round-trips through its own engine key, the card-validity
# gate rejects odds-equivalent-but-wrong-honour hits, and `zz_book_diff` prints the book-vs-engine
# percentage diff. The card-combination ENGINE's own tests live in norn now (`just test-combo` there).
# ---
# run the published suit-combination table (suit_book) unit tests + the book-vs-engine diff
test-suit-book *args: mktarget_dirs
	odin test suit_book {{norn}} -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-suit-book.exe") }} {{args}}

# Forced single-threaded: DDS shares process-global transposition tables and is NOT reentrant, so
# concurrent test procs would corrupt each other's solves.
# ---
# run the double-dummy / DDS-sampling unit tests (links the DDS solver via the dds collection)
test-deal-solve *args: mktarget_dirs
	odin test deal_solve {{norn}} {{dds}} -debug -microarch:native -define:ODIN_TEST_THREADS=1 -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-deal-solve.exe") }} {{args}}

# declarer+dummy uses '-' for the unknown hands; a full 4-hand diagram emits all four. Bridges to the
# sibling hand-ocr repo (uv), at HAND_OCR_DIR (default ~/dev/bridge-hand-ocr). A real image needs
# hand-ocr's vision extra there: (cd "$HAND_OCR_DIR" && just sync-vision).
# <image> may be `--clipboard` to read straight from the OS clipboard (screenshot, no temp file).
# e.g. `just ocr-pbn hand.png` or `just ocr-pbn hand.png --first E` or `just ocr-pbn --clipboard`
# ---
# OCR a bridge hand-diagram IMAGE to a PBN [Deal] tag, printed to stdout
ocr-pbn image *args:
	uv run --project {{HAND_OCR_DIR}} python {{HAND_OCR_DIR}}/hand-ocr.py {{image}} --format pbn {{args}}

# image -> PBN -> analyse_deal with the DDS-sampling advisor + CCA/DD features. Writes
# <image-basename>.html (override with --html); samples 400 deals by default (override with --sample).
# Extra flags pass through to analyse_deal (e.g. --contract 3NT).
# `just ocr-analyse --demo` runs hand-ocr's sample deal end-to-end (plumbing check, no vision deps needed).
# <image> may be `--clipboard` to read straight from the OS clipboard (screenshot -> card page, no temp file).
# e.g. `just ocr-analyse hand.png` ; `just ocr-analyse hand.png --contract 3NT --seed 7` ; `just ocr-analyse --clipboard`
# ---
# OCR a hand-diagram IMAGE straight to the interactive card page
ocr-analyse image *args: mktarget_dirs
	odin build analyse_deal.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", analyse_name) }}
	uv run --no-project python tools/ocr_analyse.py {{image}} {{args}}

# image -> PBN -> analyse_deal with the DDS-sampling advisor + CCA/DD features. Writes
# <image-basename>.html (override with --html); samples 400 deals by default (override with --sample).
# Extra flags pass through to analyse_deal (e.g. --contract 3NT).
# `just ocr-analyse-norebuild --demo` runs hand-ocr's sample deal end-to-end (plumbing check, no vision deps needed).
# <image> may be `--clipboard` to read straight from the OS clipboard (screenshot -> card page, no temp file).
# e.g. `just ocr-analyse-norebuild hand.png` ; `just ocr-analyse-norebuild hand.png --contract 3NT --seed 7` ; `just ocr-analyse-norebuild --clipboard`
# ---
# OCR a hand-diagram IMAGE straight to the interactive card page without recompiling analyse_deal.exe
ocr-analyse-norebuild image *args:
	uv run --no-project python tools/ocr_analyse.py {{image}} {{args}}

# build analyse_deal, run it on a fixed board+seed, and diff the emitted `data-sim='...'` against
# tests/golden/. Guards write_sim_json (incl. the misguess-tax ach/taxpts/pvt rung) from silently
# drifting out of sync with render.odin's simBand parser.
# ---
# golden test for the card page's data-sim JSON contract
test-golden: mktarget_dirs
	odin build analyse_deal.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", analyse_name) }}
	uv run --no-project python tests/golden_sim_json.py

# delete build artifacts
[unix]
clean:
	rm -rf target
	just mktarget_dirs

# cmd's equivalent of `rm -rf` is `rmdir /s /q`. Guarded by `if exist` because rmdir prints "The
# system cannot find the file specified" and exits non-zero on a missing path, which would fail the
# recipe on an already-clean tree. (This used to be PowerShell's `Test-Path` + `Remove-Item`, needed
# because PowerShell's `rm` alias rejects `-rf` and silently left the directory in place.)
# ---
# delete build artifacts
[windows]
clean:
	if exist target rmdir /s /q target
	just mktarget_dirs
