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
regen:
    cd {{justfile_directory()}}/deal-simulations; uv run regen-html-deals.py w:/deals/

# generate 48 deals for TCL_SCRIPT. Output to current dir as html.
run-scratch TCL_SCRIPT:
    cd {{justfile_directory()}}/deal-simulations; uv run run-deal.py --deal-count 48 --deal-script-path {{justfile_directory()}}/deal-simulations/{{TCL_SCRIPT}} --html-output-path {{justfile_directory()}}/{{TCL_SCRIPT}}.html

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
