#!/usr/bin/env python3
"""golden_sim_json.py -- pin the card page's data-sim JSON contract (the string render.odin's simBand JS
parses) against a committed fixture. write_sim_json in pbn_analyse.odin bakes the DDS-sampled trick grid
PLUS the misguess-tax rung (ach/taxpts/pvt) into `data-sim='...'`; the seeded xoshiro RNG makes the whole
emission byte-stable for a fixed board+seed+sample, so a golden diff catches any drift in the JSON shape
(renamed keys, reordered fields, changed rounding) that would silently break the client.

Regenerate the fixtures after an INTENTIONAL format/number change:
  just build-analyse   # or rely on the recipe below building it
  ./target/release/pbn_analyse.exe --sample 120 --seed 7 --contract 3NT --html /tmp/g.html \
    '[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]'
  # then copy the data-sim / data-sim-guess bodies into tests/golden/*.json (see extract() below).

Stdlib only + cross-platform (no bash/grep/sed); invoked from the justfile via `uv run --no-project python`.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # odin-sims/
EXE = ROOT / "target" / "release" / "pbn_analyse.exe"
FIXTURE = ROOT / "tests" / "golden" / "two_way_q_3nt.datasim.json"
GUESS_FIXTURE = ROOT / "tests" / "golden" / "two_way_q_3nt.simguess.json"
BOARD = '[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]'


def extract(html: str, attr: str) -> str:
    """First `attr='...'` body from the page (single-quoted, as pbn_analyse emits it)."""
    m = re.search(rf"{attr}='([^']*)'", html)
    return m.group(1) if m else ""


def main() -> int:
    with tempfile.NamedTemporaryFile(suffix=".html", delete=False) as tf:
        out = Path(tf.name)
    try:
        subprocess.run(
            [str(EXE), "--sample", "120", "--seed", "7", "--contract", "3NT", "--html", str(out), BOARD],
            check=True, capture_output=True, text=True,
        )
        html = out.read_text(encoding="utf-8")
    finally:
        out.unlink(missing_ok=True)

    got = extract(html, "data-sim")
    want = FIXTURE.read_text(encoding="utf-8").rstrip("\n")
    ggot = extract(html, "data-sim-guess")
    gwant = GUESS_FIXTURE.read_text(encoding="utf-8").rstrip("\n")

    fail = False
    if got != want:
        print(f"FAIL: data-sim JSON drifted from golden ({FIXTURE})")
        print(f"want: {want}")
        print(f"got:  {got}")
        fail = True
    if ggot != gwant:
        print(f"FAIL: data-sim-guess JSON drifted from golden ({GUESS_FIXTURE})")
        print(f"want: {gwant}")
        print(f"got:  {ggot}")
        fail = True
    if fail:
        return 1
    print(f"PASS: data-sim ({len(want)} B) and data-sim-guess ({len(gwant)} B) match golden")
    return 0


if __name__ == "__main__":
    sys.exit(main())
