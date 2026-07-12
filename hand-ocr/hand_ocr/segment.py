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

    Strips (N/S) are divided by card pitch; fanned W/E grids are split into their
    individual card components. A face-down hand yields no white cards, so that
    seat stays unknown (PBN '-') rather than wrong."""
    strips = [b for b in _hand_blobs(bgr) if _is_strip(b)]
    cells = [cell for blob in strips for cell in _strip_cards(bgr, blob)]
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


def read_seat_badges(bgr: Any, clusters: list[HandCluster]) -> None:  # pragma: no cover - future work
    """Set `cluster.seat` from the N/E/S/W badge nearest each cluster.

    Not yet needed for BBO (seat comes from position, which BBO respects). This
    is required for IntoBridge, which rotates seats. TODO: locate the lettered
    circle adjacent to each hand and classify the letter (4-way)."""
    raise NotImplementedError


def segment(bgr: Any) -> list[HandCluster]:
    """Colour play-view image -> HandClusters with seats assigned.

    Seam contract for the recogniser: each CardCell.index_image holds one card's
    rank glyph over its suit glyph; each HandCluster.seat is a valid seat char."""
    return cluster_hands(bgr, find_card_cells(bgr))
