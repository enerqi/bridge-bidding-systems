"""End-to-end orchestration: image path -> list[Deal].

    normalise (preprocess)
      -> split_tiles          (1 tile, or N board panels for multi-table)
      -> per tile: detect_mode
           CARDS -> segment (card cells, cluster, seat badges) -> recognise
           ROWS  -> read_rows (compass hand boxes, positional suit rows)
      -> validate each Deal (13/hand, no dup, suit overflow) -> flag misreads

One image can yield many deals (BridgeWebs multi-table), so the entry point is
`image_to_deals` returning a list; `image_to_deal` is a single-deal convenience.
Vision stages are stubbed; this wires the seams and the multi-deal flow.
"""

from __future__ import annotations

from .detect import Mode, Tile, detect_mode, split_tiles
from .model import SEATS, Deal, DealError
from .preprocess import normalise


def _read_tile(tile: Tile, first: str) -> Deal:
    mode = detect_mode(tile)
    if mode is Mode.ROWS:
        from .rows import read_rows  # lazy: vision extras

        return read_rows(tile.image, atlas_name=tile.atlas)
    # Mode.CARDS
    from .recognize import recognise  # lazy: vision extras
    from .segment import segment

    clusters = segment(tile.image)
    hands = recognise(clusters)
    return Deal(hands={seat: hands.get(seat) for seat in SEATS}, first=first)


def _tile_to_deal(tile: Tile, first: str) -> Deal:
    """Read one tile, containing any reader failure to this tile.

    A reader stage (mode detect, compass anchor, segmentation, recognition) can
    raise on an unsupported layout -- e.g. a RealBridge/print grid with no
    BridgeWebs compass. Propagating would abort the whole page for one bad panel,
    breaking the multi-board promise. Instead we swallow the exception and return
    an all-unknown Deal tagged with the failing stage, so every board still
    reports a result the CLI can flag for manual fix."""
    try:
        return _read_tile(tile, first)
    except Exception as e:  # noqa: BLE001 - reader is best-effort per tile; any failure is contained
        return Deal(
            hands=dict.fromkeys(SEATS),
            first=first,
            note=f"reader failed ({type(e).__name__}: {e})",
        )


def image_to_deals(image_path: str, first: str = "N") -> list[Deal]:
    """image path -> one Deal per board found (in reading order).

    Deals are returned unvalidated: a misread board produces an illegal deal,
    and dropping/raising here would sink a whole multi-board page for one bad
    panel. The caller validates each deal and surfaces failures for manual fix
    (see `Deal.validate` and the CLI)."""
    image = normalise(image_path)
    return [_tile_to_deal(tile, first) for tile in split_tiles(image)]


def image_to_deal(image_path: str, first: str = "N") -> Deal:
    """Convenience for single-board images. Raises if the image holds more than
    one deal -- use `image_to_deals` for multi-table views."""
    deals = image_to_deals(image_path, first=first)
    if len(deals) != 1:
        raise DealError(f"expected 1 deal, found {len(deals)}; use image_to_deals")
    return deals[0]
