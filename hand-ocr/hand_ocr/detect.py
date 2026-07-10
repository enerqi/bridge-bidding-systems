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


# compass coverage above this fraction => a CARDS baize (or unknown), not a ROWS
# grid of compasses: don't try to tile it. ROWS diagrams show only small compasses.
_GRID_GREEN_CEILING = 0.20
# min blob area to count as a compass bar; well above the red suit-symbol glyphs
# that the red half of `compass_mask` also picks up.
_MIN_COMPASS_BLOB = 1500


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
        return [Tile(image=image, origin=(0, 0))]

    col_centres = _cluster_1d([p[0] for p in pts], w * 0.12)
    row_centres = _cluster_1d([p[1] for p in pts], h * 0.12)
    if len(col_centres) * len(row_centres) <= 1:
        return [Tile(image=image, origin=(0, 0))]  # single board -> whole image

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


def detect_mode(tile: Tile) -> Mode:
    """Classify a tile as CARDS or ROWS.

    Discriminator: a ROWS diagram has the small green NORTH/EAST/SOUTH/WEST
    compass square at its centre, whereas a CARDS play view spreads green over
    the whole baize. We mask the compass-green hue and test whether the green
    forms a *compact central* cluster (ROWS) rather than a large spread (CARDS).
    """
    from .rows import compass_mask

    mask = compass_mask(tile.image)
    compass_fraction = float(mask.mean()) / 255.0
    # ROWS: compass is a few percent of the image; CARDS baize is a large fraction.
    return Mode.ROWS if compass_fraction < 0.20 else Mode.CARDS
