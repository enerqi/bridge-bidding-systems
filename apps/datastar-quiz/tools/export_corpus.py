"""Export the parsed `.bml` corpus as JSON, one file per quiz variant.

The go port (`apps/datastar-quiz-golang/`) needs the same auctions and the same topics that
this app draws questions from. Writing a third BML parser in Go is weeks of work and is not
what the comparison is about, so the corpus is exported here -- by the implementation that
already owns it -- and loaded there at boot.

What is exported is exactly `quiz.BidSequenceMeaning`'s public fields (`sequence` and
`description`, the underscore-prefixed debug fields are not needed) plus the variant's
topics, resolved through `bidfilter.topics_file_for` / `load_topics` so the go side never
has to know the one-file-per-variant rule or read a toml.

    uv run --project apps/datastar-quiz --directory apps/datastar-quiz \
        python tools/export_corpus.py ../datastar-quiz-golang/internal/corpus/data

Deterministic: the same corpus in produces byte-identical json out, so a regeneration that
changes the file is a real change to the notes rather than noise in a diff.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# flat modules, imported the way the app imports them (see corpus.py)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import corpus  # noqa: E402

DEFAULT_OUT = Path(__file__).resolve().parents[2] / "datastar-quiz-golang" / "internal" / "corpus" / "data"


def export(variant: corpus.Variant) -> dict:
    sequences = corpus.bid_sequences(variant.bml_file)
    topics = corpus.topics_for(variant.bml_file, variant.key)
    return {
        "variant": variant.key,
        "title": variant.title,
        "bml_file": variant.bml_file,
        "system_notes_url": variant.system_notes_url,
        "auctions": [
            {"sequence": list(seq.sequence), "description": seq.description} for seq in sequences
        ],
        "topics": [
            {
                "name": topic.name,
                "patterns": list(topic.patterns),
                "description": topic.description,
            }
            for topic in topics.values()
        ],
    }


def main(argv: list[str]) -> int:
    out_dir = Path(argv[1]) if len(argv) > 1 else DEFAULT_OUT
    out_dir.mkdir(parents=True, exist_ok=True)
    for variant in corpus.VARIANTS.values():
        payload = export(variant)
        path = out_dir / f"{variant.key}.json"
        # `indent=1`, not a single line: these files are checked in, so a diff has to be
        # readable, and the extra bytes cost nothing once they are parsed at boot.
        # `ensure_ascii=False` keeps the suit shorthand and any prose as written.
        path.write_text(json.dumps(payload, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        print(
            f"{path}: {len(payload['auctions']):,} auctions, "
            f"{len(payload['topics'])} topics ({path.stat().st_size:,} bytes)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
