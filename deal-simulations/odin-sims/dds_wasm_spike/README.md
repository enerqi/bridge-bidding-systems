# DDS in WebAssembly: a spike (2026-10-12)

The question: can the double-dummy solver run in the reader's browser, so that a shared link's page can have what
only the workbench gives today: the 2-hand make %, the per-lead figures, the exact contract explorer and the
play-through costs? The answer is yes, and it is cheap enough to be worth doing.

**2026-10-13: the module's build moved to `player/dds/`** (`build.py`, the two shim headers, `dds.js`; `just sims
player-dds` -> `target/player/dds.wasm`), since the player now carries DDS. What is left here is the measuring:
benches and the phone page. Where this file says `build.sh` or `target/dds-wasm/dds.wasm`, read those.

**This directory is self-contained, so it is easy to remove.** Nothing else in the repo refers to it: no
justfile recipe, no package, no vendored file. Its outputs go to `../target/dds-wasm/`. Delete the two
directories and it is gone. DDS's own sources are compiled IN PLACE from the odin-dds checkout
(`$DDS_HOME/external/dds/src`, default `~/dev/odin-dds`), unmodified.

## Tools

Only **zig** (0.17, already installed via scoop) and **node**. zig's clang ships the wasm32-wasi libc and libc++,
so this needs no Emscripten, no wasi-sdk and no separate LLVM. A browser bench (`bench.html`) needs any static
server (`python -m http.server`).

```
dds_wasm_spike/build.sh          # DDS -> ../target/dds-wasm/dds.wasm  (~2s, parallel compile)
dds_wasm_spike/build_native.sh   # the same sources natively: bench_native_1.exe (1 thread), _mt.exe (std::thread)
node dds_wasm_spike/bench.mjs [dds.wasm] [tables] [solves]
target/dds-wasm/bench_native_1.exe <tables> <solves> [threads]
# browser: serve odin-sims/ and open /dds_wasm_spike/bench.html?tables=48&workers=1,4,8,12
```

## What the port took

DDS 2.9 compiles unmodified. It needed two forced-include headers:

- **`wasm_libcxx.h`** (every file). zig's wasm32-wasi libc++ has no file streams and no threads. DDS names
  `std::ofstream` for its debug dumps, and `std::mutex` / `std::this_thread` in ThreadMgr whatever backend is
  chosen. The header gives a stream that discards what it is told, a lock that does nothing, and a sleep that
  returns at once. With no `DDS_THREADS_*` define, DDS runs one thread, so none of those are ever needed for real.
- **`wasm_system.h`** (System.cpp only, compiled as `__linux__`). On a platform DDS does not know, it reads 0 MB
  of free memory, and `SetResources` then gives itself no threads and nothing solves. This header supplies a
  `sysconf` that reports one core and 1 GB; the `SetResources(mb, 1)` budget is what bounds the tables.

The module is **389 KB stripped, 108 KB gzipped**. It imports eight WASI functions, and the harness stubs all of
them: DDS writes no file and reads no input while solving. Exports: `SolveBoard`, `CalcDDtable`,
`SetResources`, `SetMaxThreads`, `malloc`, `free`, `memory`. A struct passed by value is passed as a pointer on
wasm32.

**Memory:** `SetResources(50, 1)` gives a small transposition table, so an instance holds 25-48 MB. At 200 MB
(the large table) it holds 208 MB and is no faster on full tables. Below about 23 MB DDS gives itself zero
threads and exits.

## Measured (24-core Windows desktop, Chrome via Playwright, node 24)

The same deals (xorshift32 + Fisher-Yates, `deals.h` / `dds_bench.js`) were run in every build, and the
**checksums agree** between native and wasm. The wasm build solves exactly what native does.

| build | CalcDDtable (20 results: 5 strains x 4 declarers) | SolveBoard (one lead, NT) |
|---|---|---|
| native, zig -O3, 1 thread | 151 ms | 12.4 ms |
| native, std::thread, all cores | 73 ms (it splits only over 5 strains) | 14.1 ms |
| node wasm, 1 thread | 186 ms | 15.4 ms |
| Chrome wasm, main thread | 146 ms | 21 ms |
| Chrome wasm, one Worker | 195 ms | - |

**wasm costs about 1.2-1.3x native on one thread.** That is not the limit. The limit is that native
`deal_solve` spreads a sample over all the cores: the real `analyse_deal --sample 300` on the golden board took
**1.6 s** here, 840 ms at 120.

Workers recover that, since each is a DDS instance of its own (48 tables, wall clock):

| workers | ms a table | 300 samples (one 2-hand board) |
|---|---|---|
| 1 | 195 | ~59 s |
| 4 | 50 | ~15 s |
| 8 | 19 | ~5.7 s |
| 12 | 17 | ~5.1 s |

The 12-worker row is overhead-bound at 4 tables each. A phone has 4-8 slower cores, so expect several times
the 4-8 worker rows.

## What it would buy, per feature

- **Par / the exact grid of a 4-hand board:** 1 table, ~0.2 s a board on one worker, and 48 boards in ~1-2 s
  on 8 workers. **The player could compute par itself, so links would not need to carry it.** A link with par
  for 32 boards is QR version 26; without par it is version 18 (ECC L). Par in the page would then cost nothing
  in the code.
- **2-hand make % (green band, lead grids, guess tax):** 120-300 tables a board, ~2-6 s a board on 8 workers
  here and much slower on a phone. That is workable lazily, nearest board first, as the combo analysis is now,
  with a smaller default N.
- **Play-through costs:** about 52 SolveBoards a recorded play, ~1 s a board on one worker.

## What integrating it would mean (not done)

- `player.html` carries a second module (+~145 KB base64 of the gzipped 108 KB) and spawns N workers, each
  compiling the module once (`WebAssembly.Module` is postable, as the combo worker already does).
- `deal_solve` is Odin over the `dds` foreign bindings and cannot be compiled to `js_wasm32` as it stands. The
  sampling, tax and grid code would have to call DDS through JS imports, or the solving step would move to JS
  with the Odin player turning results into html (`write_sim_json` already takes plain numbers). Either way it
  is a real piece of work, larger than this spike.
- The build gains zig as a tool (one binary). The output is likely byte-reproducible; that was not checked.

## On a phone: `dds-bench.html` (2026-10-13)

`uv run --no-project -p 3.14 --script dds_wasm_spike/build_bench_page.py target/dds-wasm/dds.wasm target/netlify/dds-bench.html`
writes ONE self-contained page (153 KB: the module gzipped inline, plus `dds_bench.js`). Publish it beside the
player and open it on the device to be measured. It reports the device's cores, memory and battery where the
browser says, the time per table on 1 worker and on 2, 4 and up to 8, and what those mean per board: the exact
explorer, play-through costs, and the 2-hand make % at 100 and 300 samples. A Copy button gives the text to paste back.
On this desktop the whole run takes ~5 s (129 ms a table on 1 worker, 19 ms overall on 8). To remove it, delete
`target/netlify/dds-bench.html` and republish.

**Measured on a phone (2026-10-13): a Samsung Galaxy S9 (2018), Android, 8 cores reported.** Exact explorer
0.3 s a board, play-through costs 3.9 s, the 2-hand make % at 300 samples 33 s (so ~11 s at 100). That is about
3x slower per table than the desktop for the explorer and 5-6x for sampling across workers. On a seven-year-old
phone, then, the cheap jobs are cheap and sampling is a wait that needs asking for, not a wall.
