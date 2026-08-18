# Guide for Just *task* runner
# Not specifically a build tool (e.g file resource to file resource build graph like Make)
# https://just.systems/man/en/chapter_20.html
set shell := ["nu", "-c"]
set unstable  # [script] recipes - https://github.com/casey/just/issues/1479

# Bare `[script]` recipes run under this; `[script("nu")]` names its own interpreter and is unaffected.
# `python` alone is not a reliable cross-platform lookup (python/python3/python3.x); uv resolves and
# downloads on every platform, and --no-project keeps it off this repo's venv - bml2html.py and its
# `bml` module are stdlib-only, so the build needs no project dependencies at all.
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]

bml_home := env_var_or_default("BML_TOOLS_DIRECTORY", replace(home_directory(), "\\", "/") + "/dev/bml")


# The deal-simulation recipes live in the odin-sims justfile (it owns the build flags and the output
# directory defaults), reached from here as a module: `just sims gen-all 48`, `just sims gen-one 2c-opener`,
# `just sims scenarios`, `just sims sim --scenario 1c-any -n 12`, ... (`just --list sims` lists them all).
# Batch output goes to DEALS_OUTPUT_DIR (default w:/deals/); single-scenario output to the directory
# just was invoked from. Both are also trailing recipe arguments.

# deal simulations (odin/norn engine): regen, regen-cards, deal, scenarios, run, test, ...
[group('modules')]
mod sims 'deal-simulations/odin-sims'

#
# BML -> HTML. This used to be a `doit` build (dodo.py, a .doit.db of file hashes and a
# .include-deps.json cache of every file's `#INCLUDE` directives) and is now an unconditional rebuild,
# because the dependency tracking cost more than the work it was skipping. Measured, 19 .bml files:
#
#     doit, everything already up to date (no-op) ... 2.68s
#     doit -a, forced rebuild of all 46 tasks ....... 2.54s
#     this recipe, all 19 rebuilt in parallel ....... 0.41s
#
# Only ONE file in the corpus has `#INCLUDE` directives (bidding-system.bml, 13 of them), so the
# include cache existed to produce 18 empty lists -- and it could not be a doit `file_dep` anyway,
# being one shared file rewritten by unrelated .bml edits, which is why dodo.py depended on task
# ORDER instead. All of that is gone.
#
# What is deliberately NOT rebuilt conditionally, and why each still needs a guard:
#   - bml.css is copied only when it differs, because `watch` fires on .css writes too and an
#     unconditional copy into the watched directory would retrigger the build forever.
#   - `publish` skips unchanged files, because W: is the web-server volume and that is the one copy
#     here whose cost is not local disk.
#

# The web-server volume dodo.py hard-coded as W:/. Overridable so a dry run can target a scratch dir.
web_root := env_var_or_default("BML_PUBLISH_DIR", "w:/")

# alias for typing `just w`
alias w := watch

# Rebuilds and republishes on every save, as the doit loop did. `just bml` alone if W: is not mounted.
# ---
# rebuild (and publish) the bml docs whenever a .bml or .css file changes
[group('bml')]
watch:
    watchexec --no-global-ignore --exts bml,css just publish

# FILES defaults to every *.bml; name a subset to convert just those, e.g. `just bml nt-bidding.bml`.
# One subprocess per file because `bml` accumulates module-global state (`bml.content` / `bml.meta`)
# across `content_from_file`, so a single process cannot safely convert several documents.
# ---
# convert *.bml -> *.html (in parallel) and refresh bml.css from the bml tools directory
[group('bml')]
[script]
bml *FILES:
    import os, subprocess, sys, time
    from concurrent.futures import ThreadPoolExecutor
    from glob import glob
    from shutil import copy2

    tools = r"{{bml_home}}"
    bml2html = os.path.join(tools, "bml2html.py")
    if not os.path.isfile(bml2html):
    	sys.exit("no bml2html.py under " + tools + " - clone enerqi/bml or set BML_TOOLS_DIRECTORY")

    files = r"""{{FILES}}""".split() or sorted(glob("*.bml"))
    missing = [f for f in files if not os.path.isfile(f)]
    if missing:
    	sys.exit("no such bml file: " + ", ".join(missing))

    # Subprocesses, so the pool is not fighting the GIL for anything that matters.
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=min(16, os.cpu_count() or 4)) as pool:
    	codes = list(pool.map(lambda f: subprocess.run([sys.executable, bml2html, f]).returncode, files))
    failed = [f for f, code in zip(files, codes) if code != 0]
    if failed:
    	sys.exit("bml2html failed for: " + ", ".join(failed))

    # CONTENT, not mtime: this build rewrites every output unconditionally, so an mtime comparison
    # would always say "newer" and the guard would never hold.
    def same_bytes(a, b):
    	if not os.path.exists(b) or os.path.getsize(a) != os.path.getsize(b):
    		return False
    	with open(a, "rb") as fa, open(b, "rb") as fb:
    		return fa.read() == fb.read()

    css = "bml.css"
    source = os.path.join(tools, css)
    if os.path.isfile(source) and not same_bytes(source, css):
    	copy2(source, css)
    	print("refreshed " + css)

    print("built %d html in %.2fs" % (len(files), time.perf_counter() - started))

# The published set is a hand-picked subset of the corpus, not every root document.
# ---
# copy the published documents + bml.css to the web-server volume (default w:/, else BML_PUBLISH_DIR)
[group('bml')]
[script]
publish DEST=web_root: bml
    import os, sys
    from shutil import copy2

    PUBLISHED = [
    	"bidding-system.html",
    	"scanian-natural.html",
    	"squad-system.html",
    	"youth-improvements.html",
    	"alternatives.html",
    	"weak-strong-club.bboalert",
    	"bml.css",
    ]

    dest = r"{{DEST}}"
    if not os.path.isdir(dest):
    	sys.exit(dest + " is not mounted - `just bml` builds without publishing")

    # CONTENT, not mtime: `bml` rewrites every .html on every run, so by mtime everything would always
    # look newer and the whole set would cross the wire on each save. Reading the local copy back is
    # far cheaper than writing to W: needlessly.
    def same_bytes(a, b):
    	if not os.path.exists(b) or os.path.getsize(a) != os.path.getsize(b):
    		return False
    	with open(a, "rb") as fa, open(b, "rb") as fb:
    		return fa.read() == fb.read()

    copied = 0
    for name in PUBLISHED:
    	if not os.path.isfile(name):
    		sys.exit("nothing to publish at " + name + " - run `just bml` first")
    	target = os.path.join(dest, name)
    	if same_bytes(name, target):
    		continue
    	copy2(name, target)
    	copied += 1
    	print("published " + name)

    print("%d of %d files copied to %s" % (copied, len(PUBLISHED), dest))

# Only the .html beside a .bml of the same name, plus the copied bml.css -- never the whole *.html
# glob, which would also take hand-authored pages that no .bml generates.
# ---
# delete the generated html and the copied bml.css
[group('bml')]
[script]
bml-clean:
    import os
    from glob import glob

    removed = 0
    for path in [os.path.splitext(f)[0] + ".html" for f in sorted(glob("*.bml"))] + ["bml.css"]:
    	if os.path.exists(path):
    		os.remove(path)
    		removed += 1
    print("removed %d generated file(s)" % removed)

#
# Python apps (apps/<app>/). Served from the repo root so the .bml corpus beside this justfile is
# what the quiz reads; quiz.py resolves the corpus from its own location, not the cwd.
#

# serve quiz app in dev mode
[group('apps')]
quiz:
    uv run panel serve apps/quiz/quiz_app.py --dev

# serve quiz app in dev mode with OpenTelemetry tracing (see apps/quiz/run-jaeger-tracing.cmd)
[group('apps')]
quiz-traced:
    uv run panel serve apps/quiz/quiz_app.py --dev --setup apps/quiz/quiz_app_telemetry_setup.py

# run the quiz app python tests
[group('apps')]
quiz-test *args:
    uv run --with pytest pytest apps/quiz/tests {{args}}

# serve the optimal point count app in dev mode
[group('apps')]
opc:
    uv run panel serve apps/optimal-point-count/optimal_point_count_app.py --dev

# The datastar/litestar port of the quiz owns its own justfile (and its own uv project, so litestar
# stays out of this repo's lock), reached from here as a module: `just dsquiz serve` (granian, port
# 5008, alongside `just quiz` on 5006), `just dsquiz qa`, `just dsquiz test`,
# `just dsquiz serve-streamed` for the held-SSE timer variant. `just --list dsquiz` lists them all.
#
# It deploys itself too -- `just dsquiz deploy` (-> X:/quiz-ds/), NOT `deploy-quiz` below: that port
# needs the repo's directory layout rather than one flat directory, because it imports apps/quiz and
# serves an asset from there. apps/datastar-quiz/DEPLOY.md is the walkthrough.

# datastar quiz port (litestar + uvicorn/granian): serve, deploy, test, qa, routes, ...
[group('modules')]
mod dsquiz 'apps/datastar-quiz'

# copy PANEL quiz app files to deployment folder (flattened: app + bml corpus in one directory)
[group('apps')]
deploy-quiz:
    #!nu
    let dest = 'X:/quiz-u16/'
    glob '*.bml' | each {|file| cp $file $dest }
    glob 'apps/quiz/*.py' | each {|file| cp $file $dest }
    glob 'apps/quiz/*.jpeg' | each {|file| cp $file $dest }
    glob 'apps/quiz/*_topics.toml' | each {|file| cp $file $dest }
    cp pyproject.toml $dest
    cp uv.lock $dest
    let bml_dest = ($dest | path join 'bml')
    mkdir $bml_dest
    glob {{bml_home}}/*.py | each {|file| cp $file $bml_dest }


#
# Legacy tcl deal.exe + tcl script handling
#

deals_output_dir := env_var_or_default("DEALS_OUTPUT_DIR", "w:/deals/")

# regenerate all deal simulations. Output html to web server
[group('legacy')]
[script("nu")]
_py-regen:
    cd {{justfile_directory()}}/deal-simulations/tcl-sims
    uv run regen-html-deals.py {{deals_output_dir}}

# generate 48 deals for TCL_SCRIPT (a filename in deal-simulations/tcl-sims). Output to current dir as html.
[group('legacy')]
[script("nu")]
_py-run-scratch TCL_SCRIPT:
    cd {{justfile_directory()}}/deal-simulations/tcl-sims
    uv run run-deal.py --deal-count 48 --deal-script-path {{justfile_directory()}}/deal-simulations/tcl-sims/{{TCL_SCRIPT}} --html-output-path {{justfile_directory()}}/{{TCL_SCRIPT}}.html
