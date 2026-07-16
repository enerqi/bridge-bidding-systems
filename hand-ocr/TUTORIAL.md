# hand-ocr — a from-scratch tutorial

This is the gentle, start-here guide. It assumes **no** knowledge of computer
vision, and only a little about bridge. By the end you'll understand *what* the
tool does, *why* it's built the way it is, *how* each step works, and the
*tools/technology* behind it.

- Want the quick command list + current results? → `README.md` (or run `just sweep`).
- Want the tighter engineer's reference? → `ARCHITECTURE.md`.
- Want the full history + what's next? → `PLAN.md`.

---

## Part 1 — The problem, in one picture

### A tiny bit of bridge

A game of bridge is played with a standard 52-card deck. Those 52 cards are
dealt out to four players sitting at compass points: **N**orth, **E**ast,
**S**outh, **W**est — 13 cards each. One such distribution of all 52 cards is
called a **deal** (or a "board"). Each player's 13 cards are their **hand**.

A hand is usually written suit-by-suit, highest card first, using letters for
the honours: **A**ce, **K**ing, **Q**ueen, **J**ack, **T**en (`T` or `10`), then
`9 8 … 2`. The four suits are **♠** spades, **♥** hearts, **♦** diamonds, **♣**
clubs. So a hand might be:

```
♠ A K 5    ♥ Q 10 4    ♦ K 9 2    ♣ A 9 5 3
```

### The problem

Bridge websites, apps, and club printouts show deals as **pictures** — a
screenshot from an app, a results web page, a printed diagram. A picture is just
coloured pixels; a computer can't *do* anything with the deal inside it (search
it, replay it, analyse it).

**hand-ocr turns that picture back into text.** Picture in → deal as text out.

```
   ┌──────────────┐
   │  ♠ A K 5     │        hand-ocr           [Deal "N:AK5.QT4.K92.A953 ... "]
   │  ♥ Q 10 4    │   ───────────────────▶    (PBN text a computer understands)
   │  ♦ K 9 2     │
   │  ♣ A 9 5 3   │
   └──────────────┘
    (pixels)                                   (text)
```

"OCR" in the name = **Optical Character Recognition**: reading text out of an
image. That's the classic name for "turn a picture of letters into actual
letters" (the same tech that reads a scanned document or a licence plate). Here
the "characters" are card ranks and suit symbols.

Where this fits in the wider repo: the Odin simulator **generates** deals, the
web UI **displays** them — and hand-ocr **reads them back in** from images.

---

## Part 2 — The output: PBN and LIN (and why PBN wins)

The tool can emit two standard text formats. Understanding the difference
explains a design decision you'll see everywhere in the code.

- **PBN** (*Portable Bridge Notation*) — the **canonical** output. Its key power:
  it can say a hand is **unknown** by writing `-`. That matters because many
  pictures only show **two** hands (the "declarer + dummy" view) and hide the
  opponents. PBN can honestly represent "we don't know these two hands".

- **LIN** — the format BBO's online "handviewer" reads. We emit it only as a
  convenience *view*, and **only when all four hands are known**. Why the
  restriction? LIN has *no way* to write "unknown" — if you hand it fewer than
  four hands, it silently **invents** the missing cards from whatever's left
  over. That would fabricate a wrong deal, so the tool refuses to emit LIN for a
  partial deal.

**Takeaway:** PBN is the source of truth; LIN is a lossy convenience. This is why
the internal `Deal` model (see `model.py`) treats "unknown hand" as a first-class
value, not an error.

---

## Part 3 — The one big insight: two visual "modes"

Bridge pictures come in **two fundamentally different visual grammars**. Almost
the entire design follows from recognising this and handling each separately. A
small detector looks at each picture and routes it to the right reader.

### Mode CARDS — an app "play view" (BBO, IntoBridge)

Looks like a card table: each card is a little white rounded rectangle with a
**rank** and a **suit symbol** in its top-left corner.

Three facts here are *not* what you'd first guess — each one, assumed wrong, is a
bug we actually hit:

1. **Suit comes from the symbol on each card, not from position.** You must read
   the little ♠/♥/♦/♣ on every single card.
2. **Colour is not a reliable shortcut.** BBO uses a 2-colour deck (red =
   hearts/diamonds, black = spades/clubs) — so colour alone is *ambiguous*.
   IntoBridge uses a 4-colour deck (spades blue, hearts red, diamonds orange,
   clubs green) — colour alone is enough there. The **shape** of the symbol is
   the universal signal; colour only assists.
3. **Seat is not screen position.** BBO puts North at the top; IntoBridge can
   put West in that same top slot. So we read the "N/E/S/W" **badge** printed by
   each hand instead of assuming "top = North".

Bonus: in a 2-hand view the opponents are shown as **face-down card backs**. They
produce no readable cards → that seat is left **unknown** → `-` in PBN. (There's
that PBN power again.)

### Mode ROWS — a diagram / printout (BridgeWebs, RealBridge, club prints)

The classic printed look: four hands around a central compass box, each hand
written as **four text rows**, one per suit, top to bottom always **♠ ♥ ♦ ♣**:

```
        ♠ A 10 5
        ♥ A 6 4
        ♦ K 9 2
        ♣ A 9 5 3
```

Here the *simpler* intuition holds:

- **Suit is positional** — row 1 is spades, row 2 hearts, and so on. The leading
  symbol is just a double-check.
- It always shows **all four hands** → a complete deal.
- It comes with **free extra info** printed alongside — board number, dealer,
  vulnerability — which we capture into the PBN header tags.
- Sub-formats differ: BridgeWebs spaces the ranks and writes `10` (`A 10 5`);
  club printouts pack them tight and write `T` (`AT5`). The reader must not
  assume spaces, and both spellings of ten become `T` internally.

### And sometimes: many deals in one picture

A club printout can be a **grid of up to ~30 boards** in a single image. So the
very first step splits a picture into "tiles" (one per board), and the whole
tool returns a *list* of deals, not just one.

---

## Part 4 — How it works, step by step (the pipeline)

Everything flows one direction, image → text. Each arrow is a Python module.

```
 image file
   │  preprocess.py   load pixels, convert to grayscale (clean renders: near no-op)
   ▼
   │  detect.py       ONE deal or a GRID? → split into tiles (one per board)
   ▼
   │  detect.py       which MODE is this tile? CARDS vs ROWS
   ▼
   ├── CARDS ─▶ segment.py + recognize.py   (find cards, group into hands, read each)
   └── ROWS  ─▶ rows.py                      (find hand boxes, split rows, read glyphs)
   │
   ▼  model.py        assemble a Deal, CHECK it's legal, print PBN / LIN
 PBN / LIN text
```

Let's walk each stage — and pick up the general vision technique it uses.

### 4.1 Preprocess — load and clean (`preprocess.py`)

Read the image file into memory and convert to grayscale. Because every real
input is a crisp digital render (not a photo), this is almost a no-op. A *deskew*
step (straighten a tilted scan, remove speckle noise) is written as a **stub**
for a hypothetical photographed input that doesn't exist here.

> **Technique — grayscale & thresholding.** A colour pixel is three numbers
> (red, green, blue). Grayscale collapses that to one brightness number.
> *Thresholding* then turns brightness into pure black/white: "every pixel
> darker than X is ink, everything else is background". This clean two-value
> ("binary") image is what the shape-finding steps below operate on.

### 4.2 Split into tiles (`detect.py`)

Find the repeated rectangular board panels in the picture.

> **Technique — contours.** A *contour* is the outline of a connected shape.
> OpenCV can list every outline in a binary image. We keep the ones shaped like a
> board panel (roughly the right size and rectangle-ish) and treat each as one
> tile. A single-board picture just yields one tile covering everything. Tiles
> are sorted top-to-bottom, left-to-right so the output matches reading order.

### 4.3 Detect the mode (`detect.py`)

Decide CARDS vs ROWS for each tile.

> **Technique — colour masks & histograms.** A *colour mask* keeps only the
> pixels within a colour range (e.g. "greens") and blanks the rest. Counting how
> much of each colour is present (a *histogram*) is a cheap fingerprint of the
> layout: lots of white card rectangles on green baize → CARDS; a green/red
> compass square in the middle → ROWS. When colour is ambiguous we confirm with
> the universal ROWS anchor (below), so a cropped card grid with no green felt
> isn't mistaken for a diagram.

### 4.4 Reading Mode ROWS (`rows.py`, `anchor.py`)

Two ways to locate the four hands:

- **The compass path (BridgeWebs).** Mask the distinctive green/red compass
  square, take its outline, and place the four hand boxes at fixed offsets around
  it (N above, S below, W left, E right). Simple and exact when the compass is
  present.

- **The universal "suit-quadruple" anchor (`anchor.py`).** Many sources (RealBridge,
  club prints) have *no* compass. But **every** ROWS hand is four stacked rows
  whose leading suit symbols are always coloured **black, red, red, black** (♠
  black, ♥ red, ♦ red, ♣ black). That vertical colour quadruple is a fingerprint
  no compass can provide — find those 4-stacks and each marks a hand's left edge.
  One idea unlocks every compass-less source. *(This replaced an earlier design
  that was welded to the BridgeWebs compass — see `PLAN.md`'s "architecture
  verdict".)*

Then, per hand:

- Split the hand box into **four rows** (equal vertical slices) → suit by row.
- Split each row into individual character shapes (see the connected-components
  technique next) and **recognise** each with the atlas (Part 5).

> **Technique — connected components.** Group touching dark pixels into a single
> "blob"; each blob is one character. This is how `AT5` becomes `A`, `T`, `5`
> **without** relying on spaces between them — it just follows the ink.

### 4.5 Reading Mode CARDS (`segment.py`, `recognize.py`)

- **Find the cards** — white shapes on green. BBO's cards have gaps, so each card
  is its own white blob; IntoBridge's touch, so a whole hand is *one* merged blob
  that we split by locating each suit symbol inside it.
- **Group cards into hands** by table region, then assign the seat — by position
  (BBO) or by the nearest **N/E/S/W badge** (IntoBridge, which rotates seats).
- **Read each card:** split it into a rank band over a suit band using its *ink
  profile* (where the dark pixels sit vertically), match the whole rank region
  against the atlas, and read the suit by shape (BBO) or colour (IntoBridge).

### 4.6 Recognising a glyph — the "atlas" (`atlas.py`, `recognize.py`)

This is the heart of the reader, and it deliberately uses **no machine learning**
for the main path. Here's why that's the *right* call, not a shortcut:

The pictures are computer-drawn, so a given website renders every `K` as the
**exact same pixels** every time. So instead of training a neural network, we
keep a small **atlas**: a library of labelled example pictures ("this shape is a
`K`", "this one's a `7`"). To read an unknown glyph, we compare it against every
example and pick the closest match.

> **Technique — template matching by normalised cross-correlation (NCC).** Every
> glyph (example or unknown) is first scaled to a fixed small size, so comparison
> is size-independent. NCC then scores how similar two images are on a scale up to
> 1.0, in a way that ignores overall brightness (so a slightly darker render still
> matches). Because an unknown glyph is compared against examples taken from the
> *same* rendering, the true match scores essentially a perfect 1.0 — recognition
> within a known source is effectively exact, with zero training data.

Two practical notes:
- **Per-source atlases.** Different websites use different fonts, so each source
  (BridgeWebs, RealBridge, print, …) gets its own atlas of examples, built once
  from a hand-labelled board by `tools/build_atlas.py`.
- **Resolution matters.** Tiny low-res glyphs (regular club prints, ~12px tall)
  blur together and the match gets unreliable — this is the tool's main remaining
  weakness. The proven fix is *more pixels*: high-resolution "zoomed" exports read
  exact (`PLAN.md`, session 11). A machine-learning **PaddleOCR** fallback exists
  as a stub for hypothetical messy input, but no such input is expected.

### 4.7 Assemble, validate, emit (`model.py`)

Put the recognised cards into a `Deal` and **sanity-check** it: every known hand
must have exactly 13 cards, no card may appear twice, no suit may hold more than
13. This is the safety net — a misread produces an *illegal* deal, and the check
**flags it for a human** rather than silently emitting garbage.

Then print the deal as PBN (adding `[Board]/[Dealer]/[Vulnerable]` and, for
RealBridge replay, `[Contract]/[Declarer]/[Result]` tags when the picture gave us
that info), or as LIN.

> **Design principle — validate and flag, never silently drop.** Combined with
> per-tile error containment (a stage that can't read one board of a grid returns
> an all-unknown deal tagged with the failing step, instead of crashing the whole
> page), this means the tool *always* produces a result you can trust or a clear
> flag — never a wrong answer dressed up as a right one.

---

## Part 5 — The tools & technology, and why each

| Tool | What it is | Why it's here |
|---|---|---|
| **Python** | the programming language | matches the rest of this repo |
| **OpenCV** (`cv2`) | the standard image-processing library | reads pixels, finds contours, builds colour masks, does template matching |
| **NumPy** | fast numeric arrays | an OpenCV image literally *is* a NumPy array of pixel numbers; all the maths runs on it |
| **PaddleOCR** *(optional, stub)* | a machine-learning text reader | a fallback for hypothetical noisy/photographed input — none exists, so it's unscheduled and heavy, hence optional |
| **docopt** | command-line parser | the usage text at the top of `hand-ocr.py` *is* the parser |
| **uv** (astral) | Python dependency + environment manager | the repo standard; pins Python 3.14 and the deps |
| **ruff** (astral) | linter + formatter | one fast tool for both; 120-column style |
| **ty** (astral) | type checker | catches type mistakes quickly |
| **pytest** | test runner | runs the 87 tests |
| **just** | task runner | short commands: `just test`, `just qa`, `just run …`, `just sweep` |

**A design choice worth internalising:** the vision libraries (OpenCV, NumPy,
PaddleOCR) are **optional extras**. The core — building a `Deal`, validating it,
printing PBN — needs none of them. That keeps the tested "spine" tiny and fast:
the whole model/format test suite runs anywhere with no heavy vision install. You
add the extra (`uv sync --extra vision`, or just use `just sync-vision`) only when
you actually process images.

---

## Part 6 — Try it yourself

```shell
cd hand-ocr

# 1. The spine, no vision libraries needed — emits a sample deal as PBN
just demo

# 2. Install the vision stack, then read a real fixture image
just sync-vision
just run fixtures/bridgewebs-4-2.png --format pbn

# 3. Run EVERY sample image and see one status line each (valid/total boards)
just sweep

# 4. The developer checks
just test        # the model/format/vision tests (87 of them)
just qa          # lint + format-check + type-check
```

What to look for in the `just run` output: a legal deal prints as a PBN `[Deal
"…"]` line (with `-` for any unknown hand). A misread prints as `invalid deal
(flag for manual fix): …` on stderr — that's the validate-and-flag safety net
doing its job, not a bug.

---

## Where to go next

- **`README.md`** — commands, per-fixture status, project setup.
- **`ARCHITECTURE.md`** — the same pipeline in tighter, engineer-facing form.
- **`PLAN.md`** — full per-session history, the "architecture verdict" (why the
  suit-quadruple anchor exists), and the remaining diminishing-returns tail.
- **The code** — every module opens with a plain-language docstring; `model.py`
  (the vision-free spine) and `atlas.py` (the recogniser) are the friendliest
  places to start reading.
