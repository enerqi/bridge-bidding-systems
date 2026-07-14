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

from .atlas import RANK_LABELS, SUIT_LABELS, Atlas, normalise_glyph
from .model import SEATS, SUITS, Hand
from .segment import CardCell, HandCluster

# where the shipped per-app card atlases live (rank + suit sub-dirs)
_ATLAS_ROOT = Path(__file__).resolve().parent / "atlas"
DEFAULT_CARDS_ATLAS = "bbo"
# apps with a 4-colour deck read suit from the glyph COLOUR (unambiguous), not
# its shape. A 2-colour app (BBO: red H/D, black S/C) must use the shape atlas.
COLOUR_SUIT_APPS = {"intobridge"}
# apps that rotate the seats and carry N/E/S/W badges (else seat = screen position)
SEAT_BADGE_APPS = {"intobridge"}

_GLYPH_MIN_AREA, _GLYPH_MIN_H, _GLYPH_MIN_W = 40, 12, 8
# a glyph is not a border: reject the thin tall card edge (w/h ~ 0.05) and the
# thin wide top rule (w/h large). Ranks/suits sit well inside this aspect band.
_GLYPH_ASPECT_LO, _GLYPH_ASPECT_HI = 0.12, 3.0


def _ink_mask(bgr_region: Any) -> Any:
    """Glyph ink within a card region: pixels that are dark OR saturated. A dark
    threshold alone misses a bright-but-coloured glyph (IntoBridge's orange, gray
    up to ~225); adding saturated pixels captures any coloured deck while still
    rejecting the white card body (bright and unsaturated)."""
    import cv2
    import numpy as np

    gray = cv2.cvtColor(bgr_region, cv2.COLOR_BGR2GRAY) if bgr_region.ndim == 3 else bgr_region
    dark = gray < 180
    if bgr_region.ndim == 3:
        sat = cv2.cvtColor(bgr_region, cv2.COLOR_BGR2HSV)[:, :, 1]
        ink = dark | (sat > 60)
    else:
        ink = dark
    return (ink.astype(np.uint8)) * 255


def _is_glyph(w: int, h: int, area: int) -> bool:
    if not (area > _GLYPH_MIN_AREA and h > _GLYPH_MIN_H and w >= _GLYPH_MIN_W):
        return False
    return _GLYPH_ASPECT_LO < w / h < _GLYPH_ASPECT_HI


def _card_bands(img: Any) -> tuple[tuple[int, int], tuple[int, int]] | None:
    """Split a card cell into its (rank, suit) vertical regions from the ink row
    profile, rather than fixed fractions.

    A card is a stack of horizontal ink bands separated by blank rows: the rank
    glyph(s) on top, then the suit symbol below (BBO packs them tightly,
    IntoBridge leaves a big gap and taller glyphs -- fixed bands can't fit both).
    The rank is the FIRST band and the suit the SECOND; any later band (e.g. a
    BBO grey seat-label bar caught at the card foot) is ignored. Both a two-digit
    "10" (side by side, same rows) and a "J" whose curl dips low stay within the
    one rank band. Returns None if fewer than two bands are found."""
    ink = _ink_mask(img)
    h, w = img.shape[:2]
    rows = (ink > 0).sum(1)
    min_ink = max(5, int(0.08 * w))  # above a thin card-border rule (~3px/row), which else bridges the gaps
    runs: list[tuple[int, int]] = []
    y = 0
    while y < h:
        if rows[y] >= min_ink:
            y2 = y
            while y2 < h and rows[y2] >= min_ink:
                y2 += 1
            if y2 - y >= 0.04 * h:  # drop hairline runs
                runs.append((y, y2))
            y = y2
        else:
            y += 1
    if len(runs) < 2:
        return None
    return (runs[0][0], runs[0][1]), (runs[1][0], runs[1][1])


def rank_image(cell: CardCell) -> Any | None:
    """The whole rank region of a card as ONE normalised image (the union bbox of
    all glyph-sized ink in the rank band).

    Matched as a single unit against whole-rank exemplars, so neither a two-digit
    rank ("10") nor a glyph the font draws in disconnected parts (IntoBridge's
    "K" is a stem plus a detached ">") needs per-glyph segmentation -- both were a
    source of split/merge ambiguity. The rank band comes from `_card_bands`, so a
    "J"'s low curl is kept and the suit is never included. None if no glyph."""
    import cv2

    bands = _card_bands(cell.index_image)
    if bands is None:
        return None
    (ry0, ry1), _ = bands
    ink = _ink_mask(cell.index_image[ry0:ry1])
    n, _, stats, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
    boxes = []
    for i in range(1, n):
        x, y, w, hh = (int(stats[i, cv2.CC_STAT_LEFT]), int(stats[i, cv2.CC_STAT_TOP]),
                       int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT]))  # fmt: skip
        if _is_glyph(w, hh, int(stats[i, cv2.CC_STAT_AREA])):
            boxes.append((x, y, w, hh))
    if not boxes:
        return None
    x0 = min(b[0] for b in boxes)
    yy0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes)
    y1b = max(b[1] + b[3] for b in boxes)
    return normalise_glyph(ink[yy0:y1b, x0:x1])


def _suit_ink(band: Any) -> Any:
    """Dark-thresholded ink for the suit band. Suit symbols are dark (<180 gray)
    in every deck -- even IntoBridge's orange (~166) -- so a dark threshold finds
    them while excluding the bright, saturated green baize a colour mask would
    catch at a card edge."""
    import cv2

    gray = cv2.cvtColor(band, cv2.COLOR_BGR2GRAY) if band.ndim == 3 else band
    return cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)[1]


def suit_glyph(cell: CardCell) -> Any | None:
    """The largest suit symbol in the card's suit band (the biggest ink blob)."""
    import cv2

    bands = _card_bands(cell.index_image)
    if bands is None:
        return None
    (sy0, sy1) = bands[1]
    ink = _suit_ink(cell.index_image[sy0:sy1])
    n, _, stats, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
    best, best_area = None, 0
    for i in range(1, n):
        area = int(stats[i, cv2.CC_STAT_AREA])
        if area > best_area:
            x, y, w, hh = (int(stats[i, cv2.CC_STAT_LEFT]), int(stats[i, cv2.CC_STAT_TOP]),
                           int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT]))  # fmt: skip
            best, best_area = ink[y : y + hh, x : x + w], area
    return normalise_glyph(best) if best is not None else None


# hue (OpenCV 0-180) -> suit, for a 4-colour deck (orange D, blue S, red H,
# green C). Red wraps 0/180. Measured IntoBridge hues: D~18, C~76, S~99, H~178.
def _suit_from_hue(hue: float) -> str:
    if hue < 15 or hue > 165:
        return "H"
    if hue < 40:
        return "D"
    if hue < 95:
        return "C"
    return "S"


def suit_colour(cell: CardCell) -> str:
    """Suit of a 4-colour-deck card from the hue of its suit SYMBOL.

    Locates the symbol as the largest ink blob in the suit band, then reads the
    hue of its saturated pixels. A black symbol (BBO's spades/clubs) has no
    saturated pixels -> '?', so this never mistakes a sliver of green baize at a
    card edge for a colour."""
    import cv2
    import numpy as np

    bands = _card_bands(cell.index_image)
    if bands is None:
        return "?"
    sy0, sy1 = bands[1]
    band = cell.index_image[sy0:sy1]
    ink = _suit_ink(band)
    n, _, stats, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
    if n <= 1:
        return "?"
    i = max(range(1, n), key=lambda k: stats[k, cv2.CC_STAT_AREA])
    x, y, w, hh = (int(stats[i, cv2.CC_STAT_LEFT]), int(stats[i, cv2.CC_STAT_TOP]),
                   int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT]))  # fmt: skip
    hsv = cv2.cvtColor(band[y : y + hh, x : x + w], cv2.COLOR_BGR2HSV)
    mask = hsv[:, :, 1] > 80
    if int(mask.sum()) < 10:
        return "?"
    return _suit_from_hue(float(np.median(hsv[:, :, 0][mask])))


def read_card(cell: CardCell, rank_atlas: Atlas, suit_atlas: Atlas | None) -> tuple[str, str]:
    """One card cell -> (suit, rank). Rank from the whole-region match; suit from
    the 4-way shape atlas, or from colour when `suit_atlas` is None (4-colour)."""
    if suit_atlas is None:
        suit = suit_colour(cell)
    else:
        sg = suit_glyph(cell)
        suit = suit_atlas.match(sg)[0] if sg is not None else "?"
    ri = rank_image(cell)
    rank = rank_atlas.match(ri)[0] if ri is not None else ""
    return suit, rank


def detect_app(clusters: list[HandCluster]) -> str:
    """Which app produced this play view (picks atlas + suit/seat handling).

    Decided from the SUIT colours *inside the detected cards*, not the whole
    frame (whose UI chrome and baize contaminate a global colour test). A
    4-colour deck (IntoBridge) draws spades blue and clubs green; a 2-colour deck
    (BBO) draws them black -- so roughly half of a 4-colour deck's cards read as a
    cool colour, versus only a few stray baize-green edges on BBO. Defaults to
    BBO."""
    cells = [cell for cl in clusters for cell in cl.cells]
    if not cells:
        return DEFAULT_CARDS_ATLAS
    cool = sum(1 for cell in cells if suit_colour(cell) in ("S", "C"))
    return "intobridge" if cool / len(cells) > 0.3 else DEFAULT_CARDS_ATLAS


def load_seat_atlas(app: str) -> Atlas:
    """The N/E/S/W badge-letter atlas for a seat-rotating app (atlas/<app>/seat)."""
    return Atlas.load(_ATLAS_ROOT / app / "seat", labels=set(SEATS))


def load_atlases(app: str = DEFAULT_CARDS_ATLAS) -> tuple[Atlas, Atlas | None]:
    """(rank_atlas, suit_atlas) for an app. The suit atlas is None for a
    colour-deck app (suit is read from colour, not shape)."""
    suit = None if app in COLOUR_SUIT_APPS else Atlas.load(_ATLAS_ROOT / app / "suit", labels=SUIT_LABELS)
    return Atlas.load(_ATLAS_ROOT / app / "rank", labels=RANK_LABELS), suit


def recognise(clusters: list[HandCluster], app: str = DEFAULT_CARDS_ATLAS) -> dict[str, Hand]:
    """Segmented board -> {seat: Hand}. Loads the app's rank (+ suit) atlases.

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
