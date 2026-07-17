set windows-shell := ["nu", "-c"]
set shell := ["bash", "-c"]

# hand-ocr: bridge hand-diagram image -> PBN/LIN. Managed by astral uv (its own
# pyproject.toml). The vision stack (opencv/numpy, optional paddleocr) lives in
# extras, so plain `just test` / `just check` run against the light model+PBN
# spine without pulling opencv. `just sync-vision` adds the vision extra when
# working on the image pipeline.

# list recipes
default:
    just --list

# install base deps + dev tools (docopt, pytest, ruff, ty) into the uv env
sync:
    uv sync

# install the vision extra too (opencv + numpy) for the image pipeline
sync-vision:
    uv sync --extra vision

# install everything incl. the PaddleOCR fallback
sync-all:
    uv sync --extra vision --extra ocr

# run the test suite (model + PBN/LIN + validation; no vision deps needed)
test *args:
    uv run --with pytest python -m pytest {{args}}

# ruff lint (check only, no writes) at 120 cols
lint *args:
    uv run ruff check {{args}}

# apply ruff autofixes + format in place
format *args:
    uv run ruff check --fix {{args}}
    uv run ruff format {{args}}

# QA gate: lint + format-diff check + astral ty type check, no writes. Run before commit.
qa:
    uv run ruff check --quiet hand_ocr tests tools hand-ocr.py
    uv run ruff format --quiet hand_ocr tests tools hand-ocr.py
    uv run ty check hand_ocr tests tools hand-ocr.py

# emit a demo deal (spine check, no image / vision deps): PBN with '-' for unknown E/W
# `python hand-ocr.py` (not `hand-ocr.py`) so it runs in the PROJECT env, not the
# script's isolated PEP-723 env — the latter has only docopt, no opencv.
demo *args:
    uv run python hand-ocr.py --demo {{args}}

# build the per-source rank atlas from a labelled board (needs the vision extra)
build-atlas image="fixtures/bridgewebs-4-2.png" out="hand_ocr/atlas/bridgewebs":
    uv run python tools/build_atlas.py {{image}} {{out}}

# parse an image -> deal text, e.g. `just run fixtures/bridgewebs-4-2.png --format pbn` (needs the vision extra)
run image *args:
    uv run python hand-ocr.py {{image}} {{args}}

# read the hand diagram straight from the OS clipboard (screenshot -> deal text, no temp file).
# Windows/macOS work out of the box; Linux needs xclip/wl-paste on PATH. e.g. `just clip --format lin` (needs the vision extra)
clip *args:
    uv run python hand-ocr.py --clipboard {{args}}

# sweep every fixture (or a glob) -> one valid/total status line each; the per-session eyeball check (needs the vision extra)
sweep *paths:
    uv run --extra vision python tools/sweep.py {{paths}}
