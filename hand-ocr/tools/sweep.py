"""Fixture sweep: run the pipeline over every image and print a one-line status
per fixture -- the manual per-session check the PLAN describes, made a recipe.

For each image: how many boards were found and, of those, how many are valid
(legal deal), unread (contained reader failure -> Deal.note), or invalid (read
but illegal -> flag for manual fix). Shell-agnostic (nu on Windows / bash else)
so the justfile recipe stays a single call.

    just sweep                     # all fixtures/*.png
    just sweep fixtures/print-*    # a glob (expanded by the caller's shell)

Needs the vision extra (opencv/numpy); run via `just sweep` which uses
`uv run --extra vision`.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hand_ocr.model import DealError
from hand_ocr.pipeline import image_to_deals


def _classify(deal) -> str:
    if deal.note is not None:
        return "unread"
    try:
        deal.validate()
    except DealError:
        return "invalid"
    return "valid"


def _sweep(paths: list[Path]) -> int:
    worst = 0  # exit code: 0 all-valid, 2 any board not valid, 1 a fixture blew up
    name_w = max((len(p.name) for p in paths), default=0)
    for path in sorted(paths):
        try:
            deals = image_to_deals(str(path))
        except Exception as e:  # noqa: BLE001 - a sweep never aborts on one image
            print(f"{path.name:<{name_w}}  ERROR  {type(e).__name__}: {e}")
            worst = max(worst, 1)
            continue
        counts = {"valid": 0, "unread": 0, "invalid": 0}
        for deal in deals:
            counts[_classify(deal)] += 1
        total = len(deals)
        extra = "  ".join(f"{k} {v}" for k, v in counts.items() if v)
        mark = "OK " if counts["valid"] == total and total else "   "
        print(f"{path.name:<{name_w}}  {mark} {counts['valid']}/{total}  {extra}")
        if counts["valid"] != total:
            worst = max(worst, 2)
    return worst


def main(argv: list[str]) -> int:
    args = argv or ["fixtures"]
    paths: list[Path] = []
    for arg in args:
        p = Path(arg)
        paths.extend(sorted(p.glob("*.png")) if p.is_dir() else [p])
    if not paths:
        print("no images to sweep", file=sys.stderr)
        return 1
    return _sweep(paths)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
