"""Read board-number metadata from a RealBridge *replay* info box.

The replay layout carries a small pale-yellow info panel top-left whose first
line reads ``Bd <n>, Dlr <seat>``. Only the board NUMBER is OCR'd here, reusing
the very same rank atlas the hands use; dealer and vulnerability then follow
deterministically from the board number (standard duplicate rotation, see
`model.dealer_for_board` / `model.vul_for_board`), so no fragile letter- or
colour-recognition is needed.

Trick that makes a rank-only atlas enough: the atlas has no letters, so ``B``,
``d``, ``D``, ``l``, ``r``, ``N`` are *forced* onto their nearest rank template
and score poorly (<0.75 here), while a true digit -- same rendering as the atlas
exemplars -- scores ~1.0. Keeping only high-confidence digit matches leaves
exactly the board number.

Best-effort: every helper returns None / empty on any surprise, and the caller
falls back to ``first="N"`` with no metadata tags. Vision imported lazily so the
model spine stays dependency-free.
"""

from __future__ import annotations

from typing import Any

# a real digit (same render as the atlas) scores ~1.0; a forced letter <=0.75.
_DIGIT_CONF = 0.9
# info-box glyph component filters (mirrors rows.py's row segmentation)
_MIN_AREA, _MIN_H = 10, 6
# contract-line recognition thresholds (see read_contract)
_SUIT_CONF = 0.8  # strain glyph vs the live suit atlas (perfect-render ~0.99)
_SEAT_CONF = 0.5  # declarer glyph vs the live seat atlas (cross-scale ~0.8)
_LEVEL_CONF = 0.85  # contract level digit
_SUITS = "SHDC"  # positional order of a hand's four suit rows


def _yellow_mask(img_bgr: Any) -> Any:
    """Binary mask of the pale-yellow info/auction panels.

    Pale yellow is bright with R>=G and B well below both; this deliberately
    excludes the lime-green hand cells (which are also bright and low-blue but
    have G noticeably above R), so the panel does not merge with the baize."""
    import cv2
    import numpy as np

    b, g, r = cv2.split(img_bgr.astype(np.int16))
    m = (r > 200) & (g > 190) & (r - g > -10) & (r - g < 40) & (b < r - 45) & (b < g - 45)
    return (m.astype(np.uint8)) * 255


def _info_box(img_bgr: Any) -> tuple[int, int, int, int] | None:
    """Bounding box of the info panel: the largest yellow blob whose centre lies
    in the top-left quadrant (the auction table is yellow too but bottom-right)."""
    import cv2

    h, w = img_bgr.shape[:2]
    contours, _ = cv2.findContours(_yellow_mask(img_bgr), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    best: tuple[int, tuple[int, int, int, int]] | None = None
    for c in contours:
        x, y, bw, bh = cv2.boundingRect(c)
        cx, cy = x + bw / 2, y + bh / 2
        if cx < 0.5 * w and cy < 0.5 * h and bw * bh > 0.005 * w * h:
            area = bw * bh
            if best is None or area > best[0]:
                best = (area, (x, y, bw, bh))
    return None if best is None else best[1]


def _line_bands(binimg: Any) -> list[tuple[int, int]]:
    """Vertical text-row bands (y0, y1): runs of inked rows split by blank gutters.
    Band 0 is ``Bd <n>, Dlr <seat>``; band 1 (when present) the contract line."""
    import numpy as np

    inked = np.where(binimg.sum(axis=1) > 0)[0]
    if len(inked) == 0:
        return []
    bands: list[tuple[int, int]] = []
    start = prev = int(inked[0])
    for r in inked[1:]:
        if int(r) - prev > 3:  # blank gutter -> band boundary
            bands.append((start, prev + 1))
            start = int(r)
        prev = int(r)
    bands.append((start, prev + 1))
    return bands


def _info_binary(img_bgr: Any) -> tuple[Any, list[tuple[int, int]]] | None:
    """Threshold-inverted crop of the info panel (ink=255) plus its line bands,
    or None if there is no info box. Shared by the board- and contract-readers."""
    import cv2

    box = _info_box(img_bgr)
    if box is None:
        return None
    x, y, bw, bh = box
    gray = cv2.cvtColor(img_bgr[y : y + bh, x : x + bw], cv2.COLOR_BGR2GRAY)
    _, binimg = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    return binimg, _line_bands(binimg)


def _line_comps(line: Any, min_h: int = _MIN_H) -> list[tuple[int, int, int, int]]:
    """Left-to-right (x, y, w, h) glyph components of one text-row image."""
    import cv2

    n, _, stats, _ = cv2.connectedComponentsWithStats(line, connectivity=8)
    return sorted(
        (
            (int(stats[i, cv2.CC_STAT_LEFT]), int(stats[i, cv2.CC_STAT_TOP]),
             int(stats[i, cv2.CC_STAT_WIDTH]), int(stats[i, cv2.CC_STAT_HEIGHT]))
            for i in range(1, n)
            if stats[i, cv2.CC_STAT_AREA] > _MIN_AREA and stats[i, cv2.CC_STAT_HEIGHT] >= min_h
        ),
        key=lambda c: c[0],
    )  # fmt: skip


def read_board_number(img_bgr: Any, atlas: Any) -> int | None:
    """Board number from a replay info box, or None if it cannot be read.

    Isolate the panel's first text line, then keep only the high-confidence digit
    glyphs (left-to-right) matched against `atlas`."""
    from .atlas import normalise_glyph

    info = _info_binary(img_bgr)
    if info is None or not info[1]:
        return None
    binimg, bands = info
    line = binimg[bands[0][0] : bands[0][1], :]

    digits: list[str] = []
    for cx, cy, cw, ch in _line_comps(line):
        glyph = normalise_glyph(line[cy : cy + ch, cx : cx + cw])
        if glyph is None:
            continue
        label, conf = atlas.match(glyph)
        if conf >= _DIGIT_CONF and label.isdigit():
            digits.append(label)
    if not digits:
        return None
    board = int("".join(digits))
    return board if board >= 1 else None


def _cluster_rows_y(comps: list[tuple[int, int, int, int]], gap: float) -> list[list[int]]:
    """Group component indices into text rows by their y-centre (like rows.py)."""
    order = sorted(range(len(comps)), key=lambda i: comps[i][1] + comps[i][3] / 2)
    groups: list[list[int]] = [[order[0]]]
    for i in order[1:]:
        prev = groups[-1][-1]
        if (comps[i][1] + comps[i][3] / 2) - (comps[prev][1] + comps[prev][3] / 2) > gap:
            groups.append([i])
        else:
            groups[-1].append(i)
    return groups


def _harvest_suit_atlas(img_bgr: Any, seat_boxes: dict[str, tuple[int, int, int, int]]) -> Any:
    """Live suit atlas (S/H/D/C) from the hands: every hand writes all four suit
    glyphs as the leftmost symbol of its four rows (order S,H,D,C), so the atlas
    is self-supplied by the image -- no shipped file, and it matches this exact
    render. The leftmost component of each clustered row is the suit symbol."""
    import cv2
    import numpy as np

    from .atlas import Atlas, normalise_glyph

    exemplars: dict[str, list[Any]] = {}
    for x0, y0, x1, y1 in seat_boxes.values():
        gray = cv2.cvtColor(img_bgr[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY)
        _, binimg = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        box_h = binimg.shape[0]
        comps = _line_comps(binimg)
        comps = [c for c in comps if c[3] <= 0.5 * box_h and c[2] <= 6 * c[3]]
        if not comps:
            continue
        ref = float(np.percentile([c[3] for c in comps], 75))
        comps = [c for c in comps if c[3] >= 0.5 * ref]
        med = float(np.median([c[3] for c in comps]))
        rows = _cluster_rows_y(comps, med * 0.6)
        rows.sort(key=lambda g: min(comps[i][1] for i in g))
        for suit, grp in zip(_SUITS, rows, strict=False):  # positional S,H,D,C
            lx, ly, lw, lh = min((comps[i] for i in grp), key=lambda c: c[0])  # leftmost = suit
            glyph = normalise_glyph(binimg[ly : ly + lh, lx : lx + lw])
            if glyph is not None:
                exemplars.setdefault(suit, []).append(glyph)
    return Atlas(exemplars) if exemplars else None


def _bottom_right_box(img_bgr: Any) -> tuple[int, int, int, int] | None:
    """Bounding box of the auction table: the largest yellow blob centred in the
    bottom-right quadrant (its header row is ``W N E S``)."""
    import cv2

    h, w = img_bgr.shape[:2]
    contours, _ = cv2.findContours(_yellow_mask(img_bgr), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    best: tuple[int, tuple[int, int, int, int]] | None = None
    for c in contours:
        x, y, bw, bh = cv2.boundingRect(c)
        cx, cy = x + bw / 2, y + bh / 2
        area = bw * bh
        if cx > 0.5 * w and cy > 0.5 * h and area > 0.005 * w * h and (best is None or area > best[0]):
            best = (area, (x, y, bw, bh))
    return None if best is None else best[1]


def _harvest_seat_atlas(img_bgr: Any) -> Any:
    """Live seat atlas (W/N/E/S) from the auction-table header row, whose four
    letters are always drawn left-to-right in that fixed order."""
    import cv2

    from .atlas import Atlas, normalise_glyph

    box = _bottom_right_box(img_bgr)
    if box is None:
        return None
    x, y, bw, bh = box
    gray = cv2.cvtColor(img_bgr[y : y + bh, x : x + bw], cv2.COLOR_BGR2GRAY)
    _, binimg = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    bands = _line_bands(binimg)
    if not bands:
        return None
    header = binimg[bands[0][0] : bands[0][1], :]
    comps = _line_comps(header)
    if len(comps) < 4:
        return None
    exemplars: dict[str, list[Any]] = {}
    for (cx, cy, cw, ch), seat in zip(comps, "WNES", strict=False):  # fixed header order
        glyph = normalise_glyph(header[cy : cy + ch, cx : cx + cw])
        if glyph is not None:
            exemplars.setdefault(seat, []).append(glyph)
    return Atlas(exemplars) if len(exemplars) == 4 else None


def read_contract(
    img_bgr: Any, rank_atlas: Any, seat_boxes: dict[str, tuple[int, int, int, int]]
) -> tuple[str, str, int] | None:
    """(contract, declarer, result) from a replay info box's second line, or None.

    The line reads ``<level><suit><doubling><sign><result> <declarer>`` (e.g.
    ``4!cX-3 W`` or ``3!d = S``). Level and any result digits use `rank_atlas`;
    the strain suit and the declarer seat are matched against atlases harvested
    live from this image (`_harvest_suit_atlas` / `_harvest_seat_atlas`). Doubling
    and the made/over/under sign are read geometrically -- a square full-height
    non-digit glyph is an ``X``; thin horizontal bars are the ``=``/``-``/``+``
    sign -- so no atlas is needed for glyphs the two known fixtures don't show.
    Best-effort: any unreadable part returns None and the caller drops the tags."""
    from .atlas import normalise_glyph

    info = _info_binary(img_bgr)
    if info is None or len(info[1]) < 2:
        return None
    binimg, bands = info
    line = binimg[bands[1][0] : bands[1][1], :]
    comps = _line_comps(line, min_h=5)
    if len(comps) < 3:  # need at least level, strain, declarer
        return None

    suit_atlas = _harvest_suit_atlas(img_bgr, seat_boxes)
    seat_atlas = _harvest_seat_atlas(img_bgr)
    if suit_atlas is None or seat_atlas is None:
        return None

    def glyph(c: tuple[int, int, int, int]) -> Any:
        return normalise_glyph(line[c[1] : c[1] + c[3], c[0] : c[0] + c[2]])

    # level: leftmost glyph is the contract level digit
    lvl_label, lvl_conf = rank_atlas.match(glyph(comps[0]))
    if lvl_conf < _LEVEL_CONF or not lvl_label.isdigit():
        return None
    level = int(lvl_label)
    level_h = comps[0][3]

    # strain: next glyph is the suit symbol; if it doesn't match a suit it is NT
    strain_label, strain_conf = suit_atlas.match(glyph(comps[1]))
    if strain_conf >= _SUIT_CONF:
        strain, strain_end = strain_label, 2
    else:
        strain, strain_end = "NT", 3  # "N","T" letter glyphs (no fixture; best-effort)

    # declarer: rightmost glyph is the seat letter
    dcl_label, dcl_conf = seat_atlas.match(glyph(comps[-1]))
    if dcl_conf < _SEAT_CONF:
        return None
    declarer = dcl_label

    # middle glyphs = doubling X's, the result sign (thin bars) and result digits
    doubling, digits, thin_bars = "", "", 0
    for c in comps[strain_end:-1]:
        if c[3] < 0.45 * level_h:  # thin horizontal bar -> part of the =/-/+ sign
            thin_bars += 1
            continue
        lab, conf = rank_atlas.match(glyph(c))
        if conf >= _DIGIT_CONF and lab.isdigit():
            digits += lab
        else:
            doubling += "X"  # square full-height non-digit -> a double/redouble mark

    # "=" made exactly -> no digits -> 0; else a signed count (thin bar => under).
    overtricks = 0 if not digits else (-int(digits) if thin_bars else int(digits))
    contract = f"{level}{strain}{doubling}"
    return contract, declarer, 6 + level + overtricks
