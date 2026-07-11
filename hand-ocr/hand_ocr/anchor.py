"""Universal ROWS anchor: locate hands by their suit-glyph colour quadruple.

The compass anchor in `rows.py` only works for BridgeWebs (it needs that
source's green/red compass square). RealBridge results, RealBridge replay and
the club-print grids carry no such compass, so `_compass_bbox` raises before
recognition ever runs -- "Mode ROWS" was really "Mode BridgeWebs".

This module supplies the *source-independent* anchor the plan calls for. Every
ROWS hand, in every source, is four stacked suit rows in the fixed order
spade, heart, diamond, club -- and every source colours the two red suits
(heart, diamond) red and the two black suits (spade, club) black. So each hand
prints a vertical **black, red, red, black** quadruple of suit glyphs at a
consistent left edge with a regular row pitch, ranks running off to the right.
That colour quadruple is the anchor: no per-source template, no compass.

Detection:

1. Colour-mask the image into red ink (heart/diamond glyphs, plus stray red
   text) and black ink (spade/club glyphs, plus all the rank digits).
2. Find every vertical **red pair** -- a red glyph directly above another, at
   the same left edge, about one row-pitch apart. That is a hand's heart-over-
   diamond middle. Stray red text (a DD-trick-table header, a contract like
   "1H") does not form such an aligned vertical pair, so it drops out.
3. Confirm each pair is a hand by finding at least one aligned black glyph a
   row above (the spade suit symbol) or a row below (the club). This rejects
   any remaining coincidental red pair. The missing side, if any, is synthes-
   ised from the pitch so every hand yields four row centres.

Verified hand counts (clean-resolution renders): `realbridge-4-results` 4/4,
`print-3x4-format` 48/48, and `bridgewebs-4` still 4/4 (the three stray red
pairs from its DD grid are rejected by the black-neighbour test).

Known limitation -- low resolution: the two densest print grids
(`print-4x5`, `print-5x6`) render the suit glyphs so small that the red mask
shatters each into sub-pixel fragments, so the pair detector under-counts.
A morphological close trades fragmentation for merging adjacent black digits
and is a net loss; the real fix is upscaling the tile before masking, which
belongs with the per-source low-res atlas work (see PLAN step 5), not here.
Big-font sources (`realbridge-replay`) exceed `_H_MAX` and need that cap
relaxed once their atlas is on the table (PLAN step 3.6).

Vision imported lazily so importing this module stays dependency-free.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

# suit-glyph component size window (pixels). Excludes specks and merged blobs;
# also excludes very large glyphs (RealBridge replay) -- see the module note.
_AREA_MIN = 25
_W_MIN, _W_MAX = 5, 45
_H_MIN, _H_MAX = 6, 45

# vertical red-pair geometry, all relative to the median glyph height:
_PITCH_LO, _PITCH_HI = 0.7, 2.4  # heart->diamond row gap, as a multiple of glyph height
_X_TOL = 0.7  # left-edge alignment tolerance, ditto
_Y_TOL = 0.6  # black-neighbour row-centre tolerance, as a multiple of the pitch


@dataclass
class HandStack:
    """One hand located by its suit-glyph quadruple.

    `left` is the suit-glyph left edge (x); `rows_y` are the four suit-row
    y-centres in S, H, D, C order; `pitch` is the inter-row spacing. These
    define the hand box and its four row bands for the existing row segmenter,
    without any compass."""

    left: int
    rows_y: tuple[float, float, float, float]  # S, H, D, C centres
    pitch: float

    @property
    def top(self) -> float:
        return self.rows_y[0] - self.pitch * 0.6

    @property
    def bottom(self) -> float:
        return self.rows_y[3] + self.pitch * 0.6

    @property
    def centre(self) -> tuple[float, float]:
        return float(self.left), (self.rows_y[0] + self.rows_y[3]) / 2.0


# a component as (x, y, w, h, cx, cy)
_Comp = tuple[int, int, int, int, float, float]


def _colour_masks(img_bgr: Any) -> tuple[Any, Any]:
    """(red_mask, black_mask) for suit-glyph ink. Red is the two hue wraps at
    good saturation; black is dark low-saturation ink."""
    import cv2

    hsv = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2HSV)
    red = cv2.bitwise_or(
        cv2.inRange(hsv, (0, 90, 60), (12, 255, 255)),
        cv2.inRange(hsv, (168, 90, 60), (180, 255, 255)),
    )
    black = cv2.inRange(hsv, (0, 0, 0), (180, 90, 110))
    return red, black


def _glyph_components(mask: Any) -> list[_Comp]:
    """Connected components in a colour mask, filtered to suit-glyph size."""
    import cv2

    n, _, stats, cent = cv2.connectedComponentsWithStats(mask, connectivity=8)
    out: list[_Comp] = []
    for i in range(1, n):
        x, y, w, h, area = (int(stats[i, k]) for k in range(5))
        if area > _AREA_MIN and _W_MIN <= w <= _W_MAX and _H_MIN <= h <= _H_MAX:
            out.append((x, y, w, h, float(cent[i, 0]), float(cent[i, 1])))
    return out


def find_hand_stacks(img_bgr: Any) -> list[HandStack]:
    """Locate every ROWS hand in the image by its B,R,R,B suit-glyph quadruple.

    Source-independent (no compass). Returns one `HandStack` per hand found, in
    no particular order -- callers group them into boards / assign seats by
    geometry. Empty list if no colour quadruple is present (e.g. a CARDS view)."""
    import numpy as np

    red_mask, black_mask = _colour_masks(img_bgr)
    reds = _glyph_components(red_mask)
    blacks = _glyph_components(black_mask)
    if not reds:
        return []

    med_h = float(np.median([c[3] for c in reds]))
    pitch_lo, pitch_hi = med_h * _PITCH_LO, med_h * _PITCH_HI
    x_tol = med_h * _X_TOL

    stacks: list[HandStack] = []
    seen: set[tuple[int, int]] = set()
    for heart in reds:
        for diamond in reds:
            if heart is diamond:
                continue
            pitch = diamond[5] - heart[5]  # heart above diamond
            if not (pitch_lo <= pitch <= pitch_hi and abs(heart[0] - diamond[0]) <= x_tol):
                continue
            left = heart[0]
            spade_y, club_y = heart[5] - pitch, diamond[5] + pitch
            y_tol = pitch * _Y_TOL
            has_spade = any(abs(c[5] - spade_y) <= y_tol and abs(c[0] - left) <= x_tol for c in blacks)
            has_club = any(abs(c[5] - club_y) <= y_tol and abs(c[0] - left) <= x_tol for c in blacks)
            if not (has_spade or has_club):
                continue  # stray red pair (contract text / DD header), not a hand
            key = (round(left / 8), round(heart[5] / 8))
            if key in seen:
                continue
            seen.add(key)
            stacks.append(
                HandStack(left=left, rows_y=(spade_y, heart[5], diamond[5], club_y), pitch=pitch)
            )
    return stacks
