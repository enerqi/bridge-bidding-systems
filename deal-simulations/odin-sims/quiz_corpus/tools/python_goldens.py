# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Record what the PYTHON quiz extracts from every .bml file, as digests the Odin port is tested against.

    uv run --script deal-simulations/odin-sims/quiz_corpus/tools/python_goldens.py [--dump DIR]

The reference is the python quiz in the bridge-system-apps repo (`apps/quiz/quiz.py` over the python
bml parser). This repo does not depend on that one: the script is an ORACLE, run by hand after a
change to either side, and what it writes (`../testdata/goldens.json`) is all the Odin test reads.
`BRIDGE_APPS_HOME` locates the apps checkout (default `~/dev/bridge-system-apps`); `BML_TOOLS_DIRECTORY`
the python bml tools, as everywhere else.

Per file: the auction count and a SHA-256 over every auction, written as

    <call>\\x1f<call>...\\x1e<description>\\x1d

which needs no escaping rules to agree on (none of the separators occur in .bml text). `--dump DIR`
also writes each file's auctions as JSON, for diffing against `just sims quiz-corpus-dump`.
"""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
OUT = Path(__file__).resolve().parents[1] / "testdata" / "goldens.json"
APPS = Path(os.environ.get("BRIDGE_APPS_HOME", Path.home() / "dev" / "bridge-system-apps"))

os.environ.setdefault("BML_DOCS_DIRECTORY", str(REPO))
sys.path.insert(0, str(APPS / "apps" / "quiz"))

import quiz  # noqa: E402


def auctions(bml_file: str) -> list[tuple[list[str], str]]:
    # The exporter's own steps (`apps/datastar-quiz/corpus.py: bid_sequences`).
    tables = quiz.load_bid_tables(bml_file)
    quiz.prettify_bid_table_nodes(tables)
    return [(list(seq.sequence), seq.description) for seq in quiz.collect_bid_table_auctions(tables)]


def digest(entries: list[tuple[list[str], str]]) -> str:
    h = hashlib.sha256()
    for sequence, description in entries:
        h.update(("\x1f".join(sequence) + "\x1e" + description + "\x1d").encode("utf-8"))
    return h.hexdigest()


def one_file(bml_file: str) -> list[tuple[list[str], str]]:
    """One file's auctions, from a FRESH interpreter.

    The python bml module keeps its state in module globals (`#COPY` clipboards, `#VUL`/`#SEAT`,
    the content list) and `content_from_file` does not reset all of it, so a second file parsed in
    the same process can inherit the first's. The notes build runs one process per file for the same
    reason (`just bml-py`).
    """
    result = subprocess.run(
        [sys.executable, __file__, "--one", bml_file], capture_output=True, text=True, encoding="utf-8", check=True
    )
    return [(entry["sequence"], entry["description"]) for entry in json.loads(result.stdout)]


def main(argv: list[str]) -> int:
    if "--one" in argv:
        entries = auctions(argv[argv.index("--one") + 1])
        sys.stdout.reconfigure(encoding="utf-8")
        print(json.dumps([{"sequence": s, "description": d} for s, d in entries], ensure_ascii=False))
        return 0
    dump = Path(argv[argv.index("--dump") + 1]) if "--dump" in argv else None
    goldens = {}
    for path in sorted(REPO.glob("*.bml")):
        entries = one_file(path.name)
        goldens[path.name] = {"count": len(entries), "sha256": digest(entries)}
        print(f"{path.name}: {len(entries):,} auctions")
        if dump:
            dump.mkdir(parents=True, exist_ok=True)
            (dump / f"{path.stem}.json").write_text(
                json.dumps([{"sequence": s, "description": d} for s, d in entries], indent=1, ensure_ascii=False),
                encoding="utf-8",
            )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(goldens, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"-> {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
