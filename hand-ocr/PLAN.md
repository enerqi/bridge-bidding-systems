# hand-ocr — plan

State review + forward plan, written 2026-07-11 after re-running the full
fixture sweep. Pair with `README.md` (status detail) and `ARCHITECTURE.md`
(pipeline walkthrough).

---

## Progress log

- **2026-07-12 (session 3).** Anchor wired to deals; RealBridge + print atlases.
  - *Seat assignment + wiring* — `rows._hand_boxes_from_stacks` turns the
    anchor's `HandStack`s into the four seat boxes (N top / S bottom / W left /
    E right by geometry); `rows._seat_boxes` tries the compass first and falls
    back to the anchor. `read_rows` picks the atlas by source (+ an explicit
    `atlas_name` hint). **RealBridge `realbridge-4-results.png` now reads 4/4
    EXACT and validates** — first compass-less deal. No compass-path regression
    (bridgewebs 1, 3x3 6/9, multi-table 5/6 unchanged).
  - *RealBridge atlas* — built from board 5 via `tools/build_atlas.py`
    (generalised to a per-fixture `LABELLED_BOARDS` map; multi-board sources
    tiled first, board 1 used).
  - *Print grid tiling* — club-print grids have no compass but ruled board
    rectangles; `detect._frame_tiles` tiles by those frames (uniform-size
    contour grid), tagging each tile for the print atlas. **`print-3x4-format`
    now tiles 12/12 boards** (was a crash). Threaded via a new `Tile.atlas`
    hint.
  - *Print atlas + a real bug fix* — added a print atlas (ten drawn compact
    "T"). Building it surfaced a latent bug: `atlas.ATLAS_LABELS` lacked `T`, so
    `Atlas.load` silently dropped every `T_*.png` (BridgeWebs only ever used
    "10", so it never bit). Added `T`; RealBridge/print T glyphs now load.
  - *Print recognition still 0/12 valid* — after the T fix, recognition is
    correct where segmentation is (board 1: W,E rows exact), but `_box_rows`
    over/under-segments the tiny compact glyphs (e.g. ♦K92 → "A36K", short S
    rows), so no board hits a clean 13. This is the plan's low-res segmentation
    tail (step 5) — deliberately not chased (coupled-knob risk to the working
    paths). Pins added: RealBridge 4/4 exact, print tiles == 12. 30 tests pass.

- **2026-07-11 (session 2).** Steps 1-2 done; step 3's core brick landed.
  - *Step 1 housekeeping* — docs corrected (`ARCHITECTURE.md` §7, `README.md`
    test count); `keep_main_run` already committed.
  - *Step 2 crash containment* — `pipeline._tile_to_deal` now wraps the reader
    (`_read_tile`) and, on any reader exception, returns an all-unknown Deal
    tagged with `Deal.note` (the failing stage) instead of propagating. The CLI
    surfaces the note as `unread deal (flag for manual fix): …`. All seven
    previously-crashing fixtures now report soft per-board failures; no
    tracebacks. 24 tests pass (was 19).
  - *Step 3 anchor* — `hand_ocr/anchor.py`: the universal template-free ROWS
    anchor (`find_hand_stacks`). Detects each hand by its vertical
    **black,red,red,black** suit-glyph colour quadruple — no compass, no suit
    atlas (the atlas has none). **Validated**: `realbridge-4-results` 4/4,
    `print-3x4-format` 48/48 hands, and `bridgewebs-4{,-2}` still 4/4 (DD-grid
    stray red pairs correctly rejected), pinned in `tests/test_anchor.py`. This
    retires the plan's flagged "anchor welded to one source" structural flaw at
    the detection layer. **Remaining to make it produce deals** (below): wire
    into `read_rows` (seat assignment from stack geometry) and
    `detect.split_tiles` (compass-less grid tiling), and build per-source
    recognition atlases (RealBridge, print) — anchoring alone still yields
    flagged deals against the BridgeWebs atlas.
  - *Low-res note* — `print-4x5`/`print-5x6` under-count: their tiny red glyphs
    shatter under the colour mask (a morphological close is a net loss). Needs
    upscale-before-mask, deferred with the low-res atlas work (step 5).

---

## Where we are (verified 2026-07-11)

19 tests pass. Fixture sweep (`uv run --extra vision python hand-ocr.py <img>`):

| Fixture group | Result |
|---|---|
| `bridgewebs-4{,-2}.png` singles | 1/1 each — all four hands **exact**, deal validates |
| `bridgewebs-4-3x3-multi.png` (9 boards) | 6/9 valid |
| `bridgewebs-4-3x3-multi-part2.png` (9 boards) | 3/9 valid |
| `bridgewebs-4-multi-table.png` (6 boards) | 5/6 valid |
| `realbridge-4-results.png` | **crash** — `_compass_bbox` finds no BridgeWebs compass |
| `realbridge-replay*.png` (2) | crash — layout has no compass at all |
| `print-*.png` grids (4) | **crash** — `split_tiles` needs green compass to tile |
| CARDS: `bridge-base-*`, `intobridge-*` (9) | crash — `segment.py` still a stub |

So 15 of 22 fixtures produce nothing, and every one of those dies with a
traceback rather than a flagged partial result.

Uncommitted diff: `rows._box_rows` neighbour-bleed filter (`keep_main_run`).
A/B-tested by stashing: grid numbers identical with and without (6/3/5), so it
is a metric no-op — but it removes genuinely phantom glyphs (stray ink from the
adjacent board pulled in by the wide E/W tile crop), so it stays.

## Architecture verdict

**Core is sound — no rewrite.** These earned their keep and stay:

- **Spine / vision split.** `model.py` (Deal/Hand, PBN+LIN, validation) has no
  vision deps; tests run anywhere. Vision stack is an optional extra.
- **Two modes** (CARDS play-view vs ROWS suit-row diagram), routed per tile.
- **Template atlas over ML.** Digital renders are pixel-stable; nearest-exemplar
  NCC took BridgeWebs from zero to exact with no training data. The
  self-training experiment (harvest glyphs from valid boards, re-add as
  exemplars) bought +1 board for 8× atlas bloat — confirmed dead end.
- **Validate-and-flag, never silently drop.** A misread board yields an illegal
  Deal that validation flags for a human; PBN `-` handles unknown hands.

**One real structural flaw: the anchor is welded to one source.** Both
`rows._compass_bbox` (hand-box placement) and `detect.split_tiles` (grid
tiling) require the BridgeWebs green/red compass square. Every blocked ROWS
fixture — `realbridge-4-results`, both `realbridge-replay*`, all four
`print-*` grids — fails at *anchoring*, before recognition ever runs. "Mode
ROWS" is currently really "Mode BridgeWebs". Stacking another special-case
anchor per source means a fresh debugging cycle each time (the colour-split
attempt showed how coupled these knobs get).

**The fix is in the data, not more per-source code.** Every ROWS hand is four
stacked text rows, each starting with a suit glyph, always in ♠ ♥ ♦ ♣ order.
That quadruple is the *universal* ROWS anchor:

- detect suit-shaped blobs → group vertically-aligned 4-stacks → each stack is
  a hand's left edge → hand boxes derive from the stack, no compass needed;
- clusters of four hand-stacks give the board grid → compass-less tiling for
  `print-*`;
- the existing compass path remains as the verified fast path / cross-check
  for BridgeWebs, and still supplies vulnerability metadata.

One mechanism unblocks seven fixtures across three sources.

**Second, smaller flaw: crash containment.** `pipeline.image_to_deals`
promises a bad panel won't sink the page, but an anchor failure raises
straight through. Reader errors must be caught per tile.

**Considered and rejected:**

- *VLM / cloud OCR* — against the offline deterministic design; template path
  already proves near-exact on this glyph alphabet.
- *ML rank classifier / more self-training* — see above; systematic
  render-mismatch confusions need same-render exemplars, not more of the same.
- *Rescaling / scale-augmented atlas* — measured factor ~1.07 between grid-tile
  and atlas renders; scale augmentation gave zero extra boards. Disproven.

## Plan (priority order)

### 1. Housekeeping (~30 min) — DONE

- ~~Commit the `keep_main_run` diff on `rows.py`~~ (already committed).
- ~~Fix stale docs~~ (`README.md` test count, `ARCHITECTURE.md` §7).

### 2. Per-tile error containment (~1 hr) — DONE

`pipeline._tile_to_deal` wraps the reader (`_read_tile`); on any reader
exception it returns an all-unknown Deal tagged with `Deal.note` (failing
stage) instead of propagating. CLI surfaces it as `unread deal …`. All seven
tracebacks killed; every image reports per-board results.

### 3. Suit-quadruple anchor — the architecture change

The big unlock. Progress:

1. ~~Suit-glyph blob detector~~ — DONE, but **template-free**: the atlas has no
   suit exemplars, so instead of shape-matching we key on the vertical
   **black,red,red,black** colour quadruple (H/D red, S/C black in every ROWS
   source). See `hand_ocr/anchor.py`.
2. ~~Group into vertical 4-stacks~~ — DONE. `find_hand_stacks` returns one
   `HandStack` (left edge + four S,H,D,C row centres + pitch) per hand.
   Validated in `tests/test_anchor.py` (realbridge 4/4, print-3x4 48/48,
   bridgewebs preserved 4/4).
3. ~~Seat assignment~~ — DONE. `rows._hand_boxes_from_stacks`: N top / S bottom
   / W left / E right by stack geometry; `_seat_boxes` = compass-first, anchor
   fallback.
4. ~~Wire + RealBridge atlas~~ — DONE. `read_rows` consumes anchor boxes when
   `_compass_bbox` raises and picks the atlas by source. **`realbridge-4-results`
   4/4 exact + validates.** Atlas built via generalised `build_atlas.py`.
5. **Print grids — tiling DONE, recognition is the open tail.** `print-3x4`
   tiles 12/12 via `detect._frame_tiles` (ruled board rectangles; no compass
   needed) + a print atlas is shipped. BUT 0/12 validate: `_box_rows`
   over/under-segments the tiny compact glyphs. Needs low-res segmentation
   tuning (and, for `print-4x5`/`5x6`, upscale-before-mask — the anchor colour
   mask still shatters their glyphs, so they don't even tile). This is the
   diminishing-returns tail; left deliberately for later.
6. Then `realbridge-replay*.png` (own font, spaced "10", big glyphs > anchor's
   `_H_MAX` cap — relax it with that source's atlas).

Compass path stays untouched for BridgeWebs. NB `atlas.ATLAS_LABELS` now
includes `T` (was silently dropping compact-ten glyphs on load).

### 4. Mode CARDS (`segment.py` + `recognize.py`)

Biggest functional gap: 9 fixtures at 0%. Design already specified in the
module docstrings and README (mini-card white rectangles on baize; rank+suit
read at the top-left index corner; hands by spatial cluster; seat from the
N/E/S/W badge, never position; BBO 2-colour vs IntoBridge 4-colour; face-down
hands → PBN `-`). Steps: `find_card_cells` → `cluster_hands` →
`read_seat_badges` → suit 4-way glyph classify → rank atlas per app (BBO
first, then IntoBridge).

Independent of step 3 — order 3 ↔ 4 by which sources are actually needed
first (diagram/print ingestion vs app screenshots).

### 5. Only if 9/9 grids become necessary

Residual grid failures (6/9, 3/9) are render-mismatch recognition confusions:
the atlas was built from a standalone render, grid tiles render slightly
differently, so the same shapes misread the same way everywhere. Real fix is
known and cheap in principle: hand-label ONE grid tile (~52 glyphs) → build a
same-render atlas. Skip while grids stay majority-valid.

### 6. Out of scope

`preprocess` deskew + `recognize.OcrBackend` (PaddleOCR fallback). All real
input is a clean digital render — the `print-*` fixtures are *screenshots of
print output*, not photos/scans, and no photographed input exists or is
expected. The stubs stay (documented hypothetical) but nothing is scheduled.
Funbridge support likewise dropped for now (no fixture, no demand).

## Fixture coverage (assessed 2026-07-11)

The 22 fixtures cover every planned step; no new images needed. The cramped /
low-res ones (`intobridge-4-hand-cramped`, `print-*`, `…-very-small`) are the
right stress tier — realistic, keep as-is. The `print-*` multi-board grids are
the **typical** rendered print output form, so grid handling is mainline, not
long tail. Worth more than new images: expected-PBN sidecar files for the
boards that already read exactly, turning floor-count tests into a real
regression harness (see step 1 follow-on).
