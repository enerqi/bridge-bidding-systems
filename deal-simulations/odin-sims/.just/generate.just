# Convenience wrappers over `sim` / `sim-norebuild` (the root justfile reaches them as a module, e.g.
# `just sims gen-all 48`). Shares the justfile's namespace: `deals_output_dir` / `scratch_dir` come from there.
#
# NAMING: gen-all = every registered scenario, gen-some = a named subset, gen-one = one scenario.
# Suffixes stack in this order: [-cards][-dd], then -norebuild to reuse the last release build.
#
# BATCH -> <DIR>/<scenario>.html, DIR defaulting to deals_output_dir.
# SINGLE -> <DIR>/<SCENARIO>.html, DIR defaulting to scratch_dir (where you invoked just).
# -dd adds the per-scenario double-dummy annotate/filter (DD scenarios export serially - the solver is
# not reentrant). -cards swaps the BBO iframe pages for self-rendered offline card carousels.

# generate ALL scenarios (COUNT deals each) -> DIR/<scenario>.html
[group('generate')]
gen-all COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}}

# generate ALL scenarios WITH double-dummy annotations -> DIR/<scenario>.html
[group('generate')]
gen-all-dd COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --dd

# generate ALL scenarios as offline card carousels -> DIR/<scenario>.html
[group('generate')]
gen-all-cards COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --format html-cards

# generate ALL scenarios as offline card carousels WITH double-dummy par captions
[group('generate')]
gen-all-cards-dd COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --format html-cards --dd

# generate ALL scenarios WITHOUT recompiling (reuses the last release build)
[group('generate')]
gen-all-norebuild COUNT="48" DIR=deals_output_dir:
	just sim-norebuild --html-dir {{DIR}} --count {{COUNT}}

# generate a SUBSET; NAMES is comma-separated, e.g. `just gen-some 1c-any,2c-opener 100`
[group('generate')]
gen-some NAMES COUNT="48" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --scenario {{NAMES}} --count {{COUNT}}

# COUNT deals for ONE scenario -> DIR/<SCENARIO>.html
[group('generate')]
gen-one SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario WITH double-dummy annotations -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-dd SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html --dd

# COUNT deals for ONE scenario as an offline card carousel -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-cards SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario as an offline card carousel with double-dummy par -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-cards-dd SCENARIO COUNT="48" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html --dd

# COUNT deals for ONE scenario WITHOUT recompiling -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-norebuild SCENARIO COUNT="48" DIR=scratch_dir:
	just sim-norebuild --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.html

# list the scenarios compiled into the sim
[group('generate')]
scenarios:
	just sim-debug --list
