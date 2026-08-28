# Editor setup, imported by the justfile. One-off project setup rather than part of the build/test loop.
# Shares one namespace with the justfile, so `norn_home` / `dds_home` / `markup_home` resolve from there.

# ols.json is machine-specific (absolute paths) and gitignored - regenerate after cloning or when
# NORN_HOME / DDS_HOME / MARKUP_HOME change:
#     NORN_HOME=/path/to/norn DDS_HOME=/path/to/odin-dds just ols-config
#
# Read before write: ols.json also holds editor settings (checker_path, odin_command, ...) and only the
# collection list is ours to rewrite.
# ---
# (re)generate ols.json so the editor's language server resolves the `norn:`, `dds:` and `markup:` collections
[group('editor')]
[script]
ols-config:
	import json, os, sys

	config = {}
	if os.path.exists("ols.json"):
		with open("ols.json", encoding="utf-8") as f:
			try:
				config = json.load(f)
			except ValueError as err:
				sys.exit("ols.json is not valid JSON - fix or delete it first: " + str(err))
		if not isinstance(config, dict):
			sys.exit("ols.json does not hold a JSON object - fix or delete it first")

	config.setdefault(
		"$schema", "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json"
	)
	config["collections"] = [
		{"name": "norn", "path": r"{{norn_home}}"},
		{"name": "dds", "path": r"{{dds_home}}"},
		{"name": "markup", "path": r"{{markup_home}}"},
	]
	with open("ols.json", "w", encoding="utf-8", newline="\n") as f:
		f.write(json.dumps(config, indent=4) + "\n")
	print("wrote ols.json -> norn collection at {{norn_home}}, dds at {{dds_home}}, markup at {{markup_home}}")
