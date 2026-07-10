# hand-ocr

Bridge hand-diagram **image → parsed deal text**. Ingests a raster screenshot
(app screenshot from BBO / Funbridge / IntoBridge, or a photo/scan of a printed
diagram — everything becomes a PNG) and emits **PBN** (canonical) or **LIN**
(view). Complements the existing pipeline: `odin-sims` *generates* deals, the
norn HTML UX *displays* them, `hand-ocr` *ingests* them from images.

## Why PBN is canonical, LIN is only a view

- **PBN `[Deal ...]`** can mark a hand **unknown** with `-`. That is exactly the
  declarer + dummy case (E/W unknown). Canonical output.
- **LIN `md|`** *cannot* mark a hand unknown — omitted hands are silently
  auto-filled from the remaining cards, which fabricates E/W. So LIN is emitted
  only when **all four hands are known**, purely to feed the BBO handviewer
  iframe used in `deal-simulations/tcl-sims`. `to_lin` raises on a partial deal.

## Design: two recognition modes + multi-deal

The fixtures fall into two distinct visual grammars; a per-tile detector
(`detect.py`) routes each to its segmenter. And one image may hold **many**
deals, so the entry point returns a list.

| Mode | Fixtures | Unit | Suit from | Hands |
|---|---|---|---|---|
| **CARDS** (`segment.py`) | `bridge-base-*` (BBO), `intobridge-*` | mini-card | per-card glyph shape (colour app-specific) | may be partial (face-down) |
| **ROWS** (`rows.py`) | `bridgewebs-*`, `realbridge-*` | 4 text rows/hand `♠ A 10 5` | **row position** (+ leading glyph), 2-colour | always 4 known |

- **Multi-deal.** `bridgewebs-4-multi-table.png` is a grid of 6 board panels →
  6 deals. `detect.split_tiles` yields one tile per board;
  `pipeline.image_to_deals` returns `list[Deal]` (reading order).
- **Free metadata (ROWS only).** Board #, dealer, vul sit beside the diagram
  ("Dlr: North" / "Vul: None" / centre number) → captured into
  `Deal.board/dealer/vul` and emitted as PBN `[Board]/[Dealer]/[Vulnerable]`
  tags via `to_pbn_tags`. Double-dummy makeable grid, optimum/par, HCP and
  traveller results are **out of core scope** (future).

### Mode CARDS — the mini-card is the atomic unit

What is invariant across BBO and IntoBridge, 2-hand and 4-hand:

- The atomic unit is a **mini-card**: a white rounded rectangle with a rank
  glyph over a suit glyph at its **top-left index** corner. That corner stays
  visible even when cards are fanned/overlapping (W/E vertical fans), so ranks
  and suits are always read there.
- Hands are clusters: two horizontal strips (top/bottom) + two suit-grouped
  vertical fans (left/right). Card→seat is by spatial cluster.
- Rank alphabet is tiny: `A K Q J T(10) 9 8 7 6 5 4 3 2`.

Two things that a first guess gets wrong (and cost real bugs if assumed):

1. **Suit is per-card, not positional.** Read the suit glyph on each card.
   Colour is only a cross-check and its mapping is **app-specific**:
   - BBO — 2-colour deck (red = H/D, black = S/C): colour alone is ambiguous,
     the glyph shape decides.
   - IntoBridge — 4-colour deck (!s blue, !h red, !d orange, !c green): colour
     alone disambiguates.
   So the **suit glyph shape** (4-way) is the universal signal; colour assists.
2. **Seat is not screen position.** BBO puts North on top; IntoBridge in the
   same slot showed West. Read the N/E/S/W **badge** by each cluster — never
   infer seat from where the hand sits.

Face-down hands (BBO 2-hand shows W/E as card backs) produce no card cells →
that seat is unknown → PBN `-`.

### Two rank backends, one raster pipeline

The fork is **glyph consistency**, not file type:

| Source | Glyphs | Backend |
|---|---|---|
| App screenshot | pixel-identical per app | template / tiny classifier — near 100%, no training data |
| Printed → photo/scan | arbitrary font, skew, noise | PaddleOCR fallback |

Suit is always the 4-way glyph classifier (no OCR). Rank tries the template and
falls back to OCR per card when confidence is low → source detection automatic,
no user flag.

```
raster ─▶ normalise (deskew/denoise; no-op on clean screenshots)
       ─▶ split_tiles  (1, or N board panels for multi-table)
       ─▶ per tile: detect_mode
            CARDS ─▶ segment (card cells ▸ cluster ▸ seat badges) ─▶ recognise
                     (suit glyph 4-way ▸ rank template ▸ OCR fallback)
            ROWS  ─▶ read_rows (centre box ▸ compass hand boxes ▸ positional
                     suit rows ▸ rank backend) + read_metadata
       ─▶ validate each Deal (13/hand, no dup, no suit overflow) ─▶ flag misreads
       ─▶ list[Deal] ─▶ PBN (+tags) | LIN
```

## Sample screenshots (`fixtures/`)

- `bridge-base-*` = BBO (Mode CARDS), `intobridge-*` = IntoBridge (CARDS);
  `2-hand` (declarer+dummy, opponents face-down) and `4-hand`, several sizes.
- `bridgewebs-*` / `realbridge-*` = suit-row diagrams (Mode ROWS), spaced ranks
  + "10"; `bridgewebs-4-multi-table.png` is a 6-board grid;
  `bridgewebs-4-3x3-multi*.png` are 3x3 = 9-board grids (tiling fixtures).
- `realbridge-replay*.png` = a DIFFERENT ROWS sub-layout: no compass, hands in a
  3x3 cell grid with red seat badges; own font. Not yet handled.
- `print-*` = club-printout suit-row grids (Mode ROWS, multi-deal): grid dims
  vary (`3x4`=12 boards, `4x5`=18, `5x6`≈30), **compact ranks + "T"**, often
  low resolution. Fixtures for arbitrary-grid tiling + scale-tolerant reading.

"printed" here = a print-*style* layout rendered digitally, NOT a photo/scan.
No photographed sample yet — the deskew path (`preprocess.estimate_skew`) is
designed but untested against real camera noise.

## Status

- **Done & tested:** model layer — `Deal`/`Hand`, PBN(+Board/Dealer/Vul tags) +
  LIN emit, validation (`hand_ocr/model.py`). Runs with no vision deps.
- **Mode ROWS (BridgeWebs) — working end to end** (`rows.py`, `atlas.py`,
  `detect.py`, `preprocess.py`): image → compass anchor → hand boxes → row/glyph
  segmentation → template-atlas recognition → validated `Deal`. On
  `bridgewebs-4-2.png` **all four hands read exactly** and the deal validates as
  a legal 52-card deal. Shipped atlas `hand_ocr/atlas/bridgewebs/` (built by
  `tools/build_atlas.py`). Segmentation is connected-components over the whole
  hand box, clustered into rows by y-centre (robust to uneven row spacing).
  Per row the leftmost component is the suit symbol; a component wider than a
  lone suit / single rank is treated as **touching glyphs and split at ink
  valleys** (`_maybe_split`), which recovers the common `<suit>Q…` merge where a
  black ♠/♣ symbol fuses with the first rank (both black) into one blob.
- **Multi-table tiling — working** (`detect.split_tiles`): clusters the
  compass centroids into the board grid and yields one tile per board. The
  compass is coloured by **vulnerability** (green = not vul, red = vul), so the
  mask accepts both hues (`rows.compass_mask`); the central-compass filter lets
  full-cell crops ignore neighbours. `bridgewebs-4-3x3-multi*.png` → 9 boards
  each, no crash (bad boards flagged, not fatal).
- **15 tests** (11 spine + 4 ROWS; ROWS auto-skip without opencv).
- **Still stubbed:** `segment` (Mode CARDS), `preprocess` deskew,
  `recognize.OcrBackend` fallback.

### Known limitations (next fixes)
- **Grid reads are segmentation-bound, not scale-bound.** Measured: a 3×3 tile's
  compass is ~95px vs the atlas board's ~102px (factor ~1.07), and scale-
  augmenting the atlas gave **zero** extra valid boards — so the earlier "cross-
  scale drift" theory was wrong. The real blocker was suit/rank glyph *merges*;
  after the `_maybe_split` fix the grids validate `bridgewebs-4-3x3-multi.png`
  **6/9**, `…-part2.png` **3/9**, `…-multi-table.png` **5/6** (atlas board still
  4/4). Residual failures are (a) borderline merges where a wide rank fuses with
  the suit symbol just under the lone-suit width threshold (e.g. red ♦+9 → the 9
  is dropped), and (b) single-glyph recognition confusions that collide as
  duplicate cards. (b) is where a genuinely richer atlas (tile-derived exemplars)
  would help — but it needs per-tile labels, not a rescale.
- **Genuinely small/low-res fixtures still blocked upstream:** the club-print
  grids (`print-*.png`) carry **no green compass** (green fraction ~0.01), so
  they never reach recognition — they need a compass-less anchor first.
- **ROWS geometry is per-source:** RealBridge *replay* (`realbridge-replay*.png`)
  has NO compass — hands in a 3×3 cell grid with red seat badges — so it needs a
  different anchor and its own atlas. `_compass_bbox` is BridgeWebs-specific.

## Project setup

Own `pyproject.toml` (astral **uv**, Python 3.14) + `justfile`. The vision stack
is an optional extra, so the tested spine stays light.

```shell
cd hand-ocr
just sync            # base deps + dev tools (docopt, pytest, ruff, ty)
just sync-vision     # + opencv/numpy for the image pipeline
just test            # model/PBN/LIN/validation tests (no vision deps)
just qa              # ruff check + ruff format + ty check (120 cols)
```

See `ARCHITECTURE.md` for a plain-language walkthrough (pipeline, libraries,
algorithms).

## Run

```shell
# spine check — no vision deps
just demo                       # partial deal -> PBN with '-'
just demo --format=lin          # errors: LIN needs 4 hands
# equivalently: uv run hand-ocr.py --demo

# real image (once vision stages land)
just sync-vision
just run fixtures/bridgewebs-4-2.png --format pbn
```

> **Python 3.14 caveat:** PaddleOCR wheels lag CPython releases and may not
> import on 3.14. The template path (app screenshots) needs only opencv+numpy;
> keep OCR optional until a compatible Paddle wheel exists, or run the OCR path
> under a separate 3.11/3.12 venv.

## Next (implementation order)

ROWS is the easier first win (clean synthetic renders, always 4 hands, positional
suit) and covers BridgeWebs + RealBridge at once:

1. `detect.split_tiles` + `detect_mode` (compass-square vs card-baize).
2. `rows.find_centre_box` + `hand_row_crops` + rank reading → full ROWS deal;
   validate against `bridgewebs-4*` and `realbridge-4-results`.
3. `rows.read_metadata` (Dlr/Vul/board) → PBN tags.
4. CARDS: `segment.find_card_cells` + `cluster_hands` + `read_seat_badges`,
   then `recognize.classify_suit` + `TemplateBackend` atlas for BBO.
5. IntoBridge: second rank atlas + 4-colour palette prior.
6. `preprocess` deskew + `recognize.OcrBackend` (PaddleOCR) for the eventual
   printed→photo path.
