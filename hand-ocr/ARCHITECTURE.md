# hand-ocr — architecture, in plain language

This document explains, for a reader who is **not** assumed to know computer
vision or bridge software internals, what this tool does, how it is built, which
libraries do the heavy lifting, and the algorithms behind each step. Pair it
with `README.md` (quick start + status) and the module docstrings (per-file
detail). The code deliberately carries dense comments for the same reason.

---

## 1. What problem it solves

A bridge "deal" is four hands of 13 cards (North, East, South, West). Lots of
websites and printouts show a deal as a **picture**: a screenshot from an app, a
results page, or a club printout. This tool takes such a **picture** and turns it
back into **text** a computer can use — specifically the two standard interchange
formats used elsewhere in this repo:

- **PBN** (Portable Bridge Notation) — the canonical text output. Crucially it
  can say a hand is *unknown* by writing `-`. That matters because some pictures
  only show two hands (declarer + dummy) and hide the opponents.
- **LIN** — the format BBO's "handviewer" understands. We emit it only as a
  convenience *view*, and only when all four hands are known (LIN literally
  cannot represent an unknown hand — see §6).

So: **image in → `PBN` (or `LIN`) out.** It complements the rest of the repo,
where the Odin simulator *generates* deals and the web UI *displays* them; this
tool *reads them back in* from images.

---

## 2. The big picture (pipeline)

Everything flows one direction, image to text:

```
 image file
   │
   ▼  preprocess.py      load the pixels, clean them up
 grayscale picture
   │
   ▼  detect.py          is this ONE deal or a GRID of many? split into "tiles"
 one tile per deal
   │
   ▼  detect.py          which VISUAL STYLE is this tile? (two possible grammars)
   │
   ├── style A "CARDS"  ─▶ segment.py + recognize.py
   │                       (app screenshots: BBO, IntoBridge)
   │
   └── style B "ROWS"   ─▶ rows.py
                           (diagram/printout style: BridgeWebs, RealBridge, club prints)
   │
   ▼  model.py           assemble a Deal, CHECK it is legal, print PBN / LIN
 PBN / LIN text
```

The two "styles" exist because the source pictures are genuinely different kinds
of image (explained in §4). A small detector picks the style per tile, so one
program handles both.

---

## 3. The libraries and tools involved

| Tool | Role | Why this one |
|---|---|---|
| **Python** | the language | matches the rest of the repo's tooling |
| **uv** (astral) | dependency + environment manager | repo standard; `pyproject.toml` here defines deps |
| **OpenCV** (`cv2`) | image processing | the standard library for reading pixels, finding shapes, colour masks |
| **NumPy** | fast numeric arrays | OpenCV images *are* NumPy arrays; we do array maths on them |
| **PaddleOCR** *(optional)* | text recognition fallback | only for hypothetical noisy/photographed input — none exists or is expected; heavy, so optional and unscheduled |
| **docopt** | command-line parsing | the usage text *is* the parser; matches sibling scripts in this repo |
| **ruff** (astral) | linter + formatter | one tool for both; 120-column style shared with the repo |
| **ty** (astral) | type checker | catches type mistakes; astral's fast checker |
| **pytest** | test runner | runs the model/format tests |
| **just** | task runner | `just test`, `just qa`, `just run …` — shared repo convention |

**Design choice worth understanding:** the vision libraries (OpenCV, PaddleOCR)
are **optional extras**. The core — building a deal, validating it, printing PBN
— needs none of them. That keeps the tested "spine" tiny and fast, and means the
test suite runs anywhere without installing a big vision stack. You add the extra
only when processing real images: `uv sync --extra vision`.

---

## 4. The two visual "modes" (the key insight)

Bridge pictures come in two fundamentally different visual grammars. Telling them
apart, and reading each correctly, is the heart of the tool.

### Mode CARDS — app "play view" (BBO, IntoBridge)

The screen shows a card table. Each card is a little white rounded rectangle with
a **rank** (like `K`) and a **suit symbol** (♠♥♦♦) in its top-left corner.

Non-obvious facts learned from real screenshots (each one would be a bug if
assumed wrong):

- **Suit is read per-card from the symbol**, *not* from where the card sits.
- **Colour ≠ suit universally.** BBO uses a 2-colour deck (red for hearts/
  diamonds, black for spades/clubs — so colour alone is ambiguous). IntoBridge
  uses a 4-colour deck (spades blue, hearts red, diamonds orange, clubs green —
  colour alone is enough). So the *shape* of the suit symbol is the reliable
  signal; colour only assists.
- **Seat is not screen position.** BBO puts North at the top; IntoBridge can put
  West there. So we read the little "N/E/S/W" badge next to each hand rather than
  assuming "top = North".
- **Hidden hands.** In a 2-hand view the opponents are shown face-down (card
  backs). They produce no readable cards → that seat is left *unknown* → `-` in
  PBN. This is exactly why PBN is our canonical format.

### Mode ROWS — diagram / printout style (BridgeWebs, RealBridge, club prints)

The classic printed look: four hands around a central compass box, each hand
written as **four text rows**, one per suit, top to bottom always **♠ ♥ ♦ ♣**:

```
        ♠ A 10 5
        ♥ A 6 4
        ♦ K 9 2
        ♣ A 9 5 3
```

Here the original, simpler intuition holds:

- **Suit is positional** — row 1 is spades, row 2 hearts, etc. The leading suit
  symbol is only a double-check.
- Always shows **all four hands** → a full deal (LIN-emittable).
- Comes with **free extra information** next to the diagram — board number,
  dealer, vulnerability — which we capture into the PBN header tags.
- **Sub-formats vary:** BridgeWebs writes ranks spaced with "10" (`A 10 5`);
  club printouts write them tight with "T" (`AT5`). So the reader must not assume
  spaces, and both spellings of ten are normalised to `T` internally.

### Multi-deal

Some pictures (a club printout) are a **grid of many boards** in one image — up
to ~30. The detector finds each board panel and yields one deal per panel, so a
single file can produce many PBN records.

---

## 5. The algorithms, step by step

Nothing here uses machine learning for the core path — the pictures are clean,
computer-drawn diagrams, so classical image processing is more accurate, faster,
and needs no training data. (Machine-learning OCR is only the *fallback* for
genuinely messy input.)

1. **Preprocess** (`preprocess.py`). Load the image; convert to grayscale.
   All real inputs are clean digital renders, so this is nearly a no-op. A
   *deskew* step (straighten a tilted image, reduce noise) is designed for the
   hypothetical photographed/scanned case, but no such input exists or is
   expected — it stays a stub. *Algorithm, if ever needed:* threshold to find
   the page/text, measure its dominant angle, rotate back.

2. **Split into tiles** (`detect.py`). Find the repeated rectangular board
   panels. *Algorithm:* find contours (outlines) of panel-sized rectangles; a
   single-board image just returns one tile covering everything. Tiles are
   ordered top-to-bottom, left-to-right so output matches reading order.

3. **Detect the mode** (`detect.py`). *Algorithm:* look for the green compass
   square (ROWS) versus many white card rectangles on a green baize (CARDS) — a
   colour histogram plus a template for the compass square separates them.

4. **Mode ROWS reading** (`rows.py`):
   - *Find the centre box* by masking the distinctive green colour and taking its
     outline — a strong, unambiguous anchor. (This step is **implemented and
     verified**: on `bridgewebs-4-2.png` the green mask locates the compass and
     the four hand boxes derive from it correctly.)
   - *Place the four hand boxes* at fixed offsets around that anchor (N above,
     S below, W left, E right).
   - *Split each hand box into four rows* (equal vertical slices) → suit by row.
   - *Segment each row into individual glyphs* using **connected components**:
     group touching dark pixels into blobs; each blob is one character. This is
     how we split `AT5` into `A`, `T`, `5` without relying on spaces.
   - *Recognise each glyph* with **template matching** (§ below).

5. **Mode CARDS reading** (`segment.py` + `recognize.py`):
   - *Find the cards* (white shapes on green) and split each hand into cards
     (strip pitch, or grid components / merged-blob suit glyphs).
   - *Group cards into hands* by table region; seat by position (BBO) or by the
     N/E/S/W badge nearest each group (IntoBridge, which rotates seats).
   - *Per card:* split it into rank/suit bands by ink profile, match the whole
     rank region against the rank atlas, and read the suit by shape (BBO) or by
     colour (IntoBridge's 4-colour deck).

6. **Template matching** (the recogniser, `recognize.py`). The alphabet is tiny —
   `A K Q J T 9 8 7 6 5 4 3 2` plus four suit symbols. We keep a small **atlas**
   of reference pictures for each symbol (per source, because fonts differ) and
   compare each cut-out glyph against them, picking the best match. Because the
   source glyphs are pixel-identical from a given website, this is extremely
   accurate and needs no training. Low-resolution printouts are upscaled to a
   fixed size first so the comparison is fair. If the best match is weak, we fall
   back to **PaddleOCR** (the optional machine-learning reader).

7. **Assemble + validate** (`model.py`). Put the recognised cards into a `Deal`
   and **sanity-check** it: each known hand must have exactly 13 cards, no card
   may appear twice, no suit may overflow. A picture misread produces an illegal
   deal, and this check *flags* it for a human rather than silently emitting
   garbage.

8. **Emit** (`model.py`). Print the deal as PBN (with `[Board]/[Dealer]/
   [Vulnerable]` tags when Mode ROWS gave us that metadata), or as LIN.

---

## 6. Why PBN is canonical and LIN is only a view

- **PBN** can mark an unknown hand with `-`. The declarer+dummy screenshots hide
  two hands, so we *must* be able to say "unknown". PBN can; therefore it is our
  source of truth.
- **LIN** (`md|…`) has no way to say "unknown". If you give it fewer than four
  hands it silently *invents* the missing cards from whatever is left over —
  which would fabricate a wrong deal. So the tool refuses to emit LIN unless all
  four hands are known, and always keeps PBN as the real answer.

---

## 7. Current status (what's real vs. planned)

Snapshot 2026-07-16 (87 tests). See `PLAN.md` for the full per-session log and
next step; `README.md` §Status (or `just sweep`) for the fixture-by-fixture
result. Brand-new here? Start with `TUTORIAL.md`.

- **Done and tested:** the text/format core (`model.py`) — deals, validation,
  PBN (+ metadata tags), LIN — with no vision libraries.
- **Mode ROWS — working on four sources:** BridgeWebs (green/red **compass**
  anchor; single boards exact, multi-table grids mostly valid), RealBridge
  results (compass-less **suit-quadruple anchor** in `anchor.py`; 4/4 exact),
  RealBridge **replay** (baize, scale-robust anchor + own atlas; 4/4 exact +
  **full Board/Dealer/Vul/Contract/Declarer/Result metadata**), and club-print
  grids (tiled by ruled **board frames**; recognition is **resolution-bound** —
  high-res exports read exact, regular ~12px grids only partly). Recognition is a
  per-source template **atlas** (`atlas/{bridgewebs,realbridge,realbridge-replay,
  print,print-zoomed}`).
- **Mode CARDS — BBO + IntoBridge (full-scale renders):** N/S strips split by
  card pitch. Grids come two ways: BBO's are gapped, so each card is its own
  white component; IntoBridge's are gapless, so a hand is one merged blob split
  by suit glyph. Suit is read by shape (BBO, 2-colour) or **colour** (IntoBridge,
  4-colour); seat by position (BBO) or the N/E/S/W **badge** (IntoBridge, which
  rotates seats -- `read_seat_badges`). Rank is matched whole (`rank_image`) with
  rank/suit bands found per card from the ink profile (`_card_bands`). Both
  `bridge-base-4-hand-large` and `intobridge-4-hand-large` read **4/4 exact +
  validates**; face-down / hidden hands → `-`.
- **Not yet:** the cross-scale / low-res tail -- small IntoBridge CARDS renders
  and regular low-res print grids (both segmentation-bound). `preprocess` deskew
  + the PaddleOCR fallback stay documented stubs (no photographed input is
  expected).

Everything degrades safely: a stage that cannot read a tile returns an
all-unknown deal tagged with the failing stage (`Deal.note`), never a crash.
