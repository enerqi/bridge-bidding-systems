#!/usr/bin/env python3
"""ocr_analyse.py -- the image -> interactive card page pipeline. Bridges the two sibling projects:
hand-ocr (uv/Python, at ../../hand-ocr) turns a hand-diagram image into a PBN [Deal] tag; pbn_analyse
(this Odin project) turns that PBN into the card page with the DDS-sampling advisor + CCA/DD features.

hand-ocr is run as `uv run --project <ho> python hand-ocr.py` in hand-ocr's PROJECT env (NOT the script's
isolated PEP-723 env, which has only docopt, no opencv) -- mirrors hand-ocr's own `demo` recipe. A real
image needs the vision extra there:  (cd ../../hand-ocr && just sync-vision).

Usage:  ocr_analyse.py <image> [extra pbn_analyse flags...]
  Writes <image-basename>.html (the interactive page) unless an --html is passed in the extra flags.
  Defaults to --sample 400 (the honest whole-hand verdict) unless --sample is passed. Extra flags pass
  straight through, e.g. `ocr_analyse.py hand.png --contract 3NT --seed 7`.
Special: <image> may be `--demo` to run hand-ocr's hardcoded sample deal (plumbing check, no vision deps),
  or `--clipboard` to read the diagram straight from the OS clipboard (screenshot -> card page, no temp file).

Stdlib only + cross-platform (no bash); invoked from the justfile via `uv run --no-project python`.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # odin-sims/
HO = ROOT.parent.parent / "hand-ocr"  # repo-root/hand-ocr
EXE = ROOT / "target" / "release" / "pbn_analyse.exe"


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: ocr_analyse.py <image|--demo|--clipboard> [extra pbn_analyse flags...]", file=sys.stderr)
        return 2

    img, extra = argv[0], argv[1:]

    # OCR the image (or the demo/clipboard deal) to a PBN tag, in hand-ocr's project env.
    ho_cmd = ["uv", "run", "--project", str(HO), "python", str(HO / "hand-ocr.py")]
    if img == "--demo":
        ho_cmd += ["--demo", "--format", "pbn"]
        base = "ocr-demo"
    elif img == "--clipboard":
        ho_cmd += ["--clipboard", "--format", "pbn"]
        base = "ocr-clipboard"
    else:
        ho_cmd += [img, "--format", "pbn"]
        base = Path(img).stem
    pbn = subprocess.run(ho_cmd, check=True, capture_output=True, text=True).stdout

    # Defaults the caller did not override.
    if "--sample" not in extra:
        extra += ["--sample", "400"]
    if "--html" not in extra:
        extra += ["--html", f"{base}.html"]

    # Feed the PBN to pbn_analyse on stdin.
    return subprocess.run([str(EXE), *extra], input=pbn, text=True).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
