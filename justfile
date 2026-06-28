# Guide for Just *task* runner
# Not specifically a build tool (e.g file resource to file resource build graph like Make)
# https://just.systems/man/en/chapter_20.html

# set shell := ["powershell.exe", "-c"]
# set shell := ["cmd.exe", "/c"]
# set shell := ["zsh", "-cu"]
set shell := ["nu", "-c"]

# variables etc
# mytmpdir := `mktemp -d`
# blah := "x.y.z"
# stuffpath := mytmpdir / "foo" + blah
# foo := if "hello" != "goodbye" { "xyz" } else { "abc" }

# .env for env vars
# set dotenv-load

#  Examples
# https://github.com/casey/just/blob/master/justfile
# https://github.com/casey/just/tree/master/examples

# default recipe (first in the file)
# default:
#   just --list

# env var export
# export RUST_BACKTRACE := "1"
# or just prefix var with $
# test $RUST_BACKTRACE="1":
#     ...

# using different languages with #!
# python:
#   #!/usr/bin/env python3
#   print('Hello from python!')

# alias for typing `just w`
alias w := watch

# bml doc creation via doit when relevant files change
watch:
    watchexec --no-global-ignore --exts bml,css uv run doit

# regenerate all deal simulations. Output html to web server
[script("nu")]
regen:
    cd {{justfile_directory()}}/deal-simulations
    uv run regen-html-deals.py w:/deals/

# regenerate all deal simulations via the norn engine (native, no deal.exe). Output html to
# deal-simulations/html. COUNT deals per scenario (default 48).
[script("nu")]
regen-norn COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --html-dir {{justfile_directory()}}/deal-simulations/html --count {{COUNT}}

# regenerate a subset via the norn engine. NAMES is comma-separated (e.g. 1c-any,2c-opener). Output
# html to deal-simulations/html. e.g. `just regen-norn-some 1c-any,2c-opener 100`
[script("nu")]
regen-norn-some NAMES COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --html-dir {{justfile_directory()}}/deal-simulations/html --scenario {{NAMES}} --count {{COUNT}}

# generate 48 deals for TCL_SCRIPT (a filename in deal-simulations/tcl-sims). Output to current dir as html.
[script("nu")]
run-scratch TCL_SCRIPT:
    cd {{justfile_directory()}}/deal-simulations
    uv run run-deal.py --deal-count 48 --deal-script-path {{justfile_directory()}}/deal-simulations/tcl-sims/{{TCL_SCRIPT}} --html-output-path {{justfile_directory()}}/{{TCL_SCRIPT}}.html

# norn equivalent of run-scratch: generate COUNT deals for one SCENARIO via the norn engine. Output
# to current dir as <SCENARIO>.html.
[script("nu")]
run-norn SCENARIO COUNT="48":
    cd {{justfile_directory()}}/deal-simulations/odin-sims
    just run --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{justfile_directory()}}/{{SCENARIO}}.html

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
