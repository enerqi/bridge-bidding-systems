# The single-deal advisor and the hand-OCR bridge, imported by the justfile.

# Read a deal and print the combo analysis (double-dummy census + achievable single-dummy) for the known
# partnership. The deal may be a PBN [Deal] tag / bare N:... value, a bridge-site hand URL (BBO or
# IntoBridge `...?lin=...`), or a bare LIN `md|...` record. `--sample <deals>` adds the DDS-sampling
# whole-hand make-% verdict; `--contract 4H` is OPTIONAL (best contract auto-picked); `--html <out>`
# writes the interactive card page.
#
# The DEAL comes FIRST; optional flags follow. Single-quote the deal so YOUR shell hands it to just in
# one piece - a LIN URL's `|`, `!`, `%` and bare-PBN spaces all need it.
# e.g. just analyse-deal 'https://play.intobridge.com/hand?lin=...'
# e.g. just analyse-deal 'N:... - ... -' --sample 400 --contract 3NT --html out.html
#
# `[script]`, and it BUILDS then RUNS the exe rather than using `odin run`: just's `quote()` emits POSIX
# quoting cmd.exe does not understand, whereas python's `subprocess` takes an argv list and spawns no
# shell; and `odin run` re-spawns the exe, whose Windows MSVCRT argument re-parse strips the literal
# double quotes out of the `[Deal "..."]` form. `--file <path>` / stdin want the exe directly:
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
# hands. A real image needs hand-ocr's vision extra there: (cd "$HAND_OCR_DIR" && just sync-vision).
# <image> may be `--clipboard` to read straight from the OS clipboard (screenshot, no temp file).
# e.g. `just ocr-pbn hand.png --first E` ; `just ocr-pbn --clipboard`
# ---
# OCR a bridge hand-diagram IMAGE to a PBN [Deal] tag, printed to stdout
[group('analyse')]
ocr-pbn image *args:
	uv run --project {{HAND_OCR_DIR}} python {{HAND_OCR_DIR}}/hand-ocr.py {{image}} --format pbn {{args}}

# image -> PBN -> analyse_deal with the DDS-sampling advisor + CCA/DD features. Writes
# <image-basename>.html (override with --html); samples 400 deals (override with --sample). Extra flags
# pass through to analyse_deal (e.g. --contract 3NT). `--demo` runs hand-ocr's sample deal end to end
# (plumbing check, no vision deps needed); <image> may be `--clipboard`.
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
