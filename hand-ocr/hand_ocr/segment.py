"""Card-cell detection + seat grouping (Mode CARDS: app play views).

Real app screenshots (BBO, IntoBridge) are *table play views*, not printed
suit-row diagrams. Structure learned from the fixtures:

- A horizontal N/S hand renders as a run of white mini-cards that visually
  **touch**, so thresholding white yields ONE wide blob; we find that region
  then divide it into cards by pitch. A fanned W/E hand is instead a 2D **grid**
  of cards separated by green gaps, so each card is its own white component
  (isolated at a higher threshold, since the grey seat-label bar bridges the
  bottom row at the strip threshold) -- one component per card, no sub-division.
- Every card carries its **rank glyph above its suit glyph**. Within a strip the
  cards sit on a regular pitch, so the rank glyphs cluster into one column per
  card; each card cell is that column's full-height slice (rank band over suit
  band). Suit is read per-card from the glyph (see recognize), NOT positional.
- **Seat.** BBO keeps N top / S bottom / W left / E right, so for the 2-colour
  BBO path we assign seat by region position (verified against the N/E/S/W
  badges, which agree). IntoBridge *rotates* seats (top can be West), so its
  badge must be read -- that is future work; `read_seat_badges` stays a stub and
  IntoBridge tiles currently mis-seat (and mis-match the BBO atlas), so they are
  flagged, not silently wrong.
- **Face-down hands** (BBO 2-hand: W/E are teal card backs) produce no white
  blob -> that seat is simply absent -> PBN '-'. The centre played card / table
  overlays are rejected by area and by not lying in a hand region.

Vision code imported lazily.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

# hand-region (merged white cards) filters, as fractions of the image
_HAND_AREA_MIN = 0.008  # a full hand's white area; rejects the centre played card
_STRIP_ASPECT_MIN = 3.0  # w/h above this => a horizontal N/S strip
# glyph filters inside a card
_GLYPH_MIN_AREA, _GLYPH_MIN_H = 40, 12
# individual-card (grid) detection: a fanned/blocky W/E hand is a 2D grid of
# SEPARATE white cards, not a merged strip. At the _hand_blobs threshold (200)
# the grey seat-label bar bridges the bottom card row into one blob; each card
# body is pure white, so a higher threshold isolates every card on its own.
_CARD_WHITE_THR = 235
_CARD_AREA_MIN = 0.001  # one mini-card's white area, as a fraction of the image
_CARD_ASPECT_LO, _CARD_ASPECT_HI = 0.3, 0.75  # a portrait mini-card (strip ~0.67, grid ~0.5)
_CENTRE_BAND = 0.15  # half-width of the central x zone (trick/played cards live here, not hands)
# merged-grid (IntoBridge) detection: its W/E/N/S fans have NO gaps between cards,
# so a whole hand is ONE portrait white blob of four stacked suit rows.
_MERGED_ASPECT_LO, _MERGED_ASPECT_HI = 0.45, 0.9  # a few cards wide, four rows tall (~0.76); not a thin UI bar
_MERGED_H_MIN = 0.28  # tall (spans four suit rows), as a fraction of image height
_MERGED_W_MIN = 0.12  # and several cards wide, as a fraction of image width
# a merged-grid card cell, framed on its suit glyph, expressed in card-pitch units:
_GRID_TOP_ABOVE_SUIT = 1.08  # cell top sits this many pitches above the suit-glyph centre
_GRID_CARD_H = 1.44  # cell height in pitches (rank digits on top, suit below)
# seat-badge circles (IntoBridge): a white letter (N/E/S/W) on a dark disc
_BADGE_H_LO, _BADGE_H_HI = 0.03, 0.05  # letter height as a fraction of image height
_BADGE_X_MAX = 0.88  # ignore the right-hand results panel's avatar badges


@dataclass
class CardCell:
    """One detected mini-card. `index_image` is the top-left corner crop
    holding the rank glyph over the suit glyph."""

    bbox: tuple[int, int, int, int]  # x, y, w, h in the source image
    index_image: Any  # crop of the rank+suit index corner


@dataclass
class HandCluster:
    """A spatially-grouped set of card cells plus the seat read from the
    nearest seat badge. `seat` is None until the badge is classified."""

    cells: list[CardCell]
    seat: str | None
    centroid: tuple[float, float]


def _hand_blobs(bgr: Any) -> list[tuple[int, int, int, int]]:
    """Bounding boxes of the big white card-run regions (one per face-up hand).

    Thresholds near-white, and keeps blobs large enough to be a whole hand (so
    the small centre played card and UI chrome drop out)."""
    import cv2

    h, w = bgr.shape[:2]
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY) if bgr.ndim == 3 else bgr
    _, white = cv2.threshold(gray, 200, 255, cv2.THRESH_BINARY)
    n, _, stats, _ = cv2.connectedComponentsWithStats(white, connectivity=8)
    blobs = []
    for i in range(1, n):
        x, y, bw, bh, area = (int(stats[i, k]) for k in range(5))
        if area > _HAND_AREA_MIN * w * h and bw > 0.05 * w and bh > 0.03 * h:
            blobs.append((x, y, bw, bh))
    return blobs


def _seat_by_position(blob: tuple[int, int, int, int], shape: tuple[int, int]) -> str:
    """BBO seat from region position: top N, bottom S, left W, right E.

    A strip (wide) is N/S by its vertical half; a grid (tall) is W/E by its
    horizontal half. Correct for BBO; IntoBridge rotates and needs the badge."""
    x, y, bw, bh = blob
    h, w = shape[:2]
    cx, cy = x + bw / 2, y + bh / 2
    if bw / bh >= _STRIP_ASPECT_MIN:
        return "N" if cy < h / 2 else "S"
    return "W" if cx < w / 2 else "E"


def _cluster_x(centres: list[float], gap: float) -> list[list[int]]:
    """Group glyph indices by their x-centre into columns split at gaps > `gap`."""
    order = sorted(range(len(centres)), key=lambda i: centres[i])
    groups: list[list[int]] = [[order[0]]]
    for idx in order[1:]:
        if centres[idx] - centres[groups[-1][-1]] > gap:
            groups.append([idx])
        else:
            groups[-1].append(idx)
    return groups


def _strip_cards(bgr: Any, blob: tuple[int, int, int, int]) -> list[CardCell]:
    """Divide a horizontal hand strip into one CardCell per card.

    Cards sit on a regular pitch; their rank glyphs (upper band) cluster into one
    column per card. We recover the columns from those glyph centres (robust to a
    hand holding fewer than 13 cards) and slice a full card cell at each."""
    import cv2

    x, y, bw, bh = blob
    crop = cv2.cvtColor(bgr[y : y + bh, x : x + bw], cv2.COLOR_BGR2GRAY)
    # rank band = upper part of the card (the lower ~45% holds the suit + label bar)
    rank_h = int(bh * 0.55)
    _, ink = cv2.threshold(crop[:rank_h], 180, 255, cv2.THRESH_BINARY_INV)
    n, _, stats, cent = cv2.connectedComponentsWithStats(ink, connectivity=8)
    xs = [
        float(cent[i, 0])
        for i in range(1, n)
        if stats[i, cv2.CC_STAT_AREA] > _GLYPH_MIN_AREA
        and stats[i, cv2.CC_STAT_HEIGHT] > _GLYPH_MIN_H
        and stats[i, cv2.CC_STAT_WIDTH] >= 8  # drop the thin card border rule
        and 0.12 < stats[i, cv2.CC_STAT_WIDTH] / stats[i, cv2.CC_STAT_HEIGHT] < 3.0
    ]
    if not xs:
        return []
    pitch = bw / 13.0  # nominal card width; cards never pack tighter
    columns = _cluster_x(xs, pitch * 0.5)
    col_centres = sorted(sum(xs[i] for i in g) / len(g) for g in columns)
    cells = []
    half = pitch / 2.0
    # the card body (rank + suit), excluding the grey seat-label bar at the bottom
    card_h = int(bh * 0.82)
    for cx in col_centres:
        cx0 = max(0, int(cx - half))
        cx1 = min(bw, int(cx + half))
        cells.append(
            CardCell(bbox=(x + cx0, y, cx1 - cx0, card_h), index_image=bgr[y : y + card_h, x + cx0 : x + cx1])
        )
    return cells


def _card_comps(bgr: Any) -> list[tuple[int, int, int, int]]:
    """Bounding boxes of individual white mini-cards (one per face-up card).

    Thresholds white high enough that the grey seat-label bar no longer bridges
    the bottom card row (see `_CARD_WHITE_THR`), so each card body is its own
    portrait component. Applies to strips and grids alike; the caller keeps only
    the grid ones (strip cards are recovered by pitch in `_strip_cards`)."""
    import cv2

    h, w = bgr.shape[:2]
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY) if bgr.ndim == 3 else bgr
    _, white = cv2.threshold(gray, _CARD_WHITE_THR, 255, cv2.THRESH_BINARY)
    n, _, stats, _ = cv2.connectedComponentsWithStats(white, connectivity=8)
    comps = []
    for i in range(1, n):
        x, y, bw, bh, area = (int(stats[i, k]) for k in range(5))
        if area > _CARD_AREA_MIN * w * h and bh > 0.07 * h and _CARD_ASPECT_LO < bw / bh < _CARD_ASPECT_HI:
            comps.append((x, y, bw, bh))
    return comps


def _is_merged_grid(blob: tuple[int, int, int, int], img_h: int, img_w: int) -> bool:
    """A fully-merged (gapless) grid hand: a tall, several-cards-wide portrait
    white blob (excludes thin vertical UI bars and small overlays)."""
    _, _, bw, bh = blob
    return _MERGED_ASPECT_LO < bw / bh < _MERGED_ASPECT_HI and bh > _MERGED_H_MIN * img_h and bw > _MERGED_W_MIN * img_w


def _height_split(heights: list[float]) -> float:
    """Split value between two height clusters (tall rank digits vs short suit
    symbols): the midpoint of the largest gap in the sorted heights."""
    if len(heights) < 2:
        return (heights[0] + 1) if heights else 1.0
    return max((heights[i + 1] - heights[i], (heights[i + 1] + heights[i]) / 2) for i in range(len(heights) - 1))[1]


def _card_pitch(suits: list[tuple[float, float, float, float]]) -> float:
    """Card pitch = median nearest right-neighbour x-gap between suit glyphs that
    share a row (one suit per card, evenly spaced)."""
    import numpy as np

    med_h = float(np.median([s[1] for s in suits]))
    gaps = []
    for a in suits:
        right = [b[2] - a[2] for b in suits if b[2] - a[2] > 0 and abs(b[3] - a[3]) < med_h * 1.2]
        if right:
            gaps.append(min(right))
    return float(np.median(gaps)) if gaps else med_h * 2.1


def _merged_grid_cards(bgr: Any, blob: tuple[int, int, int, int]) -> list[CardCell]:
    """Divide a fully-merged grid hand (IntoBridge fan) into card cells.

    The cards touch with no gaps, so the hand is one white blob of four stacked
    suit rows. Each card carries exactly ONE suit symbol -- a short, ~square
    coloured glyph below its taller rank digit(s) -- so we split the glyphs into
    a tall (rank) and a short (suit) class by height, then anchor a card cell on
    every suit glyph. Anchoring on the suit (one per card) is robust to the
    two-glyph "10"; the cell is framed so the rank sits in `recognize`'s rank
    band and the suit in its suit band."""
    import cv2

    x, y, bw, bh = blob
    gray = cv2.cvtColor(bgr[y : y + bh, x : x + bw], cv2.COLOR_BGR2GRAY)
    _, ink = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)
    n, _, stats, cent = cv2.connectedComponentsWithStats(ink, connectivity=8)
    comps = []
    for i in range(1, n):
        gw, gh = int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT])
        area = int(stats[i, cv2.CC_STAT_AREA])
        if area > _GLYPH_MIN_AREA and _GLYPH_MIN_H < gh < 0.25 * bh:  # 0.25*bh drops the merged card-body blob
            comps.append((float(gw), float(gh), float(cent[i, 0]), float(cent[i, 1])))
    if not comps:
        return []
    thr = _height_split(sorted(c[1] for c in comps))
    suits = [c for c in comps if c[1] < thr and 0.65 < c[0] / c[1] < 1.6]
    if not suits:
        return []
    pitch = _card_pitch(suits)
    half, top_off, card_h, cw = pitch / 2.0, int(_GRID_TOP_ABOVE_SUIT * pitch), int(_GRID_CARD_H * pitch), int(pitch)
    cells = []
    for _, _, sx, sy in suits:
        cx0 = max(0, int(sx - half))
        top = max(0, int(sy) - top_off)
        crop = bgr[y + top : y + top + card_h, x + cx0 : x + cx0 + cw]
        cells.append(CardCell(bbox=(x + cx0, y + top, cw, card_h), index_image=crop))
    return cells


def _grid_cards(bgr: Any, strips: list[tuple[int, int, int, int]]) -> list[CardCell]:
    """CardCells for the fanned/blocky W/E grid hands.

    Each grid card is its own white component (`_card_comps`); we drop any whose
    centre falls inside a strip blob (those are N/S strip cards, divided by pitch
    elsewhere) or in the central x-band (the trick / played cards sit at the
    table centre, never a hand). Each remaining component is a card cell (rank
    over suit), read by the same `recognize` path as strip cells."""
    w = bgr.shape[1]
    cells = []
    for x, y, bw, bh in _card_comps(bgr):
        cx, cy = x + bw / 2, y + bh / 2
        if abs(cx - w / 2) < _CENTRE_BAND * w:
            continue
        if any(sx <= cx <= sx + sw and sy <= cy <= sy + sh for sx, sy, sw, sh in strips):
            continue
        cells.append(CardCell(bbox=(x, y, bw, bh), index_image=bgr[y : y + bh, x : x + bw]))
    return cells


def _group_grid_by_seat(cells: list[CardCell], w: int) -> list[tuple[str, list[CardCell]]]:
    """Split grid cells into the W (left half) / E (right half) hands by centroid
    x. BBO keeps W left / E right; IntoBridge rotates and will need the badge."""
    sides: dict[str, list[CardCell]] = {"W": [], "E": []}
    for c in cells:
        cx = c.bbox[0] + c.bbox[2] / 2
        sides["W" if cx < w / 2 else "E"].append(c)
    return [(seat, cs) for seat, cs in sides.items() if cs]


def find_card_cells(bgr: Any) -> list[CardCell]:
    """Detect mini-card cells across all face-up hands (Mode CARDS).

    Strips (N/S) are divided by card pitch; fanned grids are split into cards two
    ways -- BBO's gapped grids as individual white components (`_grid_cards`),
    IntoBridge's gapless fans as one merged blob divided by suit glyph
    (`_merged_grid_cards`). A face-down hand yields no white cards, so that seat
    stays unknown (PBN '-') rather than wrong."""
    h, w = bgr.shape[:2]
    blobs = _hand_blobs(bgr)
    strips = [b for b in blobs if _is_strip(b)]
    cells = [cell for blob in strips for cell in _strip_cards(bgr, blob)]
    for blob in blobs:
        if _is_merged_grid(blob, h, w):
            cells += _merged_grid_cards(bgr, blob)
    cells += _grid_cards(bgr, strips)
    return cells


def _is_strip(blob: tuple[int, int, int, int]) -> bool:
    return blob[2] / blob[3] >= _STRIP_ASPECT_MIN


def _make_cluster(cells: list[CardCell], seat: str) -> HandCluster:
    cxs = [c.bbox[0] + c.bbox[2] / 2 for c in cells]
    cys = [c.bbox[1] + c.bbox[3] / 2 for c in cells]
    return HandCluster(cells=cells, seat=seat, centroid=(sum(cxs) / len(cxs), sum(cys) / len(cys)))


def cluster_hands(bgr: Any, cells: list[CardCell]) -> list[HandCluster]:
    """Group cells into hands, seat by position.

    N/S strip cells share a strip blob's y-band and take that blob's seat; the
    remaining cells are the fanned W/E grids, split into the left (W) / right (E)
    hands. Grouping strips first also claims their cells, so a grid card near a
    strip's x-range isn't double-counted."""
    h, w = bgr.shape[:2]
    strips = [b for b in _hand_blobs(bgr) if _is_strip(b)]
    clusters: list[HandCluster] = []
    claimed: set[int] = set()
    for blob in strips:
        x, y, bw, bh = blob
        blob_cells = [c for c in cells if x <= c.bbox[0] < x + bw and y - 5 <= c.bbox[1] < y + bh]
        if not blob_cells:
            continue
        claimed.update(id(c) for c in blob_cells)
        clusters.append(_make_cluster(blob_cells, _seat_by_position(blob, (h, w))))
    grid_cells = [c for c in cells if id(c) not in claimed]
    for seat, side_cells in _group_grid_by_seat(grid_cells, w):
        clusters.append(_make_cluster(side_cells, seat))
    return clusters


def _seat_badge_glyphs(bgr: Any) -> list[tuple[float, float, Any]]:
    """Find the seat-badge letters. Each badge is a white letter (N/E/S/W) on a
    dark disc, so it thresholds as a small ~square white blob sitting on the dark
    table (card glyphs are dark on white, not white). Returns (cx, cy, glyph) for
    each, the glyph normalised for atlas matching. The right-hand results panel's
    avatar badges are smaller and excluded by `_BADGE_X_MAX`."""
    import cv2

    from .atlas import normalise_glyph

    h, w = bgr.shape[:2]
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY) if bgr.ndim == 3 else bgr
    _, white = cv2.threshold(gray, _CARD_WHITE_THR, 255, cv2.THRESH_BINARY)
    n, _, stats, cent = cv2.connectedComponentsWithStats(white, connectivity=8)
    out = []
    for i in range(1, n):
        x, y, bw, bh, area = (int(stats[i, k]) for k in range(5))
        if not (_BADGE_H_LO * h < bh < _BADGE_H_HI * h and 0.6 < bw / bh < 1.4):
            continue
        if float(cent[i, 0]) > _BADGE_X_MAX * w or area < 0.35 * bw * bh:
            continue
        glyph = normalise_glyph(white[y : y + bh, x : x + bw])
        if glyph is not None:
            out.append((float(cent[i, 0]), float(cent[i, 1]), glyph))
    return out


def read_seat_badges(bgr: Any, clusters: list[HandCluster], seat_atlas: Any) -> None:
    """Set each `cluster.seat` from the N/E/S/W badge nearest its centroid.

    Required for IntoBridge, which ROTATES seats (the top hand may be West), so
    screen position is not the seat -- the lettered badge beside each hand is.
    BBO needs none of this (position is the seat). The badge letter is read
    against `seat_atlas` (an N/E/S/W exemplar set)."""
    badges = _seat_badge_glyphs(bgr)
    if not badges:
        return
    for cluster in clusters:
        cx, cy = cluster.centroid
        _, _, glyph = min(badges, key=lambda b: (b[0] - cx) ** 2 + (b[1] - cy) ** 2)
        cluster.seat = seat_atlas.match(glyph)[0]


def segment(bgr: Any) -> list[HandCluster]:
    """Colour play-view image -> HandClusters with seats assigned.

    Seam contract for the recogniser: each CardCell.index_image holds one card's
    rank glyph over its suit glyph; each HandCluster.seat is a valid seat char."""
    return cluster_hands(bgr, find_card_cells(bgr))
