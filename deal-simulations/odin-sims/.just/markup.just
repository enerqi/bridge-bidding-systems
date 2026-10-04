# BML -> HTML, the notes build. `bml2html.odin` is a thin driver over the `bridge-markup` library
# (`markup:.`); the ROOT justfile's `bml` recipe calls the exe this builds, ONE process for the whole
# corpus where it used to spawn one `bml2html.py` per file. The python in `~/dev/bml` stays the
# reference: `just parity` THERE renders the corpus both ways and compares bytes.

# FILES defaults to every *.bml in the directory just was invoked from. `--stdout` renders one file to
# stdout untranslated (the byte stream parity compares); `--out-dir` puts the html elsewhere.
# e.g. `just bml2html nt-bidding.bml` ; `just bml2html --stdout nt-bidding.bml`
# ---
# convert .bml notes to .html (one process, one thread per file)
[group('markup')]
bml2html *args: build-bml2html
	{{ target_path("release", bml2html_name) }} {{args}}

# The root `bml` recipe builds through this and runs the exe itself from the repository root, so
# `#INCLUDE` and the output paths resolve there rather than here. It names the exe on STDERR, and only
# when it actually builds one: a `--stdout` render through `bml2html` above stays a clean byte stream,
# and the `watch` loop stays silent while nothing needs compiling.
#
# STALENESS, not an unconditional build: `just watch` runs `just publish` on every .bml/.css save and
# the odin build is 2.9s of it (LLVM code gen; Odin has no build cache) against 0.03s for the whole
# 19-file render. Odin is not a build graph, so the guard is here: rebuild when the exe is missing,
# when any source it was built from is newer than it (bml2html.odin plus every .odin in the
# `bridge-markup` collection - a package's test files are type-checked with it, so they count), or when
# the BUILD COMMAND ITSELF differs from the one recorded beside the exe (a changed linker, collection
# path or optimisation flag has to force a rebuild the way a changed source does).
#
# mtime here, CONTENT hashing for the html/css copies in the root justfile - opposite choices for
# opposite reasons: those outputs are rewritten unconditionally so their mtimes are meaningless, while
# these inputs are only written when edited, so an mtime is both true and free.
# ---
# build bml2html.exe if its sources changed (for the root justfile's bml/publish recipes)
[group('markup')]
[script]
build-bml2html: mktarget_dirs
	import os, subprocess, sys
	from glob import glob

	exe = os.path.normpath(r"""{{ target_path("release", bml2html_name) }}""")
	command = [
		"odin", "build", "bml2html.odin", "-file", r"""{{markup}}""",
		"-o:speed", "-linker:{{linker}}", "-out:" + exe,
	]
	stamp = os.path.splitext(exe)[0] + ".stamp"
	record = "\n".join(command)

	def stale():
		if not os.path.isfile(exe):
			return "not built yet"
		try:
			if open(stamp, encoding="utf-8").read() != record:
				return "build command changed"
		except OSError:
			return "no build stamp"
		built = os.path.getmtime(exe)
		sources = ["bml2html.odin"] + glob(os.path.join(r"""{{markup_home}}""", "*.odin"))
		newer = [s for s in sources if os.path.getmtime(s) > built]
		return os.path.basename(newer[0]) + " is newer" if newer else ""

	why = stale()
	if why:
		print("building " + exe + " (" + why + ")", file=sys.stderr)
		if subprocess.run(command).returncode != 0:
			sys.exit("bml2html build failed")
		# AFTER the build, so an interrupted or failed one leaves the stamp saying "rebuild me".
		with open(stamp, "w", encoding="utf-8") as f:
			f.write(record)
		print(exe, file=sys.stderr)
