set windows-shell := ["nu", "-c"]
set shell := ["bash", "-c"]

# This project is a CONSUMER of the norn library: norn provides the hand-generation engine
# (`norn:norn`) and the reusable scenario CLI framework (`norn:cli`); everything here (conditions/,
# scenarios/, sim/, parity/) is this specific bidding system. norn is referenced as an Odin
# collection.
#
# `norn_home` is the single source of truth for where the norn checkout lives: the NORN_HOME
# environment variable if set, else `<home>/dev/norn` (just's `home_directory()` is cross-platform;
# `replace` normalises Windows backslashes to the forward slashes Odin wants). It feeds BOTH the
# `-collection` build flag AND the generated ols.json (see the `ols-config` recipe) — so the
# machine-specific path is set in exactly one place, and ols.json — which has no env-var expansion of
# its own — is regenerated from it rather than hand-edited.
norn_home := env_var_or_default("NORN_HOME", replace(home_directory(), "\\", "/") + "/dev/norn")
norn := "-collection:norn=" + norn_home
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

# ols.json is machine-specific (an absolute path) and gitignored — regenerate it after
# cloning or when NORN_HOME changes:  NORN_HOME=/path/to/norn just ols-config
#
# (re)generate ols.json from norn_home so the editor's Odin language server resolves the `norn:` collection.
[script("python")]
ols-config:
	import json
	config = {
		"$schema": "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json",
		"collections": [{"name": "norn", "path": r"{{norn_home}}"}],
	}
	with open("ols.json", "w") as f:
		f.write(json.dumps(config, indent=4) + "\n")
	print("wrote ols.json -> norn collection at {{norn_home}}")

# odinfmt every .odin file under this directory (odinfmt walks subdirs itself)
format:
	odinfmt -w .

# lint the library package + the single-file programs (the library needs -no-entry-point)
lint *args:
	odin check bidding {{norn}} -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check sim.odin -file {{norn}} -vet -vet-cast -strict-style {{args}}
	odin check parity.odin -file {{norn}} -vet -vet-cast -strict-style {{args}}

# run the deal generator (release). Pass CLI args through, e.g. `just run --scenario 1c-any -n 12`.
run *args: mktarget_dirs
	odin run sim.odin -file {{norn}} -keep-executable -o:speed -microarch:native -out:target/release/{{sim_name}} -- {{args}}

# rerun the deal generator (release) without recompiling. Pass CLI args through, e.g. `just run --scenario 1c-any -n 12`.
rerun *args: mktarget_dirs
	target/release/{{sim_name}} {{args}}

run_debug *args: mktarget_dirs
	odin run sim.odin -file {{norn}} -microarch:native -out:target/debug/{{sim_name}} -- {{args}}

# build the sim deal generator (release)
build *args: mktarget_dirs
	odin build sim.odin -file {{norn}} -o:speed -microarch:native -out:target/release/{{sim_name}} {{args}}

# Frequency test every scenario by default, or pass `-S name[,name]` to restrict the subset.
# e.g. `just freq` (1M, -all), `just freq 5000000`, `just freq 1000000 -S 1c-any,2c-opener`.
#
# measure each scenario's acceptance frequency over N deals (no deals emitted)
freq trials="1000000" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} -o:speed -microarch:native -out:target/release/{{sim_name}} -- --frequency {{trials}} {{args}}

# run the bidding-system unit tests
test *args: mktarget_dirs
	odin test bidding {{norn}} -debug -file -microarch:native -show-timings -out:target/debug/test-bidding.exe {{args}}

# build the parity candidate generator (see parity.tcl for the deal.exe side)
parity *args: mktarget_dirs
	odin run parity.odin -file {{norn}} -o:speed -out:target/release/parity.exe {{args}}

# delete build artifacts
clean:
	rm -rf target
	just mktarget_dirs
