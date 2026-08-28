# Pinned-toolchain recipes, pulled in by the project justfile's `import '.just/toolchain.just'`.
#
# The `ols_tag` / `ols_sha256` pin and everything that reads or rewrites it lives here rather than in
# the justfile: it is a machine setup task, run once per checkout and then only when the pin moves, so
# it does not belong in the file you open to find `just run`. `just --list` is unaffected - an imported
# recipe keeps its `[group]` and lists exactly as it did before.
#
# Unlike the `import?` that brings in bench/bench.just, this one is NOT optional. This file ships with
# every project, so a missing one is a mistake worth an error rather than `format` and `fetch-ols`
# quietly disappearing from `just --list`.
#
# An imported justfile shares one namespace with its importer and inherits its settings - `set
# script-interpreter` in the justfile is what the `[script]` recipes below run on, and `.just/editor.just`
# can see `ols_bin` and `home_dir` from here. Recipe names must not collide across the three files.

# Suffix on a native executable, for the pinned tool paths below.
exe_ext := if os() == "windows" { ".exe" } else { "" }

# The pinned ols release; odinfmt ships inside it. Note odinfmt has no `--version` flag.
# `just bump-ols` rewrites this and the digests below. README, "Pinned tooling".
ols_tag := "dev-2026-06"

# A hash and not just a tag, so a re-cut tag is caught rather than installed. One archive per platform,
# digests published per asset; `just bump-ols` writes both lines.
ols_plat := if os() == "windows" { "x86_64-pc-windows-msvc" } else if os() == "macos" { if arch() == "aarch64" { "arm64-darwin" } else { "x86_64-darwin" } } else { if arch() == "aarch64" { "arm64-unknown-linux-gnu" } else { "x86_64-unknown-linux-gnu" } }
ols_sha256 := if ols_plat == "x86_64-pc-windows-msvc" { "08785a8ae2ef5073b9d2e27abae83a7a8000cc6503711d0a92a61e2900bddf9e" } else if ols_plat == "arm64-darwin" { "931bca3776491e7809fc5054fad1c95459c25e62af5492294b84c5950c1a5e36" } else if ols_plat == "x86_64-darwin" { "2e2d3c168ae8dc56d76574a95ebd998f7764b21d5da4dc1f4a66b1e880acbc9b" } else if ols_plat == "arm64-unknown-linux-gnu" { "423c28323223d229dea3b69bc49679dbadd6e4559dc5d6b50eb10ac708f9c9eb" } else { "d0b232947a258032979321626a54c3dba54e44ebd23be255a34eb254dfc679a3" }

# Where versioned tool installs live; `$ODIN_TOOLS` overrides the root. See README, "Pinned tooling".
# `USERPROFILE` before `HOME` on Windows (note Git-bash parent sets `HOME=/c/Users/you`, an MSYS path)
home_dir := if os() == "windows" { env_var_or_default("USERPROFILE", env_var_or_default("HOME", ".")) } else { env_var_or_default("HOME", ".") }
odin_tools := env_var_or_default("ODIN_TOOLS", join(home_dir, ".odin-tools"))
ols_install := join(odin_tools, "ols", ols_tag)

# `ODINFMT=odinfmt just format` opts out of the pin and uses PATH; `ensure-odinfmt` then skips the download too.
odinfmt_override := env_var_or_default("ODINFMT", "")
odinfmt_bin := if odinfmt_override != "" { odinfmt_override } else { join(ols_install, "odinfmt" + exe_ext) }
# Installed beside odinfmt from the same archive. For the editor setup - `just sublime-lsp-init`.
ols_bin := join(ols_install, "ols" + exe_ext)

# A shell test rather than depending on `fetch-ols` directly, which is a `[script]` recipe (uv/python overhead)
# ---
# make sure the pinned odinfmt is installed before formatting with it
[group('toolchain')]
[unix]
@ensure-odinfmt:
	test -n "{{odinfmt_override}}" || test -f "{{odinfmt_bin}}" || just fetch-ols

# Nested `if`s because cmd has no short-circuit operator to write the unix line's `||` with.
# ---
# make sure the pinned odinfmt is installed before formatting with it
[group('toolchain')]
[windows]
@ensure-odinfmt:
	if "{{odinfmt_override}}"=="" if not exist "{{odinfmt_bin}}" just fetch-ols

# Installs ols, odinfmt and the `builtin/` directory ols needs beside it - one archive holds all three -
# into `$ODIN_TOOLS/ols/<tag>/`, after checking it against `ols_sha256`. README, "Pinned tooling".
#
#     just fetch-ols            install if missing
#     just fetch-ols --check    exit non-zero when missing, install nothing (CI)
#     just fetch-ols --force    reinstall over an existing directory
# ---
# download the pinned ols + odinfmt into ~/.odin-tools, verified against its SHA-256
[group('toolchain')]
[script]
fetch-ols *args:
	import hashlib, os, shutil, stat, sys, tempfile, urllib.request, zipfile

	TAG, PLAT, WANT = r"{{ols_tag}}", r"{{ols_plat}}", r"{{ols_sha256}}"
	flags = r'''{{args}} '''.split()
	check_only, force = "--check" in flags, "--force" in flags

	# Passed in rather than re-derived: `$ODIN_TOOLS` and the USERPROFILE-before-HOME rule are
	# already applied above, and Python's `expanduser` does not agree with them on every machine.
	dest = r"{{ols_install}}"
	exe = ".exe" if "windows" in PLAT else ""

	# All three, not just the directory: an odinfmt-only install from an older layout would otherwise
	# read as a satisfied pin forever.
	complete = all(
		os.path.exists(os.path.join(dest, part))
		for part in ("ols" + exe, "odinfmt" + exe, "builtin")
	)
	if complete and not force:
		print(dest + ": present")
		sys.exit(0)
	if check_only:
		sys.exit(dest + ": missing or incomplete - run `just fetch-ols`")

	url = os.environ.get("OLS_URL") or "https://github.com/DanielGavin/ols/releases/download/" + TAG + "/ols-" + PLAT + ".zip"
	fd, archive = tempfile.mkstemp(suffix=".zip")
	os.close(fd)
	try:
		print("fetching " + url)
		try:
			urllib.request.urlretrieve(url, archive)
		except OSError as err:
			# URLError and HTTPError are both OSError subclasses.
			sys.exit("  " + str(err) + "\n  set OLS_URL to fetch the archive from somewhere else")

		h = hashlib.sha256()
		with open(archive, "rb") as f:
			for chunk in iter(lambda: f.read(1 << 20), b""):
				h.update(chunk)
		got = h.hexdigest()
		if got != WANT:
			sys.exit(
				"  sha256   " + got + "\n"
				"  expected " + WANT + "\n"
				"  refusing to install: this is not the pinned ols. A re-cut " + TAG + " has to be\n"
				"  adopted deliberately - `just bump-ols " + TAG + "` rewrites the digest."
			)

		# Staged in a sibling `.part` directory and renamed into place: the guards treat the path existing
		# as the pin being satisfied, so a half-extracted install would be permanently convincing.
		staging = dest + ".part"
		shutil.rmtree(staging, ignore_errors=True)
		os.makedirs(staging)
		with zipfile.ZipFile(archive) as z:
			# By prefix, not exact name: the release ships platform-suffixed binaries
			# (`ols-x86_64-pc-windows-msvc.exe`), and one that drops the suffix still works.
			for member in z.infolist():
				if member.is_dir():
					continue
				base = os.path.basename(member.filename)
				if base.startswith("odinfmt"):
					out = os.path.join(staging, "odinfmt" + exe)
				elif base.startswith("ols"):
					out = os.path.join(staging, "ols" + exe)
				elif "builtin/" in member.filename.replace("\\", "/"):
					out = os.path.join(staging, "builtin", base)
				else:
					continue
				os.makedirs(os.path.dirname(out), exist_ok=True)
				with open(out, "wb") as f:
					f.write(z.read(member))

		for name in ("ols" + exe, "odinfmt" + exe):
			path = os.path.join(staging, name)
			if not os.path.exists(path):
				sys.exit("  archive contained no " + name + " - did the release layout change?")
			# The zip's mode bits are not usable on every platform. Harmless on Windows; without it the
			# unix binary is not runnable.
			os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
		if not os.path.isdir(os.path.join(staging, "builtin")):
			# ols hard-errors without it, so an install missing it is a server that starts knowing nothing.
			sys.exit("  archive contained no builtin/ directory - did the release layout change?")

		if os.path.isdir(dest):
			old = dest + ".old"
			shutil.rmtree(old, ignore_errors=True)
			try:
				os.rename(dest, old)
			except OSError as err:
				# Windows refuses to move a directory holding a running executable - the editor's ols.
				sys.exit("  cannot replace " + dest + ": " + str(err) + "\n  close any editor running ols and retry")
			shutil.rmtree(old, ignore_errors=True)
		os.makedirs(os.path.dirname(dest), exist_ok=True)
		os.rename(staging, dest)
		print("  installed " + dest)
	finally:
		if os.path.exists(archive):
			os.remove(archive)


# Rewrites the `ols_tag` and `ols_sha256` lines from GitHub's release API, so a bump is one command
# rather than six digests copied by hand. Edits this file and stops - no fetch, no format, no commit -
# because the next `format` may reformat files nobody edited and that diff is worth seeing first.
#
#     just bump-ols                 rewrite the pin to the latest release
#     just bump-ols dev-2026-07     ... to a named release instead
#     just bump-ols --check         report whether a newer release exists, change nothing (exit 1 if so)
#
# `/releases/latest` skips prereleases, which keeps the continuously re-cut `nightly` tag out of a pin
# that only means anything if the bytes are fixed. Uses `$GITHUB_TOKEN` / `$GH_TOKEN` when set.
# ---
# rewrite the ols pin in .just/toolchain.just to the latest release (or --check for whether one exists)
[group('toolchain')]
[script]
bump-ols *args:
	import hashlib, json, os, re, sys, tempfile, urllib.request

	# In the order the generated `ols_sha256` chain tests them, last entry being the `else` arm. Must
	# match `ols_plat` above, or a platform silently gets another one's digest.
	PLATS = [
		"x86_64-pc-windows-msvc",
		"arm64-darwin",
		"x86_64-darwin",
		"arm64-unknown-linux-gnu",
		"x86_64-unknown-linux-gnu",
	]

	flags = r'''{{args}} '''.split()
	check_only = "--check" in flags
	named = [f for f in flags if not f.startswith("--")]
	if len(named) > 1:
		sys.exit("expected at most one tag, got " + repr(named))

	def api(url):
		request = urllib.request.Request(url, headers={
			"Accept": "application/vnd.github+json",
			# GitHub rejects an API request with no User-Agent.
			"User-Agent": "odin-skel-justfile",
		})
		token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
		if token:
			request.add_header("Authorization", "Bearer " + token)
		try:
			with urllib.request.urlopen(request) as response:
				return json.load(response)
		except OSError as err:
			sys.exit("  " + str(err) + "\n  GitHub's API is unreachable - the pin can also be edited by hand")

	base = "https://api.github.com/repos/DanielGavin/ols/releases"
	release = api(base + "/tags/" + named[0] if named else base + "/latest")
	tag = release["tag_name"]

	current = r"{{ols_tag}}"
	if tag == current:
		print("ols_tag " + current + " is already the " + ("named" if named else "latest") + " release")
		sys.exit(0)
	# "differs", not "is newer": these tags have no ordering this recipe can rely on, and the
	# release marked latest can be older than a hand-picked pin. Adopting it is the caller's call.
	print(current + " -> " + tag)
	if check_only:
		sys.exit("  the pin does not match the " + ("named" if named else "latest") + " release - `just bump-ols` adopts it")

	assets = {a["name"]: a for a in release.get("assets", [])}
	digests = {}
	for plat in PLATS:
		name = "ols-" + plat + ".zip"
		asset = assets.get(name)
		if asset is None:
			sys.exit(
				"  release " + tag + " has no " + name + "\n"
				"  every platform this project can run on needs one, so a partial release is not\n"
				"  something to pin - got: " + ", ".join(sorted(assets))
			)
		# Published per asset, saving ~5 MB of downloads. A recent API field, so older releases fall
		# back to hashing.
		published = (asset.get("digest") or "")
		if published.startswith("sha256:"):
			digests[plat] = published[len("sha256:"):]
			print("  " + plat + " " + digests[plat] + " (published)")
			continue
		fd, tmp = tempfile.mkstemp(suffix=".zip")
		os.close(fd)
		try:
			print("  " + plat + ": no published digest, hashing " + name)
			urllib.request.urlretrieve(asset["browser_download_url"], tmp)
			h = hashlib.sha256()
			with open(tmp, "rb") as f:
				for chunk in iter(lambda: f.read(1 << 20), b""):
					h.update(chunk)
			digests[plat] = h.hexdigest()
			print("  " + plat + " " + digests[plat] + " (hashed)")
		finally:
			if os.path.exists(tmp):
				os.remove(tmp)

	arms = ["if ols_plat == \"%s\" { \"%s\" }" % (p, digests[p]) for p in PLATS[:-1]]
	line = "ols_sha256 := " + " else ".join(arms) + " else { \"" + digests[PLATS[-1]] + "\" }"

	with open(".just/toolchain.just", encoding="utf-8", newline="") as f:
		text = f.read()
	# Anchored to the start of a line so the spelling in this recipe's own comments cannot be rewritten.
	text, tags = re.subn(r'^ols_tag := ".*"$', 'ols_tag := "' + tag + '"', text, count=1, flags=re.M)
	text, shas = re.subn(r"^ols_sha256 := .*$", line.replace("\\", "\\\\"), text, count=1, flags=re.M)
	if tags != 1 or shas != 1:
		sys.exit("  could not find the `ols_tag` / `ols_sha256` lines to rewrite - edit them by hand")
	with open(".just/toolchain.just", "w", encoding="utf-8", newline="") as f:
		f.write(text)

	print("")
	print("rewrote the pin in .just/toolchain.just. Next:")
	print("  just fetch-ols --force    install " + tag + " (the digests above are checked on the way in)")
	print("  just format               a new odinfmt may reformat files you did not edit - review that diff")
