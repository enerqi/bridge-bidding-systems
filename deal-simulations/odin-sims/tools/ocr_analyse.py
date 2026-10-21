#!/usr/bin/env python3
"""ocr_analyse.py -- the image -> interactive card page pipeline. Joins two programs:
hand-ocr (the Odin reader from the sibling bridge-hand-ocr checkout, built into target/release by
`just build-hand-ocr`) turns a hand-diagram image into a PBN [Deal] tag; analyse_deal (this Odin project)
turns that PBN into the card page with the DDS-sampling advisor + CCA/DD features.

Usage:  ocr_analyse.py <image> [extra analyse_deal flags...]
  Writes <image-basename>.html (the interactive page) unless an --html is passed in the extra flags.
  Defaults to --sample 400 (the honest whole-hand verdict) unless --sample is passed. Extra flags pass
  straight through, e.g. `ocr_analyse.py hand.png --contract 3NT --seed 7`.
Special: <image> may be `--clipboard` to read the diagram straight from the Windows clipboard
  (screenshot -> card page, no temp file).

Stdlib only + cross-platform (no bash); invoked from the justfile via `uv run --no-project python`.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # odin-sims/
EXE = ROOT / "target" / "release" / "analyse_deal.exe"
HAND_OCR = ROOT / "target" / "release" / "hand-ocr.exe"


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: ocr_analyse.py <image|--clipboard> [extra analyse_deal flags...]", file=sys.stderr)
        return 2

    img, extra = argv[0], argv[1:]

    # OCR the image (or the clipboard's picture) to a PBN tag.
    ho_cmd = [str(HAND_OCR)]
    if img == "--clipboard":
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

    # Feed the PBN to analyse_deal on stdin.
    return subprocess.run([str(EXE), *extra], input=pbn, text=True).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
