# Convenience wrappers over `sim` / `sim-norebuild` (the root justfile reaches them as a module, e.g.
# `just sims gen-all 32`). Shares the justfile's namespace: `deals_output_dir` / `scratch_dir` come from there.
#
# NAMING: gen-all = every registered scenario, gen-some = a named subset, gen-one = one scenario.
# Suffixes stack in this order: [-cards][-par], then -norebuild to reuse the last release build.
#
# BATCH -> <DIR>/<scenario>.hv.html (BBO hand viewers) or <scenario>.html (-cards), DIR defaulting to deals_output_dir.
# SINGLE -> <DIR>/<SCENARIO>.hv.html or .html likewise, DIR defaulting to scratch_dir (where you invoked just).
# The two page formats have different names on purpose (the workbench's convention): with one name, a run of
# the BBO default replaced a folder of card pages.
# -par solves every deal and captions it with its par (those scenarios export serially - the solver is
# not reentrant). A scenario's OWN double-dummy check (`slam-makes-dd`, a file's `double-dummy:` line)
# always applies, with or without it. -cards swaps the BBO iframe pages for self-rendered offline card carousels.

# generate ALL scenarios (COUNT deals each) as BBO hand-viewer pages -> DIR/<scenario>.hv.html
[group('generate')]
gen-all COUNT="32" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}}

# generate ALL scenarios as BBO hand-viewer pages WITH a double-dummy par caption -> DIR/<scenario>.hv.html
[group('generate')]
gen-all-par COUNT="32" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --par

# generate ALL scenarios as offline card carousels -> DIR/<scenario>.html
[group('generate')]
gen-all-cards COUNT="32" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --format html-cards

# generate ALL scenarios as offline card carousels WITH double-dummy par captions -> DIR/<scenario>.html
[group('generate')]
gen-all-cards-par COUNT="32" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --count {{COUNT}} --format html-cards --par

# generate ALL scenarios WITHOUT recompiling (reuses the last release build)
[group('generate')]
gen-all-norebuild COUNT="32" DIR=deals_output_dir:
	just sim-norebuild --html-dir {{DIR}} --count {{COUNT}}

# generate a SUBSET; NAMES is comma-separated, e.g. `just gen-some 1c-any,2c-opener 100`
[group('generate')]
gen-some NAMES COUNT="32" DIR=deals_output_dir:
	just sim --html-dir {{DIR}} --scenario {{NAMES}} --count {{COUNT}}

# COUNT deals for ONE scenario as BBO hand viewers -> DIR/<SCENARIO>.hv.html
[group('generate')]
gen-one SCENARIO COUNT="32" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.hv.html

# COUNT deals for ONE scenario as BBO hand viewers WITH a double-dummy par caption -> DIR/<SCENARIO>.hv.html
[group('generate')]
gen-one-par SCENARIO COUNT="32" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.hv.html --par

# COUNT deals for ONE scenario as an offline card carousel -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-cards SCENARIO COUNT="32" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html

# COUNT deals for ONE scenario as an offline card carousel with double-dummy par -> DIR/<SCENARIO>.html
[group('generate')]
gen-one-cards-par SCENARIO COUNT="32" DIR=scratch_dir:
	just sim --scenario {{SCENARIO}} --count {{COUNT}} --format html-cards --output {{DIR}}/{{SCENARIO}}.html --par

# COUNT deals for ONE scenario as BBO hand viewers WITHOUT recompiling -> DIR/<SCENARIO>.hv.html
[group('generate')]
gen-one-norebuild SCENARIO COUNT="32" DIR=scratch_dir:
	just sim-norebuild --scenario {{SCENARIO}} --count {{COUNT}} --format html --output {{DIR}}/{{SCENARIO}}.hv.html

# list the scenarios compiled into the sim
[group('generate')]
scenarios:
	just sim-debug --list
