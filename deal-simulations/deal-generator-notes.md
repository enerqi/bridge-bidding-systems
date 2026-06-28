# Deal Generator — Alternatives & Roll-Your-Own Notes

Notes on replacing `deal.exe` (Thomas Andrews `deal`, TCL-scripted) with something faster / scriptable in another language.

## Existing alternatives

| Tool | Lang / scripting | Notes |
|------|------------------|-------|
| **dealer** (Hans van Staveren) | C, custom compiled DSL (not TCL) | Classic fast generator. De-facto standard for serious sims. |
| **dealerv2** (JGM fork) | C + DSL | dealer plus bundled DDS double-dummy, par scores, more functions. |
| **redeal** (Antony Lee) | Python predicates | DDS integration; `SmartStack` pre-biases shape so rare hands generate fast. Best fit for this repo's existing Python tooling. |
| roll-your-own | Rust / Odin / anything | Dealing is trivial; only double-dummy is hard (bind DDS, don't rewrite). |

`deal.exe` slowness is mostly per-deal **TCL interpretation + reject sampling** on rare conditions — not the actual dealing.

## dealer size

Hans van Staveren `dealer` ≈ 3–5k lines C total, but most of that is **not** the generator:

- DSL parser — `defs.y` (yacc) + `scan.l` (lex): the biggest chunk
- predefined functions — hcp, shape, controls, losers, point-counts
- statistics — frequency / average / histogram over expressions
- output / PBN formatting

The actual **deal + evaluate loop is only ~300–500 lines.** dealerv2 is bigger only because it links DDS (~10k+ C++).

Andrews `deal` is the same shape: small C core, large TCL library on top.

## Rolling our own (Odin / Rust)

Core is genuinely small — ~200–400 lines:

```
deck[52] := 0..51              // card = suit*13 + rank
loop:
  fisher_yates(deck, predealt) // partial shuffle (respect predealt cards)
  split into 4 hands (13 each)
  if predicate(hands): accept, output
  until count reached
```

The big win: skip dealer's DSL parser entirely — write predicates as **native procs**, same shape as `deal-utils.tcl` helpers (`is_strong_1c`, hcp, suit lengths). Native predicate, no interpreter.

What actually costs effort (not LOC):

| Feature | Effort | Note |
|---------|--------|------|
| deal + reject loop | trivial | few hundred lines |
| hcp/shape/control helpers | small | port from `deal-utils.tcl` |
| predeal (fix some cards) | small | needed by some scripts |
| **double-dummy tricks** | big | FFI to DDS, never rewrite |
| biased gen for rare hands | medium | only if perf matters |
| stats / histograms | medium | only if used |

### Perf reality

Pure generator (no DDS) = millions of deals/sec in any compiled lang. Strong-1C ~3% accept → ~33 deals/accept → still trivial. Crushes `deal.exe` regardless of language.

**Catch:** if makeable-tricks (double-dummy) are needed, the DDS solve dominates 100%+ and language choice is irrelevant. The current `.tcl` scripts are all accept/reject — **no double-dummy used** — so an Odin/Rust rewrite is a real, small, fast win (~1 day).

## DDS (double-dummy solver) — only if/when needed

DDS = Bo Haglund's double-dummy solver. The current sims do not need it.

### Rust crates

| Crate | What |
|-------|------|
| **dds-bridge** | High-level Rusty API over the C++ DDS. Most mature, recommended FFI route. |
| **dds-bridge-sys** | Low-level FFI bindings it sits on (links the C++ `dds` lib). |
| **bridgitte** | Pure-Rust double-dummy solver (no C++ dep). |
| **brydz_dd** | Pure-Rust DDS, author says unoptimized/slow — skip. |

Trap: **`rustdds`** is unrelated — DDS there = Data Distribution Service (networking pub/sub), not double-dummy.

### DDS has a C ABI (why FFI works from anything)

DDS is C++ internally, but the public header `dll.h` wraps everything in `extern "C"` with `DLLEXPORT`. Functions take plain POD C structs — no C++ types cross the boundary. Rust's `dds-bridge-sys` just runs bindgen over `dll.h`; Python uses ctypes/cffi; Odin would `foreign import` the lib and redeclare the structs.

Main entry points (all `extern "C"`):

| Func | Does |
|------|------|
| `SolveBoard` | tricks for one deal, one declarer/leader |
| `SolveAllBoards` | batch of boards |
| `CalcDDtable` | full 20-cell DD table (all strains × declarers) for one deal |
| `CalcAllTables` | batch of DD tables |
| `Par` / `DealerPar` | par contract/score from a DD table |
| `SetMaxThreads` | init thread pool (call once at startup) |

Core structs are C-layout PODs: `deal`, `ddTableDeal`, `futureTricks`, `ddTableResults`, `parResults`. Cards passed as suit/rank bitfields.

Odin FFI sketch:

```odin
foreign import dds "dds.dll"   // or libdds.so
@(default_calling_convention="c")
foreign dds {
    SolveBoard    :: proc(dl: deal, target, solutions, mode: c.int, fut: ^futureTricks, thrId: c.int) -> c.int ---
    CalcDDtable   :: proc(tableDeal: ddTableDeal, res: ^ddTableResults) -> c.int ---
    SetMaxThreads :: proc(userThreads: c.int) ---
}
```

Mirror the structs from `dll.h` exactly (field order + padding). Returns `RETURN_NO_FAULT` (1) on success, negative error codes otherwise (header lists them).

Gotchas:

- Call `SetMaxThreads(0)` once before solving (auto-detects cores). Not safe to skip.
- DDS keeps a large transposition-table cache — reuse it across boards, don't re-init per deal.
- Windows ships `dds.dll`; Linux/Mac build `libdds` from source (needs a C++ compiler even though linking is via the C ABI).

## Decision: Norn

The deal.exe replacement is named **Norn** and lives at **`~/dev/norn`** (separate repo, base of the program).

- Norse fate-weavers who *deal out* destiny → ties to the system's **Scanian / Swedish club** (Nordic) heritage, not a forced bridge pun.
- `norn` is free on crates.io; distinct from the `deal*` family (deal, dealer, redeal, dealerv2).
- Bridge framing carried by jargon subcommands (`norn deal`, `norn predeal`, `norn par`, `norn shape`) + suit glyphs in branding.

## Recommendation

- `.tcl` scripts are simple accept/reject predicates → two clean paths:
  - **redeal** (Python) — least friction, unifies with `quiz.py` / `run-deal.py`; port `deal-utils.tcl` helpers to Python funcs.
  - **Odin/Rust** — max throughput, native predicates, ~1 day for core + one ported predicate.
- Reach for DDS (`dds-bridge` / `dds.dll` FFI) only when adding makeable-tricks analysis. Dealing stays native; double-dummy is a thin C-ABI call.
