set windows-shell := ["nu", "-c"]
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
# only by the local `dd` package (the norn->DDS boundary). DDS_HOME overrides the default checkout
# location, mirroring norn_home. Its lib/dds.lib (Windows) / lib/dds.a (Unix) must be built first —
# see odin-dds `just build-lib`.
dds_home := env_var_or_default("DDS_HOME", replace(home_directory(), "\\", "/") + "/dev/odin-dds")
dds := "-collection:dds=" + dds_home
sim_name := "sim.exe"

# ensure the build artifacts directory exists
[unix]
@mktarget_dirs:
	-mkdir -p target/debug
	-mkdir -p target/release

[windows]
@mktarget_dirs:
	-mkdir target/debug
	-mkdir target/release

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

# lints the two library packages (`bidding`, `dd`) with -no-entry-point and the `sim.odin` single-file
# program; `dd` and `sim` pull in the `dds` collection (the DDS boundary), `bidding` does not.
# ---
# type check + vet + strict style (bidding, combo, dd, sim.odin). `combo` (the naive card-combination
# analyser) is solver-free like `bidding`, so it needs only the norn collection.
lint *args:
	odin check bidding {{norn}} -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check combo {{norn}} -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check dd {{norn}} {{dds}} -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check sim.odin -file {{norn}} {{dds}} -vet -vet-cast -strict-style {{args}}

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

# Frequency test every scenario by default, or pass `-S name[,name]` to restrict the subset.
# e.g. `just freq` (1M, -all), `just freq 5000000`, `just freq 1000000 -S 1c-any,2c-opener`.
# With --dd the rate also counts each scenario's double-dummy filter (filtered scenarios run serially).
# ---
# measure each scenario's acceptance frequency over N deals (no deals emitted)
freq trials="1000000" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -o:speed -microarch:native -out:target/release/{{sim_name}} -- --frequency {{trials}} {{args}}

# run the bidding-system unit tests
test *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -out:target/debug/test-bidding.exe {{args}}

# run the card-combination analyser unit tests
test-combo *args: mktarget_dirs
	odin test combo {{norn}} -debug -microarch:native -show-timings -out:target/debug/test-combo.exe {{args}}

# delete build artifacts
clean:
	rm -rf target
	just mktarget_dirs
