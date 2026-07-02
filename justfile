# Guide for Just *task* runner
# Not specifically a build tool (e.g file resource to file resource build graph like Make)
# https://just.systems/man/en/chapter_20.html
set shell := ["nu", "-c"]

deals_output_dir := "w:/deals/"

# alias for typing `just w`
alias w := watch

# bml doc creation via doit when relevant files change
watch:
    watchexec --no-global-ignore --exts bml,css uv run doit


# regenerate all deal simulations via the norn engine. Output html to deals_output_dir. COUNT deals per scenario.
[script("nu")]
regen-norn COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --html-dir {{deals_output_dir}} --count {{COUNT}}

# --dd variant of regen-norn: per-scenario double-dummy annotate/filter (scenarios registered in
# sim.odin). DD scenarios export serially (solver isn't reentrant); the rest still pool.
# ---
# regenerate all deal simulations with double-dummy annotations. COUNT deals per scenario.
[script("nu")]
regen-norn-dd COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --html-dir {{deals_output_dir}} --count {{COUNT}} --dd

# card-carousel variant of regen-norn: self-rendered, offline HTML (no BBO iframe) — every scenario
# is one page with a prev/next carousel of text-compass diagrams, a seat toggle, and a par toggle.
# Add --dd (as regen-norn-cards-dd) for the par-score caption on scenarios that register an annotator.
# ---
# regenerate all deal simulations as offline card carousels. COUNT deals per scenario.
[script("nu")]
regen-norn-cards COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --html-dir {{deals_output_dir}} --count {{COUNT}} --format html-cards

# regenerate all deal simulations as offline card carousels WITH double-dummy par captions. COUNT deals per scenario.
[script("nu")]
regen-norn-cards-dd COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --html-dir {{deals_output_dir}} --count {{COUNT}} --format html-cards --dd

# regenerate all deal simulations without recompiling for any changes within odin-sims. Output html to deals_output_dir. COUNT deals per scenario.
[script("nu")]
rerun-regen-norn COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just rerun --html-dir {{deals_output_dir}} --count {{COUNT}}

# regenerate a subset via the norn engine. NAMES is comma-separated (e.g. 1c-any,2c-opener). e.g. `just regen-norn-some 1c-any,2c-opener 100`
[script("nu")]
regen-norn-some NAMES COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --html-dir {{deals_output_dir}} --scenario {{NAMES}} --count {{COUNT}}

# norn equivalent of py-run-scratch: generate COUNT deals for one SCENARIO via the norn engine. Output to current dir as <SCENARIO>.html
[script("nu")]
run-norn SCENARIO COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{justfile_directory()}}/{{SCENARIO}}.html

# --dd variant of run-norn: double-dummy annotate/filter for SCENARIO (if registered in sim.odin).
# ---
# generate COUNT deals for one SCENARIO with double-dummy annotations -> <SCENARIO>.html
[script("nu")]
run-norn-dd SCENARIO COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{justfile_directory()}}/{{SCENARIO}}.html --dd

# card-carousel variant of run-norn: one SCENARIO as a self-rendered offline card carousel. Add --dd
# (run-norn-cards-dd) for par captions if the scenario registers an annotator in sim.odin.
# ---
# generate COUNT deals for one SCENARIO as an offline card carousel -> <SCENARIO>.html
[script("nu")]
run-norn-cards SCENARIO COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{justfile_directory()}}/{{SCENARIO}}.html

# generate COUNT deals for one SCENARIO as an offline card carousel with double-dummy par -> <SCENARIO>.html
[script("nu")]
run-norn-cards-dd SCENARIO COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{justfile_directory()}}/{{SCENARIO}}.html --dd

# norn equivalent of py-run-scratch: generate COUNT deals for one SCENARIO via the norn engine. Output to current dir as <SCENARIO>.html
[script("nu")]
rerun-norn SCENARIO COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just rerun --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{justfile_directory()}}/{{SCENARIO}}.html

# list the available scenarios as compiled into the odin-sims
[script("nu")]
list-scenarios:
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run_debug --list

# raw sim program access, freshly built
[script("nu")]
sim *args:
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run {{args}}

# raw sim program access, rerun last compiled version
[script("nu")]
resim *args:
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just rerun {{args}}

# serve quiz app in dev mode
quiz:
    uv run panel serve quiz_app.py --dev

# copy quiz app files to deployment folder
deploy-quiz:
    #!nu
    let dest = 'X:/quiz-u16/'
    glob '*.bml' | each {|file| cp $file $dest }
    glob '*.py' | each {|file| cp $file $dest }
    glob '*.jpeg' | each {|file| cp $file $dest }
    cp pyproject.toml $dest
    cp uv.lock $dest


#
# Legacy tcl deal.exe + tcl script handling
#

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
