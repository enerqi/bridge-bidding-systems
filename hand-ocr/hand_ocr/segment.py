"""Card-cell detection + seat grouping.

Revised against real app screenshots (BBO, IntoBridge). These are *table play
views*, not printed suit-row diagrams, so the structure is different from a
first guess:

- The atomic unit is a single **mini-card**: a white rounded rectangle with a
  rank glyph and a suit glyph at its **top-left corner** (the "index"). This
  corner is visible even when cards are fanned/overlapping (W/E vertical
  columns), so we always read it there.
- Hands appear as clusters: two horizontal strips (top/bottom) and two
  suit-grouped vertical fans (left/right). Card-to-seat is by spatial cluster.
- **Seat is NOT positional.** BBO puts North on top; IntoBridge in the same
  slot showed West. So each cluster's seat is read from the adjacent **seat
  badge** (a lettered circle N/E/S/W), never assumed from position.
- Face-down hands (BBO 2-hand: W/E are card backs) yield no card cells -> that
  seat stays unknown -> PBN '-'.

Suit is per-card here (read from the glyph, see recognize), NOT positional.
Vision code imported lazily.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


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


def find_card_cells(gray: Any) -> list[CardCell]:  # pragma: no cover - vision stub
    """Detect mini-card rectangles.

    TODO: threshold to isolate white cards on the green baize, find contours,
    keep those matching the card aspect ratio / min area, crop each card's
    top-left index region into `index_image`. Must reject the centre table
    region and overlay junk (trick cards, 'Contract Made' star, robot avatars).
    """
    raise NotImplementedError


def cluster_hands(cells: list[CardCell]) -> list[HandCluster]:  # pragma: no cover
    """Group cells into (up to) four hands by position.

    TODO: cluster by the four table regions (top strip / bottom strip / left
    fan / right fan). Overlapping vertical fans are one cluster even though
    cards share x. Returns 1..4 clusters (fewer when hands are face-down).
    """
    raise NotImplementedError


def read_seat_badges(gray: Any, clusters: list[HandCluster]) -> None:  # pragma: no cover
    """Set `cluster.seat` from the N/E/S/W badge nearest each cluster.

    TODO: locate the lettered circle adjacent to each hand, classify the
    letter (4-way). Do NOT infer seat from screen position -- IntoBridge and
    BBO disagree on which seat sits on top.
    """
    raise NotImplementedError


def segment(gray: Any) -> list[HandCluster]:  # pragma: no cover - vision stub
    """normalised gray -> HandClusters with seats assigned.

    Seam contract for the recogniser:
    - each CardCell.index_image contains exactly one rank glyph over one suit
      glyph, at native card orientation,
    - each HandCluster.seat is a valid seat char (N/E/S/W) once badges read.
    """
    cells = find_card_cells(gray)
    clusters = cluster_hands(cells)
    read_seat_badges(gray, clusters)
    return clusters
