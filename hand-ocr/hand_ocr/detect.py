"""Front-of-pipeline dispatch: tile splitting + recognition-mode detection.

One image may contain one deal or many. And the deal(s) come in one of two
visual grammars. This module decides both, so the rest of the pipeline can
route each tile to the right segmenter.

- **Tiles.** BridgeWebs' multi-table view (`bridgewebs-4-multi-table.png`) is a
  grid of independent board panels -> N deals in one PNG. Every other fixture
  is a single tile. `split_tiles` returns one Tile per board.
- **Mode.** Two grammars, detected per tile:
    - Mode.CARDS -- mini-card table play view (BBO, IntoBridge). Per-card suit
      glyph; hands may be partial (face-down). -> segment.py
    - Mode.ROWS  -- suit-row diagram / results view (BridgeWebs, RealBridge).
      Four hands in a compass cross, each four rows `<suit> <ranks>`; suit is
      positional; 2-colour deck; always 4 hands known. -> rows.py
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from itertools import pairwise
from typing import Any


class Mode(Enum):
    CARDS = "cards"  # mini-card play view -> segment.py
    ROWS = "rows"  # suit-row diagram -> rows.py


@dataclass
class Tile:
    """A single-deal sub-image plus where it sat in the source (for ordering
    multi-table output N->S, W->E)."""

    image: Any  # grayscale (or colour) crop of one board
    origin: tuple[int, int]  # (x, y) of the tile in the source image
    atlas: str | None = None  # recognition-atlas hint (e.g. "print"); None = auto-pick


# compass coverage above this fraction => a CARDS baize (or unknown), not a ROWS
# grid of compasses: don't try to tile it. ROWS diagrams show only small compasses.
_GRID_GREEN_CEILING = 0.20
# min blob area to count as a compass bar; well above the red suit-symbol glyphs
# that the red half of `compass_mask` also picks up.
_MIN_COMPASS_BLOB = 1500

# board-frame tiling (club-print grids have no compass but draw each board in a
# ruled rectangle). A frame's area as a fraction of the page, and its aspect.
_FRAME_AREA_LO, _FRAME_AREA_HI = 0.02, 0.25
_FRAME_ASPECT_LO, _FRAME_ASPECT_HI = 0.5, 2.2
_FRAME_MIN_COUNT = 4  # need a real grid, not one stray rectangle


def _cluster_1d(values: list[float], min_gap: float) -> list[float]:
    """Group sorted 1-D coordinates into clusters separated by gaps > min_gap;
    return each cluster's mean. Used to recover the grid's column/row centres
    from the compass centroids of a regular multi-board layout."""
    ordered = sorted(values)
    groups: list[list[float]] = [[ordered[0]]]
    for v in ordered[1:]:
        if v - groups[-1][-1] > min_gap:
            groups.append([v])
        else:
            groups[-1].append(v)
    return [sum(g) / len(g) for g in groups]


def _frame_tiles(image: Any) -> list[Tile]:
    """Tile a compass-less print grid by its ruled board rectangles.

    Club-print output (`print-*`) has no compass, but draws each board in a
    black-bordered box. We find those frames as rectangular contours of roughly
    uniform, board-sized area, dedupe the nested double borders, and return one
    Tile per frame in reading order tagged for the print atlas. Returns [] when
    no plausible uniform grid of frames is present (so single boards and the
    card views fall through to the whole-image path)."""
    import cv2
    import numpy as np

    h, w = image.shape[:2]
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if image.ndim == 3 else image
    _, binv = cv2.threshold(gray, 200, 255, cv2.THRESH_BINARY_INV)
    contours, _ = cv2.findContours(binv, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)

    rects: list[tuple[int, int, int, int]] = []
    for c in contours:
        x, y, bw, bh = cv2.boundingRect(c)
        area = bw * bh
        if _FRAME_AREA_LO * w * h < area < _FRAME_AREA_HI * w * h and _FRAME_ASPECT_LO < bw / bh < _FRAME_ASPECT_HI:
            rects.append((x, y, bw, bh))
    # dedupe every box drawn as more than one rectangle (concentric inner/outer
    # borders, or a border + a slightly-inset fill) by SHARED CENTRE: such frames
    # share a centre to within a few px, while neighbouring boards are a full frame
    # apart, so a centre gap under a fifth of the frame is the same board. (Matching
    # on size alone missed borders whose widths differed by >15px -> a duplicate
    # tile for one board.) Largest first, so the outer frame is the one kept.
    rects.sort(key=lambda r: -r[2] * r[3])
    kept: list[tuple[int, int, int, int]] = []
    for r in rects:
        cx, cy = r[0] + r[2] / 2, r[1] + r[3] / 2
        if not any(
            abs(cx - (k[0] + k[2] / 2)) < 0.2 * r[2] and abs(cy - (k[1] + k[3] / 2)) < 0.2 * r[3] for k in kept
        ):
            kept.append(r)
    if len(kept) < _FRAME_MIN_COUNT:
        return []
    # require a genuine grid: frame sizes must be uniform (rules out a lone box
    # plus stray rectangles). Median-relative spread under ~15%.
    ws, hs = np.array([r[2] for r in kept]), np.array([r[3] for r in kept])
    if ws.std() > 0.15 * float(np.median(ws)) or hs.std() > 0.15 * float(np.median(hs)):
        return []
    # reading order: top-to-bottom by row band (half a frame height), then left-to-right
    band = float(np.median(hs)) * 0.5
    kept.sort(key=lambda r: (round(r[1] / band), r[0]))
    return [Tile(image=image[y : y + bh, x : x + bw], origin=(x, y), atlas="print") for (x, y, bw, bh) in kept]


def split_tiles(image: Any) -> list[Tile]:
    """Split a possibly-multi-board image into one Tile per deal (reading order).

    ROWS diagrams put one green compass at the centre of each board and nowhere
    else, so a multi-board page (BridgeWebs 3x3 / 6-up / club-print grids) is
    found by clustering the green-compass centroids into a regular grid: the
    distinct X's are the columns, the distinct Y's the board rows, and the grid
    product gives the boards. The header/footer summary tables carry no green and
    drop out for free. Grid dimensions are discovered (no hardcoded count).

    Falls back to a single whole-image tile when there is no grid to find: a
    single board (one cluster), or a green-heavy CARDS baize (which is handled
    by the CARDS path, not tiled here).
    """
    import cv2

    from .rows import compass_mask

    h, w = image.shape[:2]
    mask = compass_mask(image)
    if float(mask.mean()) / 255.0 > _GRID_GREEN_CEILING:
        return [Tile(image=image, origin=(0, 0))]  # CARDS baize / not a compass grid

    n, _, stats, centroids = cv2.connectedComponentsWithStats(mask, connectivity=8)
    pts = [centroids[i] for i in range(1, n) if stats[i, cv2.CC_STAT_AREA] > _MIN_COMPASS_BLOB]
    if not pts:
        return _frame_tiles(image) or [Tile(image=image, origin=(0, 0))]  # no compass: try print frames

    col_centres = _cluster_1d([p[0] for p in pts], w * 0.12)
    row_centres = _cluster_1d([p[1] for p in pts], h * 0.12)
    if len(col_centres) * len(row_centres) <= 1:
        return _frame_tiles(image) or [Tile(image=image, origin=(0, 0))]  # single board / print grid

    def _spacing(centres: list[float], full: int) -> float:
        diffs = [b - a for a, b in pairwise(centres)]
        return min(diffs) if diffs else float(full)

    # crop slightly wider than a half-cell so each board's outer (E/W) hands are
    # fully included; _compass_bbox's central-only filter still ignores the
    # neighbours' compass edges that this overlap pulls in.
    half_w = int(_spacing(col_centres, w) * 0.56)
    half_h = int(_spacing(row_centres, h) * 0.56)
    tiles: list[Tile] = []
    for cy in row_centres:  # top-to-bottom
        for cx in col_centres:  # left-to-right
            x0, y0 = max(0, int(cx - half_w)), max(0, int(cy - half_h))
            x1, y1 = min(w, int(cx + half_w)), min(h, int(cy + half_h))
            if mask[y0:y1, x0:x1].sum() < _MIN_COMPASS_BLOB * 255:
                continue  # empty grid cell (fewer boards than the full grid) -> no compass
            tiles.append(Tile(image=image[y0:y1, x0:x1], origin=(x0, y0)))
    return tiles


# a card play-view shows pure-white card faces over this fraction of the tile;
# below it, a green-baize tile with a full suit-row board is a RealBridge replay
# diagram (text on tinted panels, no white cards).
_WHITE_CARD_MAX = 0.12


def _white_card_fraction(bgr: Any) -> float:
    """Fraction of the tile that is pure white card face -- bright AND unsaturated.

    Real BBO/IntoBridge cards are white (v>235, s<30); a ROWS diagram's tinted
    baize panels (RealBridge replay's light green/blue) are bright but saturated,
    so they do not count. Separates a card play view from a suit-row diagram that
    happens to share a green baize."""
    import cv2

    if bgr.ndim != 3:
        return float((bgr > 235).mean())
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    white = (hsv[:, :, 2] > 235) & (hsv[:, :, 1] < 30)
    return float(white.mean())


def detect_mode(tile: Tile) -> Mode:
    """Classify a tile as CARDS or ROWS.

    A green baize alone does not decide it: both a CARDS play view and a RealBridge
    *replay* suit-row diagram sit on baize. The tell is card faces -- a play view
    shows pure-white cards, replay shows text on tinted panels. So a high-green
    tile is ROWS only when it has few white cards AND a full board of suit-row
    anchor stacks (replay); otherwise it is a CARDS play view.

    A low-green tile is a ROWS diagram (white/light page) *unless* the anchor finds
    no stacks at all -- then it is a baize-less *cropped* CARDS grid (e.g. a tight
    IntoBridge grid), which the green test would otherwise misroute to ROWS.
    """
    from .rows import compass_mask

    compass_fraction = float(compass_mask(tile.image).mean()) / 255.0
    try:
        from .anchor import find_hand_stacks

        n_stacks = len(find_hand_stacks(tile.image))
    except Exception:  # noqa: BLE001 - anchor is best-effort; fall back to the green-only test
        n_stacks = None

    if compass_fraction >= 0.20:
        is_replay = (n_stacks or 0) >= 4 and _white_card_fraction(tile.image) < _WHITE_CARD_MAX
        return Mode.ROWS if is_replay else Mode.CARDS
    if n_stacks == 0:
        return Mode.CARDS  # low green + no stacks -> baize-less cropped card grid
    return Mode.ROWS
