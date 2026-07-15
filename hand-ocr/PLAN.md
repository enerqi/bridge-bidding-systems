# hand-ocr — plan

State review + forward plan. Started 2026-07-11; see the Progress log for the
per-session updates (latest first). Pair with `README.md` (status detail) and
`ARCHITECTURE.md` (pipeline walkthrough).

---

## Next step (start here)

**IntoBridge large — DONE (session 6).** `intobridge-4-hand-large` reads **4/4
exact + validates**, `intobridge-2-hand-large` E/W exact. Suit from colour
(4-colour deck), seats from the N/E/S/W badges (rotated: the top hand is West),
grids split from one merged blob by suit glyph. Two robustness wins came from
this and now cover BBO too: **whole-rank matching** (`rank_image` matches the
whole rank region as one image, so `10` and IntoBridge's split `K` need no
per-glyph segmentation) and **adaptive rank/suit bands** (`_card_bands` splits
each card by its ink profile instead of fixed fractions). Bonus:
`bridge-base-4-hand-small` now reads 4/4 (the tens no longer shatter).

**Remaining CARDS tails** (small / cramped renders):
- `intobridge-2-hand-small` mis-segments one seat (cross-scale);
- ~~`intobridge-4-hand-{small,cramped}` misrouted to ROWS~~ — **FIXED (session 7)**:
  `detect_mode` now confirms ROWS in its low-green branch with the suit-row anchor
  (`find_hand_stacks`); no stacks -> a baize-less cropped CARDS grid. Both route to
  CARDS now (cramped -> all-unknown, small -> flagged partial). Still scale-bound
  (recognition soft-fails), but on the right path;
- `bridge-base-4-hand-very-small` still yields nothing (too small to segment).
All soft-fail; none crash. Same cross-scale theme as the ROWS low-res tail.

**Regression harness — DONE (session 6).** `fixtures/expected/*.pbn` +
`tests/test_regression.py` pin all nine exact-read fixtures end to end (add a
sidecar when a new fixture reads exact). See "Fixture coverage" below.

**Pick next session from:** (a) RealBridge *replay* layout — feature, own font +
atlas, relax the anchor `_H_MAX` cap (§3.6); (b) the cross-scale / low-res tail
above + ROWS print-grid recognition (§3.5) — hard, repeatedly deferred, low
value. (~~(c) `detect_mode` tweak~~ — DONE session 7.)

See §4 (Mode CARDS) and §3.5-3.6 (ROWS print / replay) below for the full list.

---

## Progress log

- **2026-07-15 (session 7).** `detect_mode` routing tweak. The green-fraction
  discriminator assumed CARDS always shows abundant baize, so a *cropped* card
  grid with no felt (`intobridge-4-hand-{small,cramped}`, green ~0.017) fell into
  the low-green branch and was routed ROWS -> soft-failed `suit anchor found 0
  hands`. Fix: in that branch, confirm ROWS with the universal suit-row anchor
  (`find_hand_stacks`) — a real ROWS diagram yields hand stacks (genuine ROWS
  fixtures give >=4; these two give 0), so 0 stacks -> a CARDS grid. Clean split,
  reuses the existing anchor, no new per-source code; anchor exceptions fall back
  to the historical ROWS default. Both fixtures now route CARDS (cramped ->
  all-unknown, small -> flagged partial); still scale-bound (recognition
  soft-fails) but on the correct path, exactly as scoped. 62 tests pass, lints
  clean. (Rejected: seat-badge count as the discriminator — noisy:
  `bridgewebs-4-2` gave 16 false badges, `cramped` gave 0.)

- **2026-07-14 (session 6).** Mode CARDS — IntoBridge. `intobridge-4-hand-large`
  reads **4/4 exact + validates** (rotated seats de-rotated correctly);
  `intobridge-2-hand-large` E/W exact.
  - *Segmentation.* IntoBridge grids are the OPPOSITE of BBO's: cards touch with
    no gaps, so a hand is one merged portrait blob (`_is_merged_grid` gated by
    aspect/size to skip UI bars + the central trick cards). `_merged_grid_cards`
    splits it by anchoring a cell on each suit glyph (short, ~square; the taller
    rank digits are the other height class -- `_height_split`), robust to the
    two-glyph "10". Pitch from the median suit x-gap.
  - *Suit from colour.* 4-colour deck -> `suit_colour` reads the suit-symbol hue
    (D~18, C~76, S~99, H~178). `detect_app` routes BBO vs IntoBridge by the
    fraction of cards whose suit reads cool (blue/green) -- ~0.5 on the 4-colour
    deck, ~0.1 (baize slivers) on BBO.
  - *Rotated seats.* `read_seat_badges` (was a stub) reads each hand's N/E/S/W
    badge -- a white letter on a dark disc, found as a small white blob and
    matched against a new `atlas/intobridge/seat`. Seat = nearest badge to the
    cluster centroid, overriding screen position.
  - *Two general robustness wins (also help BBO).* (1) **Whole-rank matching**:
    `rank_image` matches the entire rank region as ONE image vs whole-rank
    exemplars ("10", "K"), retiring per-glyph split/merge ambiguity (IntoBridge's
    `K` is a stem + a detached ">"). (2) **Adaptive bands**: `_card_bands` splits
    each card into rank/suit from its ink row-profile (BBO packs them tight,
    IntoBridge leaves a big gap + a low "J" curl -- no fixed fraction fits both);
    ink mask is dark-OR-saturated so bright orange glyphs are captured, suit
    detection stays dark-only so green baize is never mistaken for a suit.
  - *Bonus.* `bridge-base-4-hand-small` now reads **4/4** (whole-rank matching
    ended the tens shattering at that scale).
  - *Not yet.* Small/cramped IntoBridge renders (cross-scale; two are misrouted
    to ROWS by `detect_mode`), `bridge-base-4-hand-very-small`. All soft-fail.
  - *Same session — PBN regression harness* (see "Fixture coverage" below):
    `fixtures/expected/*.pbn` + `tests/test_regression.py` pin all nine
    exact-read fixtures end to end. 62 tests pass (was 41).

- **2026-07-12 (session 5).** Mode CARDS — BBO W/E grids. `bridge-base-4-hand-
  large` reads **4/4 exact + validates** (first complete CARDS deal).
  - *Segmentation.* Corrected the plan's premise: a W/E grid is **not** a merged
    blob. Its cards are separated by green gaps and each is its own portrait
    white component (~72×145) — but only above the seat-label bar's grey, which
    at the strip threshold (200) bridges the bottom row into one blob. A higher
    threshold (`_CARD_WHITE_THR=235`) isolates every card. New `_card_comps`
    (individual cards, both strips and grids) + `_grid_cards` (grid cards =
    comps not inside a strip blob and not in the central x-band — the trick /
    played cards live at the table centre; e.g. the 2-hand view's two ♦J).
    `cluster_hands` now emits W (left) / E (right) grid clusters too.
  - *Atlas.* The old `atlas/bbo` had **no `1`/`0`** exemplars (the 2-hand deal
    has no tens), so every grid "10" misread ("10"→"J6"). `build_cards_atlas.py`
    now also harvests the W/E grids (`_reading_order`: suit rows top-to-bottom,
    BBO stacks them ♥♠♦♣; each row L→R), giving all 52 cards → `1`,`0` + richer
    suit exemplars. Rebuilt.
  - *Bonus.* The grid-enriched suit atlas also fixed `bridge-base-2-hand-small`:
    its N/S strips now read **exact** (was a ♠/♣ mix-up). Pinned.
  - *Not yet.* `bridge-base-4-hand-{small,very-small}` still soft-fail (tens
    shatter at small scale → `bad rank '0'`); IntoBridge unchanged (needs seat
    badges). No hard crashes anywhere. 39 tests pass (was 34).

- **2026-07-12 (session 4).** Mode CARDS — first working slice (BBO strips).
  - Real `segment.py` + `recognize.py` (were stubs). Insight: face-up cards
    render as ONE merged white blob per hand (`_hand_blobs`), not per card. A
    horizontal N/S strip is divided into cards by rank-glyph column pitch
    (`_strip_cards`); each card = rank glyph(s) over a suit symbol, read by
    `recognize` against a per-app rank atlas + a 4-way suit atlas
    (`atlas/bbo/{rank,suit}`, built by `tools/build_cards_atlas.py`). Border/
    suit-bleed rejected by a size+aspect glyph filter. `atlas.py` gained a
    `labels` arg on `load` + `SUIT_LABELS` (suit atlas holds S/H/D/C, not ranks).
  - **BBO 2-hand `bridge-base-2-hand-large` reads N + S EXACT and validates**;
    W/E are card backs → no blob → unknown → PBN `-` (the declarer+dummy case,
    exactly why PBN is canonical). 4-hand-large N/S exact too. First CARDS deals.
    Pinned in `tests/test_cards.py`. 34 tests pass.
  - **Not yet:** W/E **grids** (fanned/blocky, not strips) yield no cells → those
    seats stay unknown; `intobridge-*` (4-colour, seats **rotated** so position
    fails — needs the seat badge; `read_seat_badges` still a stub); and
    **cross-scale** — `bridge-base-2-hand-small` mis-reads ♠/♣ because the atlas
    is built at the large render's scale. Seat is currently position-based
    (BBO-correct only).

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

## Where we are (verified 2026-07-14, sessions 2-6 applied)

62 tests pass. Fixture sweep (`uv run --extra vision python hand-ocr.py <img>`):

| Fixture group | Result |
|---|---|
| `bridgewebs-4{,-2}.png` singles | 1/1 each — four hands **exact**, validates (compass) |
| `bridgewebs-4-3x3-multi.png` (9) | 6/9 valid |
| `bridgewebs-4-3x3-multi-part2.png` (9) | 3/9 valid |
| `bridgewebs-4-multi-table.png` (6) | 5/6 valid |
| `realbridge-4-results.png` | **4/4 exact + validates** (compass-less suit anchor + RealBridge atlas) |
| `print-3x4-format.png` (12) | tiles **12/12** (frame anchor); recognition 0/12 valid (low-res seg tail) |
| `print-4x5`/`5x6` grids | partial tiling; glyphs too small to anchor/segment — deferred |
| `realbridge-replay*.png` (2) | soft-fail — big-font glyphs exceed anchor `_H_MAX`; own atlas TODO |
| CARDS `bridge-base-2-hand-large` | **N+S exact + validates**; W/E card-backs → `-` |
| CARDS `bridge-base-4-hand-large` | **4/4 exact + validates** (N/S strips + W/E grids) |
| CARDS `bridge-base-{2-hand-small,4-hand-small}` | **exact** (cross-scale now works: 2-hand N/S, 4-hand 4/4) |
| CARDS `bridge-base-4-hand-very-small` | soft-fail — too small to segment |
| CARDS `intobridge-4-hand-large` | **4/4 exact + validates** (colour suit, badge seats, merged grids) |
| CARDS `intobridge-2-hand-large` | **E/W exact + validates**; N/S hidden → `-` |
| CARDS `intobridge-{2-hand-small,4-hand-small,4-hand-cramped}` | soft-fail — cross-scale (4-hand small/cramped now route CARDS, session 7; still scale-bound) |

Every non-green cell now **soft-fails** (flagged partial), not a traceback
(session-2 containment). Session 2-4 code is committed; sessions 4-6 leave the
`atlas/{realbridge,print,bbo,intobridge}` dirs untracked plus the sessions 5-6
`segment.py` / `recognize.py` / `atlas.py` / `pipeline.py` /
`build_cards_atlas.py` / `test_cards.py` diffs.

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

### 4. Mode CARDS (`segment.py` + `recognize.py`) — BBO + IntoBridge (large) DONE

**Done:** both apps at full render scale.
- **BBO** — horizontal strips (divided by card pitch) + gapped W/E grids
  (individual `_card_comps` at threshold 235, minus strip and central trick
  cards). `bridge-base-4-hand-large` **4/4 exact + validates**; 2-hand + small
  variants exact.
- **IntoBridge** — 4-colour deck, rotated seats, gapless grids. Grids are one
  merged blob split by suit glyph (`_merged_grid_cards`); suit from colour
  (`suit_colour` / `detect_app`); seats from the N/E/S/W badges
  (`read_seat_badges` + `atlas/intobridge/seat`). `intobridge-4-hand-large`
  **4/4 exact + validates**; `intobridge-2-hand-large` E/W exact.
- **Recognition core** — rank matched as a whole region (`rank_image`, whole-rank
  exemplars incl. "10","K"); rank/suit regions found per card from the ink
  profile (`_card_bands`); ink mask dark-OR-saturated (captures bright coloured
  glyphs), suit detection dark-only (ignores baize). Atlases via
  `build_cards_atlas.py` (harvests all 52 cards through `cluster_hands`).

**Remaining (cross-scale / low-res tail):**
- `intobridge-2-hand-small` mis-segments a seat; `bridge-base-4-hand-very-small`
  too small to segment. Same theme as the ROWS low-res tail — a same-scale atlas
  or scale-robust segmentation.
- ~~`intobridge-{4-hand-small,4-hand-cramped}` misrouted to ROWS~~ — **routing
  FIXED (session 7)**: `detect_mode` confirms ROWS via `find_hand_stacks` in its
  low-green branch, so these route CARDS. Still scale-bound (recognition
  soft-fails), but no longer misrouted.

Independent of step 3 — order by which sources are actually needed first.

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
long tail.

**Regression harness — DONE (session 6).** `fixtures/expected/<stem>.pbn`
sidecars hold the ground-truth `[Deal "..."]` for every exact-read fixture (BBO +
IntoBridge play views, RealBridge results, BridgeWebs singles);
`tests/test_regression.py` re-reads each image end to end and asserts the PBN
matches — a stronger guard than the floor-count tests. Add a sidecar whenever a
new fixture reads exact.
