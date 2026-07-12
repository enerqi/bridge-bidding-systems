"""Card recognition: a card cell (rank glyph over suit glyph) -> (suit, rank).

Each mini-card carries BOTH its rank and its suit, stacked: the rank glyph(s) in
the upper band, the suit symbol in the lower band. So we read each per-card:

- **Rank** = segment the upper band into glyphs and match each against a rank
  `Atlas` (nearest exemplar); "10" is two glyphs "1","0" that `model` folds to
  "T". App screenshots are pixel-stable, so the template match is near-exact.
- **Suit** = match the single lower-band symbol against a 4-way suit `Atlas`
  (labels S/H/D/C). This is the universal signal; colour only assists (BBO is a
  2-colour deck so colour alone is ambiguous -- the glyph shape decides;
  IntoBridge is 4-colour so colour would suffice, but the shape works for both).

Atlases are per-app (fonts differ). `recognise` assembles one Hand per seat.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .atlas import SUIT_LABELS, Atlas, normalise_glyph
from .model import SEATS, SUITS, Hand
from .segment import CardCell, HandCluster

# where the shipped per-app card atlases live (rank + suit sub-dirs)
_ATLAS_ROOT = Path(__file__).resolve().parent / "atlas"
DEFAULT_CARDS_ATLAS = "bbo"

# card-cell bands (fractions of the cell height): rank on top, suit below it,
# clear of the card's top/bottom borders and the grey seat-label bar.
_RANK_BAND = (0.02, 0.42)
_SUIT_BAND = (0.48, 0.82)
_GLYPH_MIN_AREA, _GLYPH_MIN_H, _GLYPH_MIN_W = 40, 12, 8
# a glyph is not a border: reject the thin tall card edge (w/h ~ 0.05) and the
# thin wide top rule (w/h large). Ranks/suits sit well inside this aspect band.
_GLYPH_ASPECT_LO, _GLYPH_ASPECT_HI = 0.12, 3.0


def _is_glyph(w: int, h: int, area: int) -> bool:
    if not (area > _GLYPH_MIN_AREA and h > _GLYPH_MIN_H and w >= _GLYPH_MIN_W):
        return False
    return _GLYPH_ASPECT_LO < w / h < _GLYPH_ASPECT_HI


def _band_glyphs(card_bgr: Any, band: tuple[float, float]) -> list[Any]:
    """Normalised ink-glyph images within a horizontal band of a card cell,
    left-to-right (one for a rank digit / suit symbol; two for a "10")."""
    import cv2

    h = card_bgr.shape[0]
    gray = cv2.cvtColor(card_bgr, cv2.COLOR_BGR2GRAY) if card_bgr.ndim == 3 else card_bgr
    y0, y1 = int(h * band[0]), int(h * band[1])
    _, ink = cv2.threshold(gray[y0:y1], 180, 255, cv2.THRESH_BINARY_INV)
    n, _, stats, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
    comps = []
    for i in range(1, n):
        x, y, w, hh = (int(stats[i, cv2.CC_STAT_LEFT]), int(stats[i, cv2.CC_STAT_TOP]),
                       int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT]))  # fmt: skip
        if _is_glyph(w, hh, int(stats[i, cv2.CC_STAT_AREA])):
            comps.append((x, y, w, hh))
    glyphs = []
    for x, y, w, hh in sorted(comps, key=lambda c: c[0]):
        g = normalise_glyph(ink[y : y + hh, x : x + w])
        if g is not None:
            glyphs.append(g)
    return glyphs


def rank_glyphs(cell: CardCell) -> list[Any]:
    return _band_glyphs(cell.index_image, _RANK_BAND)


def suit_glyph(cell: CardCell) -> Any | None:
    """The single largest suit symbol in the lower band (the biggest blob; ranks
    that dip into the band are smaller fragments)."""
    import cv2

    img = cell.index_image
    h = img.shape[0]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    y0, y1 = int(h * _SUIT_BAND[0]), int(h * _SUIT_BAND[1])
    _, ink = cv2.threshold(gray[y0:y1], 180, 255, cv2.THRESH_BINARY_INV)
    n, _, stats, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
    best, best_area = None, 0
    for i in range(1, n):
        area = int(stats[i, cv2.CC_STAT_AREA])
        if area > best_area:
            x, y, w, hh = (int(stats[i, cv2.CC_STAT_LEFT]), int(stats[i, cv2.CC_STAT_TOP]),
                           int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT]))  # fmt: skip
            best, best_area = ink[y : y + hh, x : x + w], area
    return normalise_glyph(best) if best is not None else None


def read_card(cell: CardCell, rank_atlas: Atlas, suit_atlas: Atlas) -> tuple[str, str]:
    """One card cell -> (suit, rank). Suit from the 4-way suit atlas; rank from
    the concatenated best matches of the upper-band glyphs."""
    sg = suit_glyph(cell)
    suit = suit_atlas.match(sg)[0] if sg is not None else "?"
    rank = "".join(rank_atlas.match(g)[0] for g in rank_glyphs(cell))
    return suit, rank


def load_atlases(app: str = DEFAULT_CARDS_ATLAS) -> tuple[Atlas, Atlas]:
    """(rank_atlas, suit_atlas) for an app, from atlas/<app>/{rank,suit}."""
    return (
        Atlas.load(_ATLAS_ROOT / app / "rank"),
        Atlas.load(_ATLAS_ROOT / app / "suit", labels=SUIT_LABELS),
    )


def recognise(clusters: list[HandCluster], app: str = DEFAULT_CARDS_ATLAS) -> dict[str, Hand]:
    """Segmented board -> {seat: Hand}. Loads the app's rank + suit atlases.

    Only clusters with a resolved seat are emitted; missing / face-down seats
    are simply absent (the caller marks them None -> PBN '-')."""
    rank_atlas, suit_atlas = load_atlases(app)

    hands: dict[str, Hand] = {}
    for cluster in clusters:
        if cluster.seat is None or cluster.seat not in SEATS:
            continue
        by_suit: dict[str, list[str]] = {s: [] for s in SUITS}
        for cell in cluster.cells:
            suit, rank = read_card(cell, rank_atlas, suit_atlas)
            if suit in by_suit and rank:
                by_suit[suit].append(rank)
        hands[cluster.seat] = Hand.from_rows(
            "".join(by_suit["S"]), "".join(by_suit["H"]), "".join(by_suit["D"]), "".join(by_suit["C"])
        )
    return hands
