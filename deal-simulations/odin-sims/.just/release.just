# Releasing the workbench. The release itself is CI's (.github/workflows/release-workbench.yml, on a `v*`
# tag); these are the two local halves it depends on. The build is `dist` (workbench.just). Plan and
# routes: DEPLOYMENT_PLAN.md.
#
# Shares one namespace with the justfile, so `norn_home` / `dds_home` / `sciter_home` / `markup_home` /
# `HAND_OCR_DIR` resolve from there.

# Writes packaging/deps.json from the local checkouts' HEADs. Refuses a checkout with uncommitted or
# untracked files, or with commits not on its upstream: CI checks out from GitHub, so a pin to anything
# else is a release that cannot be built (or, worse, one built from different code than was tested here).
# Also records the local compiler, as a reminder - the pin CI uses is the `odin` field, edited by hand.
# ---
# pin the release's sibling repositories to the local checkouts' pushed HEADs
[group('release')]
[script]
pin-deps:
	import json, subprocess, sys
	homes = {
	    "norn": r"""{{norn_home}}""",
	    "odin-dds": r"""{{dds_home}}""",
	    "odin-sciter": r"""{{sciter_home}}""",
	    "bridge-markup": r"""{{markup_home}}""",
	    "bridge-hand-ocr": r"""{{HAND_OCR_DIR}}""",
	}
	def git(home, *args):
	    return subprocess.run(["git", "-C", home, *args], capture_output=True, text=True).stdout.strip()
	path = "packaging/deps.json"
	with open(path, encoding="utf-8") as f:
	    deps = json.load(f)
	problems = []
	for name, home in homes.items():
	    if git(home, "status", "--porcelain"):
	        problems.append(f"{name} ({home}) has uncommitted or untracked files")
	        continue
	    if not git(home, "rev-parse", "--abbrev-ref", "@{u}"):
	        problems.append(f"{name} ({home}) has no upstream branch")
	        continue
	    ahead = git(home, "rev-list", "--count", "@{u}..HEAD")
	    if ahead != "0":
	        problems.append(f"{name} ({home}) has {ahead} commit(s) not pushed")
	        continue
	    deps["siblings"][name]["commit"] = git(home, "rev-parse", "HEAD")
	if problems:
	    sys.exit("not pinned:" + "".join(chr(10) + "  " + p for p in problems))
	with open(path, "w", encoding="utf-8", newline=chr(10)) as f:
	    json.dump(deps, f, indent=4)
	    f.write(chr(10))
	local = subprocess.run(["odin", "version"], capture_output=True, text=True).stdout.strip()
	print(f"pinned {len(homes)} siblings in {path}; CI's compiler is {deps['odin']} (this machine: {local})")

# The release notes: the `## <version>` section of CHANGELOG.md, printed. A tag with no section fails the
# release early (the workflow calls this before anything is built).
# ---
# print a version's CHANGELOG.md section (fails if there is none)
[group('release')]
[script]
changelog-section version:
	import re, sys
	version = "{{version}}".removeprefix("v")
	text = open("CHANGELOG.md", encoding="utf-8").read()
	heading = re.compile(r"^## +v?" + re.escape(version) + r"\b.*$", re.M)
	m = heading.search(text)
	if not m:
	    sys.exit(f"CHANGELOG.md has no '## {version}' section")
	rest = text[m.end():]
	nxt = re.search(r"^## ", rest, re.M)
	print((rest[: nxt.start()] if nxt else rest).strip())
