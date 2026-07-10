"""Card recognition: a card's index crop -> (suit, rank).

Revised for the real screenshots. Each card carries BOTH its rank and its suit
in the top-left index, so suit is read per-card (not positional):

- **Suit** = classify the suit glyph shape, 4-way (S/H/D/C). This is the
  universal signal across apps. Colour is only a cross-check and its mapping is
  app-specific: BBO is a 2-colour deck (red = H/D, black = S/C -- colour alone
  is ambiguous, needs the glyph); IntoBridge is a 4-colour deck
  (!s blue, !h red, !d orange, !c green -- colour alone disambiguates).
- **Rank** = classify the rank glyph. App screenshots have pixel-identical
  glyphs -> template / tiny classifier, near 100%, no training data. Printed →
  photo diagrams fall back to PaddleOCR (optional, lazy; Paddle wheels may lag
  Python 3.14). Note IntoBridge renders ten as "10"; `model` normalises to T.

`recognise` assembles one Hand per seat from a segmented board.
"""

from __future__ import annotations

from typing import Any, Protocol

from .model import SEATS, SUITS, Hand
from .segment import CardCell, HandCluster

# below this rank-template confidence, defer the rank to the OCR backend
TEMPLATE_CONFIDENCE_FLOOR = 0.85


def classify_suit(index_image: Any) -> str:  # pragma: no cover - vision stub
    """Suit glyph -> one of SUITS. 4-way shape match; colour as a prior/tie-break.

    TODO: match the suit-symbol sub-crop against 4 shape templates. Optionally
    read the dominant hue and, per detected app palette, use it to break ties.
    """
    raise NotImplementedError


class RankBackend(Protocol):
    def read_rank(self, index_image: Any) -> tuple[str, float]:
        """Return (rank_char, confidence 0..1). Rank char in model.RANKS,
        with ten as 'T'."""
        ...


class TemplateBackend:
    """Per-app glyph atlas match for rank (app screenshots)."""

    def __init__(self, atlas_dir: str | None = None) -> None:
        self.atlas_dir = atlas_dir

    def read_rank(self, index_image: Any) -> tuple[str, float]:  # pragma: no cover - stub
        raise NotImplementedError("template rank match not implemented; slide atlas, argmax")


class OcrBackend:
    """PaddleOCR fallback for printed/photographed diagrams."""

    def __init__(self) -> None:
        self._ocr = None

    def _engine(self) -> Any:  # pragma: no cover - env dependent
        if self._ocr is None:
            try:
                from paddleocr import PaddleOCR  # ty: ignore[unresolved-import]  # optional 'ocr' extra, lazy
            except ImportError as e:
                raise RuntimeError(
                    "paddleocr not installed / unsupported on this Python; "
                    "install the 'ocr' extra (note: Paddle wheels may lag Python 3.14)"
                ) from e
            self._ocr = PaddleOCR(use_angle_cls=False, lang="en")
        return self._ocr

    def read_rank(self, index_image: Any) -> tuple[str, float]:  # pragma: no cover - stub
        raise NotImplementedError("OCR rank read not implemented; run engine, keep rank chars")


def read_card(cell: CardCell, template: RankBackend, ocr: RankBackend) -> tuple[str, str]:
    """One card cell -> (suit, rank). Suit is always the 4-way glyph classifier
    (no OCR); rank tries the template and falls back to OCR on low confidence."""
    suit = classify_suit(cell.index_image)
    rank, conf = template.read_rank(cell.index_image)
    if conf < TEMPLATE_CONFIDENCE_FLOOR:
        rank, _ = ocr.read_rank(cell.index_image)
    return suit, rank


def recognise(
    clusters: list[HandCluster],
    template: RankBackend | None = None,
    ocr: RankBackend | None = None,
) -> dict[str, Hand]:
    """Segmented board -> {seat: Hand}. Only clusters with a resolved seat are
    emitted; missing/face-down seats are simply absent (caller marks None)."""
    template = template or TemplateBackend()
    ocr = ocr or OcrBackend()

    hands: dict[str, Hand] = {}
    for cluster in clusters:
        if cluster.seat is None or cluster.seat not in SEATS:
            continue
        by_suit: dict[str, list[str]] = {s: [] for s in SUITS}
        for cell in cluster.cells:
            suit, rank = read_card(cell, template, ocr)
            by_suit[suit].append(rank)
        hands[cluster.seat] = Hand.from_rows(
            "".join(by_suit["S"]), "".join(by_suit["H"]), "".join(by_suit["D"]), "".join(by_suit["C"])
        )
    return hands
