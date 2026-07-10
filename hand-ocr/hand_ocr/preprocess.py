"""Raster normalisation: the shared front of the pipeline.

Both ingest sources arrive as a raster PNG. App screenshots are already clean
(no-op here); printed-then-photographed diagrams are skewed / noisy and need
deskew + denoise. `normalise` is safe to run on both -- it is a near no-op when
the input is already axis-aligned and high-contrast.

OpenCV is imported lazily so the model/PBN layer and tests run without it.
"""

from __future__ import annotations

from typing import Any


def _cv2() -> Any:
    try:
        import cv2
    except ImportError as e:  # pragma: no cover - env dependent
        raise RuntimeError("opencv-python not installed; install the 'vision' extra to run preprocessing") from e
    return cv2


def load_gray(image_path: str) -> Any:
    """Read an image from disk as a single-channel grayscale array."""
    cv2 = _cv2()
    img = cv2.imread(image_path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise FileNotFoundError(f"could not read image {image_path!r}")
    return img


def estimate_skew(gray: Any) -> float:  # pragma: no cover - vision stub
    """Return estimated skew angle in degrees (0.0 for clean screenshots).

    TODO(printed): threshold -> largest text/line contour -> minAreaRect angle,
    or Hough-line dominant angle. Return ~0 when confidence low so the deskew
    step is a no-op rather than a corruption.
    """
    raise NotImplementedError("skew estimation not implemented")


def load_bgr(image_path: str) -> Any:
    """Read an image from disk as a 3-channel BGR array (colour needed for the
    green compass mask and the red/black suit split)."""
    cv2 = _cv2()
    img = cv2.imread(image_path, cv2.IMREAD_COLOR)
    if img is None:
        raise FileNotFoundError(f"could not read image {image_path!r}")
    return img


def normalise(image_path: str) -> Any:
    """image path -> a BGR image ready for tiling/segmentation.

    For the clean digital renders we handle today this is just `load_bgr`
    (screenshots are already axis-aligned and high-contrast). The deskew /
    denoise branch for photographed input lands here later via `estimate_skew`;
    keeping it a single seam means callers never change.
    """
    return load_bgr(image_path)
