# Editor setup recipes, pulled in by the project justfile's `import '.just/editor.just'`.
#
# Installing snippets, seeding a .sublime-project and writing ols.json are one-off machine or project
# setup, not part of the build/test loop, so they live here instead of in the justfile. `just --list`
# still shows all four under `[editor]`.
#
# `sublime-lsp-init` depends on the `fetch-ols` recipe and reads `ols_bin` / `home_dir` from
# .just/toolchain.just - the three files share one namespace, so that resolves without either file
# importing the other. See the header of .just/toolchain.just.

# Cross platform: Sublime then offers them in every window. The `.sublime-project` file is
# project-local and intentionally NOT installed. Override the destination with the SUBLIME_USER_DIR
# env var if your setup is non-standard.
# ---
# install the editor snippets + build systems into Sublime Text's global `Packages/User` directory
[group('editor')]
[script]
install-sublime:
	import os, sys, shutil
	home = os.path.expanduser("~")
	override = os.environ.get("SUBLIME_USER_DIR")
	if override:
		candidates = [override]
	elif sys.platform == "win32":
		appdata = os.environ.get("APPDATA", os.path.join(home, "AppData", "Roaming"))
		candidates = [os.path.join(appdata, p, "Packages", "User") for p in ("Sublime Text", "Sublime Text 3")]
	elif sys.platform == "darwin":
		base = os.path.join(home, "Library", "Application Support")
		candidates = [os.path.join(base, p, "Packages", "User") for p in ("Sublime Text", "Sublime Text 3")]
	else:
		base = os.path.join(home, ".config")
		candidates = [os.path.join(base, p, "Packages", "User") for p in ("sublime-text", "sublime-text-3")]

	# prefer a candidate whose Sublime data dir (the `Packages` parent) already exists
	target = next((c for c in candidates if os.path.isdir(os.path.dirname(c))), None)
	if target is None:
		sys.exit(
			"could not find a Sublime Text Packages directory. Set SUBLIME_USER_DIR to your "
			"Packages/User folder and retry. Tried: " + ", ".join(candidates)
		)
	os.makedirs(target, exist_ok=True)
	for name in (
		"Odin-skeleton.sublime-snippet",
		"Just-Odin.sublime-snippet",
		"Just-Odin-lib.sublime-snippet",
		"Odin.sublime-build",
		"OdinJustTarget.sublime-build",
	):
		shutil.copy2(os.path.join(".sublime", name), os.path.join(target, name))
		print("installed " + name)
	print("-> " + target)


# Opening the project in Sublime then exposes project-local build variants (Tools -> Build System) with
# no global install. Seeds one working `just test` build plus commented-out examples to extend. Refuses
# if a build_systems entry already exists. (Excluded from the Just-Odin snippet because it contains
# literal `$file` / `$project_path` which would be parsed as snippet fields; still copied into new
# projects by `just new`.)
# ---
# add a `build_systems` stub to the project's .sublime-project
[group('editor')]
[script]
sublime-build-init:
	import glob, os, sys
	matches = glob.glob(os.path.join(".sublime", "*.sublime-project"))
	if not matches:
		sys.exit("no .sublime/*.sublime-project file found")
	if len(matches) > 1:
		sys.exit("multiple .sublime-project files found: " + ", ".join(matches))
	path = matches[0]
	with open(path, encoding="utf-8") as f:
		text = f.read()
	if "build_systems" in text:
		sys.exit(path + " already has a build_systems entry - edit it by hand")
	name = os.path.splitext(os.path.basename(path))[0]
	block = (
		'    "build_systems":\n'
		'    [\n'
		'        {\n'
		'            "name": "' + name + ' (just)",\n'
		'            "selector": "source.odin",\n'
		'            "working_dir": "$project_path/..",\n'
		'\n'
		'            // file_regex turns lines of build output into clickable error links. Odin reports\n'
		'            // diagnostics as `path(line:column) message`, so the four regex capture groups below\n'
		'            // map, in order, to (1) file path (2) line (3) column (4) message -- the order Sublime\n'
		'            // expects. A matched line becomes a link that jumps to that file/line/column; F4 and\n'
		'            // Shift+F4 step forward/back through the matches. The doubled backslashes are JSON\n'
		'            // string escaping: `\\\\(` in this file is the regex `\\(` (a literal open paren).\n'
		'            "file_regex": "^(.+)\\\\(([0-9]+):([0-9]+)\\\\) (.+)$",\n'
		'\n'
		'            // `just test` rather than `just run`: it is the one recipe both an executable and a\n'
		'            // library project have, and this is a stub to edit rather than a finished setup.\n'
		'            "shell_cmd": "just test",\n'
		'\n'
		'            // uncomment / extend; each variant appears under Tools -> Build With... Sublime expands\n'
		'            // these build variables in shell_cmd / working_dir (full list:\n'
		'            // https://www.sublimetext.com/docs/build_systems.html#variables):\n'
		'            //   $file            full path of the current file,  e.g. /home/me/proj/src/main.odin\n'
		'            //   $file_path       directory of the current file (its package dir for Odin)\n'
		'            //   $file_base_name  current file name without extension,  e.g. main\n'
		'            //   $folder          first folder open in the side bar (the project root; no project file needed)\n'
		'            //   $project_path    directory containing this .sublime-project file\n'
		'            // "variants":\n'
		'            // [\n'
		'            // (a program has run/run_release; a library has check/example/doc - keep the ones\n'
		'            //  your project actually defines)\n'
		'            //     { "name": "run",                    "shell_cmd": "just run" },\n'
		'            //     { "name": "release",                "shell_cmd": "just run_release" },\n'
		'            //     { "name": "check",                  "shell_cmd": "just check" },\n'
		'            //     { "name": "example basic",          "shell_cmd": "just example basic" },\n'
		'            //     { "name": "doc",                    "shell_cmd": "just doc" },\n'
		'            //     { "name": "lint",                   "shell_cmd": "just lint" },\n'
		'            //     { "name": "current file (run)",     "shell_cmd": "odin run \\"$file\\" -file -debug" },\n'
		'            //     { "name": "current package",        "shell_cmd": "odin build \\"$file_path\\" -debug" },\n'
		'            //     { "name": "current file -> target", "working_dir": "$folder", "shell_cmd": "odin build \\"$file\\" -file -out:target/debug/$file_base_name.exe -debug" },\n'
		'            // ],\n'
		'        },\n'
		'    ],\n'
	)
	idx = text.index("{") + 1
	text = text[:idx] + "\n" + block.rstrip("\n") + text[idx:]
	with open(path, "w", encoding="utf-8", newline="\n") as f:
		f.write(text)
	print("added build_systems stub to " + path)

# Points this project's Sublime window at the pinned ols, so the server and the formatter come from one
# release. Only `command` is overridden; the global `initializationOptions` are merged, not replaced.
# What the written path can and cannot contain: README, "Pinned tooling".
# (Excluded from the Just-Odin snippet like `sublime-build-init` - the `$home` it writes would be
# parsed as a snippet field. Still copied into new projects by `just new`.)
# ---
# point the project's Sublime LSP client at the pinned ols
[group('editor')]
[script]
sublime-lsp-init: fetch-ols
	import glob, os, sys

	matches = glob.glob(os.path.join(".sublime", "*.sublime-project"))
	if not matches:
		sys.exit("no .sublime/*.sublime-project file found")
	if len(matches) > 1:
		sys.exit("multiple .sublime-project files found: " + ", ".join(matches))
	path = matches[0]
	with open(path, encoding="utf-8") as f:
		text = f.read()
	if '"LSP"' in text:
		sys.exit(path + " already has an LSP entry - edit it by hand")

	# Forward slashes: Sublime accepts them on every platform, and a Windows path written natively would
	# need every separator escaped to survive JSON.
	server = r"{{ols_bin}}".replace("\\", "/")
	home = r"{{home_dir}}".replace("\\", "/").rstrip("/")
	if home and server.lower().startswith(home.lower() + "/"):
		server = "$home" + server[len(home):]

	block = (
		'        "LSP":\n'
		'        {\n'
		'            "odin":\n'
		'            {\n'
		'                // Replaces the `command` from Sublime\'s global LSP settings for this project\n'
		'                // only. Every other key there - `selector`, `initializationOptions` - still\n'
		'                // applies: the client merges this override into the global entry rather than\n'
		'                // replacing it. Regenerate with `just sublime-lsp-init` after bumping `ols_tag`.\n'
		'                "command": ["' + server + '"],\n'
		'            },\n'
		'        },\n'
	)

	# Textual splice rather than json.load/dump: this file carries comments and trailing commas that a
	# JSON round trip would delete, and the build_systems stub above is written the same way.
	marker = '"settings"'
	if marker in text:
		idx = text.index("{", text.index(marker)) + 1
		text = text[:idx] + "\n" + block.rstrip("\n") + text[idx:]
	else:
		idx = text.index("{") + 1
		text = text[:idx] + "\n    \"settings\":\n    {\n" + block.rstrip("\n") + "\n    },\n" + text[idx:]
	with open(path, "w", encoding="utf-8", newline="\n") as f:
		f.write(text)
	print("pointed " + path + " at " + server)


# Resolves extra collection imports (`import "xyz:pkg"`), needed only for packages outside this project.
# Each argument is `name=path` and the arguments are the whole collection list - a rerun replaces it, and
# every other setting already in ols.json is left alone. No arguments prints what is configured.
#     just ols-config xyz=../xyz-lib abc=/opt/odin/abc
#
# ols resolves a relative path against this project's root, so a collection kept as a sibling checkout
# gives an ols.json identical on every machine - drop the `ols.json` line from .gitignore and commit it.
# An absolute path is machine-specific, which is why the file is ignored by default. A leading `~` expands
# on Linux and macOS only; on Windows write the path out in full.
#
# A path containing a space cannot be passed here: just joins a variadic parameter's arguments with spaces
# before the body sees them, so no quoting survives. Edit ols.json by hand for that - the recipe reads the
# file back, so it is not an either/or.
# ---
# SKELETON: (re)generate ols.json so the Odin language server resolves extra collections
[group('editor')]
[script]
ols-config *pairs:
	import json, os, re, sys

	USAGE = "usage: just ols-config name=path [name=path ...]   e.g. just ols-config xyz=../xyz-lib"

	# str.split, not shlex.split: shlex's default POSIX mode treats a backslash as an escape and would eat
	# every separator in a Windows path (C:\odin\libs -> C:odinlibs). The space before the closing quote is
	# load-bearing - a path ending in a backslash would otherwise escape the quote and leave the string
	# unterminated. str.split() discards it again as trailing space.
	args = r'''{{pairs}} '''.split()

	# Read before write. ols.json also holds editor settings (enable_document_symbols, checker_path,
	# odin_command, ...), and only the collection list is ours to rewrite.
	config = {}
	if os.path.exists("ols.json"):
		with open("ols.json", encoding="utf-8") as f:
			try:
				config = json.load(f)
			except ValueError as err:
				sys.exit("ols.json is not valid JSON - fix or delete it first: " + str(err))
		if not isinstance(config, dict):
			sys.exit("ols.json does not hold a JSON object - fix or delete it first")

	if not args:
		configured = config.get("collections") or []
		for entry in configured:
			print(entry.get("name", "?") + " -> " + entry.get("path", "?"))
		if not configured:
			print("no collections configured")
		print(USAGE)
		sys.exit(0)

	collections = []
	seen = set()
	for arg in args:
		# partition, not split: only the first `=` separates, so a path may contain one.
		name, sep, path = arg.partition("=")
		if not sep or not name or not path:
			sys.exit("expected name=path, got " + repr(arg) + "\n" + USAGE)
		# The name is what precedes the colon in `import "xyz:pkg"`, so odin's own rule applies: it has
		# to be an identifier. Without this a typo like `b/c=d` writes a collection nothing can import.
		if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
			sys.exit("collection name " + repr(name) + " is not an identifier")
		if name in seen:
			sys.exit("collection " + repr(name) + " given twice")
		seen.add(name)
		collections.append({"name": name, "path": path})

	# Second pass so a later bad argument fails before any warning about an earlier good one.
	for entry in collections:
		if not os.path.isdir(entry["path"]):
			# Not fatal - the collection may be cloned later, and ols reads this file on startup.
			print("warning: " + entry["path"] + " is not a directory (yet)", file=sys.stderr)

	config.setdefault(
		"$schema", "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json"
	)
	config["collections"] = collections
	with open("ols.json", "w", encoding="utf-8", newline="\n") as f:
		f.write(json.dumps(config, indent=4) + "\n")
	for entry in collections:
		print("wrote ols.json -> " + entry["name"] + " collection at " + entry["path"])
