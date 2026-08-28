# datastar-quiz-golang — handoff

A third implementation of the bidding quiz, in Go, to sit beside `apps/quiz/` (Panel) and
`apps/datastar-quiz/` (Datastar + Litestar). **The point is the comparison**, not the app: the same
hypermedia architecture, the same corpus, the same routes, driven by the same load harness, so that
what differs is the runtime and the language rather than the design.

Written 2026-08-28, after a week of measuring the Python port. Everything below marked *measured* was
measured on this machine (24 cores, Windows); everything marked *verified* was checked against the
installed toolchain rather than recalled.

---

## 1. Ground rules for the comparison

Get these wrong and the numbers mean nothing.

**Two core budgets, both reported.** The Python app is one asyncio loop in one process: one core,
whatever the machine has (*measured*: the granian worker pins at ~89% of one core and 3.7% of 24).
Go will use all 24 by default, so a naive comparison says "Go is 20× faster" when it means "Go used
20 cores".

- `GOMAXPROCS=1` — the honest like-for-like: same work, same core budget, and the number that says
  what the runtime costs.
- unrestricted — what the language actually buys you on this box, which is the other half of the
  question and the more useful one for a real deployment.

Make it a flag *and* an env var (`GOMAXPROCS` is already honoured by the runtime; also expose
`--procs` so a run records its own setting in the log). Pin `GOGC` and `GOMEMLIMIT` for
reproducibility — a GC that happens to run mid-percentile is a real effect and should be a
*deliberate* one.

**Same server shape.** One process. No worker pool trickery the Python side cannot match. If you add
`--workers`, report it separately.

**Identical SSE choreography.** `/answer` streams toasts with deliberate server-side pauses (§3).
Those pauses must be the same to the millisecond, or the answer-route comparison is meaningless. In
Go they cost a `time.Sleep` on a goroutine instead of an `await` on a loop — that difference *is* one
of the interesting findings, so it has to be measured, not designed away.

**Same compression.** Litestar is pinned at brotli quality 5, minimum size 256 bytes. Match it.

**Prime the caches the same way.** The Python app now parses both corpora at startup
(`DSQUIZ_PREWARM`, on by default) rather than on the first request. Load the corpus at boot too, and
warm anything you memoise, or the first request pays and the percentiles lie.

---

## 2. What the app is

A bidding quiz. It draws an auction from a corpus of ~7,600 bidding sequences parsed out of `.bml`
notes, shows 4–8 candidate answers, scores the pick against a clock, and streams the reaction as a
sequence of SSE frames. The player can filter the corpus (per keystroke, validated server-side),
pick topics from a dialog, skip, restart, and switch between two systems (`squad` default,
`?swedish`).

Read `apps/datastar-quiz/README.md`, `DESIGN.md` and `COMPARISON.md` first — they are the design
record, and `COMPARISON.md` is where a Go column belongs when you have numbers.

**State model.** All state is server-side, keyed by a cookie. `dsq_sid`, `HttpOnly`, `SameSite=Lax`,
path scoped to the mount point. Sessions live under **(browser, variant)** — the same browser has a
separate squad and swedish session, which is what stops a background tab answering into the wrong
quiz. TTL 6 hours, swept every 10 minutes.

In Go this store is touched by many goroutines at once, which the Python version never had to think
about. `map` + `sync.RWMutex` is fine and idiomatic; run the tests with `-race`. Do not reach for a
cache library — the semantics here are specific (per-variant keying, a nonce per question, TTL
sweep) and small.

**Game rules** (`apps/datastar-quiz/engine.py`, port exactly):

- difficulty 4–8 = candidate count; initial 5. Question clock by difficulty: `{4:8s, 5:7s, 6:6s,
  7:5s, 8:4s}`.
- points goal 1000; skip milestones at 10/25/45/65/80/100% of the goal, each awarding one skip;
  3 skips to start.
- scoring: candidate-length points + streak bonus + time bonus, the time bonus computed from the
  **server's** clock at the moment the answer arrives (the browser's countdown bar is animation).
- ladder mode subtracts the last correct score on a wrong answer; target mode withholds completion
  until a percentage is met.

---

## 3. The wire protocol, exactly

The load harness parses the HTML. Emit these shapes or it cannot drive the app.

**Routes** (all under an optional mount prefix, `DSQUIZ_PREFIX`):

| method + path | what |
|---|---|
| `GET /` | the whole document; `Cache-Control: no-store` |
| `POST /answer/{qid}/{index}` | score an answer, stream the toast choreography |
| `POST /next` | leave a reveal, draw the next question |
| `POST /skip` | spend a skip |
| `POST /restart`, `POST /settings` | restart; adopt changed bound signals (restarts if changed) |
| `GET /filter/preview`, `GET /filter/preview-topics`, `GET /filter/topics-reset` | validate, commit nothing |
| `POST /filter/apply`, `POST /filter/apply-topics` | commit a filter (restarts the quiz) |
| `GET /timer` | held SSE countdown, only in `DSQUIZ_TIMER=stream` |
| `GET /static/…`, `GET /sfx/{name}` | assets; five synthesised WAVs |

**Signals.** Datastar uploads browser-owned signals with every request: a JSON body on POST, a
`?datastar=<json>` query parameter on GET. Names must match: `difficulty`, `ladderMode`, `targetOn`,
`targetPct`, `filterText`, `topics.<key>`. Server-owned signals are `_`-prefixed and are never
uploaded: `_points`, `_pointsPct`, `_streak`, `_skipsLeft`, `_playing`, `_ticking`, `_questionMs`,
`_timeLeftPct`, `_correct`, `_attempted`, `_scorePct`.

**A 204 is a no-op, not an error.** A datastar response with no events is `204 No Content`, and the
app returns one deliberately whenever a press no longer applies: Skip with none left, Next while not
on a reveal, a settings POST that changed nothing, an answer to a finished quiz, `/timer` in client
mode. The harness treats 200 and 204 alike — do the same or every one of those becomes a "failure".

**What the harness reads out of your HTML** (`apps/dsquiz-perf/common/datastar.py`):

- `@post('<prefix>/answer/<qid>/<index><?variant>')` on each candidate button — this is how it learns
  the question nonce, the candidate count, the mount prefix and the variant query;
- `@post('…/next')` ⇒ parked on a reveal; `class="finale"` ⇒ completed;
- `data-bind:topics.<slug>` for the topic keys;
- `href`/`src` of `…/static/…` for the cold-visit asset sweep;
- `"_playing"` and `"_skipsLeft"` in a signals payload, escaped or not.

Note the signal-name transform, which is a real trap: HTML lowercases attribute names, so datastar
converts kebab attribute keys to camel signals **splitting letter/digit boundaries** —
`data-bind:topics.1c-opening` becomes the signal `topics.1COpening`. Port
`render.datastar_kebab`/`datastar_camel` faithfully; there are tests for it
(`tests/test_signal_names.py`).

**Morph.** The default is the *fat* morph: an interaction patches `#app` — everything below `<body>`
— and the server never has to remember which fragments a state change touches. That is the Tao of
Datastar's explicit advice ("rather than trying to manage fine-grained updates yourself"), and the
Python app keeps `DSQUIZ_MORPH=fragment` only for comparison. *Measured* at 1000 users: fragment buys
~40% off the P99 tail and nothing on throughput. **Default to fat in Go too**, and keep the same
env-var escape hatch so the same experiment can be run on both.

**The answer stream, frame by frame** — reproduce the order and the pauses:

1. `_streak` signal patch (immediately — the chip belongs to the answer just given);
2. clear `#sfx`, append the verdict sound marker (before the toast it belongs to);
3. per toast: patch `#toasts`, optionally a milestone sweep + skip sound, optionally a `_points` /
   `_pointsPct` patch, optionally a floating score appended to the picked card — **then sleep**:
   - wrong answer: 0.6s, plus 0.6s more if ladder mode took points;
   - correct: 0.5s per beat (verdict, base points, streak bonus, time bonus, each skip award,
     target warning) then a final 1.0s;
4. on completion, the finale sound;
5. clear `#toasts`, restart the question clock, then the view patch (`#app` or `#quiz`).

*Measured*, Python: a whole stream averages ~1.1s and did not move (1101 → 1105 ms) between 3 users
and 1000 users with the core saturated.

---

## 4. The corpus — the one big decision

The quiz needs auctions and their meanings. Python gets them by importing the external `bml` module
and walking the parsed bid tables (`apps/quiz/quiz.py`). There is also an Odin implementation
(`~/dev/bridge-markup`). Writing a third BML parser in Go is weeks of work and is **not** what this
comparison is about.

**Recommended: export the corpus to JSON from the Python app, load it in Go at startup.**

Write `apps/datastar-quiz/tools/export_corpus.py` emitting, per variant:

```json
{
  "variant": "squad",
  "bml_file": "bidding-system.bml",
  "auctions": [{"sequence": ["1C (Pass) 1H", "2D"], "description": "..."}],
  "topics": [{"name": "1C opening", "patterns": ["1C"], "description": "..."}]
}
```

`sequence` and `description` are exactly `quiz.BidSequenceMeaning`'s public fields (*verified*); the
underscore-prefixed debug fields are not needed. Check the JSON into the Go app and regenerate it
with a just recipe, so the two implementations provably share a corpus.

**But port the matcher.** The filter is where the CPU goes, so a comparison that skips it is not a
comparison. Port `apps/quiz/bidfilter.py`'s matching half: `parse_pattern`, `prepare_auction`,
`matches_prefix`, `position_matches`, `bid_matches`, `bids_match_any`, plus `parse_filter`'s
topic/pattern resolution and `normalize_filter_text`. It is pure, well-commented, and has a thorough
test suite (`apps/quiz/tests/test_bidfilter.py`) whose cases port directly as Go table tests — do
that, it is the cheapest correctness you will get.

*Measured* per call, Python, warm: `check_filter("1C")` 15.8 ms, a topic 43 ms, over 7,627 auctions.
The Python app memoises it on `(bml_file, variant_key, normalised_text, min_hits)` with an
`lru_cache(maxsize=256)` and gets an **87.6% hit rate** under load. Port that memo too — and note
**case is deliberately not folded** into the key: `m` is the minors and `M` the majors, so a
case-insensitive key answers `1m` with the majors.

---

## 5. Libraries — chosen, with reasons

*Verified* against the installed toolchain (`go1.26.7 windows/amd64`).

| need | choice | why |
|---|---|---|
| routing | **stdlib `net/http`** + `ServeMux` | since 1.22 the mux matches method and path wildcards (`POST /answer/{qid}/{index}`), which is all this app needs. A framework would add a dependency and a comparison confound. |
| datastar | **`github.com/starfederation/datastar-go` v1.2.2**, package `datastar` | the official SDK. `datastar.NewSSE(w, r)`, `sse.PatchElements`, `sse.PatchSignals` / `MarshalAndPatchSignals`, `datastar.ReadSignals(r, &signals)`. Requires Go ≥1.24. |
| templates | **`github.com/a-h/templ`** | compiled to Go, type-checked, no runtime parse — and the SDK has first-class support (`sse.PatchElementTempl`), which is the strongest signal available that it is the intended pairing. Costs a codegen step (`templ generate`). If you would rather not have codegen, stdlib `html/template` is the fallback and still fine. |
| compression | **`github.com/CAFxX/httpcompression`** (+ `klauspost/compress`) | brotli, zstd and gzip in one negotiating middleware — and it is what the Datastar SDK itself depends on (*verified* in its `go.mod`), so it is known to behave with SSE flushing. Set brotli quality **5**, min size **256**, to match Litestar. |
| sessions | **stdlib**: `map` + `sync.RWMutex`, a TTL sweep goroutine | the semantics are specific and small. Test with `-race`. |
| logging | **stdlib `log/slog`** | structured, no dependency. |
| config | **stdlib `os.Getenv`** | mirror the `DSQUIZ_*` names exactly, so the same env drives both apps. |
| tests | **stdlib `testing` + `net/http/httptest`**, `github.com/google/go-cmp` for diffs | idiomatic. Port the Python suite's *behaviours*, especially `test_stale_pages.py`, `test_morph_modes.py`, `test_variants.py` and the bidfilter cases. |
| profiling | **stdlib `net/http/pprof`** | see §7. |
| dev reload | `github.com/air-verse/air`, or `templ generate --watch` | optional. |

Not chosen, deliberately: no ORM (no database), no DI framework, no `gin`/`echo`/`fiber` (the
stdlib mux covers it and `fiber` is not `net/http`-compatible, which would complicate the SSE and
compression story), no `encoding/json/v2` (*verified*: not present in this install, `GOEXPERIMENT`
is empty).

Suggested layout — flat and boring, matching the Python app's own flatness:

```
apps/datastar-quiz-golang/
  go.mod  justfile  README.md  HANDOFF.md
  cmd/quizd/main.go          flags, GOMAXPROCS, server lifecycle
  internal/corpus/           the JSON corpus, loaded once at boot
  internal/bidfilter/        the ported matcher + its memo
  internal/engine/           scoring, toasts, the question clock — pure, no HTTP
  internal/session/          the store, the cookie, TTL sweep
  internal/web/              handlers, SSE choreography, middleware
  internal/view/             templ components (or html/template)
  static/                    copied verbatim from apps/datastar-quiz/static/
  testdata/corpus/*.json
```

Keep `engine` and `bidfilter` free of `net/http`. That is what lets you benchmark them with
`go test -bench` directly and compare against the Python microbenchmarks without a server in the way.

---

## 6. Driving it with the existing harness

`apps/dsquiz-perf/` (locust + the shared `gclocust` library) works against the Go app **unchanged** —
it reads the prefix and variant query off the page rather than assuming them. Point it at the port:

```shell
DSQUIZ_PERF_HOST=http://127.0.0.1:5060 just dsperf smoke      # 2 users, 30s — plumbing
DSQUIZ_PERF_HOST=http://127.0.0.1:5060 just dsperf headless 400 20 300
```

Run `smoke` the moment `GET /` and one answer work; it will tell you immediately whether your HTML
carries what the parser needs.

**Numbers to compare against** (*measured*, Python, single core, after both this week's
optimisations, 0 failures throughout):

| | 400 users | 1000 users |
|---|---|---|
| aggregate P50 / P95 | 4 ms / 72 ms | 15 ms / 380 ms |
| throughput | ~100 req/s | ~200 req/s |
| `POST /answer` (server work, TTFB) | P50 2 ms, P95 62 ms | P50 10 ms, P95 300 ms |
| `GET /filter/preview` | P50 4 ms, P95 77 ms | — |
| `POST /filter/apply-topics` | P50 10 ms | — |
| whole `/answer` SSE stream | mean ~1.1 s (choreography) | mean ~1.1 s |
| worker RSS | ~120 MB | ~185 MB |

Two axes where Go should differ in kind, and which are worth designing the runs around:

1. **Held connections.** `DSQUIZ_TIMER=stream` gives every open tab an SSE connection pushing a
   signal patch every 100 ms. On Python that is the expensive mode nobody would ship; on Go it is a
   goroutine and a ticker. The harness has a scenario for it
   (`locustfiles/timer_stream_scenario.py`) that has never been run in anger because the Python side
   could not carry it. Implement `/timer` and run it.
2. **Multi-core.** Everything above is one core. The `GOMAXPROCS=1` run is the language comparison;
   the unrestricted run is the deployment comparison.

---

## 7. Profiling — where Go is simply better, and it is worth saying why

The Python side spent a day on this and it is written up in `apps/datastar-quiz/profiling.py`:
py-spy (sampling) **pauses the process** to read stacks, and with one asyncio loop on one core the
pause *is* the outage — at 100 Hz against 100 users the P90 went from ~50 ms to **18 seconds**. Its
`--nonblocking` mode does not pause and then loses ~35% of samples to torn reads (*measured*: 108
samples, 59 errors). The workable answer was yappi, an instrumenting profiler behind an env var, at
several times slower.

Go needs none of that. Register `net/http/pprof` behind the same debug flag and take a CPU profile of
a *live, unmodified, full-speed* server:

```shell
go tool pprof -http=: "http://127.0.0.1:5060/debug/pprof/profile?seconds=30"
```

Add `runtime/trace` for the scheduler view when you want to see goroutine behaviour under the held
timer streams. Gate it behind `DSQUIZ_DEBUG`, exactly as the Python app gates its profiler — an
open pprof endpoint is a production mistake.

**Findings from profiling the Python app that you should check for in yours**, because they are
design-level rather than language-level: memoise the filter check (87.6% hit rate under load);
memoise the topic-slug derivation (*measured*: 37,868 regex calls a minute for values that never
change); do the corpus work at startup, never in a request (*measured*: 5.5 s landing on one
unlucky visitor).

---

## 8. Repo conventions to follow

- **justfile per app**, reachable as a module from the root justfile (`mod dsgo
  'apps/datastar-quiz-golang'`). Shell is `cmd.exe` on Windows / `bash` on unix, with `[script]`
  python for anything with logic — copy the header of `apps/datastar-quiz/justfile` verbatim,
  including the `set script-interpreter` line. Recipes: `serve`, `serve-prod`, `serve-1core`,
  `serve-streamed`, `test`, `bench`, `qa` (`gofmt -l` / `go vet` / `staticcheck`), `pprof`,
  `export-corpus`.
- Go 1.26.7 is installed. Pin the toolchain in `go.mod` (`go 1.26.7`).
- Comments explain **why**, and record measurements with their numbers — that is the house style in
  both the Python app and the Odin sims, and it is why this handoff could be written at all.
- `.html` files in the repo root are build artifacts; nothing here touches them.

---

## 9. Staged plan

1. **Skeleton + corpus.** `export_corpus.py`, load JSON at boot, `GET /` rendering a question with
   the right `@post('/answer/{qid}/{i}')` markup. Then `just dsperf smoke` — if the harness drives
   it, the contract is right.
2. **The quiz loop.** answer / next / skip / restart / settings, the SSE choreography with its
   pauses, session store with TTL. Now `just dsperf headless 400 20 300` is meaningful.
3. **The filter.** Port `bidfilter` matching with its tests, the preview/apply routes, the memo.
   This is where the CPU comparison actually happens.
4. **Parity pass.** Both morph modes, both timer modes, both variants, the `?debug` panel, the sound
   sink, the prefix mount. Port the Python behavioural tests that encode the traps: stale `qid`
   resync, session replacement, `(browser, variant)` keying.
5. **Measure.** `GOMAXPROCS=1` and unrestricted, 400 and 1000 users, plus the held-timer scenario.
   Write the results into `COMPARISON.md` beside the Python column, and into a `README.md` here.

Do not skip 4 before 5. The Python port's own history is a list of behaviours that look optional
until they are missing — the 204 no-ops, the question nonce, the per-variant session keying — and
each one silently corrupts a load run rather than failing it.
