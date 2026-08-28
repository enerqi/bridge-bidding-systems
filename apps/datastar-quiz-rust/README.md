# datastar-quiz-rust

The bidding quiz a fourth time, in Rust on tokio + axum, beside `apps/quiz/` (Panel),
`apps/datastar-quiz/` (Datastar + Litestar) and `apps/datastar-quiz-golang/`. **The point is the
comparison**, not the app: the same hypermedia architecture, the same corpus, the same routes,
driven by the same load harness, so what differs is the runtime and the language.

Where the Go port answers *"what does a compiled runtime cost"*, this one answers the narrower
question the brief asked: **what do you get for no GC and for spending real effort on not
allocating**. `RESULTS.md` has the numbers.

```shell
just dsrs serve          # every core, client countdown          -> http://127.0.0.1:5070
just dsrs serve-1core    # ONE tokio worker: the like-for-like run against the python
just dsrs dev            # debug panel armed
just dsrs test           # cargo test  (101 tests)
just dsrs bench          # the microbenchmarks
just dsrs qa             # cargo fmt --check + clippy -D warnings
just dsrs export-corpus  # re-export the shared corpus + goldens from the python app
```

---

## What is shared, and what is ported

Writing a fourth BML parser is weeks of work and is not what this is about. So the corpus is
**exported** from the python app (`tools/export_corpus.py`) into `corpus/{squad,swedish}.json`, the
same bytes the Go port embeds, and checked in here too — each app owns a copy so each stays a
self-contained deployable.

The **matcher is ported**, because the filter is where the CPU goes and a comparison that skips it
is not a comparison. Two things hold it to the reference:

1. `tests/bidfilter.rs` — 63 cases, the whole of `apps/quiz/tests/test_bidfilter.py`. That python
   file is the specification of the pattern language.
2. `tests/corpus.rs` — **132 probes over the real corpus**, the same goldens the Go port asserts
   against: every topic of both variants plus hand-written patterns, each recording the status, the
   hit count and a **sha256 of the exact auction indices selected**. One auction moving in or out
   fails the test.

Parity was also checked at the wire: rendering the same page from all three servers gives
**identical element ids, identical `data-*` attributes, identical class vocabulary and a
byte-identical signal payload** (same keys, same values, same 18 topic keys). 23,414 bytes here
against the python's 23,775 and the Go port's 23,698.

## The allocation story, in four places

This is the part the brief asked for, and each one is a number rather than a preference.

**A call is six bytes and `Copy`.** The python holds a frozen dataclass with two `frozenset`s and
two `str`s. The Go port shrank the sets to a bitmask but kept `Kind` and `SuitClass` as `string` —
32 of its 40 bytes are two pointers and two lengths carrying what is really a pair of small enums.
Here they *are* enums: `size_of::<Bid>() == 6`.

**The prepared corpus is one arena, not a tree.** Preparing the swedish system produces 35,206
positions across 37,053 calls. Written the obvious way that is `Vec<Vec<Vec<Bid>>>` — tens of
thousands of separate allocations, 24 bytes of pointer on each 6-byte payload. `src/flat.rs` stores
the calls end to end with three offset tables, so the whole system is **four allocations and
0.72 MB**, and the matcher walks contiguous memory. A borrowed `Groups` view over a run of that
arena costs three words and no allocation.

**A filter's hits are indices, shared.** The memo holds up to 256 answers. The Go port stores each
as a `[]Auction` — 40 bytes per hit, and its heap profile showed 14.6 MB of live memo under load.
Here a hit is a `u32` and the list is an `Arc<[u32]>`: four bytes per hit, and two browsers that
apply the same filter hold the same allocation. The "everything matches" answer is built once at
load and shared by every unfiltered session.

**The signals are written, not serialised.** `src/render/signals.rs` appends `"key":value` pairs
straight into one `String`. The keys are fixed and the values are numbers, booleans and two strings,
so the JSON is a handful of `write!` calls and one allocation — and the server-owned set goes out
with every view patch, which is the hottest thing this app does after rendering.

The templates are [askama]: checked and compiled at build time into `write!` calls against one
buffer. That is the same trade `templ` offers the Go port, which did not take it because it costs a
codegen step there; here it is a derive.

[askama]: https://github.com/askama-rs/askama

## Libraries

*Verified* against `rustc 1.98.0`.

| need | choice | why |
|---|---|---|
| server | `tokio` + `axum` 0.8 | the mainstream async stack, and `tower`/`hyper` underneath, which is what makes the compression story tractable. |
| datastar | `datastar` 0.4 (`axum` feature) | the official SDK. Unlike the Go one it has no `ServerSentEventGenerator` — the framework owns the stream and the SDK hands back framework-native events. Its `DatastarEvent` also `Display`s as the exact SSE frame, which is what lets the compressed body be built by hand. |
| templates | `askama` 0.16 | compile-time, type-checked, one buffer. |
| compression | `brotli` + `flate2`, by hand for SSE; `tower-http` for the rest | see below — `tower-http` refuses to compress SSE at all. |
| sessions | `parking_lot` + `HashMap` | faster than `std::sync` and, more usefully, no lock poisoning: a panic in one handler must not take every session with it. |
| memo | `lru` | a small, well-known LRU; the Go port hand-rolled the same thing on `container/list`. |
| json | `serde_json` | for reading signals and the corpus. The signals going *out* are written by hand. |
| rand | `rand` 0.10 | question generation. |

No web framework beyond axum, no ORM (no database), no DI, no `include_dir` (nine files and a
`match`), no criterion (see `benches/micro.rs`).

## Four things that are different because the language is

**The lock is not optional.** The Go port guards its session with a mutex the compiler does not
check: forgetting to take it is a data race that only `go test -race` finds — and on the machine
this was written on that race runtime does not even start. Here the state lives *inside* a `Mutex`
and is unreachable without locking it, so the same class of bug does not compile. There is
deliberately no `test-race` recipe.

**The corpus is `&'static`, not refcounted.** It is loaded once and lives for the process, so it is
leaked at startup rather than wrapped in an `Arc` every session would refcount. A session holds a
plain shared reference: nothing to copy, nothing to drop.

**`tower-http` will not compress an SSE stream, and says so.** Its `DefaultPredicate` skips
`text/event-stream` outright, and its `Flush` is documented as a no-op until enough bytes have
accumulated to decide whether to compress at all. So an axum app that simply adds the layer ships
*uncompressed* streams — safe, and it would have quietly handed this column a 5× wire-size advantage
in the comparison it exists to make. `src/web/sse.rs` does it by hand instead: negotiate once, flush
the compressor and the socket after every event, terminate the stream properly at the end. All three
ecosystems get this wrong differently — litestar is correct, the Go SDK compresses but never closes
(a truncated brotli stream the harness rejects), tower-http refuses.

**No brotli encoder pool, and the stock window.** The Go port needed a `sync.Pool` here: one encoder
per SSE response took its resident set to 506 MB, with `ringBufferInitBuffer` at 282 MB — 81.6% of
the live heap. It also pinned the window to 64 KB, comfortably larger than the ~28 KB fat morph that
is the biggest thing this app streams. Neither is copied here.

There is no pool because the encoder is dropped at the end of the response and its pages go back to
the allocator *then*, rather than whenever a collector next runs. That was enough on its own:
**53 MB resident at 400 users against the Go port's 171 MB**, with no pool to size and nothing to
reset between responses.

Copying the pinned window, on the other hand, was actively wrong, and only a measurement said so —
brotli q5 over the real 23,453-byte page:

| window | encode | output |
|---|---|---|
| `lgwin` 16 (64 KB, the Go port's) | 6,078 µs | 5,333 bytes |
| the crate's default | **789 µs** | **5,294 bytes** |

**7.7× the CPU for 0.7% worse compression.** In this crate `lgwin` also sizes the metablocks, so a
small window does not merely bound the history — it makes the encoder re-scan. End to end,
`POST /restart` served **158 req/s** pinned against **912** with the default. The one-line change
that fixed the Go port's memory would have cost this one most of its throughput; "the same tuning"
is not the same tuning.

## One bug the harness found, and it was ours

`axum::serve` **does not set `TCP_NODELAY`** on accepted connections — `set_nodelay` appears in
axum's own source only inside its tests. Go's `net/http` sets it by default, and so do uvicorn and
granian.

Measured: without it, locust (which keeps connections alive) saw **10–11 ms** for `/next`, `/skip`,
`/restart` and `/settings` against the Go port's 2–3 ms, and the answer stream ran 1401 ms instead of
~1000 ms — while `curl`, opening a fresh connection per request, reported **1.0–1.7 ms** for the same
work. That gap is Nagle waiting on a delayed ACK, not the server. One `tap_io` in `main.rs` fixes it,
and without it this column would have looked five times worse than it is for reasons that have
nothing to do with Rust.

## Layout

```
src/main.rs             flags, the runtime, TCP_NODELAY, server lifecycle
src/bids.rs             the bml call model -- a 6-byte Copy struct
src/flat.rs             the group-of-slices arena the matcher walks
src/bidfilter/          the ported matcher: pattern, matcher, relative calls, topics
src/corpus.rs           the embedded corpus, the prepared arena, the memoised filter check
src/engine.rs           scoring, toasts, question generation -- no HTTP
src/session.rs          the store, the cookie, the TTL sweep
src/render/             askama templates, the signal writer, the datastar name transform
src/web/                axum routes, the SSE choreography, compression, embedded assets
src/sfx.rs              five synthesised WAVs, no binary assets
templates/              the six askama templates
corpus/                 the exported corpus, embedded
```

Everything except `web` is free of the HTTP stack, which is what lets the rules, the matcher and the
renderer be benchmarked with no server in the way.

## Parity notes

The behaviours that look optional until they are missing — all ported, all in `tests/web.rs`:

- **A 204 is a no-op, not an error.** Skip with none left, Next while not on a reveal, a settings
  POST that changed nothing, `/timer` in client mode. (The SDK's own `ReadSignals` extractor is not
  used, because it answers a malformed payload with a 400 where this app must answer 204.)
- **The question nonce is process-wide**, so a stale answer is always recognised as stale.
- **Sessions are keyed by (browser, variant)**, so the two systems coexist in one browser.
- **A stale interaction resyncs the page** rather than answering with a dead 204.
- **The bonus that scores is the server's clock.** The browser's countdown bar is animation.

Two inherited things worth knowing. `RequestedVariant` reads the whole query string looking for
`swedish`/`squad`, and datastar sends signals as `?datastar=<json>` on a GET — so typing `swedish`
into the filter box switches systems. The python does this and so does the Go port; it is reproduced
here rather than quietly fixed, because a divergence would show up in the load runs and be read as a
runtime effect. And askama escapes `<` as `&#60;` where jinja and `html/template` write `&lt;`;
`render::escape_html` matches the others wherever the output is compared byte for byte.
