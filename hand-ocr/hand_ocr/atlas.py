"""Template atlas: recognise a single glyph by nearest-exemplar match.

Why an atlas (not a neural OCR): the source diagrams are computer-drawn, so a
given website renders every `K` as the *same* pixels. We therefore keep a small
library ("atlas") of labelled example glyphs and classify a cut-out glyph by
finding its closest example. Tiny alphabet, no training, deterministic, and —
crucially — a glyph matched against an exemplar taken from the *same* rendering
scores a perfect 1.0, so recognition within a source is essentially exact.

Representation
--------------
Every glyph (exemplar or query) is normalised to a fixed 20x28 float image in
[0, 1] (ink = 1) by `normalise_glyph`, so comparison is size-independent. The
atlas maps a label character -> a list of such exemplar images (we keep every
example, not an average: averaging blurs `2` into `9`; nearest-exemplar keeps
each variant crisp).

Matching uses zero-mean normalised cross-correlation (a.k.a. Pearson
correlation) between the query and each exemplar; the label of the best-scoring
exemplar wins, and that score is the confidence the caller can threshold on to
fall back to OCR.

On disk an atlas is a directory of PNGs named `<label>_<n>.png`, where <label>
is a rank glyph. `10` is stored as two glyphs `1` and `0`; `model` normalises a
recognised "10" to "T". Suit symbols are NOT in the atlas: in ROWS diagrams the
suit is positional (the row index), so only ranks need recognising.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

# fixed normalised glyph size (width, height); all exemplars and queries share it
GLYPH_W, GLYPH_H = 20, 28

# labels that a filename encodes; PNGs are "<label>_<n>.png". Digits 0/1 exist
# because ten is drawn "10" (two glyphs); model.py folds "10" -> "T" later.
ATLAS_LABELS = set("AKQJ0123456789")


def normalise_glyph(binary_crop: Any) -> Any:
    """Tight-crop a binary glyph (ink > 0) and resize to GLYPH_W x GLYPH_H,
    returned as float32 in [0, 1]. Returns None for an empty crop."""
    import cv2
    import numpy as np

    ys, xs = np.where(binary_crop > 0)
    if len(xs) == 0:
        return None
    tight = binary_crop[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1]
    resized = cv2.resize(tight, (GLYPH_W, GLYPH_H), interpolation=cv2.INTER_AREA)
    return resized.astype(np.float32) / 255.0


class Atlas:
    """A labelled set of exemplar glyphs with nearest-exemplar matching."""

    def __init__(self, exemplars: dict[str, list[Any]]) -> None:
        self.exemplars = exemplars  # label -> list of GLYPH_W x GLYPH_H float images

    def match(self, glyph: Any) -> tuple[str, float]:
        """Return (label, confidence) for the best-matching exemplar.

        Confidence is the zero-mean normalised cross-correlation in [-1, 1];
        1.0 is a pixel-identical match. Raises if the atlas is empty."""
        import numpy as np

        if not self.exemplars:
            raise RuntimeError("empty atlas")
        q = glyph - glyph.mean()
        qn = float(np.sqrt((q * q).sum())) + 1e-6
        best_label, best_score = "?", -2.0
        for label, examples in self.exemplars.items():
            for ex in examples:
                e = ex - ex.mean()
                score = float((q * e).sum() / (qn * (float(np.sqrt((e * e).sum())) + 1e-6)))
                if score > best_score:
                    best_score, best_label = score, label
        return best_label, best_score

    def save(self, atlas_dir: str | Path) -> None:
        """Write each exemplar as `<label>_<n>.png` under atlas_dir."""
        import cv2
        import numpy as np

        d = Path(atlas_dir)
        d.mkdir(parents=True, exist_ok=True)
        # 0/1 in filenames are fine; nothing else is a path-hostile char here
        for label, examples in self.exemplars.items():
            for n, ex in enumerate(examples):
                cv2.imwrite(str(d / f"{label}_{n}.png"), (np.clip(ex, 0, 1) * 255).astype(np.uint8))

    @classmethod
    def load(cls, atlas_dir: str | Path) -> Atlas:
        """Load an atlas directory written by `save`."""
        import cv2
        import numpy as np

        d = Path(atlas_dir)
        exemplars: dict[str, list[Any]] = {}
        for png in sorted(d.glob("*.png")):
            label = png.stem.split("_", 1)[0]
            if label not in ATLAS_LABELS:
                continue
            img = cv2.imread(str(png), cv2.IMREAD_GRAYSCALE)
            if img is None:
                raise FileNotFoundError(f"unreadable atlas glyph {png}")
            exemplars.setdefault(label, []).append(img.astype(np.float32) / 255.0)
        if not exemplars:
            raise FileNotFoundError(f"no atlas PNGs under {d}")
        return cls(exemplars)
