# hand-ocr

Bridge hand-diagram **image → parsed deal text**. Ingests a raster screenshot
(app screenshot from BBO / IntoBridge, or a digitally rendered print-style
diagram — every input is a clean digital PNG; photographed/scanned input is
**not** expected) and emits **PBN** (canonical) or **LIN** (view). Complements the existing pipeline: `odin-sims` *generates* deals, the
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
| Digital render (screenshot / print-style) | pixel-identical per source | template / tiny classifier — near 100%, no training data |
| Photo/scan (hypothetical — no such input expected) | arbitrary font, skew, noise | PaddleOCR fallback (stub, unscheduled) |

Suit is always the 4-way glyph classifier (no OCR). Rank tries the template and
falls back to OCR per card when confidence is low → source detection automatic,
no user flag. In practice every real input is a digital render, so the template
path is the whole story; the OCR fallback stays a stub unless photographed
input ever actually appears.

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
- `realbridge-replay*.png` = a DIFFERENT ROWS sub-layout: no compass, hands on
  green baize with red seat badges; own font. **Handled** — 4/4 exact + full
  metadata (see Status).
- `print-*` = club-printout suit-row grids (Mode ROWS, multi-deal): grid dims
  vary (`3x4`=12 boards, `4x5`=18, `5x6`≈30), **compact ranks + "T"**, often
  low resolution. Fixtures for arbitrary-grid tiling + scale-tolerant reading.

"printed" here = a print-*style* layout **rendered digitally** — a screenshot
of print output, NOT a photo/scan. Photographed/scanned input is out of scope
(none exists or is expected); the deskew path (`preprocess.estimate_skew`) and
the PaddleOCR fallback remain designed-but-unscheduled stubs for that
hypothetical only.

## Status

Full history + next step: see `PLAN.md`; live per-fixture results: **`just
sweep`**. Snapshot (2026-07-16): **87 tests** (incl. a PBN-sidecar regression
harness pinning 11 exact-read fixtures); every fixture either produces a deal or
**soft-fails** (flagged partial), none crash.

- **Done & tested:** model layer — `Deal`/`Hand`, PBN(+Board/Dealer/Vul tags) +
  LIN emit, validation (`hand_ocr/model.py`). Runs with no vision deps.
- **Mode ROWS — three sources.**
  - *BridgeWebs (compass)* — end to end: compass anchor → hand boxes → row/glyph
    segmentation → template-atlas recognition. `bridgewebs-4-2.png` all four
    hands exact + validates. Multi-table grids tile via clustered compass
    centroids; `3x3-multi` **6/9**, `…-part2` **9/9**, `…-multi-table` **6/6**.
  - *RealBridge results (compass-less)* — `hand_ocr/anchor.py` locates hands by
    their vertical **black-red-red-black** suit-glyph colour quadruple (no
    compass, no suit atlas); `rows._hand_boxes_from_stacks` seats them by
    geometry. `realbridge-4-results.png` **4/4 exact + validates**.
  - *RealBridge replay (baize, no compass)* — big hand glyphs amid small UI text;
    a scale-robust anchor + white-card routing + own `realbridge-replay` atlas.
    Both `realbridge-replay-*.png` **4/4 exact + validate**, and emit the **full
    metadata block** (Board/Dealer/Vulnerable from the board number + duplicate
    rotation; Contract/Declarer/Result parsed from the info box).
  - *Club-print grids* — tiled by ruled board rectangles (`detect._frame_tiles`,
    no compass). Recognition is **resolution-bound**: high-res "zoomed" exports
    read well (`print-4x5-zoomed-format-high` **8/8**), regular ~12px grids only
    partly (`print-3x4-format` board 1 exact, 3/12 overall — segmentation tail).
- **Mode CARDS — BBO + IntoBridge (full-scale renders).**
  - *BBO* (2-colour, seats by position): N/S strips split by pitch, W/E gapped
    grids as separate white components. `bridge-base-4-hand-large.png` **4/4
    exact + validates**; 2-hand and the smaller renders exact too.
  - *IntoBridge* (4-colour, **rotated** seats, gapless grids): the grid is one
    merged blob split by suit glyph; suit read from **colour**; seat from the
    N/E/S/W **badge** (`read_seat_badges`). `intobridge-4-hand-large.png` **4/4
    exact + validates**, `intobridge-2-hand-large.png` E/W exact.
  - *Recognition* matches the whole rank region as one image (`rank_image`, so
    "10"/split-"K" need no per-glyph split) and finds each card's rank/suit bands
    from its ink profile (`_card_bands`). Atlases in `hand_ocr/atlas/{bbo,
    intobridge}` (rank, suit, and for IntoBridge a seat-letter atlas).
- **Shipped atlases:** `atlas/{bridgewebs,realbridge,print}` (ROWS ranks),
  `atlas/bbo/{rank,suit}` + `atlas/intobridge/{rank,suit,seat}` (CARDS), built by
  `tools/build_atlas.py` / `tools/build_cards_atlas.py`.

### Known limitations (next fixes — priority in `PLAN.md`)
- **Cross-scale / low-res CARDS:** `intobridge-2-hand-small` and `-4-hand-small`
  still mis-segment a seat. Same theme as the ROWS `print-4x5`/`5x6` regular-grid
  tail. Fix = same-scale atlas / upscale-before-match, not rescaling exemplars
  (that was disproven). The resolution lever is proven for prints: high-res
  exports read exact where regular ~12px grids can't (session 11).
- **Still stubbed (unscheduled):** `preprocess` deskew and the `paddleocr` OCR
  fallback — all real input is clean digital renders, so neither is on the plan.

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

New to the project? **`TUTORIAL.md`** is a from-scratch, plain-language walkthrough
(bridge basics → what the tool does → how each step works → the tools/tech it
uses). `ARCHITECTURE.md` is the tighter pipeline/library/algorithm reference.

## Run

```shell
# spine check — no vision deps
just demo                       # partial deal -> PBN with '-'
just demo --format=lin          # errors: LIN needs 4 hands
# equivalently: uv run hand-ocr.py --demo

# real image
just sync-vision
just run fixtures/bridgewebs-4-2.png --format pbn

# run EVERY fixture and print one valid/total status line each (the eyeball check)
just sweep
just sweep fixtures/print-*        # or just a glob
```

> **Python 3.14 caveat:** PaddleOCR wheels lag CPython releases and may not
> import on 3.14. The template path (app screenshots) needs only opencv+numpy;
> keep OCR optional until a compatible Paddle wheel exists, or run the OCR path
> under a separate 3.11/3.12 venv.

## Next (implementation order)

See **`PLAN.md`** ("Next step") for the reviewed plan. Done so far: containment
→ suit-quadruple anchor (RealBridge 4/4, print grids tiled) → Mode CARDS BBO +
**IntoBridge** (colour suit, badge seats, merged grids) → **RealBridge replay**
4/4 + full metadata → the print **resolution lever** (high-res exports read
exact). **Remaining** is the diminishing-returns tail: cross-scale small/cramped
CARDS renders and regular low-res print grids (segmentation-bound). Deskew +
PaddleOCR stay out of scope — no photographed input exists or is expected.
