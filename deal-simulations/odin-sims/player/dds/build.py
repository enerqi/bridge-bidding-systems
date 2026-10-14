# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""DDS, the double-dummy solver, as ONE wasm module for the shared-deals player:
uv run --script player/dds/build.py <dds-src-dir> <out.wasm>

Needs only `zig` (its clang ships the wasm32-wasi libc and libc++). DDS's sources are compiled unmodified from the
odin-dds checkout, one thread, with two forced-include headers standing in for what wasm32-wasi lacks:
`wasm_libcxx.h` (file streams, mutexes, sleeping - every file) and `wasm_system.h` (System.cpp only, which is
compiled as Linux so it asks `sysconf` for cores and memory). See each header for why. Measured against native DDS
on the same deals: the same results, ~1.2-1.3x the time a thread (`dds_wasm_spike/README.md`).

The module imports eight WASI functions, none used while solving; the player gives it do-nothing ones.
"""

import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

here = Path(__file__).resolve().parent
src, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
obj = out.parent / "dds-obj"
obj.mkdir(parents=True, exist_ok=True)

EXPORTS = ["CalcDDtable", "SolveBoard", "SetResources", "malloc", "free"]
flags = ["-target", "wasm32-wasi", "-O3", "-fno-exceptions", "-DNDEBUG", f"-I{src.parent / 'include'}",
         "-include", str(here / "wasm_libcxx.h")]


def compile_one(cpp: Path) -> str:
    extra = ["-D__linux__", "-include", str(here / "wasm_system.h")] if cpp.stem == "System" else []
    run = subprocess.run(["zig", "c++", *flags, *extra, "-c", str(cpp), "-o", str(obj / f"{cpp.stem}.o")],
                         capture_output=True, text=True)
    return "" if run.returncode == 0 else f"{cpp.name}:\n{run.stderr}"


with ThreadPoolExecutor() as pool:
    errors = [e for e in pool.map(compile_one, sorted(src.glob("*.cpp"))) if e]
if errors:
    sys.exit("DDS did not compile to wasm:\n" + "\n".join(errors))
link = subprocess.run(["zig", "c++", "-target", "wasm32-wasi", "-O3", *sorted(map(str, obj.glob("*.o"))),
                       "-mexec-model=reactor", "-Wl,--strip-all", *[f"-Wl,--export={e}" for e in EXPORTS],
                       "-o", str(out)], capture_output=True, text=True)
if link.returncode != 0:
    sys.exit("DDS did not link:\n" + link.stderr)
print(f"{out}: {out.stat().st_size:,} bytes")
