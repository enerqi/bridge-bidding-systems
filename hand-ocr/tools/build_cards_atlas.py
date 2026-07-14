"""Bootstrap a Mode-CARDS atlas from a hand-labelled play view.

Given an app screenshot whose hands we know, reuse the exact card segmentation
the recogniser uses, then save each card's upper-band glyph under its rank label
and its lower-band symbol under its suit label. Up to three atlases result:
    atlas/<app>/rank   (rank glyphs A K Q J T 9..2, ten as "10")
    atlas/<app>/suit   (suit symbols S H D C)
    atlas/<app>/seat   (seat-badge letters N E S W -- only where the app rotates
                        seats and carries badges, i.e. IntoBridge)

Run (from hand-ocr/, needs the vision extra):
    uv run python tools/build_cards_atlas.py fixtures/bridge-base-4-hand-large.png bbo
    uv run python tools/build_cards_atlas.py fixtures/intobridge-4-hand-large.png intobridge

Hands are harvested through `cluster_hands`, which keys each hand by SCREEN
position (N=top, S=bottom, W=left, E=right). IntoBridge rotates the true seats,
so the labels below are given per *position* (top/bottom/left/right) -- the atlas
stores glyph->label pairs only, the seat is irrelevant to it. Labels are two
aligned strings in the hand's reading order (strips left-to-right; grids by suit
row top-to-bottom, each row left-to-right), ten written "10". A card whose upper
band does not segment into exactly its rank's glyph count is skipped.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hand_ocr.atlas import Atlas
from hand_ocr.recognize import rank_image, suit_glyph
from hand_ocr.segment import CardCell, HandCluster, _seat_badge_glyphs, cluster_hands, find_card_cells

# per fixture stem: position seat (N=top/S=bottom/W=left/E=right) -> (ranks, suits)
LABELLED_HANDS = {
    "bridge-base-4-hand-large": {
        "N": ("432432Q432KQJ", "HHHSSSDDDDCCC"),
        "S": ("QJ9876AQJ5A32", "HHHHHHSSSDCCC"),
        "W": ("K105765KJ1091098", "HHHSSSDDDDCCC"),
        "E": ("AK1098A8767654", "HSSSSDDDDCCCC"),
    },
    "intobridge-4-hand-large": {
        "N": ("AQ1053J98K64AK", "DDDDDSSSHHHCC"),  # top = West's cards
        "S": ("KJ962KQ747534", "DDDDDSSSSHHHC"),  # bottom = East's cards
        "W": ("74A2Q1092QJ1095", "DDSSHHHHCCCCC"),  # left = South's cards
        "E": ("810653AJ887632", "DSSSSHHHCCCCC"),  # right = North's cards
    },
}

# per fixture stem: geometric badge position -> the seat letter drawn on it. Only
# apps that rotate seats (IntoBridge) carry badges and need a seat atlas.
LABELLED_SEATS = {
    "intobridge-4-hand-large": {"top": "W", "bottom": "E", "left": "S", "right": "N"},
}


def _reading_order(cells: list[CardCell]) -> list[CardCell]:
    """Cells in reading order: rows top-to-bottom, each row left-to-right. A
    single-row strip collapses to plain left-to-right (all one row bucket)."""
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


def _build_seat_atlas(img, positions: dict[str, str]) -> Atlas:
    """Label the four badge letters by geometry: topmost badge is `top`, etc."""
    badges = _seat_badge_glyphs(img)
    if len(badges) != 4:
        print(f"  seat atlas: found {len(badges)} badges, expected 4 -- skipping")
        return Atlas({})
    by_y = sorted(badges, key=lambda b: b[1])
    by_x = sorted(badges, key=lambda b: b[0])
    picked = {"top": by_y[0], "bottom": by_y[-1], "left": by_x[0], "right": by_x[-1]}
    seat_ex: dict[str, list] = {}
    for where, seat in positions.items():
        seat_ex.setdefault(seat, []).append(picked[where][2])
    return Atlas(seat_ex)


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

    def harvest(cluster: HandCluster) -> None:
        seat = cluster.seat
        if seat not in labelled:
            return
        ranks, suits = _split_ranks(labelled[seat][0]), list(labelled[seat][1])
        cells = _reading_order(cluster.cells)
        if len(cells) != len(ranks):
            print(f"  {seat}: segmented {len(cells)} cards, expected {len(ranks)} -- skipping hand")
            return
        for cell, rank, suit in zip(cells, ranks, suits, strict=True):
            ri = rank_image(cell)  # whole-rank image, labelled by the full token ("10", "K", ...)
            sg = suit_glyph(cell)
            if ri is None or sg is None:
                print(f"  skip {seat} card {rank}{suit}: rank={ri is not None}, suit={sg is not None}")
                counts["skipped"] += 1
                continue
            rank_ex.setdefault(rank, []).append(ri)
            suit_ex.setdefault(suit, []).append(sg)
            counts["kept"] += 1

    for cluster in cluster_hands(img, find_card_cells(img)):
        harvest(cluster)

    out = Path(__file__).resolve().parents[1] / "hand_ocr" / "atlas" / app
    Atlas(rank_ex).save(out / "rank")
    Atlas(suit_ex).save(out / "suit")
    msg = (
        f"wrote {out}: {counts['kept']} cards -> rank classes {sorted(rank_ex)}, "
        f"suit classes {sorted(suit_ex)} ({counts['skipped']} cards skipped)"
    )
    if stem in LABELLED_SEATS:
        seat_atlas = _build_seat_atlas(img, LABELLED_SEATS[stem])
        seat_atlas.save(out / "seat")
        msg += f"; seat classes {sorted(seat_atlas.exemplars)}"
    print(msg)


if __name__ == "__main__":
    main()
