# dsquiz-perf

[Locust](https://locust.io/) performance tests for the datastar quiz in `apps/datastar-quiz/`,
built on the shared [`gclocust`](https://git.int.gigaclear.net/gis/gclocust) helper library and
following the conventions in the Confluence guide
[Comparison: Auth Service API Performance Testing with Locust](https://gigaclear.atlassian.net/wiki/spaces/DEV/pages/1253408776/).

```shell
just dsquiz serve-prod          # in one terminal: the system under test (no --reload!)
just dsperf smoke               # in another: 2 users, 30s -- does the plumbing work?
just dsperf headless 200 20 300 # 200 users, 20/s ramp, 5 minutes, html report in .reports/
just dsperf run                 # or the web UI on :8089, with the live charts
```

## Layout

```
common/            imported by every scenario; importing it is what arms the run
  __init__.py      reporting options + the aggregate threshold checks (the run's exit code)
  config.py        every tunable, read from the environment once
  datastar.py      the wire protocol: signals up, SSE down, and the parsing that drives the quiz
  profiles.py      who the simulated players are -- system, settings, pace
locustfiles/       one file per scenario; locust loads these by path
  player_scenario.py        people playing quizzes (the main one)
  filter_scenario.py        the bid-table filter's per-keystroke server validation
  cold_visit_scenario.py    first loads, with the static assets
  timer_stream_scenario.py  the held-SSE countdown (needs DSQUIZ_TIMER=stream)
```

`-f locustfiles` runs them all together, `-f locustfiles/player_scenario.py` runs one, and a
comma-separated list runs any combination — which is the scenario separation the guide describes,
and the reason there is no scenario-selection code here.

## Different users, different cookies

**Every locust user has its own session, and this costs nothing to arrange.** A `FastHttpUser`
builds its own `FastHttpSession`, which holds its own `http.cookiejar.CookieJar`; running `-u 500`
therefore creates 500 independent `dsq_sid` cookies and 500 entries in the app's `state.SessionStore`.
Nothing in this project sets a cookie by hand. Two consequences worth knowing:

* Users are greenlets, not threads or processes, so a few thousand of them on one machine is
  ordinary. Memory per user is small (a connection pool of 2 and a parsed `View`); the real ceiling
  is the injector's CPU, not its user count.
* "Abandoning" a quiz is `self.client.cookiejar.clear()` followed by a page load — the server then
  creates a *new* session while the old one sits in the store until its six-hour TTL sweeps it.
  `DSQUIZ_PERF_ABANDON_CHANCE` (default 0.15 of `start_over` beats) controls how fast that pile
  grows, which makes a long run a session-memory test as well as a latency test.

They also differ in what they *do*: each user draws a profile in `on_start` and keeps it — the
system (`?swedish` or the default squad, 30/70 by default), the difficulty (4–8 candidate answers,
which changes both the render and the scoring), ladder mode, the target percentage, and a think-time
band (fast / typical / slow, against a question clock of 4–8 seconds). See `common/profiles.py`.

## Running the injector on the same machine as the server

You can, and for a first look you should — but read the numbers with that in mind:

* **The load generator competes for CPU with the system under test.** Locust is one python process
  per worker; so is the app (granian, one worker — see below). On a machine with several cores that
  is fine to a few hundred users, and it stops being fine exactly when it matters: at the point the
  server saturates, the injector is also busy, and the added latency you measure is partly your own.
  Watch the injector's CPU (locust prints a warning above 90%) before believing any run near the
  knee.
* **Windows cannot use `locust --processes N`.** One python process, one core, for the whole
  injector. `docker-run-locust.cmd` is the way out (the guide's approach), or run the injector from
  WSL, or from another machine — `--host http://<the box>:5008`. In docker, note that the container
  reaches the host as `host.docker.internal`, and that the `[tool.uv.sources]` path to `~/dev/gclocust`
  does not resolve inside the container: use the GitLab index variant of `pyproject.toml` there
  (the block is written out in a comment).
* **Brotli decoding happens on the injector.** The app compresses everything over 256 bytes at
  brotli q5 and this client asks for it, because that CPU is part of what a real page load costs the
  server. If the injector becomes the bottleneck, `DSQUIZ_PERF_ENCODING=identity` takes the client's
  decode cost out — at the price of no longer measuring the server's compression cost.

**The server is one process, and that is not an accident.** `granian --workers` defaults to 1 (so
does `--runtime-threads`), which means one python process running one asyncio loop: the app's own
code gets one core, whatever the machine has. Raising `--workers` does not help here — the session
store is a plain in-process dictionary (`app.STORE`), so with two workers a browser's requests land
on whichever worker answers and half of them find no session; the app resyncs the page and the run
measures the resync path instead of the quiz. More workers needs either sticky sessions or a session
store outside the process, and that is a design change, not a flag.

So the ceiling this measures is one core's worth of python, and the numbers say where it goes:
`/answer` is ~2 ms of that, a topic preview tens of ms, `POST /filter/apply-topics` hundreds. What
granian's Rust layer does across threads (accepting connections, TLS, I/O) is not the part that runs
out first. And never load-test a `--reload` server: the file watcher is a second process on the same
core.

## What the answer route measures

`POST /answer` is the only route whose response deliberately takes seconds: the handler scores the
answer, then streams the toast choreography with `asyncio.sleep` between the frames — 0.6s for a
wrong answer, up to ~4s for a right one that pays a milestone. A load test that timed the whole
response would report a P95 of three seconds and tell you nothing about the server.

So it is measured twice:

* **`POST /answer` in the report is the server's scoring work.** The request is made with
  `stream=True`, and locust stops its clock when the response headers arrive — which is after
  `score_answer` has finished and before the generator has yielded anything. This is the number to
  watch: it is what every player does most often, and it is the first thing to degrade when the
  single-process event loop runs out of room.
* **The whole stream is timed separately and judged as a rate**, not as a latency
  (`common.slow_sse_stream_rate`): what share of streams took longer than `DSQUIZ_PERF_SSE_BUDGET_MS`
  (default 6s). The mean is logged at the end of a run. A stream running well past its own pacing is
  what a starved event loop looks like from the player's chair; the mean by itself is mostly
  deliberate sleeping.

**A 204 is a no-op, not a failure.** A datastar response with no events comes back as
`204 No Content`, and this app returns one deliberately whenever a press no longer applies: Skip with
none left, Next while not on a reveal, a settings POST that changed nothing, an answer to a finished
quiz, and `/timer` in the default client mode. The scenarios treat 200 and 204 alike — the guide's
"Failure Definition" section is about exactly this, and getting it wrong reported `GET /timer (held)`
as 100% failed against a perfectly healthy server. For the same reason a page load is checked for a
question **or a reveal or the finale**: a page parked on a revealed answer carries no `/answer/...`
URL at all.

Two related notes on what the scenarios can and cannot know. The correct answer is not in the page,
so a simulated player picks at random and is right about 1-in-`difficulty` times: both paths are
exercised, but **completions are rare**, so the finale render is barely covered by a normal run.
And `state.SessionStore` keys sessions by (browser, variant), so a user switching systems does not
replace its own session — which is why each user sticks to one.

## The first run, for calibration

A 40-second run of 3 players plus a 40-second run of 4 filter/cold-visit users, against
`granian` single-worker on the same laptop as the injector (2026-08-27, medians):

| request | median | note |
| --- | --- | --- |
| `POST /answer` | **2 ms** | the scoring work; the max of 550 ms is the first request of the run |
| `POST /next` | 5 ms | re-renders the quiz body |
| `POST /skip` | 6 ms | the same |
| `GET /` | 10-30 ms | the whole document |
| `GET /filter/preview` | 19 ms | one keystroke pause, whole-corpus check |
| `GET /filter/preview-topics` | 53 ms | several topics at once, so several times the work |
| `POST /filter/apply-topics` | 200 ms | commits, restarts the quiz and re-renders everything |
| `GET /static/*`, `GET /sfx/*` | 1-3 ms | |
| whole `/answer` SSE stream | mean 1.1 s | dominated by the server's own toast pauses, as expected |

Two things to read off that. **The cold start is real and large** -- the first render of a session
is ~550 ms against ~2 ms warm, so a short run is mostly measuring template compilation and corpus
loading; warm the server or run long enough for it not to matter (`just dsperf smoke` relaxes the
thresholds for exactly this reason). And **the filter, not the quiz loop, is the expensive path**:
answering costs single-digit milliseconds, while previewing a topic selection costs tens and
committing one costs hundreds.

## Pass / fail

The process exit code is the test result, so a CI job needs nothing else. Checks are split the way
the guide describes: the aggregate ones in `common/__init__.py` (fired on `quitting`), the per-route
ones in the scenario file that makes those requests.

| check | default | env var |
| --- | --- | --- |
| aggregate P50 / P95 / P99 | 150 / 600 / 1500 ms | `DSQUIZ_PERF_P50_MS`, `_P95_MS`, `_P99_MS` |
| aggregate failure ratio | 1% | `DSQUIZ_PERF_FAIL_RATIO` |
| `POST /answer` P95 | 400 ms | `DSQUIZ_PERF_ANSWER_P95_MS` |
| `GET /` P95 | 900 ms | `DSQUIZ_PERF_PAGE_P95_MS` |
| `GET /filter/preview*` P95 | 400 ms | `DSQUIZ_PERF_PREVIEW_P95_MS` |
| answer streams over budget | 2% over 6000 ms | `DSQUIZ_PERF_SLOW_SSE_RATE`, `_SSE_BUDGET_MS` |

**These are starting values, not measurements.** Take a baseline run on an idle machine and set them
from it; a threshold nobody derived from a real run only fails at inconvenient moments.
`do_fail_ratio_threshold_check` also replaces locust's default "any error at all fails the run"
policy, so a single dropped connection in a five-minute run does not fail the build.

Everything else worth turning is in `common/config.py`: the load mix
(`DSQUIZ_PERF_SWEDISH_SHARE`, `_FAST_SHARE`, `_SLOW_SHARE`, `_SKIP_CHANCE`, `_ABANDON_CHANCE`), and
`SCALE`, which `gclocust` reads for throughput-paced scenarios.

## Reports

A headless run writes `.reports/DSQuiz (<scenarios>) <timestamp>.html` — the name comes from
`gclocust.do_set_output_report_name_if_missing`, so it says which scenarios ran. `--html <path>`
overrides it. `just dsperf report` opens the newest. The live web UI has the same statistics plus
charts, and P99 is added to them (`do_increase_live_charting_latency_details`).

## Adding a scenario

Copy the shape of `player_scenario.py`: the `sys.path` fix, `import common` (which registers the
shared listeners), a `FastHttpUser` subclass whose `on_start` draws a profile and loads a page, and
tasks that drive the quiz through `common/datastar.py` rather than raw client calls. Give every
request an explicit `name=` — the per-route threshold checks look statistics up by (name, method),
and an unnamed request with an id in its URL becomes a hundred separate rows.
