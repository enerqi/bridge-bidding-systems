"""Bootstrap a rank-glyph atlas from a hand-labelled ROWS board.

Given one diagram image whose four hands we already know, cut out every rank
glyph (reusing the exact segmentation the recogniser uses) and save each under
its known label. Rows whose glyph count does not match the label length are
skipped (that row under/over-segmented) -- the rest of the alphabet is still
covered many times over, so the atlas ends up complete.

Run (from hand-ocr/, needs the vision extra):
    uv run python tools/build_atlas.py fixtures/bridgewebs-4-2.png hand_ocr/atlas/bridgewebs

The default board labels below describe `bridgewebs-4-2.png` (board 1), rank
glyph sequences per hand in suit order S, H, D, C, ten written "10".
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hand_ocr.atlas import Atlas
from hand_ocr.rows import hand_row_glyphs

# board 1 of bridgewebs-4-2.png; per seat, four rows in suit order S,H,D,C
LABELLED_BOARD = {
    "N": ["A105", "A64", "K92", "A953"],
    "W": ["KJ94", "9752", "QJ10", "106"],
    "E": ["8763", "KQ", "A8764", "QJ"],
    "S": ["Q2", "J1083", "53", "K8742"],
}


def main() -> None:
    import cv2

    if len(sys.argv) != 3:
        print("usage: build_atlas.py <image> <out_atlas_dir>", file=sys.stderr)
        raise SystemExit(2)
    image_path, out_dir = sys.argv[1], sys.argv[2]

    img = cv2.imread(image_path)
    if img is None:
        print(f"cannot read {image_path!r}", file=sys.stderr)
        raise SystemExit(2)

    per_seat = hand_row_glyphs(img)
    exemplars: dict[str, list] = {}
    kept = skipped = 0
    for seat, rows in per_seat.items():
        for r, glyphs in enumerate(rows):
            label = LABELLED_BOARD[seat][r]
            if len(glyphs) != len(label):
                print(f"  skip {seat} row{r}: segmented {len(glyphs)} glyphs, expected {len(label)} ({label})")
                skipped += 1
                continue
            for glyph, ch in zip(glyphs, label, strict=True):
                exemplars.setdefault(ch, []).append(glyph)
                kept += 1

    atlas = Atlas(exemplars)
    atlas.save(out_dir)
    classes = sorted(exemplars)
    print(
        f"wrote atlas -> {out_dir}: {kept} exemplars across {len(classes)} classes {classes} ({skipped} rows skipped)"
    )


if __name__ == "__main__":
    main()
