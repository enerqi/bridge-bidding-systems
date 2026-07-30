set windows-shell := ["powershell", "-c"]
set shell := ["bash", "-c"]

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
# only by the local `dealsolve` package (the norn->DDS boundary). DDS_HOME overrides the default checkout
# location, mirroring norn_home. Its lib/dds.lib (Windows) / lib/dds.a (Unix) must be built first —
# see odin-dds `just build-lib`.
dds_home := env_var_or_default("DDS_HOME", replace(home_directory(), "\\", "/") + "/dev/odin-dds")
dds := "-collection:dds=" + dds_home
sim_name := "sim.exe"

# Where the batch `regen-*` recipes write their per-scenario HTML: DEALS_OUTPUT_DIR if set, else the
# w: web-server volume. Every recipe also takes it as a trailing argument, e.g. `just regen 48 ./out/`.
deals_output_dir := env_var_or_default("DEALS_OUTPUT_DIR", "w:/deals/")

# Where the single-scenario `deal-*` recipes write <SCENARIO>.html: the directory just was invoked
# from (NOT this justfile's directory, which just would otherwise chdir to), so a scratch run lands
# where you typed it. `_native` + `replace` because the plain builtin hands back a /c/... path on
# Windows. Overridable per-recipe too, and via DEALS_SCRATCH_DIR.
scratch_dir := env_var_or_default("DEALS_SCRATCH_DIR", replace(invocation_directory_native(), "\\", "/"))

# hand-ocr is a SEPARATE sibling repo (image -> PBN/LIN; uv/Python). HAND_OCR_DIR overrides the default
# checkout location, mirroring norn_home/dds_home. `export` re-exports it as an env var so the `ocr-analyse`
# recipe's `ocr_analyse.py` reads the SAME value (just variables are not environment variables otherwise) --
# the path lives in one place across just and Python.
export HAND_OCR_DIR := env_var_or_default("HAND_OCR_DIR", replace(home_directory(), "\\", "/") + "/dev/bridge-hand-ocr")

# ensure the build artifacts directory exists
[unix]
@mktarget_dirs:
	-mkdir -p target/debug
	-mkdir -p target/release

[windows]
@mktarget_dirs:
	New-Item -ItemType Directory -Force target/debug | Out-Null
	New-Item -ItemType Directory -Force target/release | Out-Null

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

# lints the local library packages with -no-entry-point plus the two single-file programs. `dealsolve`,
# `sim` and `analyse_deal` pull in the `dds` collection (the DDS boundary); `bidding` and `suitbook` do not
# (`suitbook` is this project's published suit-combination table, plugged into `norn:combo`'s book hook).
# The card-combination ENGINE itself now lives in norn (`norn:combo`) — lint it there.
# ---
# type check + vet + strict style (bidding, suitbook, dealsolve, sim.odin, analyse_deal.odin)
lint *args:
	odin check bidding {{norn}} -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check suitbook {{norn}} -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check dealsolve {{norn}} {{dds}} -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check sim.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style {{args}}
	odin check analyse_deal.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style {{args}}

# run the deal generator (release). Pass CLI args through, e.g. `just run --scenario 1c-any -n 12`.
run *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -keep-executable -o:speed -microarch:native -out:target/release/{{sim_name}} -- {{args}}

# rerun the deal generator (release) without recompiling. Pass CLI args through, e.g. `just run --scenario 1c-any -n 12`.
rerun *args: mktarget_dirs
	target/release/{{sim_name}} {{args}}

# run the deal generator (debug build). Pass CLI args through, e.g. `just run_debug --scenario 1c-any -n 12`.
run_debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -microarch:native -out:target/debug/{{sim_name}} -- {{args}}

# build the sim deal generator (release)
build *args: mktarget_dirs
	odin build sim.odin -file {{norn}} {{dds}} -o:speed -microarch:native -out:target/release/{{sim_name}} {{args}}

#
# Convenience wrappers over `run` / `rerun` (these used to live in the repo-root justfile as the
# `*-norn` family; the root reaches them as a just module, e.g. `just sims regen 48`).
#
# BATCH: every registered scenario -> <DIR>/<scenario>.html, DIR defaulting to deals_output_dir.
# SINGLE: one scenario -> <DIR>/<SCENARIO>.html, DIR defaulting to scratch_dir (where you invoked just).
# Variants: -dd adds the per-scenario double-dummy annotate/filter (scenarios register these in
# sim.odin; DD scenarios export serially since the solver isn't reentrant, the rest still pool);
# -cards swaps the BBO iframe pages for self-rendered offline card carousels (one page per scenario,
# prev/next carousel of text-compass diagrams, seat toggle, par toggle).
#

# regenerate ALL scenarios (COUNT deals each) -> DIR/<scenario>.html
regen COUNT="48" DIR=deals_output_dir:
	just run --html-dir {{DIR}} --count {{COUNT}}

# regenerate ALL scenarios WITH double-dummy annotations -> DIR/<scenario>.html
regen-dd COUNT="48" DIR=deals_output_dir:
	just run --html-dir {{DIR}} --count {{COUNT}} --dd

# regenerate ALL scenarios as offline card carousels -> DIR/<scenario>.html
regen-cards COUNT="48" DIR=deals_output_dir:
	just run --html-dir {{DIR}} --count {{COUNT}} --format html-cards

# regenerate ALL scenarios as offline card carousels WITH double-dummy par captions
regen-cards-dd COUNT="48" DIR=deals_output_dir:
	just run --html-dir {{DIR}} --count {{COUNT}} --format html-cards --dd

# regenerate ALL scenarios WITHOUT recompiling (reuses the last release build)
regen-rerun COUNT="48" DIR=deals_output_dir:
	just rerun --html-dir {{DIR}} --count {{COUNT}}

# regenerate a SUBSET; NAMES is comma-separated, e.g. `just regen-some 1c-any,2c-opener 100`
regen-some NAMES COUNT="48" DIR=deals_output_dir:
	just run --html-dir {{DIR}} --scenario {{NAMES}} --count {{COUNT}}

# COUNT deals for ONE scenario -> DIR/<SCENARIO>.html
deal SCENARIO COUNT="48" DIR=scratch_dir:
	just run --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario WITH double-dummy annotations -> DIR/<SCENARIO>.html
deal-dd SCENARIO COUNT="48" DIR=scratch_dir:
	just run --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html --dd

# COUNT deals for ONE scenario as an offline card carousel -> DIR/<SCENARIO>.html
deal-cards SCENARIO COUNT="48" DIR=scratch_dir:
	just run --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario as an offline card carousel with double-dummy par -> DIR/<SCENARIO>.html
deal-cards-dd SCENARIO COUNT="48" DIR=scratch_dir:
	just run --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html --dd

# COUNT deals for ONE scenario WITHOUT recompiling -> DIR/<SCENARIO>.html
deal-rerun SCENARIO COUNT="48" DIR=scratch_dir:
	just rerun --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html

# list the scenarios compiled into the sim
scenarios:
	just run_debug --list

# read a deal and print the combo analysis (double-dummy census + achievable single-dummy) for the
# known partnership. The deal may be a PBN [Deal] tag / bare N:... value, a bridge-site hand URL
# (BBO/IntoBridge `...?lin=...`), or a bare LIN `md|...` record. Add `--sample <deals>` for the
# DDS-sampling whole-hand make-% verdict (links DDS); `--contract 4H` is OPTIONAL (best contract
# auto-picked if omitted). `--html <out>` writes the interactive card page (green verdict band +
# contract picker when sampling).
# The DEAL comes FIRST (single-quoted); optional flags follow it. The deal is quoted-through with
# just's `quote()` so a LIN URL's `|` pipes, `!` alerts, `%` escapes and bare-PBN spaces survive the shell
# (nu/powershell/bash all treat the metachars as pipes otherwise). Flags after it are plain tokens.
# e.g. just analyse-deal 'https://play.intobridge.com/hand?lin=...'                         (paste a hand URL)
# e.g. just analyse-deal 'N:AK6.AT753..AKQ98 T952.KJ.J4.T5432 QJ7.QT75.KQ96.76 843.986432.A82.J'
# e.g. just analyse-deal 'N:... - ... -' --sample 400                                       (auto-pick the contract)
# e.g. just analyse-deal 'N:... - ... -' --sample 400 --contract 3NT --html out.html
# Prefer the BARE `N:...` deal form over the `[Deal "..."]` wrapper: on Windows `odin run` strips the
# wrapper's literal double-quotes when it spawns the exe (MSVCRT arg re-parse), so the tag form loses its
# quotes. For that form / --file <path> / stdin (a .pbn with SEVERAL [Deal] tags -> one carousel page, or
# `hand-ocr ... | analyse_deal`), run the built exe directly: target/release/analyse_deal.exe --file <path>.
# ---
# single-deal advisor: declarer+dummy (defenders `-`) OR a complete 4-hand deal (exact DD), from PBN / LIN URL -> combo analysis (+ optional --sample verdict / --html card page)
analyse-deal deal *flags: mktarget_dirs
	odin run analyse_deal.odin -file {{norn}} {{dds}} -o:speed -microarch:native -out:target/release/analyse_deal.exe -- {{flags}} {{quote(deal)}}

# deprecated alias for `analyse-deal` (recipe + program were PBN-only before they learned LIN; the
# program is now `analyse_deal.odin`, was `pbn_analyse.odin`)
alias analyse-pbn := analyse-deal

# Frequency test every scenario by default, or pass `-S name[,name]` to restrict the subset.
# e.g. `just freq` (1M, -all), `just freq 5000000`, `just freq 1000000 -S 1c-any,2c-opener`.
# With --dd the rate also counts each scenario's double-dummy filter (filtered scenarios run serially).
# ---
# measure each scenario's acceptance frequency over N deals (no deals emitted)
freq trials="1000000" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -o:speed -microarch:native -out:target/release/{{sim_name}} -- --frequency {{trials}} {{args}}

# Override counts: just bench '-define:COUNT_SUIT=5000' '-define:COUNT_DEAL=500'
# ---
# benchmark the combo package (Phase 1, Phase 2 lines/optimal, annotate end-to-end)
bench *args: mktarget_dirs
	odin run bench.odin -file {{norn}} -o:speed -microarch:native {{args}}

# the compute behind `sim -S slam-makes-dd --count 48 --format html-cards --dd`, minus the file write.
# Links DDS like sim. Knobs via -define, e.g.:
#   just bench-e2e                                   (slam-makes-dd, count 48, 3 iters)
#   just bench-e2e '-define:E2E_COUNT=24' '-define:E2E_ITERS=5'
#   just bench-e2e '-define:COMBO_THREADS=false'     (time the serial combo path)
# ---
# END-TO-END benchmark of ONE scenario's full pipeline (generate + DD filter + dealsolve/combo annotate + render)
bench-e2e *args: mktarget_dirs
	odin run bench_e2e.odin -file {{norn}} {{dds}} -o:speed -microarch:native {{args}}

# run the bidding-system unit tests
test *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -out:target/debug/test-bidding.exe {{args}}

# Covers the baked table itself: every entry round-trips through its own engine key, the card-validity
# gate rejects odds-equivalent-but-wrong-honour hits, and `zz_book_diff` prints the book-vs-engine
# percentage diff. The card-combination ENGINE's own tests live in norn now (`just test-combo` there).
# ---
# run the published suit-combination table (suitbook) unit tests + the book-vs-engine diff
test-suitbook *args: mktarget_dirs
	odin test suitbook {{norn}} -debug -microarch:native -show-timings -out:target/debug/test-suitbook.exe {{args}}

# Forced single-threaded: DDS shares process-global transposition tables and is NOT reentrant, so
# concurrent test procs would corrupt each other's solves.
# ---
# run the double-dummy / DDS-sampling unit tests (links the DDS solver via the dds collection)
test-dealsolve *args: mktarget_dirs
	odin test dealsolve {{norn}} {{dds}} -debug -microarch:native -define:ODIN_TEST_THREADS=1 -show-timings -out:target/debug/test-dealsolve.exe {{args}}

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
	odin build analyse_deal.odin -file {{norn}} {{dds}} -o:speed -microarch:native -out:target/release/analyse_deal.exe
	uv run --no-project python tools/ocr_analyse.py {{image}} {{args}}

# image -> PBN -> analyse_deal with the DDS-sampling advisor + CCA/DD features. Writes
# <image-basename>.html (override with --html); samples 400 deals by default (override with --sample).
# Extra flags pass through to analyse_deal (e.g. --contract 3NT).
# `just ocr-analyse-rerun --demo` runs hand-ocr's sample deal end-to-end (plumbing check, no vision deps needed).
# <image> may be `--clipboard` to read straight from the OS clipboard (screenshot -> card page, no temp file).
# e.g. `just ocr-analyse-rerun hand.png` ; `just ocr-analyse-rerun hand.png --contract 3NT --seed 7` ; `just ocr-analyse-rerun --clipboard`
# ---
# OCR a hand-diagram IMAGE straight to the interactive card page without recompiling analyse_deal.exe
ocr-analyse-rerun image *args: mktarget_dirs
	uv run --no-project python tools/ocr_analyse.py {{image}} {{args}}

# build analyse_deal, run it on a fixed board+seed, and diff the emitted `data-sim='...'` against
# tests/golden/. Guards write_sim_json (incl. the misguess-tax ach/taxpts/pvt rung) from silently
# drifting out of sync with render.odin's simBand parser.
# ---
# golden test for the card page's data-sim JSON contract
test-golden: mktarget_dirs
	odin build analyse_deal.odin -file {{norn}} {{dds}} -o:speed -microarch:native -out:target/release/analyse_deal.exe
	uv run --no-project python tests/golden_sim_json.py

# delete build artifacts
clean:
	rm -rf target
	just mktarget_dirs
