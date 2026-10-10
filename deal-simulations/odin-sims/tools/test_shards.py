# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Run the workbench tests as N PROCESSES at once (`just sims test-workbench [SHARDS]`, the default).

    uv run --no-project -p 3.14 --script tools/test_shards.py <test exe> <shards>

WHY PROCESSES. Inside one process the window tests are one thread by necessity: Sciter has thread affinity
(odin-sciter `docs/rules.md` 1), the suite shares ONE windowless view (a second cannot be created after the
first is destroyed), and DDS is not reentrant. Each process has its own engine, view and solver, so N of them
are N independent runs of the same exe, each told which tests are its own with the runner's `-tests:`.

WHICH TESTS GO TOGETHER. Tests that use `target/debug` itself as a deals folder (`PARITY_DIR`) generate files
there and read the folder back for the format chips, so one shard's new file would be another's surprise:
they all run in shard 0. Every other test writes a folder of its own name, and goes wherever it balances.

BALANCED BY MEASUREMENT. The exe is built with `-define:WB_TEST_TIMINGS=true`, so every window test logs its
time; those lines (from the last sharded or `test-workbench-timings` run) weight the split, longest first onto
the least-loaded shard. A test with no measurement yet counts as 80ms.
"""

import contextlib
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # odin-sims/
DEBUG = ROOT / "target" / "debug"
TIMINGS = DEBUG / "test-workbench-timings.txt"
TEST_RE = re.compile(r"@\(test\)\s*\n\s*(\w+)\s*::\s*proc")
TIMING_RE = re.compile(r"timing (\S+) total=([\d.]+)")
SHARED_RE = re.compile(r'PARITY_DIR|PARITY_FILE|"target/debug|"target", "debug"')
DEFAULT_MS = 80.0
# A shard that has not finished by now is STUCK, not slow (a shard is ~5s): a crash inside the engine makes the
# runner's crash handler touch the engine from another thread and hang. Measured: a broken document script made
# every shard crash on its first test and then hang the run for ten minutes.
SHARD_TIMEOUT_S = 120


def discover() -> tuple[list[str], set[str]]:
    """Every test in the package, and the ones that touch the shared `target/debug` folder."""
    names: list[str] = []
    shared: set[str] = set()
    for path in sorted((ROOT / "workbench").glob("*_test.odin")):
        text = path.read_text(encoding="utf-8")
        matches = list(TEST_RE.finditer(text))
        for i, m in enumerate(matches):
            body = text[m.end() : matches[i + 1].start() if i + 1 < len(matches) else len(text)]
            names.append(m.group(1))
            if SHARED_RE.search(body):
                shared.add(m.group(1))
    return names, shared


def weights() -> dict[str, float]:
    found: dict[str, float] = {}
    for log in [TIMINGS, *sorted(DEBUG.glob("test-workbench-shard-*.txt"))]:
        if log.exists():
            for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
                if m := TIMING_RE.search(line):
                    found[m.group(1)] = float(m.group(2))
    return found


def plan(names: list[str], shared: set[str], measured: dict[str, float], shards: int) -> list[list[str]]:
    groups: list[list[str]] = [[] for _ in range(shards)]
    load = [0.0] * shards
    for name in names:
        if name in shared:
            groups[0].append(name)
            load[0] += measured.get(name, DEFAULT_MS)
    for name in sorted((n for n in names if n not in shared), key=lambda n: -measured.get(n, DEFAULT_MS)):
        k = load.index(min(load))
        groups[k].append(name)
        load[k] += measured.get(name, DEFAULT_MS)
    return groups


def main(argv: list[str]) -> int:
    exe, shards = Path(argv[1]).resolve(), max(1, int(argv[2]))
    names, shared = discover()
    measured = weights()
    groups = [g for g in plan(names, shared, measured, shards) if g]

    started = time.time()
    procs = []
    with contextlib.ExitStack() as logs:  # every shard's log stays open until every shard has finished
        for k, group in enumerate(groups):
            log = DEBUG / f"test-workbench-shard-{k}.txt"
            out = logs.enter_context(open(log, "w", encoding="utf-8"))
            tests = "-tests:" + ",".join(f"main.{n}" for n in group)
            procs.append(
                (k, group, log, subprocess.Popen([str(exe), tests], cwd=ROOT, stdout=out, stderr=subprocess.STDOUT))
            )
        stuck: set[int] = set()
        for k, *_, proc in procs:
            try:
                proc.wait(timeout=max(1.0, SHARD_TIMEOUT_S - (time.time() - started)))
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                stuck.add(k)
    wall = time.time() - started

    failed, problems, timing_lines, ran, bad = [], [], [], 0, 0
    for k, group, log, proc in procs:
        text = log.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        finished = next((l for l in lines if l.startswith("Finished ")), "no Finished line - the run died")
        if m := re.match(r"Finished (\d+) test", finished):
            ran += int(m.group(1))
        planned = sum(measured.get(n, DEFAULT_MS) for n in group)
        print(f"shard {k}: {len(group):3d} tests, ~{planned / 1000:4.1f}s planned  {finished}  [{log.name}]")
        if proc.returncode != 0:
            bad += 1
        if k in stuck:
            print(f"STUCK shard {k}: killed after {SHARD_TIMEOUT_S}s - see the FATAL line in {log.name}")
        failed += [l.strip() for l in lines if re.match(r"\s*- main\.", l)]
        current = ""
        for l in lines:
            if "[WARN" in l and "::" in l:
                current = l.rsplit("::", 1)[1].strip()
            if "+++ leak" in l or "+++ bad free" in l:
                problems.append(f"{current}: {l.strip()}")
            if "[ERROR" in l:
                problems.append(l.strip())
        timing_lines += [l for l in lines if TIMING_RE.search(l)]

    # The measurements, for the next run's balancing and for `test-workbench-timings`-style reading.
    TIMINGS.write_text("\n".join(timing_lines) + "\n", encoding="utf-8")

    print(f"{len(groups)} shards, {ran} of {len(names)} tests ran, {wall:.1f}s wall")
    for line in failed:
        print(f"FAILED {line}")
    for line in problems[:40]:
        print(line)
    if ran != len(names):
        print(f"MISMATCH: {len(names)} tests found in the source, {ran} ran - a name the runner did not match?")
        return 1
    return 1 if bad or failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
