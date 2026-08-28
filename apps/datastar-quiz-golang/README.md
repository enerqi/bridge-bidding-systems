# datastar-quiz-golang

A third implementation of the bidding quiz, in Go, beside `apps/quiz/` (Panel) and
`apps/datastar-quiz/` (Datastar + Litestar). **The point is the comparison**, not the app: the same
hypermedia architecture, the same corpus, the same routes, driven by the same load harness, so what
differs is the runtime and the language rather than the design.

`HANDOFF.md` is the brief this was built from. `../datastar-quiz/README.md`, `DESIGN.md` and
`COMPARISON.md` are the design record for the architecture both ports share.

```shell
just dsgo serve          # every core, client countdown          -> http://127.0.0.1:5060
just dsgo serve-1core    # pinned to ONE core: the like-for-like run against the python
just dsgo dev            # debug panel armed + /debug/pprof
just dsgo test           # go test ./...
just dsgo bench          # the microbenchmarks (scoring, question generation, the filter)
just dsgo qa             # gofmt -l, go vet, staticcheck if installed
just dsgo export-corpus  # re-export the shared corpus + filter goldens from the python app
```

---

## The ground rules, and how they are honoured

**Two core budgets, both reported.** The python app is one asyncio loop in one process: one core,
whatever the machine has (*measured*: the granian worker pins at ~89% of one core and 3.7% of 24).
Go will use all 24 by default, so a naive comparison says "Go is 20× faster" when it means "Go used
20 cores". `--procs 1` (or `GOMAXPROCS=1`) is the honest like-for-like; unrestricted is the
deployment question. `--gogc` and `--memlimit` exist so a GC that lands mid-percentile is a
deliberate effect rather than an accident, and **every setting a run used is logged at startup**, so
one log line reconstructs it:

```
INFO quizd listening addr=127.0.0.1:5060 prefix="" timer=client morph=fat debug=""
     pprof=false gomaxprocs=1 numcpu=24 gogc=0 memlimit=0 corpus_ms=74
```

**Same server shape.** One process, no worker pool. **Same compression**: brotli quality 5, gzip
fallback, minimum size 256 — what Litestar is pinned to. **Identical SSE choreography**: the
deliberate server-side pauses in `/answer` are the same to the millisecond; in Go they cost a
`time.Sleep` on a goroutine instead of an `await` on the one loop, and that difference *is* one of
the findings, so it is measured rather than designed away. **Caches primed the same way**: the
corpus is loaded and pre-parsed at boot, always — there is no lazy path to fall back to and
therefore no `DSQUIZ_PREWARM`.

## What is shared, and what is ported

Writing a third BML parser in Go (after the python one and the Odin `bridge-markup`) is weeks of
work and is not what this is about. So:

- **The corpus is exported, not re-parsed.** `apps/datastar-quiz/tools/export_corpus.py` writes
  `internal/corpus/data/{squad,swedish}.json` — the auctions (`sequence` + `description`, exactly
  `quiz.BidSequenceMeaning`'s public fields) and the variant's topics, already resolved through
  `bidfilter.topics_file_for`. Those files are checked in and embedded, so the two implementations
  provably draw questions from the same 1,652 and 7,627 auctions.
- **The matcher IS ported**, because the filter is where the CPU goes and a comparison that skips it
  is not a comparison. `internal/bids` is the bml tools' `bmlbids.py`; `internal/bidfilter` is the
  matching half of `apps/quiz/bidfilter.py` — the pattern language, the prefix match, the correlated
  suit classes (`1HS--2M` is one major named twice) and the relative calls (`next`, `jump`, `cue`,
  `raise`, `slam`, `4thSuit`, …).

Two things hold the port to the reference:

1. `internal/bidfilter/bidfilter_test.go` — every case of `apps/quiz/tests/test_bidfilter.py`,
   ported one for one. That file is the specification of the pattern language.
2. `internal/corpus/corpus_test.go` — **132 probes over the real corpus**, exported from the python
   by `tools/export_filter_goldens.py`: every topic of both variants plus a spread of hand-written
   patterns, each recording the status, the hit count and a **sha256 of the exact auction indices
   selected**. A single auction moving in or out fails the test.

Re-run both after editing a `.bml` file or a topics toml: `just dsgo export-corpus && just dsgo test`.

## Libraries

*Verified* against `go1.26.7 windows/amd64`.

| need | choice | why |
|---|---|---|
| routing | stdlib `net/http` + `ServeMux` | since 1.22 the mux matches method and path wildcards (`POST /answer/{qid}/{index}`), which is all this app needs. A framework would add a dependency and a comparison confound. |
| datastar | `github.com/starfederation/datastar-go` v1.2.2 | the official SDK: `NewSSE`, `PatchElements`, `PatchSignals`. |
| templates | stdlib `html/template` | the handoff's named fallback to `templ`. templ is the better pairing on paper — compiled, type-checked, `PatchElementTempl` — but it costs a codegen step and a generator binary. Both compile the markup once; if a profile ever points at template execution, templ is the move. |
| compression | `github.com/CAFxX/httpcompression` + `andybalholm/brotli` | brotli/gzip negotiation, and it is what the datastar SDK itself depends on. Used as middleware for whole responses; the SSE streams compress through `internal/web/sse_compress.go` instead — see below. |
| sessions | stdlib `map` + `sync.RWMutex`, a TTL sweep goroutine | the semantics are specific and small (per-variant keying, a nonce per question, a TTL sweep). |
| logging | stdlib `log/slog` | |
| config | stdlib `os.Getenv` + `flag` | the `DSQUIZ_*` names are the python's, so one environment drives both. |
| tests | stdlib `testing` + `net/http/httptest` | |
| profiling | stdlib `net/http/pprof` | see below. |

Deliberately not chosen: no ORM (no database), no DI framework, no `gin`/`echo`/`fiber` (the stdlib
mux covers it, and `fiber` is not `net/http`-compatible, which would complicate both the SSE and the
compression story).

## Layout

```
cmd/quizd/main.go       flags, GOMAXPROCS, server lifecycle
internal/bids/          the bml call model (bmlbids.py)
internal/bidfilter/     the ported matcher: pattern language, prefix match, relative calls
internal/corpus/        the embedded corpus, the variants, the memoised filter check
internal/engine/        scoring, toasts, question generation -- pure, no HTTP
internal/session/       the store, the cookie, the TTL sweep
internal/render/        html/template views, the signal payloads, the datastar name transform
internal/web/           handlers, SSE choreography, compression, pprof
internal/sfx/           five synthesised WAVs, no binary assets
assets/                 static/ and media/, embedded
```

`engine` and `bidfilter` are free of `net/http` on purpose: that is what lets `go test -bench` run
them with no server in the way and compare them against the python microbenchmarks.

`assets/` is a package rather than a bare directory because `go:embed` patterns are relative to the
package directory — the files have to sit beside a `.go` file, and this keeps them where somebody
editing a stylesheet would look.

## Three things that are different because the runtime is

**Every session has a mutex.** Litestar on one asyncio loop cannot have two handlers inside the same
session at once, so nothing there is guarded. Here every request is a goroutine: two tabs of one
browser, a click arriving during an answer stream, and the held timer connection all touch one
`Session`. Every read and every write goes through `Session.With` — *including rendering*, which
reads a dozen fields. `internal/web.TestConcurrentBrowsersAndTabs` hammers it.

> `go test -race` is the right tool and the handoff asks for it. On the machine this was written on
> the race runtime does not start — `exit status 0xc0000139` for **any** package, including an empty
> one, which is the mingw-8.1 in `PATH` rather than anything in this repo. Until that is replaced the
> concurrency test earns its place without it: the Go runtime throws on a concurrent map write on its
> own, and an unguarded store, memo or choices cache would produce exactly that. `just dsgo test-race`
> is there for a box with a working C toolchain.

**The mount prefix is spliced into the template source, not interpolated per render.** `html/template`
decides an attribute's content type from its name, and after stripping `data-` every `data-on:*`
attribute begins with "on" — so datastar's event expressions are treated as JavaScript, correctly,
and a value interpolated inside one is rewritten `/` → `\/`. A browser does not care (`'\/skip'` is
`'/skip'`); the load harness reads the mount prefix out of the markup with a regex and would then
post to a path with a backslash in it. The prefix is process-wide configuration, so it is spliced
into the template text at load — literal markup, which is exactly what it is in the jinja. See
`internal/render/templateset.go`; `ValidatePrefix` is what makes splicing safe.

**SSE compresses through its own writer.** The SDK's `WithCompression` flushes the compressor after
every event but never CLOSES it, so the stream ends without its terminating block. `just dsperf
smoke` failed every POST with `brotli.error: brotli: decoder failed` — an unterminated brotli stream
is one a client that decodes the whole body refuses. The `httpcompression` middleware closes
properly but *buffers*: its `Flush` is documented as a no-op until `MinSize` bytes have been written,
and the answer choreography's early frames are a few dozen bytes each — whose pacing is the thing
being measured. So the SSE routes use `internal/web/sse_compress.go`: negotiate once, flush the
compressor **and** the response after every event, close at the end of the handler. The middleware
still covers the document, the assets and the sounds, where buffering is right and `MinSize` means a
tiny response is not brotli'd for nothing.

## Profiling — where Go is simply better

The python side spent a day on this (`apps/datastar-quiz/profiling.py`): py-spy is a *sampling*
profiler that PAUSES the process to read stacks, and with one asyncio loop on one core the pause *is*
the outage — at 100 Hz against 100 users the P90 went from ~50 ms to **18 seconds**. Its
`--nonblocking` mode does not pause and then loses ~35% of samples to torn reads (*measured*: 108
samples, 59 errors). The workable answer was yappi, an instrumenting profiler behind an env var, at
several times slower — so it can answer "where does the time go" and never "how fast is it".

Here it is a CPU profile of a live, unmodified, full-speed server:

```shell
just dsgo dev                    # or --pprof
just dsgo pprof 30               # go tool pprof -http=: .../debug/pprof/profile?seconds=30
just dsgo trace 10               # the scheduler view, for the held timer streams
```

Gated behind `DSQUIZ_DEBUG=1` / `--pprof`, exactly as the python gates its profiler: an open pprof
endpoint is a production mistake.

## Measurements

Machine: 24 cores, Windows, loopback. The python column is from `../datastar-quiz/COMPARISON.md`,
measured on the same box after that app's own optimisation week.

### Startup, and the work that used to land on a visitor

| | python | go |
|---|---|---|
| parse + prepare both corpora | ~5.5 s (`load_bid_tables` 1.31 s + `prepare_sequence_bids` 4.25 s) | **~70 ms** |

The python number is why `DSQUIZ_PREWARM` exists: the yappi profile caught that 5.5 s landing inside
a REQUEST, on the first visitor to open the second system. Here the parse is already done (the
corpus is embedded JSON) and only the preparation is left — `BenchmarkPrepareCorpus` puts the
swedish system's 7,627 auctions at **44.7 ms**, against the python's 4.25 s for both, a ~95× gap on
the same work.

### The filter — where the CPU goes

`go test -bench . -benchmem -run XXX ./internal/corpus/`, one core's worth of work either way:

| | python (warm) | go | |
|---|---|---|---|
| `check_filter("1C")`, 7,627 auctions | 15.8 ms | **0.38 ms** | ~41× |
| a topic (several patterns) | 43 ms | **0.27 ms** | ~160× |
| the same, memo hit | — | 15 µs | the 87.6% case under load |
| `check_filter("1C")`, 1,652 auctions (squad) | — | 0.056 ms | |

The memo is ported too, and for the same reason: the preview routes run per keystroke, and under
load they were the only two to miss their latency targets on the python (400 users, P95 420 ms and
520 ms). Keyed on the *normalised* text, and **case is deliberately not folded** — `m` is the minors
and `M` the majors, so a case-insensitive key would answer `1m` with the majors.

### Scoring and question generation

| | go |
|---|---|
| `ScorePoints` | 0.68 µs |
| `Answer` (the whole state change + toast script) | 1.3 µs |
| `NewQuestion` (5 candidates out of 1,652 auctions) | 3.6 µs |

The python's answer handler measures ~2 ms end to end, which is a different quantity (it includes
the HTTP layer and the render); these are here to be compared against a python microbenchmark of the
same three functions when someone writes one.

### Load

See `RESULTS.md` for the runs and the numbers, including the held-timer scenario the python side
could not carry.

**One core saturates at ~3,850 simulated players** (measured: 4,000 pins it at 99.8% and the P50 goes
from 3 ms to 120 ms). The cost is dead linear on the way up — **0.26 milli-cores per player, ~1.3 ms
of one core per request** — and the usable ceiling is lower than the saturation point: comfortable to
~2,000, the knee at 2,500-3,000. For scale, the python's own 1,000-user numbers (P50 15 ms / P95
380 ms) are worse than this server's at 3,000. **~46% of that core is brotli**, not rendering and not
the bidding-tree matcher, so moving compression to a reverse proxy roughly doubles the ceiling.

The harness is `apps/dsquiz-perf/`, **unchanged** — it reads the mount prefix and the variant query
off the page rather than assuming them:

```shell
DSQUIZ_PERF_HOST=http://127.0.0.1:5060 just dsperf smoke            # 2 users, 30s -- plumbing
DSQUIZ_PERF_HOST=http://127.0.0.1:5060 just dsperf headless 400 20 300
```

## Parity notes

Behaviours that look optional until they are missing, each of which silently corrupts a load run
rather than failing it — all ported, all tested in `internal/web/web_test.go`:

- **A 204 is a no-op, not an error.** Skip with none left, Next while not on a reveal, a settings
  POST that changed nothing, an answer to a finished quiz, `/timer` in client mode.
- **The question nonce is process-wide.** Per session, starting at 1, a page whose session had been
  replaced posted `qid=1` at a brand new session whose first question was *also* `qid=1`; the
  staleness guard passed by coincidence and the answer was scored against a question that had never
  been on screen. That is the "I answered one question and it showed me another" report.
- **Sessions are keyed by (browser, variant)**, so the squad quiz and the swedish one coexist in one
  browser instead of one replacing the other.
- **A stale interaction resyncs the page** rather than answering with a bare 204, which from the
  player's chair is a dead button that stays dead.
- **The bonus that scores is the server's clock.** The browser's countdown bar is animation.

Two deliberate differences from the python, both recorded above: no `DSQUIZ_PREWARM`, and the mount
prefix is a template-source substitution rather than a render-time value.

### One inherited defect, kept for parity

`RequestedVariant` reads the whole query string looking for `swedish` / `squad`, and datastar sends
the browser's signals as `?datastar=<json>` on a GET. So typing `swedish` into the **filter box** of
a squad page makes the next `/filter/preview` switch systems. The python does the same thing
(`corpus.requested_variant(request.url.query)`), so it is reproduced here rather than quietly fixed:
a divergence would show up as a difference in the load runs and be read as a runtime effect. The fix
is the same in both — look at the query *keys* other than `datastar` — and belongs in the python
first.
