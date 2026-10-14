#!/usr/bin/env bash
# The spike's native yardstick: DDS + bench_native.cpp with the same zig clang, -O3, as two programs - one
# thread (the wasm build's configuration) and DDS's std::thread backend (what deal_solve's dds.lib uses: all cores).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-${DDS_HOME:-$HOME/dev/odin-dds}/external/dds/src}"
out="$here/../target/dds-wasm"
mkdir -p "$out"
zig c++ -O3 -DNDEBUG -I"$src/../include" -I"$src" "$src"/*.cpp "$here/bench_native.cpp" -o "$out/bench_native_1.exe" &
zig c++ -O3 -DNDEBUG -DDDS_THREADS_STL -I"$src/../include" -I"$src" "$src"/*.cpp "$here/bench_native.cpp" -o "$out/bench_native_mt.exe" &
wait
ls -l "$out"/bench_native_*.exe
