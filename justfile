# Guide for Just *task* runner
# Not specifically a build tool (e.g file resource to file resource build graph like Make)
# https://just.systems/man/en/chapter_20.html
set shell := ["nu", "-c"]

bml_home := env_var_or_default("BML_TOOLS_DIRECTORY", replace(home_directory(), "\\", "/") + "/dev/bml")


# The deal-simulation recipes live in the odin-sims justfile (it owns the build flags and the output
# directory defaults), reached from here as a module: `just sims gen-all 48`, `just sims gen-one 2c-opener`,
# `just sims scenarios`, `just sims sim --scenario 1c-any -n 12`, ... (`just --list sims` lists them all).
# Batch output goes to DEALS_OUTPUT_DIR (default w:/deals/); single-scenario output to the directory
# just was invoked from. Both are also trailing recipe arguments.

# deal simulations (odin/norn engine): regen, regen-cards, deal, scenarios, run, test, ...
mod sims 'deal-simulations/odin-sims'

# alias for typing `just w`
alias w := watch

# bml doc creation via doit when relevant files change
watch:
    watchexec --no-global-ignore --exts bml,css uv run doit

#
# Python apps (apps/<app>/). Served from the repo root so the .bml corpus beside this justfile is
# what the quiz reads; quiz.py resolves the corpus from its own location, not the cwd.
#

# serve quiz app in dev mode
quiz:
    uv run panel serve apps/quiz/quiz_app.py --dev

# serve quiz app in dev mode with OpenTelemetry tracing (see apps/quiz/run-jaeger-tracing.cmd)
quiz-traced:
    uv run panel serve apps/quiz/quiz_app.py --dev --setup apps/quiz/quiz_app_telemetry_setup.py

# run the quiz app python tests
quiz-test *args:
    uv run --with pytest pytest apps/quiz/tests {{args}}

# serve the optimal point count app in dev mode
opc:
    uv run panel serve apps/optimal-point-count/optimal_point_count_app.py --dev

# copy quiz app files to deployment folder (flattened: app + bml corpus in one directory)
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
[script("nu")]
_py-regen:
    cd {{justfile_directory()}}/deal-simulations/tcl-sims
    uv run regen-html-deals.py {{deals_output_dir}}

# generate 48 deals for TCL_SCRIPT (a filename in deal-simulations/tcl-sims). Output to current dir as html.
[script("nu")]
_py-run-scratch TCL_SCRIPT:
    cd {{justfile_directory()}}/deal-simulations/tcl-sims
    uv run run-deal.py --deal-count 48 --deal-script-path {{justfile_directory()}}/deal-simulations/tcl-sims/{{TCL_SCRIPT}} --html-output-path {{justfile_directory()}}/{{TCL_SCRIPT}}.html
