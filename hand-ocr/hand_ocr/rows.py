"""Mode B: suit-row cross diagram -> Deal (BridgeWebs, RealBridge, club prints).

The classic printed-style layout: four hands around a central compass box, each
hand written as four text rows

    <suit glyph> <ranks>        e.g.  "A 10 5"  (BridgeWebs)  or  "AT5" (prints)

with rows ordered S, H, D, C top->bottom. Here suit is *positional* (row index);
the leading suit glyph is only a cross-check, so we recognise ranks only.

Algorithm (all classical image processing; verified on `bridgewebs-4-2.png`):

1. Find the central compass by masking its distinctive green and taking the
   bounding box of the green blobs -- a strong, unambiguous anchor.
2. Place the four hand boxes at fixed offsets around that anchor (N above,
   S below, W left, E right).
3. Split each hand box into four equal rows -> suit by row index.
4. Otsu-threshold the row, find connected components (each = one glyph),
   drop the leftmost (the suit symbol), keep the rest left-to-right.
5. Classify each rank glyph against a template `Atlas` (nearest exemplar).

`model` folds a recognised "10" into "T" and validates the assembled deal.

Known limitations (documented, not yet solved): touching glyphs occasionally
merge into one component (under-segmentation); and an atlas built from one
rendering degrades on a *different-resolution* rendering of the same source
(cross-scale drift). The deployment model is one atlas per source rendering.

Vision + atlas imported lazily so the model spine stays dependency-free.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .model import SEATS, SUITS, Deal, DealError, Hand

# where the shipped per-source atlases live (see tools/build_atlas.py)
_ATLAS_ROOT = Path(__file__).resolve().parent / "atlas"
DEFAULT_ATLAS = "bridgewebs"  # compass anchor => BridgeWebs render
# atlas used when the hands were located by the compass-less suit-quadruple
# anchor (RealBridge results, and — until it gets its own — the print grids).
ANCHOR_ATLAS = "realbridge"

# component filters: ignore specks and thin noise when splitting a row into glyphs
_MIN_AREA, _MIN_W, _MIN_H = 10, 3, 6


def compass_mask(img_bgr: Any) -> Any:
    """Binary mask of the compass square. Its bars are coloured by vulnerability:
    GREEN when not vulnerable, RED when vulnerable (so a 'Vul All' board has an
    all-red compass). We therefore accept both hues. The small red suit symbols
    in the hands also match red, but they are filtered out by area/centrality
    wherever this mask is used."""
    import cv2

    hsv = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2HSV)
    green = cv2.inRange(hsv, (35, 60, 40), (90, 255, 200))
    red1 = cv2.inRange(hsv, (0, 80, 60), (10, 255, 255))
    red2 = cv2.inRange(hsv, (170, 80, 60), (180, 255, 255))
    return cv2.bitwise_or(cv2.bitwise_or(green, red1), red2)


def _compass_bbox(img_bgr: Any) -> tuple[int, int, int, int]:
    """Bounding box (minx, miny, maxx, maxy) of the *central* compass.

    Only compass-coloured blobs whose centre lies in the central region are
    considered, so on a full-cell multi-board tile the neighbouring boards'
    compass edges (near the tile border) are ignored and we lock onto this
    board's compass. On a single board the compass is central anyway."""
    import cv2

    h, w = img_bgr.shape[:2]
    mask = compass_mask(img_bgr)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    boxes = []
    for c in contours:
        if cv2.contourArea(c) <= 600:  # compass bars are chunky; excludes red suit symbols
            continue
        x, y, bw, bh = cv2.boundingRect(c)
        cx, cy = x + bw / 2, y + bh / 2
        if abs(cx - w / 2) < 0.34 * w and abs(cy - h / 2) < 0.40 * h:  # central only
            boxes.append((x, y, bw, bh))
    if not boxes:
        raise RuntimeError("no central green compass found; not a ROWS diagram?")
    minx = min(x for x, _, _, _ in boxes)
    miny = min(y for _, y, _, _ in boxes)
    maxx = max(x + bw for x, _, bw, _ in boxes)
    maxy = max(y + bh for _, y, _, bh in boxes)
    return minx, miny, maxx, maxy


def _hand_boxes(compass: tuple[int, int, int, int]) -> dict[str, tuple[int, int, int, int]]:
    """Four hand regions as (x0, y0, x1, y1), derived from the compass box by
    fixed proportional offsets (tuned on the BridgeWebs layout)."""
    minx, miny, maxx, maxy = compass
    w, h = maxx - minx, maxy - miny

    def r(a: float, b: float, c: float, d: float) -> tuple[int, int, int, int]:
        return int(a), int(b), int(c), int(d)

    # N/S extend right up to the compass (down to -0.05h / +0.05h) so the innermost
    # suit row is not clipped; W/E stay tight to avoid pulling in the DD-grid text.
    return {
        "N": r(minx - 15, miny - 1.15 * h, maxx + 8, miny - 0.05 * h),
        "S": r(minx - 15, maxy + 0.05 * h, maxx + 8, maxy + 1.35 * h),
        "W": r(minx - 1.30 * w, miny - 0.05 * h, minx - 0.10 * w, maxy + 0.05 * h),
        "E": r(maxx + 0.10 * w, miny - 0.05 * h, maxx + 1.30 * w, maxy + 0.05 * h),
    }


def _hand_boxes_from_stacks(stacks: list[Any], img_w: int) -> dict[str, tuple[int, int, int, int]]:
    """Four hand boxes from suit-quadruple `HandStack`s (the compass-less path).

    A single board is a cross of four stacks: assign seats by relative position
    -- top -> N, bottom -> S, left -> W, right -> E. Each box starts just left of
    the suit glyph and spans the stack's four rows; its right edge stops at the
    nearest stack to the right that shares the row band (so a neighbour hand's
    ranks are not pulled in), else a generous cap that `_box_rows`' bleed filter
    trims. Raises unless exactly four hands with an unambiguous seat each."""
    if len(stacks) != 4:
        raise RuntimeError(f"suit anchor found {len(stacks)} hands, need 4")
    seats = {
        "N": min(stacks, key=lambda s: s.centre[1]),
        "S": max(stacks, key=lambda s: s.centre[1]),
        "W": min(stacks, key=lambda s: s.centre[0]),
        "E": max(stacks, key=lambda s: s.centre[0]),
    }
    if len({id(s) for s in seats.values()}) != 4:
        raise RuntimeError("ambiguous seat geometry from suit anchor")

    boxes: dict[str, tuple[int, int, int, int]] = {}
    for seat, s in seats.items():
        x0 = max(0, int(s.left - s.pitch * 0.35))
        y0, y1 = max(0, int(s.top)), int(s.bottom)
        # right edge: nearest stack to the right whose rows overlap this one
        x1 = img_w
        for o in stacks:
            if o is s or o.left <= s.left + s.pitch:
                continue
            if o.top < y1 and o.bottom > y0:  # shares the vertical band
                x1 = min(x1, int(o.left - s.pitch * 0.3))
        x1 = min(x1, int(s.left + s.pitch * 7))  # generous cap; bleed filter trims the rest
        boxes[seat] = (x0, y0, max(x0 + 1, x1), y1)
    return boxes


def _seat_boxes(img_bgr: Any) -> tuple[dict[str, tuple[int, int, int, int]], str]:
    """Four hand boxes plus which anchor produced them ("compass" | "anchor").

    Tries the BridgeWebs green/red compass first (the verified fast path that
    also supplies vulnerability metadata); on its absence falls back to the
    source-independent suit-quadruple anchor. The source tag lets the caller
    pick the matching recognition atlas."""
    try:
        return _hand_boxes(_compass_bbox(img_bgr)), "compass"
    except RuntimeError:
        from .anchor import find_hand_stacks

        return _hand_boxes_from_stacks(find_hand_stacks(img_bgr), img_bgr.shape[1]), "anchor"


def _cluster_rows(centres_y: list[float], gap: float) -> list[list[int]]:
    """Group glyph-component indices (given their y-centres) into rows: sort by
    y and split where the gap between successive y-centres exceeds `gap`. Robust
    to the four suit rows being unevenly spaced (unlike a fixed 4-way band split,
    which mis-aligned rows and clipped glyphs)."""
    order = sorted(range(len(centres_y)), key=lambda i: centres_y[i])
    groups: list[list[int]] = [[order[0]]]
    for idx in order[1:]:
        if centres_y[idx] - centres_y[groups[-1][-1]] > gap:
            groups.append([idx])
        else:
            groups[-1].append(idx)
    return groups


def _col_ink(binimg: Any, box: tuple[int, int, int, int]) -> Any:
    """Per-column ink count over a component box (len == box width)."""
    x, y, w, h = box
    return binimg[y : y + h, x : x + w].sum(axis=0) / 255.0


def _valley_cuts(col: Any, n_cuts: int, min_spacing: float) -> list[int]:
    """Choose up to `n_cuts` interior split columns at the lowest-ink ("valley")
    positions, greedily, keeping cuts at least `min_spacing` apart so they land on
    the gaps between touching glyphs rather than clustering in one wide gap."""
    if n_cuts <= 0:
        return []
    w = len(col)
    interior = sorted(range(1, w - 1), key=lambda j: (col[j], abs(j - w / 2)))
    chosen: list[int] = []
    for j in interior:
        if all(abs(j - c) >= min_spacing for c in chosen):
            chosen.append(j)
            if len(chosen) == n_cuts:
                break
    return sorted(chosen)


def _split_box(box: tuple[int, int, int, int], cuts: list[int]) -> list[tuple[int, int, int, int]]:
    """Slice a component box vertically at `cuts` (relative x offsets)."""
    x, y, w, h = box
    xs = [0, *cuts, w]
    return [(x + xs[i], y, xs[i + 1] - xs[i], h) for i in range(len(xs) - 1) if xs[i + 1] - xs[i] > 0]


# a component only holds >1 glyph once it is clearly wider than a single wide rank
# (K/Q/A run ~1.6x the median); below this a lone glyph must not be split.
_SPLIT_RATIO = 1.8


def _maybe_split(box: tuple[int, int, int, int], binimg: Any, glyph_w: float) -> list[tuple[int, int, int, int]]:
    """Split a component wide enough to hold several touching glyphs into
    `round(w/glyph_w)` sub-boxes at ink valleys; else return it whole."""
    w = box[2]
    if w <= glyph_w * _SPLIT_RATIO:
        return [box]
    k = max(2, round(w / glyph_w))
    cuts = _valley_cuts(_col_ink(binimg, box), k - 1, max(3.0, glyph_w * 0.5))
    return _split_box(box, cuts)


def _box_rows(box_gray: Any) -> list[list[Any]]:
    """A hand-box crop -> up to 4 rows of normalised rank-glyph images.

    Connected components over the WHOLE box (not per-band), then cluster the
    components into rows by their y-centre; within each row drop the leftmost
    (the suit symbol) and normalise the rest left-to-right. Rows are padded /
    trimmed to exactly four (suit order S,H,D,C)."""
    import cv2
    import numpy as np

    from .atlas import normalise_glyph

    _, binimg = cv2.threshold(box_gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    n, _, stats, centroids = cv2.connectedComponentsWithStats(binimg, connectivity=8)
    comps = [
        (int(stats[i, cv2.CC_STAT_LEFT]), int(stats[i, cv2.CC_STAT_TOP]),
         int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT]), float(centroids[i, 1]))
        for i in range(1, n)
        if stats[i, cv2.CC_STAT_AREA] > _MIN_AREA
        and stats[i, cv2.CC_STAT_WIDTH] >= _MIN_W
        and stats[i, cv2.CC_STAT_HEIGHT] >= _MIN_H
    ]  # fmt: skip
    if not comps:
        return [[], [], [], []]

    median_h = float(np.median([c[3] for c in comps]))
    groups = _cluster_rows([c[4] for c in comps], median_h * 0.6)
    groups.sort(key=lambda g: min(comps[i][4] for i in g))  # top-to-bottom

    ordered_rows = [sorted((comps[i] for i in g), key=lambda c: c[0]) for g in groups]  # each left-to-right

    # Drop neighbour-board bleed: a multi-board tile is cropped wider than a cell so
    # each board's outer (E/W) hands fit, which also pulls in stray glyphs from the
    # adjacent board at the far edge. A real hand is one contiguous x-run; a bled
    # glyph sits past a wide horizontal gap (~4x the small inter-rank gap). Keep each
    # row's largest run (ties -> leftmost, the suit side, so a lone-suit run is kept).
    def keep_main_run(row: list[tuple[int, int, int, int, float]]) -> list[tuple[int, int, int, int, float]]:
        if len(row) < 2:
            return row
        runs: list[list[tuple[int, int, int, int, float]]] = [[row[0]]]
        for c in row[1:]:
            prev = runs[-1][-1]
            if c[0] - (prev[0] + prev[2]) > median_h * 2.5:
                runs.append([c])
            else:
                runs[-1].append(c)
        return max(runs, key=len)

    ordered_rows = [keep_main_run(row) for row in ordered_rows]

    # Reference widths for splitting touching glyphs. Ranks are the non-leftmost
    # components (leftmost is the suit symbol); the suit glyph is a touch wider.
    rank_ws = [c[2] for row in ordered_rows for c in row[1:]]
    glyph_w = float(np.median(rank_ws)) if rank_ws else median_h * 0.7
    # Suit glyphs are the leftmost component of each row; the club symbol is a bit
    # wider than the others, so take the median across rows as the lone-suit width.
    # A leftmost wider than ~1.45x that has merged with the first rank(s).
    lead_ws = [row[0][2] for row in ordered_rows if row]
    suit_w = float(np.median(lead_ws)) if lead_ws else glyph_w * 1.4
    lone_suit_max = suit_w * 1.45

    rows: list[list[Any]] = []
    for ordered in ordered_rows:
        if not ordered:
            rows.append([])
            continue
        # Leftmost component holds the suit symbol. If it is only suit-wide it is a
        # lone glyph to drop; if it is wider the suit has merged with the first
        # rank(s) (same-colour black touching) -- cut the suit off and keep the rest.
        fx, fy, fw, fh, _ = ordered[0]
        if fw <= lone_suit_max:
            rank_boxes: list[tuple[int, int, int, int]] = []
        else:
            col = _col_ink(binimg, (fx, fy, fw, fh))
            lo, hi = int(suit_w * 0.7), min(fw - 2, int(suit_w * 1.6))
            cut = lo + int(min(range(hi - lo), key=lambda k: col[lo + k])) if hi > lo else int(suit_w)
            rank_boxes = _maybe_split((fx + cut, fy, fw - cut, fh), binimg, glyph_w)
        for x, y, w, h, _cy in ordered[1:]:
            rank_boxes.extend(_maybe_split((x, y, w, h), binimg, glyph_w))

        glyphs = []
        for x, y, w, h in rank_boxes:
            glyph = normalise_glyph(binimg[y : y + h, x : x + w])
            if glyph is not None:
                glyphs.append(glyph)
        rows.append(glyphs)

    kept = [r for r in rows if r] or rows  # prefer non-empty rows if noise added blanks
    return kept[:4] + [[]] * (4 - len(kept))  # exactly four (S,H,D,C)


def _glyphs_from_boxes(gray: Any, boxes: dict[str, tuple[int, int, int, int]]) -> dict[str, list[list[Any]]]:
    """seat box -> 4 rows of normalised rank-glyph images, per seat."""
    ih, iw = gray.shape[:2]
    out: dict[str, list[list[Any]]] = {}
    for seat, (x0, y0, x1, y1) in boxes.items():
        # clamp to image bounds: on a tightly-cropped multi-board tile the derived
        # offsets can spill past the edge, which would make an empty/negative slice
        x0, y0 = max(0, x0), max(0, y0)
        x1, y1 = min(iw, x1), min(ih, y1)
        box = gray[y0:y1, x0:x1]
        out[seat] = [[], [], [], []] if box.size == 0 else _box_rows(box)
    return out


def hand_row_glyphs(img_bgr: Any) -> dict[str, list[list[Any]]]:
    """seat -> 4 rows (S,H,D,C) -> list of normalised rank-glyph images.

    Pure geometry + segmentation, no recognition. Separated out so the atlas
    bootstrap (which knows the labels) and the recogniser share it. Uses the
    compass anchor when present, else the suit-quadruple anchor."""
    import cv2

    boxes, _ = _seat_boxes(img_bgr)
    return _glyphs_from_boxes(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY), boxes)


def read_rows(img_bgr: Any, atlas: Any = None, atlas_name: str | None = None) -> Deal:
    """A ROWS tile -> full Deal.

    Suit is positional (row index -> SUITS); each row's ranks come from matching
    its glyphs against an atlas. Atlas selection: an explicit `atlas` object wins;
    else `atlas_name` (the tile's hint, e.g. "print") names a shipped atlas; else
    it is auto-picked by anchor source -- the BridgeWebs atlas for a compass
    board, the RealBridge atlas for a suit-quadruple board. `model` normalises
    "10"->"T" and validates."""
    import cv2

    from .atlas import Atlas

    boxes, source = _seat_boxes(img_bgr)
    if atlas is None:
        name = atlas_name or (DEFAULT_ATLAS if source == "compass" else ANCHOR_ATLAS)
        atlas = Atlas.load(_ATLAS_ROOT / name)

    per_seat = _glyphs_from_boxes(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY), boxes)
    hands: dict[str, Hand | None] = dict.fromkeys(SEATS)
    for seat, rows in per_seat.items():
        ranks = {suit: "".join(atlas.match(g)[0] for g in glyphs) for suit, glyphs in zip(SUITS, rows, strict=True)}
        try:
            hands[seat] = Hand.from_rows(ranks["S"], ranks["H"], ranks["D"], ranks["C"])
        except DealError:
            # a misrecognised glyph produced an illegal rank string (e.g. a lone
            # '0'); leave the hand unknown so the board still yields a Deal that
            # validation flags, instead of aborting the whole page.
            hands[seat] = None
    # metadata (dealer/vul/board) not yet read from the diagram text; default first=N
    return Deal(hands=hands, first="N")
