"""Export what the PYTHON filter selects, so the go port can be held to it.

The unit tests ported into `apps/datastar-quiz-golang/internal/bidfilter` cover the pattern
language case by case. This covers the other half: run a spread of filters -- every topic
of both variants, plus a set of hand-written patterns exercising each token kind -- against
the whole corpus and record, per filter, the status and the exact set of auctions selected.

The set is recorded as a sha256 over the matching indices rather than the indices
themselves: it is exact (a single auction moving in or out changes the digest), and it
keeps the golden file a few kilobytes instead of a few megabytes.

    uv run --project apps/datastar-quiz --directory apps/datastar-quiz \
        python tools/export_filter_goldens.py
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import corpus  # noqa: E402

DEFAULT_OUT = (
    Path(__file__).resolve().parents[2]
    / "datastar-quiz-golang"
    / "internal"
    / "corpus"
    / "testdata"
    / "filter_goldens.json"
)

# One filter per token kind the matcher can meet, plus the shapes a player actually types.
# Every one of these runs against both variants' whole corpus.
PROBES = [
    "",
    "   ",
    "1C",
    "1c",
    "1D-1M-1N",
    "1D--1M",
    "1D 1M",
    "1m",
    "1M",
    "2C",
    "1N",
    "1C-(X)",
    "1C-(*)",
    "1H-(X)-2H",
    "*-*-*",
    "*-*-*-*-*-*",
    "1C-1D-1H-1S",
    "1M-2M",
    "1M-3M",
    "1m-2m",
    "2M",
    "3*",
    "1*",
    "4N",
    "1C, 1D",
    "1C, 1D, 1H, 1S",
    "1N-2C",
    "1N-2D/2H",
    "1M-3S/4C",
    "1C-2oM",
    "P",
    "1C-P",
    "1C-XX",
    "nonsense!!",
    "1C, nonsense!!",
    "2C-2D-2H",
    "1S-2N",
    "4C-4D",
    "(1H)-2C",
    "(*)-2C",
    "1D-(1S)-1H",
]


def digest(indices: list[int]) -> str:
    return hashlib.sha256(",".join(str(i) for i in indices).encode()).hexdigest()


def probe(variant: corpus.Variant, text: str, min_hits: int) -> dict:
    sequences = corpus.bid_sequences(variant.bml_file)
    check = corpus.check_filter(variant.bml_file, variant.key, text, min_hits)
    # index within the variant's full auction list, which is the order the go port loads
    by_id = {id(seq): i for i, seq in enumerate(sequences)}
    indices = [by_id[id(seq)] for seq in check.hits]
    return {
        "text": text,
        "min_hits": min_hits,
        "status": check.status,
        "hits": len(check.hits),
        "digest": digest(indices),
        "canonical": check.parsed.canonical_text,
        "errors": list(check.parsed.errors),
        "topic_names": list(check.parsed.topic_names),
    }


def main(argv: list[str]) -> int:
    out = Path(argv[1]) if len(argv) > 1 else DEFAULT_OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    payload = {}
    for variant in corpus.VARIANTS.values():
        topics = corpus.topics_for(variant.bml_file, variant.key)
        # 8 is engine.MAX_DIFFICULTY, the min_hits every route asks with
        probes = [probe(variant, text, 8) for text in PROBES]
        probes += [probe(variant, name, 8) for name in topics]
        payload[variant.key] = probes
    out.write_text(json.dumps(payload, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    total = sum(len(v) for v in payload.values())
    print(f"{out}: {total} probes over {len(payload)} variants ({out.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
