# Load runs

Every number here was measured on **2026-08-28**, on the machine the python numbers in
`../datastar-quiz/COMPARISON.md` were measured on: 24 cores, Windows, over loopback, load generated
by `apps/dsquiz-perf/` (locust) on the same box.

The harness is **unchanged**. It reads the mount prefix, the variant query, the question nonce and
the candidate count off the page rather than assuming them, so the same scenarios drive both
implementations. That is the whole point: what differs is the runtime, not the client.

```shell
just dsgo serve-1core                                     # or `just dsgo serve`
DSQUIZ_PERF_HOST=http://127.0.0.1:5060 just dsperf headless 400 20 300
```

`req/s` is **not** a saturation number in the runs below — it is set by the scenarios' think time
and by the ~1 s answer choreography, and neither server was saturated. The latency percentiles are
the comparison; *"Where one core actually saturates"* is where the ceiling is found.

---

## Player + filter + cold-visit scenarios

`just dsperf headless <users> 20 300` — every scenario, 300 s, after a 20/s spawn.

| | python, 400 | **go 1 core, 400** | python, 1000 | **go 1 core, 1000** | **go 24 cores, 1000** |
|---|---|---|---|---|---|
| aggregate P50 | 4 ms | **1 ms** | 15 ms | **2 ms** | **1 ms** |
| aggregate P95 | 72 ms | **4 ms** | 380 ms | **5 ms** | **3 ms** |
| aggregate P99 | — | 16 ms | — | 17 ms | 16 ms |
| throughput | ~100 req/s | 82 req/s | ~200 req/s | 195 req/s | 195 req/s |
| `POST /answer` (server work, TTFB) | P50 2 ms, P95 62 ms | **P50 1 ms, P95 3 ms** | P50 10 ms, P95 300 ms | **P50 1 ms, P95 4 ms** | **P50 1 ms, P95 2 ms** |
| `GET /filter/preview` | P50 4 ms, P95 77 ms | **P50 1 ms, P95 3 ms** | — | P50 1 ms, P95 4 ms | P50 1 ms, P95 2 ms |
| `POST /filter/apply-topics` | P50 10 ms | **P50 2 ms** | — | P50 2 ms | P50 2 ms |
| whole `/answer` SSE stream | mean ~1.1 s | **mean 1.004 s** | mean ~1.1 s | mean 0.981 s | mean 0.990 s |
| worker RSS | ~120 MB | 171 MB | ~185 MB | 278 MB | 458 MB |
| failures | 0 | **0** | 0 | **0** | **0** |

Three things worth reading out of that:

**The like-for-like run is the interesting column.** One core against one asyncio loop, same work,
same corpus: the P95 goes from 72 ms to 4 ms at 400 users, and from 380 ms to 5 ms at 1000. The P50
barely moves in either implementation, because at these rates neither is queueing much — what
changes is the **tail**, which is where a single loop's head-of-line blocking shows up. The python's
own `/answer` P95 of 300 ms at 1000 users is one request waiting behind others on the loop; on Go
the same work is a goroutine on the same single core and the queue never builds.

**Nothing was bought by the other 23 cores.** All-cores at 1000 users is P95 3 ms against one core's
5 ms — a rounding difference on a load neither is straining under. That is the honest answer to "how
much of this is Go and how much is 24 cores": at this load, none of it. The multi-core column would
start to matter at a rate that saturates one core, which this scenario does not reach.

**The choreography is the choreography.** The `/answer` stream means 1.00 s in Go and ~1.1 s in
python, against a script of deliberate sleeps that sums to ~0.95-1.0 s for a correct answer. Both are
serving the pauses they were told to; the ~100 ms the python adds is loop scheduling around them. The
handoff asked for the `time.Sleep`-on-a-goroutine versus `await`-on-a-loop difference to be measured
rather than designed away — measured, it is ~100 ms of a one-second script at 1000 users.

## The held-timer scenario

`DSQUIZ_TIMER=stream` gives every open tab an SSE connection pushing a signal patch every 100 ms.
The handoff: *"On python that is the expensive mode nobody would ship; on Go it is a goroutine and a
ticker. The harness has a scenario for it that has never been run in anger because the Python side
could not carry it."*

`just dsperf timer-stream 400 20 240`, server on **one core**:

| | |
|---|---|
| users | 400 (timer-holders + players, mixed) |
| held `/timer` streams opened | 669 over 240 s |
| goroutines mid-run | 600 |
| aggregate P50 / P95 | 2 ms / 6 ms |
| `POST /answer` P50 / P95 | 1 ms / 3 ms |
| answer SSE stream mean | 985 ms |
| RSS mid-run / final | 123 MB / 144 MB |
| failures | **0** |

So it runs, on one core, while several hundred players are answering questions through it — and the
interactive latency is indistinguishable from the client-interval mode's. That is the axis where the
two runtimes differ in kind rather than in degree, and it is now a measurement rather than a
prediction.

## Where one core actually saturates

Neither the 400- nor the 1000-user run above is a capacity measurement: both are far from the
ceiling, and their `req/s` is set by the scenarios' think time. This is the ceiling, found by ramping
the same scenarios against a `--procs 1` server and sampling the process's own CPU time
(`TotalProcessorTime` over an 80 s steady-state window, so it is the server's consumption and not a
sampler's guess).

| users | server cores | achieved req/s | agg P50 | agg P95 | `POST /answer` P95 | failures |
|---|---|---|---|---|---|---|
| 400 | ~0.10 | 82 | 1 ms | 4 ms | 3 ms | 0 |
| 1,000 | 0.253 | 196 | 2 ms | 5 ms | 4 ms | 0 |
| 2,000 | 0.524 | 395 | 3 ms | 18 ms | 10 ms | 0 |
| 2,500 | 0.637 | 480 | 3 ms | 25 ms | 16 ms | 0 |
| 3,000 | 0.780 | 562 | 4 ms | 35 ms | 24 ms | 0 |
| **4,000** | **0.998** | 676 | **120 ms** | **290 ms** | 280 ms | 11 (0.01%) |

**~3,850 simulated players saturate one core**, and 4,000 is where it is measurably pinned: 99.8% of
one core, the P50 up 40× from 3 ms to 120 ms, the P99.9 at 7.1 s, and the first failures of any run
in this document. The offered load at 4,000 users is ~780 req/s and only 676 arrived -- that ~13%
shortfall *is* the queue.

The CPU cost is dead linear all the way up, which is what makes the extrapolation trustworthy rather
than a guess:

| users | 1,000 | 2,000 | 2,500 | 3,000 | 4,000 |
|---|---|---|---|---|---|
| milli-cores per user | 0.253 | 0.262 | 0.255 | 0.260 | 0.250 (clipped) |

So: **0.26 milli-cores per player, ~1.3 ms of one core per request**, and a ceiling of ~680-780
scenario-shaped requests per second.

**The usable number is lower than the saturation number**, and that is the one to deploy against.
Latency degrades gracefully to about 0.6-0.8 of a core and then falls off a cliff:

- **≤ 2,000 users** (~0.52 cores) -- P95 18 ms. Comfortable.
- **2,500-3,000** (~0.64-0.78 cores) -- P95 25-35 ms, tails climbing, still nothing failing. This is
  the knee.
- **4,000** (1.00 core) -- collapsed.

For context, the python column at **1,000** users was P50 15 ms / P95 380 ms. The Go server is
running better than that at **3,000** users on the same one core, and it reaches 1,000 users using a
quarter of it.

### What the core is spent on, and the one lever

A CPU profile of the live server at 1,000 users (`/debug/pprof/profile?seconds=30`) has almost
nothing of this app in its top twenty:

```
Duration: 30s, Total samples = 7270ms (24.23%)
     780ms 10.73%  brotli.(*h5).FindLongestMatch
     580ms  7.98%  brotli.(*hashForgetfulChain).FindLongestMatch
     550ms  7.57%  brotli.(*hashForgetfulChain).Store
     300ms  4.13%  brotli.createBackwardReferences        <- 3320ms / 45.67% cumulative
```

**Compression is ~46% of the core**, and the closed-loop probe agrees: the same render with
`Accept-Encoding: identity` is 2.0-2.3× the throughput.

| route (1 core, concurrency 4) | brotli q5 | uncompressed |
|---|---|---|
| `POST /restart` (full fat morph, ~28 KB) | 794 req/s | **1,867 req/s** |
| `GET /` (full page) | 1,040 req/s | **2,108 req/s** |

So the single-core ceiling is a *compression* ceiling, not a rendering or filtering one -- neither the
template execution nor the bidding-tree matcher appears in the profile at all. Two consequences worth
knowing before tuning anything else:

- Moving compression to a reverse proxy (which a deployment behind nginx is doing anyway, and which
  would then also cache the assets) roughly **doubles** this ceiling, to ~7,500-8,000 users per core.
- Fat morph is what makes compression matter: it is ~28 KB per interaction compressed to ~4.9 KB.
  `DSQUIZ_MORPH=fragment` sends far less and would move the same ceiling, at the cost the python's
  COMPARISON.md documents.

A fourth implementation later put a number on how much of that is *this* runtime. The same
closed-loop probe, both servers on one core alternating in the same run, with and without
`Accept-Encoding: br` (`../datastar-quiz-rust/RESULTS.md`):

| one core, concurrency 4 | go, brotli | rust, brotli | go, identity | rust, identity |
|---|---|---|---|---|
| `GET /` | 785 req/s | 955 | 1,337 | **10,933** |
| `POST /restart` | 605 req/s | 809 | 1,499 | **4,806** |

Uncompressed, the Rust app renders this page 8.2x faster than this one does; compressed, 1.22x.
Compression is 41% of a page response here and 91% there, so this port's `andybalholm/brotli` is
carrying the comparison rather than losing it -- at q5 it is 1.0-2.9x *faster* than the Rust
`brotli` crate depending on the payload. The 46% figure above is real, and it is also the reason the
gap between these two ports is 12% rather than the 3-8x their renderers differ by.

### How this was measured

The locust scenarios cannot find a ceiling on their own -- a player who thinks between actions
generates a fixed rate no matter how fast the server is -- so two instruments were used and they
agree:

1. **The ramp above**: real scenarios, real mix, CPU sampled from the OS. This is the number quoted.
2. **A closed-loop probe** (no think time, N distinct sessions, one route at a time) for the per-route
   ceilings: 794 req/s for a full fat-morph render, 1,040 for a full page, ~6,500 for a memo-hit
   filter preview, ~5,000 for a memo MISS on the squad corpus, and ~27,000 for a 204 no-op. Distinct
   sessions matter: hammering one session measures its mutex rather than the work.

Two traps in the second instrument, both of which produced a wrong answer first:

- **`/skip` and `/next` stop doing anything.** Three skips per session and then every request is a
  204; Next only applies off a reveal. A sweep over those reported ~25,000 req/s, which is the no-op
  path. `/restart` always does the whole job and is the honest full-render route.
- **An invalid filter never touches the corpus.** `1C-123` does not parse, so it is rejected before
  matching -- the memo-miss probe has to use patterns that are distinct *and* valid (a 35x35 grid of
  two-call patterns, comfortably more than the 256-entry memo).

## Memory, and the bug the profiler found

The first 400-user run reported **506 MB** resident against the python's ~120 MB, which is the wrong
shape of answer for a server whose live data is a 25 MB corpus and a few hundred small sessions. A
heap profile of the **live, unmodified, full-speed server** — the thing this port can do and the
python could not (see the README's profiling section) — answered it in one line:

```
      flat  flat%   sum%        cum   cum%
  282.46MB 81.56% 81.56%   282.46MB 81.56%  github.com/andybalholm/brotli.ringBufferInitBuffer
   31.74MB  9.17% 90.72%    31.74MB  9.17%  github.com/andybalholm/brotli.(*h5).Initialize
```

A brotli encoder allocates its sliding window up front, and the SSE path was building one per
response. Two fixes, both in `internal/web/sse_compress.go`: **pool** the encoders, and **pin the
window** to 2^16 = 64 KB, which is comfortably larger than the biggest thing this app ever streams
(one fat morph patch, ~28 KB raw). After:

| | live heap | `ringBufferInitBuffer` | RSS at 400 users |
|---|---|---|---|
| before | 346 MB | 282 MB (81.6%) | 506 MB |
| after | **77 MB** | **12.9 MB** | **150 MB** |

Compression ratio is unaffected: a fat `/skip` patch is 27,709 bytes raw and 4,935 compressed
(**5.6×**), against the python's measured 23.6 KB → 4,069 B (5.8×) on its slightly smaller page.

The remaining RSS is honest: ~25 MB of prepared corpus, ~15 MB of filter memo under a load that
types many distinct filters, the pooled encoders, and Go's usual reluctance to return freed spans to
Windows promptly. `--memlimit` is there for a deployment that wants a ceiling.

## Microbenchmarks

`just dsgo bench` — `engine` and `bidfilter` are free of `net/http` so these run with no server in
the way. Python numbers from the app's own measurements, warm.

| | python | go | |
|---|---|---|---|
| `check_filter("1C")`, 7,627 auctions | 15.8 ms | 0.38 ms | ~41× |
| a topic (several patterns), 7,627 auctions | 43 ms | 0.27 ms | ~160× |
| the same, memo hit | — | 15 µs | the 87.6% case under load |
| `check_filter("1C")`, 1,652 auctions | — | 0.056 ms | |
| prepare the whole corpus for filtering | 4.25 s (both systems) | 44.7 ms (swedish alone) | ~95× |
| boot: parse + prepare both corpora | ~5.5 s | ~70 ms | |
| `ScorePoints` | — | 0.68 µs | |
| `Answer` (state change + toast script) | — | 1.3 µs | |
| `NewQuestion` (5 of 1,652) | — | 3.6 µs | |

The boot number is the one with a user-visible history: on the python that 5.5 s used to land inside
a REQUEST, on the first visitor to open the second system, and the yappi profile is what found it.

## Caveats

- Loopback only, and the load generator shares the machine with the server. The 24-core column in
  particular is measuring a box where locust has 23 cores to itself.
- `req/s` is scenario-bound, not server-bound. Neither implementation was saturated; a saturation
  comparison would need a scenario with no think time and is a different experiment.
- The python column is from `../datastar-quiz/COMPARISON.md`, measured on the same machine but not
  on the same day, and not interleaved with these runs.
- RSS on Windows is not a like-for-like against a python process's RSS; the heap profile is the
  number to argue about.
- The python's `/answer` numbers are TTFB (locust stops its clock at the headers on a streamed
  response), and so are these — the whole-stream mean is reported separately for both.
