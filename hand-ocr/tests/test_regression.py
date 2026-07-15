"""Full-image regression harness: exact-read fixtures vs committed PBN sidecars.

Each `fixtures/expected/<stem>.pbn` holds the ground-truth `[Deal "..."]` line(s)
for a fixture whose boards read EXACTLY today (BBO + IntoBridge play views,
RealBridge results, BridgeWebs single boards). The test re-reads the image end to
end and asserts every deal's PBN matches, so any recognition/segmentation
regression on a known-good image fails loudly (a stronger guard than the
floor-count tests, which only check that *enough* boards are legal).

Sidecars are the curated ground truth -- regenerate deliberately (never blindly
from current output) when a fixture's correct reading changes. Unknown/face-down
hands are encoded as `-`, exactly as `Deal.to_pbn` emits them.

Skipped without the vision extra (opencv), like the other vision tests.
"""

from __future__ import annotations

from pathlib import Path

import pytest

cv2 = pytest.importorskip("cv2")  # skip whole module without the vision extra

from hand_ocr.pipeline import image_to_deals  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
EXPECTED = FIXTURES / "expected"
SIDECARS = sorted(EXPECTED.glob("*.pbn"))


def _expected_lines(sidecar: Path) -> list[str]:
    return [line.strip() for line in sidecar.read_text().splitlines() if line.strip()]


@pytest.mark.parametrize("sidecar", SIDECARS, ids=lambda p: p.stem)
def test_reads_match_expected_pbn(sidecar: Path):
    expected = _expected_lines(sidecar)
    deals = image_to_deals(str(FIXTURES / f"{sidecar.stem}.png"))
    assert [d.note for d in deals] == [None] * len(deals), f"reader flagged: {[d.note for d in deals]}"
    assert len(deals) == len(expected), f"{sidecar.stem}: {len(deals)} deals, expected {len(expected)}"
    assert [d.to_pbn() for d in deals] == expected


def test_sidecars_present():
    # guard the harness itself: catch an accidentally-emptied expected/ dir
    assert SIDECARS, "no expected/*.pbn sidecars found"
