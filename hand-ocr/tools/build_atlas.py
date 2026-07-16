"""Bootstrap a rank-glyph atlas from a hand-labelled ROWS board.

Given one diagram image whose four hands we already know, cut out every rank
glyph (reusing the exact segmentation the recogniser uses) and save each under
its known label. Rows whose glyph count does not match the label length are
skipped (that row under/over-segmented) -- the rest of the alphabet is still
covered many times over, so the atlas ends up complete.

Run (from hand-ocr/, needs the vision extra):
    uv run python tools/build_atlas.py fixtures/bridgewebs-4-2.png hand_ocr/atlas/bridgewebs

The labelled boards below are keyed by fixture stem; the right one is chosen
from the input filename. Each is a single board's rank glyph sequences per hand
in suit order S, H, D, C, ten written "10". A compass source (BridgeWebs) is
segmented via the compass anchor; a compass-less source (RealBridge, print) via
the suit-quadruple anchor -- both go through `hand_row_glyphs` transparently.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hand_ocr.atlas import Atlas
from hand_ocr.rows import hand_row_glyphs

# per fixture stem: one board's four rows per seat, suit order S,H,D,C, ten="10"
LABELLED_BOARDS = {
    # board 1 of bridgewebs-4-2.png (compass anchor)
    "bridgewebs-4-2": {
        "N": ["A105", "A64", "K92", "A953"],
        "W": ["KJ94", "9752", "QJ10", "106"],
        "E": ["8763", "KQ", "A8764", "QJ"],
        "S": ["Q2", "J1083", "53", "K8742"],
    },
    # realbridge-4-results.png, board 5 (suit-quadruple anchor)
    "realbridge-4-results": {
        "N": ["872", "Q10863", "J53", "104"],
        "W": ["K643", "94", "82", "KQ632"],
        "E": ["Q1095", "AK75", "AQ4", "AJ"],
        "S": ["AJ", "J2", "K10976", "9875"],
    },
    # print-3x4-format.png, board 1 (frame-tiled; same deal as bridgewebs board 1
    # but ten is drawn compact "T", not "10")
    "print-3x4-format": {
        "N": ["AT5", "A64", "K92", "A953"],
        "W": ["KJ94", "9752", "QJT", "T6"],
        "E": ["8763", "KQ", "A8764", "QJ"],
        "S": ["Q2", "JT83", "53", "K8742"],
    },
    # board 1 of bridgewebs-4-3x3-multi.png (a 3x3 grid tile -- SAME deal as
    # bridgewebs-4-2 board 1 but rendered at the smaller grid scale, ten "10").
    # Gives grid tiles a same-render atlas, curing the standalone-atlas confusion.
    "bridgewebs-4-3x3-multi": {
        "N": ["A105", "A64", "K92", "A953"],
        "W": ["KJ94", "9752", "QJ10", "106"],
        "E": ["8763", "KQ", "A8764", "QJ"],
        "S": ["Q2", "J1083", "53", "K8742"],
    },
    # board 1 of print-5x6-format-zoomed.png -- a HIGH-RES ("zoomed") club-print
    # grid (~22px glyphs vs the ~12px regular print). Its own same-render atlas
    # (the 12px "print" atlas misreads these larger glyphs). Ten "10", void = "".
    "print-5x6-format-zoomed": {
        "N": ["A1095", "7", "J83", "109653"],
        "W": ["Q842", "1042", "KQ4", "AJ2"],
        "E": ["", "AQJ986", "A97652", "K"],
        "S": ["KJ763", "K53", "10", "Q874"],
    },
    # realbridge-replay-1.png (big-font cross diagram; suit-quadruple anchor,
    # ten written "10"; a void suit row is the empty string)
    "realbridge-replay-1": {
        "N": ["Q104", "AKJ963", "Q1097", ""],
        "W": ["A873", "854", "", "AKQ1097"],
        "E": ["62", "Q72", "AKJ653", "84"],
        "S": ["KJ95", "10", "842", "J6532"],
    },
}


def main() -> None:
    import cv2

    from hand_ocr.detect import split_tiles

    if len(sys.argv) < 3:
        print("usage: build_atlas.py <image> [<image> ...] <out_atlas_dir>", file=sys.stderr)
        raise SystemExit(2)
    *image_paths, out_dir = sys.argv[1:]

    # Merge every labelled board into one atlas. Passing several renders of the
    # same source (e.g. a standalone board + a grid tile) builds a multi-render
    # atlas: nearest-exemplar then matches whichever render a query came from, so
    # no per-render routing is needed downstream.
    exemplars: dict[str, list] = {}
    kept = skipped = 0
    for image_path in image_paths:
        stem = Path(image_path).stem
        if stem not in LABELLED_BOARDS:
            print(f"no labelled board for {stem!r}; known: {sorted(LABELLED_BOARDS)}", file=sys.stderr)
            raise SystemExit(2)
        labelled = LABELLED_BOARDS[stem]

        img = cv2.imread(image_path)
        if img is None:
            print(f"cannot read {image_path!r}", file=sys.stderr)
            raise SystemExit(2)

        # labelled board is the first board in reading order; on a multi-board grid
        # tile the page and take board 1, so segmentation matches the pipeline.
        tiles = split_tiles(img)
        board = tiles[0].image if len(tiles) > 1 else img
        per_seat = hand_row_glyphs(board)
        for seat, rows in per_seat.items():
            for r, glyphs in enumerate(rows):
                label = labelled[seat][r]
                if len(glyphs) != len(label):
                    print(f"  skip {stem} {seat} row{r}: {len(glyphs)} glyphs, expected {len(label)} ({label})")
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
