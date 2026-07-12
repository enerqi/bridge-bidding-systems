"""Bootstrap a Mode-CARDS rank + suit atlas from a hand-labelled play view.

Given an app screenshot whose hands we know, reuse the exact card segmentation
the recogniser uses, then save each card's upper-band glyph under its rank label
and its lower-band symbol under its suit label. Two atlases result:
    atlas/<app>/rank   (rank glyphs A K Q J T 9..2, ten as "10")
    atlas/<app>/suit   (suit symbols S H D C)

Run (from hand-ocr/, needs the vision extra):
    uv run python tools/build_cards_atlas.py fixtures/bridge-base-4-hand-large.png bbo

Labels below are per fixture stem, per seat, as two aligned left-to-right
strings: the rank of each card and its suit (S/H/D/C). A card whose upper band
does not segment into exactly its rank's glyph count is skipped (the rest of the
alphabet is covered many times over).
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hand_ocr.atlas import Atlas
from hand_ocr.recognize import rank_glyphs, suit_glyph
from hand_ocr.segment import (
    CardCell,
    _grid_cards,
    _group_grid_by_seat,
    _hand_blobs,
    _is_strip,
    _seat_by_position,
    _strip_cards,
)

# per fixture stem: seat -> (ranks, suits) in the seat's reading order, ten
# written "10". N/S are horizontal strips read left-to-right; W/E are grids read
# by suit row top-to-bottom (BBO stacks the rows red/black-alternating: hearts,
# spades, diamonds, clubs), each row left-to-right, matching `_reading_order`.
LABELLED_HANDS = {
    "bridge-base-4-hand-large": {
        "N": ("432432Q432KQJ", "HHHSSSDDDDCCC"),
        "S": ("QJ9876AQJ5A32", "HHHHHHSSSDCCC"),
        "W": ("K1057 65KJ109 1098".replace(" ", ""), "HHHSSSDDDDCCC"),
        "E": ("AK1098A8767654", "HSSSSDDDDCCCC"),
    },
}


def _reading_order(cells: list[CardCell]) -> list[CardCell]:
    """Grid cells in suit-row reading order: rows top-to-bottom, each row
    left-to-right. Rows sit ~a card-height apart, so a coarse y bucket separates
    them while keeping a row's cards together."""
    return sorted(cells, key=lambda c: (round(c.bbox[1] / (c.bbox[3] * 0.5)), c.bbox[0]))


def _split_ranks(ranks: str) -> list[str]:
    """Split a per-hand rank string into per-card ranks, keeping "10" whole."""
    out: list[str] = []
    i = 0
    while i < len(ranks):
        if ranks[i : i + 2] == "10":
            out.append("10")
            i += 2
        else:
            out.append(ranks[i])
            i += 1
    return out


def main() -> None:
    import cv2

    if len(sys.argv) != 3:
        print("usage: build_cards_atlas.py <image> <app>", file=sys.stderr)
        raise SystemExit(2)
    image_path, app = sys.argv[1], sys.argv[2]

    stem = Path(image_path).stem
    if stem not in LABELLED_HANDS:
        print(f"no labelled hands for {stem!r}; known: {sorted(LABELLED_HANDS)}", file=sys.stderr)
        raise SystemExit(2)
    labelled = LABELLED_HANDS[stem]

    img = cv2.imread(image_path)
    if img is None:
        print(f"cannot read {image_path!r}", file=sys.stderr)
        raise SystemExit(2)

    rank_ex: dict[str, list] = {}
    suit_ex: dict[str, list] = {}
    counts = {"kept": 0, "skipped": 0}

    def harvest(seat: str, cells: list) -> None:
        ranks, suits = _split_ranks(labelled[seat][0]), list(labelled[seat][1])
        if len(cells) != len(ranks):
            print(f"  {seat}: segmented {len(cells)} cards, expected {len(ranks)} -- skipping hand")
            return
        for cell, rank, suit in zip(cells, ranks, suits, strict=True):
            rgs = rank_glyphs(cell)
            sg = suit_glyph(cell)
            if len(rgs) != len(rank) or sg is None:
                print(f"  skip {seat} card {rank}{suit}: {len(rgs)} rank glyphs, suit={sg is not None}")
                counts["skipped"] += 1
                continue
            for g, ch in zip(rgs, rank, strict=True):
                rank_ex.setdefault(ch, []).append(g)
            suit_ex.setdefault(suit, []).append(sg)
            counts["kept"] += 1

    strips = [b for b in _hand_blobs(img) if _is_strip(b)]
    for blob in strips:  # N/S horizontal strips, cards left-to-right
        seat = _seat_by_position(blob, img.shape[:2])
        if seat in labelled:
            harvest(seat, _strip_cards(img, blob))
    for seat, side_cells in _group_grid_by_seat(_grid_cards(img, strips), img.shape[1]):  # W/E grids
        if seat in labelled:
            harvest(seat, _reading_order(side_cells))

    kept, skipped = counts["kept"], counts["skipped"]
    out = Path(__file__).resolve().parents[1] / "hand_ocr" / "atlas" / app
    Atlas(rank_ex).save(out / "rank")
    Atlas(suit_ex).save(out / "suit")
    print(
        f"wrote {out}: {kept} cards -> rank classes {sorted(rank_ex)}, "
        f"suit classes {sorted(suit_ex)} ({skipped} cards skipped)"
    )


if __name__ == "__main__":
    main()
