# Panel vs Datastar: what the port actually cost and bought

Findings from porting `apps/quiz/` (Panel/Bokeh) to `apps/datastar-quiz/` (Datastar + Litestar). Both
run the same quiz off the same unmodified domain code, so the difference is architecture and
presentation, not features.

Measured 2026-08-05, squad variant, 1652 auctions in the working set. The line counts in the Size table
are from the first measurement and have not been re-taken as features landed; the test row is current,
because its growth is the interesting part -- most of it is invariants written *after* a bug, and each
one names the failure it prevents rather than the function it calls.

## Size

| | lines |
|---|---|
| Panel app (`apps/quiz/quiz_app.py`) | 1237 |
| Datastar app — python (`app/corpus/engine/render/state/telemetry`) | 1389 |
| Datastar app — templates | 363 |
| Datastar app — CSS, hand-rolled | 737 |
| **Datastar total, excluding tests** | **2489** |
| Datastar tests | 1667 code lines, 20 files, **345 tests** (was 1264 / 176 when this table was first measured) |
| Shared and unmodified by both (`quiz.py`, `bidfilter.py`) | 1553 |

So the hypermedia version is **2× the hand-written lines** of the Panel app for the same quiz. That
is the honest headline, and the split says where it went:

- **737 lines of CSS** that Panel supplied as `MaterialTemplate` + `Dial` + `LinearGauge` +
  notifications. This is the single biggest cost and it is nearly all presentation.
- **363 lines of templates** — markup Panel generated from widget objects.
- The **python is roughly a wash** (1389 vs 1237), and that number flatters Panel slightly: ~200 of
  our lines are structure Panel had no equivalent of (session store, engine/render separation) and
  the Panel file carries several hundred lines of exploratory comments.

Swapping the hand-rolled CSS for Pico classless plus an adapter (`static/app-pico.css`, live via the
sidebar's *Base CSS* picker — debug sessions only, since Pico is now the default everyone gets)
takes 737 → **532 lines, a 28% cut** — for 71KB of vendored stylesheet.
What survives is what no base can know: layout, the drawer, the four widgets, the suit colours. What
disappears is buttons, inputs, select, `<details>`, `<dialog>`, typography, focus rings, light/dark.

Bulma 1.0.4 is spiked the same way (`static/app-bulma.css`, third option in the picker), which prices
the *class-based* family against the classless one. Counting code lines only — comments and blanks
stripped, so all three are measured alike:

| | adapter | vendored | vendored, brotli | framework classes in markup |
|---|---|---|---|---|
| hand-rolled | 629 | — | — | — |
| Pico classless | 564 (−10%) | 71 KB | 9.9 KB | none |
| Bulma | 536 (−15%) | 678 KB | 44 KB | 28 tokens, 5 templates, 2 wrapper elements |

Pico's adapter measured 490 (−22%) until the variant was actually *played* rather than looked at: its
`<details>` panels had no surface, its `dialog` is an overlay expecting a `> article` card, it claims
`aria-busy` as a loading component (which wrecked the choice grid for the 2.5-3.5s an answer takes),
and its colour roles are declared at a specificity that silently ignores an adapter's `:root`. 74
lines to put right — and the reason the picker exists rather than a screenshot comparison.

The class strings ride in every patch, but they compress away: the document went 19,347 → 20,631
bytes raw and 4,384 → **4,448** brotli; one interaction 4,129 → **4,215**. So the argument against a
class-based framework here is the templates, not the wire. (The digit-accelerator rewrite afterwards
returned ~360 raw bytes of that, by replacing five per-button `keydown` attributes with one on the
group — currently 20,268 raw / 4,490 brotli for the document.) Full findings — six Bulma quirks and nine
Pico ones, each costing adapter lines — are in `DESIGN.md`; the short version is that both frameworks
leave the same ~300-line core (layout, drawer, dial, gauge, timer, toasts, suit colours) untouched and
only compete over the controls, where Pico wins on markup and weight and Bulma wins on theming.

Vendored assets: `datastar.js` 34KB, Pico 71KB, Bulma 678KB (44KB brotli — the whole framework, since
trimming it to the components used needs a Sass build). Panel/Bokeh ships roughly 2MB of JS before
its own CSS.

## Wire traffic

| interaction | bytes | SSE events |
|---|---|---|
| `GET /` full page | 19,543 | — |
| `POST /answer` (wrong: toasts, then the reveal) | 2,783 | 4 |
| `POST /next` (new question + score) | 3,942 | 3 |
| one signal-only frame | 167 | 1 |
| uploaded with **every** request (bound signals) | 475 | — |

Two things worth noting.

**The signal upload is not free.** 475 bytes ride along on every request, and 383 of them are the 18
topic checkboxes — a picker the user opens rarely. That is the concrete cost of `data-bind`
convenience, and it is the argument for `filterSignals` on hot paths. The 15 `_`-prefixed local
signals (237 bytes) never travel, which is exactly why server-owned display values are underscored.

**Element patches dominate.** A question fragment is ~2-4KB; a signal frame is 167 bytes. Hence the
design of keeping the score panel, skip counter and timer as static markup fed by signals: answering
a question sends one element patch plus one small signal patch, rather than re-rendering the sidebar.

## The two push models

Both are implemented; `DSQUIZ_TIMER` picks one (`app.TIMER_MODE`).

| | client interval (default) | held SSE stream |
|---|---|---|
| how | `data-on-interval` walks `$_timeLeftPct` down from an allowance stated once per question | `GET /timer` held open, `patch_signals` every 100ms |
| connections | none | one per tab, and browsers cap HTTP/1.1 at 6 per host |
| server work | none between answers | a tick per 100ms per connected client |
| wire | 0 | ~1.7KB/s/client (10 × 167-byte frames) |
| fidelity to Panel | approximates it | exactly Panel's model (`add_periodic_callback` over the websocket) |

Scoring is identical either way: the bonus is recomputed server-side from the question's start time,
so the bar is only ever an animation. Given that, the client interval wins on every axis that
matters here, and the stream exists to make the comparison concrete rather than theoretical. The
stream also needs a cap (`TIMER_STREAM_MAX_SECONDS`) or an abandoned tab holds a worker slot and a
session alive indefinitely — a problem the interval simply does not have.

The honest caveat: this quiz has no genuinely server-driven state. Nothing changes unless the user
acts. An app with live external data would invert this table.

## Performance

Measured on one Windows machine over loopback, granian with one worker, panel/bokeh via
`panel serve --dev`. Medians of 15-21 runs. Loopback hides real network latency, which matters for
the interpretation below.

**A measurement trap first**: `curl http://localhost:5008/...` reported ~214ms for *everything*,
including a static file. That is Windows resolving `localhost` to IPv6 and falling back to IPv4 —
`time_connect` alone was 204ms. Against `127.0.0.1` the same static file is 2.0ms. Every number here
uses `127.0.0.1`; anything measured over `localhost` on this platform is measuring the resolver.

### Server handler latency

| endpoint | median | what it does |
|---|---|---|
| `GET /static/app.css` | 2.1 ms | floor: granian + static file |
| `GET /` | 2.6 ms | render the whole page from session state |
| `POST /skip` | 1.7 ms | draw a question, render fragment + signals |
| `POST /settings` | 1.7 ms | adopt signals, restart, render |
| `GET /filter/preview` | 6.2 ms | match 1652 pre-parsed auctions against a pattern |
| `GET /filter/preview` (unparseable) | 2.0 ms | rejected before matching |
| panel `GET /quiz_app` | 682 ms | bokeh session + document creation |

Throughput, driven from the page with `fetch` (no per-request process spawn): `POST /skip` **607
req/s** sequential (1.65ms each), `GET /` 308 req/s, `/filter/preview` 166 req/s. Twenty concurrent
skips completed in 13ms total, so one worker is nowhere near saturated by a single user.

The 6.2ms filter preview is the only endpoint doing real work, and it is the one running per
keystroke — comfortably inside the 300ms debounce.

### Load cost

| | datastar | panel |
|---|---|---|
| requests | 3 | 26-29 |
| transferred (cold) | 68 KB | 5.4 MB |
| DOMContentLoaded | 21 ms | ~590-710 ms |
| load event | 45 ms | ~600-740 ms |
| biggest assets | `datastar.js` 34KB, `app.css` 16KB | `bokeh-mathjax` 1.7MB, `bokeh.min.js` 1.2MB, `panel.min.js` 747KB, `bokeh-widgets` 373KB, `material-components-web` 320KB |

**80× the bytes and 9× the requests** for the same first screen. Warm, panel drops to ~13KB
transferred because the bundles cache — but it still parses and boots them, which is where its
~600ms DOMContentLoaded goes.

### Interaction latency

Same gesture in both apps, measured in the page: click *Skip*, poll `requestAnimationFrame` until
the question text actually changes.

| | median | samples |
|---|---|---|
| datastar | **8 ms** | 4, 4, 8, 8, 8, 8, 8, 8, 8, 9 |
| panel | **64 ms** | 59, 59, 60, 64, 65, 67 |

### So why is datastar faster — less round-tripping, or more on the client?

**Neither.** Both do exactly one server round trip per interaction, and datastar does *less* on the
client, not more. The 8× difference is work per trip on both ends:

- **Server**: datastar renders a 2-4KB HTML fragment (1.7ms). Panel mutates widget objects, and
  Bokeh diffs its document model to produce a patch message.
- **Wire**: an HTML fragment the browser parses natively, versus a Bokeh protocol message.
- **Client**: datastar morphs one subtree. Panel applies the patch to its widget models, which
  re-render Bokeh views inside shadow DOM. That client-side model update is the part that does not
  exist here at all — it is what "deleting the client model" removed.

The one thing datastar demonstrably does *more* of is HTTP requests where panel had a standing
websocket: a request per action, each with ~475 bytes of signals uploaded. On loopback that is free;
over a real network the picture narrows, because the fixed cost of a request starts to dominate the
1.7ms of server work. A held connection would win back the handshake — which is exactly the
`DSQUIZ_TIMER=stream` variant, and the reason its ~1.7KB/s/client tick cost is a fair trade only when
the server genuinely has something to say.

Per-keystroke filter validation is a round trip in *both* apps, so nothing is saved or lost there.

### Footprint

| | resident | note |
|---|---|---|
| datastar (granian main + worker) | 77 MB | 22MB supervisor + 55MB worker holding the corpus |
| panel (bokeh/tornado) | 219 MB | one process |

CPU-seconds are not comparable here (the two processes served different request counts during the
session), so they are not quoted.

### Caveats

- Loopback only. The interaction gap would narrow over a real network, and the load gap would widen.
- One granian worker versus panel's single process — fair for one user, untested under many.
- Panel was run with `--dev`.
- The datastar `POST /answer` path is deliberately paced (toast sequence), so *Skip* is the only
  like-for-like interaction; comparing answer timings would measure my chosen sleeps.

## Resumability, and how much state a response carries

`GET /` renders the **whole page from session state**, so a reload, a second tab, or a recovered
connection all resume exactly where the quiz was — same question, same `qid`, same score, same
applied filter, and mid-reveal if that is where you were. Nothing is stored in the URL and nothing is
replayed; the page is a projection of the session.

That is the sharpest contrast with Panel, where the state lives in a Bokeh session tied to the
websocket: **reloading the Panel quiz starts a new one and loses the score** (`quiz_app.py:49`
documents the abandoned `--reuse-sessions` experiment). Here a reload is free.

What does *not* survive: sessions are a process-local dict, so a server restart or the 6-hour TTL
sweep loses them. The recovery path is a fresh quiz rather than an error — the cookie is honoured if
it resolves and replaced if it does not.

### Full state or partials?

Per interaction this app sends:

| | granularity |
|---|---|
| elements | **whole page** (`#app`) — fat morph, the default; `#toasts` alone during a toast sequence |
| server-owned signals | **full set**, all ten, every time (not a diff) |
| effective settings | **full set**, echoed after the server has adopted them |
| drafts (`filterText`, topic ticks) | **never as signals**; their markup rides along in the fat patch, which does not clobber a draft |

The Tao is explicit that the doctrine is the opposite of minimal diffing:

> "Morphing ensures that only modified parts of the DOM are updated, preserving state and improving
> performance. This allows you to send down large chunks of the DOM tree (all the way up to the `html`
> tag), sometimes known as 'fat morph'"

Both halves now follow the doctrine — see *Fat morph and compression* above for the numbers and the
reason. The fine-grained version shipped a bug that fat morph makes impossible: `POST /settings`
adopted a proposed `difficulty` of 99, clamped it to 8, and told the browser nothing, so the slider
read 99 while questions had 8 candidates until a reload. The echo (`render.settings_signals`) fixes
that for signals; the fat patch removes the whole class of it for markup.

The nuance the doctrine does not cover is **drafts**. `filterText` is client-owned until committed,
so re-stating it on an unrelated patch — a Skip, say — would wipe a half-typed filter. Full-state
patching is right for state the server owns and wrong for state the user is still editing. Hence the
split: `settings_signals` (server clamps them, always echoed) versus `bound_signals` (includes the
drafts, sent only when a commit has just made the server's version authoritative).

## Fat morph and compression

The Tao is explicit about granularity:

> "Morphing ensures that only modified parts of the DOM are updated, preserving state and improving
> performance. This allows you to send down large chunks of the DOM tree (all the way up to the `html`
> tag), sometimes known as 'fat morph'"

This app now does that by default: an interaction patches `#app` — everything below `<body>` — and
`DSQUIZ_MORPH=fragment` keeps the old `#quiz`-only behaviour for comparison. Measured with
`uv run --project . python tools/measure.py`:

| | raw | brotli | ratio |
|---|---|---|---|
| `GET /` document | 19,347 | **4,384** | 4.4× |
| interaction, **fat** (`#app`) | 23,156 | **4,129** | 5.6× |
| interaction, fragment (`#quiz`) | 3,748 | **767** | 4.9× |
| `app.css` | 15,714 | 5,122 | 3.1× |
| `datastar.js` | 33,952 | 12,831 | 2.6× |

Fat morph costs **~3.4KB more per interaction** over the wire, and the repetitive markup compresses
*better* than the document does. Server render is unchanged within noise (1.9ms uncompressed, 1.8ms
brotli, against 1.7ms for a fragment), and the click-to-updated-DOM latency is **8ms either way** —
identical to the fragment measurement, so the morph itself is not the cost.

### Compression is what makes it cheap — including on the SSE stream

`CompressionConfig(backend="brotli", brotli_quality=5, brotli_gzip_fallback=True, minimum_size=256)`.
zstd is not a litestar backend, and at these sizes the choice of codec matters far less than the
level. **Quality 5 is the knee**, measured on this app's own 23.6KB fat patch:

| quality | bytes | ratio | time |
|---|---|---|---|
| q1 | 5,021 | 4.7× | 0.04 ms |
| q4 | 4,391 | 5.4× | 0.32 ms |
| **q5** | **4,069** | **5.8×** | **0.56 ms** |
| q6 | 4,053 | 5.8× | 0.94 ms |
| q9 | 4,022 | 5.9× | 4.41 ms |
| q11 | 3,641 | 6.5× | 22.34 ms |
| gzip -9 | 4,350 | 5.4× | 0.24 ms |

q6 costs 68% more time for 0.4% fewer bytes, q9 is 8× the CPU for 1%, and q11 is **40× for 10%** —
useless for dynamic responses, though fine for something built once. q5 also beats gzip -9 on size at
about twice its cost. Worth keeping in proportion: 0.56ms of compression against a 1.8ms handler is
roughly a third of the response's CPU, so q4 (0.32ms, 8% more bytes) is the reasonable dial-down if
CPU ever matters more than bandwidth. It is pinned explicitly rather than inherited from litestar's
default (which is also 5 today) so the choice cannot move underneath us; a test asserts it.

The datastar SDK spec warns that compression middleware "may interfere" with flushing, which would be
fatal for a paced toast sequence. It does not here, and the reason is worth recording: litestar's
brotli facade calls `compressor.process(chunk)` **followed by `compressor.flush()`** for every ASGI
chunk (`litestar/middleware/compression/brotli_facade.py`), and the middleware forwards each
compressed chunk while `more_body` is set. Verified rather than assumed — chunk arrivals for a wrong
answer, compressed:

```
content-encoding: br
chunk arrivals (ms): [3, 618, 623, 623, 623]
spread 620 ms over 5 chunks -- paced, so compression is not buffering
```

The first toast lands in 3ms and the rest arrive after the server's own 0.6s pause. Had compression
buffered, every frame would have appeared together at the end. So the streaming routes are compressed
too, which is the only way the "fat morph is fine, it compresses" argument actually holds — exclude
SSE and a fat patch costs its full 23KB.

### What fat morph bought

The reason to prefer it is not bytes, it is that **the server stops having to remember which fragments
a state change touches**. That was a real bug class here: a clamped `difficulty` sat stale in the
sidebar because `/settings` patched `#quiz` and the slider lived outside it. Under fat morph that is
structurally impossible.

Browser-verified that a fat morph preserves everything it should: input focus, a typed filter draft,
`<details open>`, the open topics dialog, scroll position, and the system-notes iframe is not
reloaded. The draft survives because the morph only writes `input.value` when the value *attribute*
differs, and typing changes the property (`patchElements.ts` — "many bothans died to bring us this
information"). Signals are unaffected either way: they live in the store, not the DOM.

One trap fat morph introduces: anything inside the morph target with `data-init` re-runs on every
patch. In `DSQUIZ_TIMER=stream` mode that would open a fresh held connection per interaction, so the
stream's `data-init` lives on `<body>`, outside `#app`. The client-interval expression is safe to
re-create and stays inside. Pinned by a test.

## What got better

- **One state machine instead of two.** Panel is a stateful server *plus* a stateful client (a Bokeh
  document of widget models synced over a websocket). The port deleted the client model. There is no
  reconciliation code because there is nothing to reconcile.
- **Correctness moved to where it can be enforced.** Panel guarded double-clicks by disabling
  buttons and checking `any(button.disabled ...)` — client state the server was reaching into. Here
  the question carries a `qid` nonce and a stale answer is a 204, which a reload cannot defeat.
- **Validation stayed on the server.** The bid-filter preview runs `bidfilter` per keystroke and
  returns a fragment; the browser knows nothing about bidding. Panel did this too, but through a
  widget model; here it is an HTTP request that can be curled.
- **The page is the state.** `view-source` shows the current quiz. No hydration, no bootstrap.
- **Testability.** 176 tests over routes, SSE framing, rules parity with the Panel source, signal
  naming, CSS invariants — most of which have no natural equivalent against a Bokeh document.

## What got worse

- **Presentation is now our problem.** 737 lines of CSS, plus every widget by hand.
- **`AutocompleteInput` was a real loss.** `<datalist>` gives the dropdown but not
  `search_strategy="includes"`, styled matches, or prefix-resolves-on-Enter (that moved server-side).
- **Rich tooltips are gone.** Panel rendered markdown in a hover tooltip from `description=`;
  substituted a `<details>` block.
- **Notification choreography is coarser.** Panel queued stacked toasts with independent durations;
  here the sequence lives in the SSE stream, so one shows at a time.
- **Sessions are process-local**, so one worker or sticky routing — the same constraint Panel had.

## Bugs the port surfaced, and what they have in common

Every one of these was found by *measuring the visible result*, not by asserting that code ran:

1. `data-bind:filterText` — HTML lowercases attribute keys, so it bound a second signal `filtertext`
   while the server kept writing `filterText`.
2. Slug `1c_opening` → signal `1COpening`: datastar's `kebab` splits letter/digit boundaries.
3. `data-indicator:_answering` → `Answering`: a leading underscore cannot survive an attribute key,
   silently promoting a local signal to one uploaded on every request.
4. An undeclared signal reads as `''`, and `data-attr` treats `''` as *set the attribute* — so an
   undeclared `$_topicsOpen` left `<dialog open>` permanently.
5. The nav collapse set a zero-width first grid track *and* hid the sidebar, so `main` was
   auto-placed into the zero track: the quiz collapsed instead of the nav.
6. The points gradient was painted on the growing fill, so 100/1000 points looked as green as
   1000/1000.
7. The reveal's Next button had both `data-on:click` and an Enter `data-on:keydown__window`; a
   focused button activates natively, so two requests fired and the second aborted the first *after*
   the server had advanced the question.
8. The drawer's dismiss-on-outside-click also fired for the hamburger, so the two handlers cancelled.
9. `?swedish` was silently ignored for anyone who already had a session cookie — Panel got this free
   by keying sessions on the variant.
10. Arrow keys on a range input fire `change` per keypress, and a settings change restarts the quiz:
    keyboard use wiped the score.
11. A malformed signals body (`{}{}`, truncated json) made `read_signals` raise `JSONDecodeError`,
    which surfaced as a 500 and a stack trace on every affected route. Found by a broken benchmark
    harness; absent or unusable signals now mean "nothing to adopt", which every handler already
    coped with.
12. Settings the server clamped were not echoed back, so a rejected value sat in the UI until a
    reload — the live page and the session disagreed. Found by asking what the Tao's "fat morph"
    advice would have caught.
13. The countdown kept running after the question was answered: the interval gated on `$_playing`,
    which is only false when the whole *quiz* ends, so the bar drained to empty behind the revealed
    answer and through the toast sequence — time pressure on a question already scored. `$_playing`
    was the closest existing signal, not the right one; the condition needed was "a live, unanswered
    question is being timed" (`_ticking`), plus `$_answering` for the click-to-patch window. The
    server side matters too: `percent_time_left()` kept counting against `question_start`, so a
    reload while parked on the reveal reported *less* time than the answer was scored with. It is
    frozen at the moment of scoring instead.
14. The digit accelerators were inert in two states nobody tried — focus parked in a `<select>`, and
    the whole answer stream (see DESIGN.md). Neither logged anything; both looked like "the shortcuts
    are broken".
15. **Two counters that both started at 1.** Reported as "I clicked an answer and it showed me a
    different question, marked wrong". The question nonce was per session and started at 1, and the
    session cookie is one per browser — so `?swedish` (which *replaces* the session, since the
    variant decides the bml system) left the other tab, the back-history entry and the phone's first
    tab showing a quiz that no longer existed, and their `qid=1` **matched** the new session's first
    question. The staleness guard that exists for exactly this passed by coincidence, and the answer
    scored against a question that had never been on screen — from a different *system*, so the app
    bar changed its title too. A restart (`--reload`, constantly) and the six-hour sweep produce the
    same stale page. Nonces are now unique per process, so the guard is exact; a stale interaction
    **resyncs the page** instead of returning a silent 204, because a dead button leaves the page
    wrong and the next click stale as well; and every action URL now carries its variant, so a
    session that has to be *rebuilt* is rebuilt as the system the page is actually showing rather
    than as the default. Then the model itself was fixed: sessions are keyed by **(browser, variant)**
    rather than by the cookie alone, which is what panel had for free by keying its sessions on the
    variant. Switching systems now parks one quiz and resumes the other — both keep their score, both
    can be open in two tabs at once — instead of one silently ending the other. One cookie still, and
    still under one name, because nginx pins a player to a worker by hashing it (DEPLOY.md); the
    variant is the other half of the key and it comes from the page's own URLs.
16. **The keys were being delivered to another document.** "The shortcuts randomly stop working, and
    a reload does not bring them back" — on a live question, with the mouse still working. Nothing in
    the app was broken: the System Notes are a cross-origin `<iframe>`, so a click inside them (to
    scroll, to follow a link) moves focus out of our document, and every accelerator here is a
    `__window` listener on ours. No guard we own can see that state — `$_answering`, `$_topicsOpen`
    and the qid are all healthy — and the mouse is unaffected because a click is delivered by
    position, not by focus. The pointer arriving back on the question card now takes focus back, and
    only from an iframe, so a half-typed filter box is left alone. **And a second cause with the same
    signature, outside the app entirely**: a keyboard extension. Vimium binds 1-9 as count prefixes
    (`3j`), so it eats precisely the digits, spares the mouse and survives reloads — established by
    elimination, since a private window plays fine. Nothing to fix in the page; the cure is the
    extension's own URL exclusion list. Two of the five causes of "the shortcuts are broken" turned
    out not to be shortcuts at all, which is the lesson: when a key never arrives, no amount of guard
    inspection will find it — ask *which document has focus*, then *what else is listening*.

Five patterns, worth carrying forward:

- **The thing being sized was not the thing being measured** (5, 6).
- **One gesture must not drive two handlers** (7, 8) — and note 7's deeper lesson: with
  mutate-then-stream, an aborted request still leaves the mutation applied.
- **Naming conventions are load-bearing** (1, 2, 3, 4). Datastar's attribute-key casing and the
  underscore-means-local rule are silent when violated: no error, just state that stops agreeing.
- **The nearest existing signal is not the right condition** (13, 14). `$_playing` for "is this
  question live", `evt.target.tagName` for "is the user typing" — both are *almost* the predicate you
  want, both are wrong in exactly the states that are hard to notice, and neither fails loudly.
- **A guard that can pass by coincidence is not a guard** (15). The nonce was there precisely to make
  a stale click harmless, and it worked for every case it was written against (double click, replay)
  because those share a session. Scoped per session, it was a *local* answer to a question that is
  global: two quizzes existing at once. Anything used to say "this message is about the thing I think
  it is" has to be unique across everything that can send one — and when it does catch something,
  saying nothing is its own bug (the page stays wrong, so the next click is stale too).

## The third implementation: the same app in Go

`apps/datastar-quiz-golang/` is this architecture again on `net/http` + the datastar Go SDK -- same
routes, same corpus (exported from here and embedded there), same choreography, driven by the same
`apps/dsquiz-perf` harness unchanged. Its `RESULTS.md` has the runs; the short version, measured
2026-08-28 on this machine:

| | python (litestar, one loop) | go, ONE core | go, 24 cores |
|---|---|---|---|
| aggregate P50 / P95, 400 users | 4 ms / 72 ms | 1 ms / 4 ms | -- |
| aggregate P50 / P95, 1000 users | 15 ms / 380 ms | 2 ms / 5 ms | 1 ms / 3 ms |
| `POST /answer` TTFB, 1000 users | P50 10 ms, P95 300 ms | P50 1 ms, P95 4 ms | P50 1 ms, P95 2 ms |
| `check_filter("1C")` over 7,627 auctions | 15.8 ms | 0.38 ms | -- |
| parse + prepare both corpora at boot | ~5.5 s | ~70 ms | -- |
| held `/timer` streams (`DSQUIZ_TIMER=stream`) | not shippable | 400 users, 600 goroutines, 0 failures | -- |

Three things that column says, and one it does not:

- **The P50s barely move; the TAILS collapse.** At these rates neither implementation is queueing
  much, and what a single event loop costs is head-of-line blocking -- which is a P95/P99 effect. The
  `/answer` P95 of 300 ms at 1000 users is one request waiting behind others on the loop.
- **The other 23 cores bought nothing.** One core against 24 is 5 ms against 3 ms at the P95. At this
  load the difference is Go, not parallelism; the multi-core column would only start to matter at a
  rate that saturates one core, which these scenarios never reach.
- **The held-connection timer is the one difference in KIND.** `DSQUIZ_TIMER=stream` is a connection
  per tab pushing a signal patch every 100 ms; the harness has had a scenario for it since it was
  written and it had never been run in anger, because this side could not carry it. On the Go side it
  is a goroutine and a ticker, and the interactive latency alongside it is indistinguishable from the
  client-interval default's. That is the case where "the push half of datastar starts earning its
  keep" stops being hypothetical -- see the last section.
- **It does not say the design was wrong.** The architecture is unchanged, and every design decision
  in this document survived the port intact: fat morph, the `_`-prefixed signals, the server-owned
  question, the 204 no-ops, the process-wide nonce. What changed is the floor under it.

The Go port also settles a measurement this document could not make. Profiling here means yappi (see
`profiling.py`: py-spy's stop-the-world pause *is* the outage on a single loop -- 100 Hz against 100
users took the P90 from ~50 ms to 18 s), so the profile can say where the time goes and never how
fast it is. A heap profile of the live Go server at full speed found a 282 MB line in one look -- a
brotli encoder allocated per SSE response -- and the fix took the resident set from 506 MB to 150 MB
without touching a percentile. That is the class of question this side has to answer by reasoning.

## The fourth implementation: the same app in Rust

`apps/datastar-quiz-rust/` is the architecture a fourth time, on tokio + axum + askama with the Rust
datastar SDK. Same routes, same exported corpus, same choreography, same harness. Where the Go port
answered *"what does a compiled runtime cost"*, this one answers a narrower question: **what do you
get for no GC and for spending real effort on not allocating**. Its `RESULTS.md` has the runs.

| at 1,000 users, ONE core | python (one loop) | go | rust |
|---|---|---|---|
| aggregate P50 / P95 | 15 / 380 ms | 2 / 5 ms | 2 / 17 ms |
| `POST /answer` TTFB | P50 10, P95 300 ms | P50 1, P95 4 ms | P50 1, P95 7 ms |
| server CPU | -- | 0.253 cores | 0.223 cores |
| **worker RSS** | ~185 MB | 278 MB | **99 MB** |
| players that saturate one core | -- | ~3,850 | ~4,300 |
| `check_filter("1C")` over 7,627 auctions | 15.8 ms | 380 us | 96.5 us |
| parse + prepare both corpora at boot | ~5.5 s | ~70 ms | 21.3 ms |

**The memory answer is unambiguous and the throughput answer is not.** 99 MB against Go's 278 MB for
identical work, from four decisions each measurable on its own: a parsed call is 6 bytes rather than
40, the prepared corpus is one flat arena of 0.72 MB rather than ~25 MB of nested slices, a memoised
filter hit is a shared `u32` rather than a copied 40-byte struct, and the brotli encoders need no
pool at all because they are freed when the response ends rather than when a collector next runs --
the Go port needed that pool to get from 506 MB down to 150 MB. But the CPU is only ~12% lower and
the ceiling only ~13% higher.

**Why, and it is the most interesting number of the three ports.** Run each route twice, once with
`Accept-Encoding: br` and once with `identity`, both servers on one core alternating in the same run:

| one core, closed loop | go, brotli | rust, brotli | go, identity | rust, identity |
|---|---|---|---|---|
| `GET /` (the full page) | 785/s | 955/s | 1,337/s | **10,933/s** |
| `POST /restart` (a full fat morph) | 605/s | 809/s | 1,499/s | **4,806/s** |

With compression off the Rust app renders this page **8.2x** what the Go one does. With compression
on, 1.22x. Brotli is **91%** of a compressed page response there against **41%** here -- so the
entire measured advantage of the careful, allocation-free version is spent inside a compression
library both of them merely call, and the `brotli` crate at q5 turns out to be 1.0-2.9x slower than
`andybalholm/brotli` at q5 depending on payload. That single library choice, not the language,
decides every per-route ranking: `/filter/preview` is 1.25x *faster* in Rust uncompressed and 0.71x
compressed.

Which is the same lesson this document reaches in [Fat morph and compression](#fat-morph-and-compression)
from the other end. Fat morph makes every interaction a ~23 KB render, that render must be
compressed to be affordable on the wire, and compression then becomes the workload. The application
code -- the matcher, the templates, the session -- stopped being the cost three implementations ago.

Two smaller things the Rust column is honest about:

- **Its aggregate P95 is worse than Go's** (17 ms vs 5 ms), and it is one route: the player
  scenario's `GET /` during the spawn burst, P50 31 ms against Go's 10 ms. Uncompressed it is the
  fastest server of the three at that route, so it is queueing under a burst rather than service
  time. One tokio worker handles that ramp less gracefully than one `GOMAXPROCS=1` Go process.
- **`axum::serve` does not set `TCP_NODELAY`.** `net/http`, uvicorn and granian all do. Without it
  the keep-alive routes measured 10-11 ms against Go's 2-3, and the answer stream ran 1,401 ms
  instead of ~1,000 -- Nagle waiting on a delayed ACK, and nothing to do with Rust. It is one line in
  `main.rs`, and without it this column would have read five times worse than it is.

## The sixth implementation: the same app in F#

`apps/datastar-quiz-fsharp/` is the architecture a sixth time, on .NET 10 + Oxpecker + the ViewEngine
DSL, with `StarFederation.Datastar.FSharp` for the datastar contract. Same routes, same exported corpus,
same choreography, same harness. Where the Go port asked *"what does a compiled runtime cost"* and the
Rust one *"what does no GC and no allocation buy"*, this port asks two questions neither can:

**What does it cost when the SSE writer is FIRST-PARTY LIBRARY CODE in the app's own language** —
`StarFederation.Datastar.FSharp` is the core of `starfederation/datastar-dotnet`, and the C# package is
a shim over it — **and what does the deploy-time codegen axis buy**: JIT, ReadyToRun and Native AOT are
three ways to ship the same IL, and nothing else in this repo measures that.

The answer to the first is a flat no, for a reason worth recording: every writer the SDK offers takes an
`HttpResponse` and writes to `httpResponse.BodyWriter`, which leaves **no seam for a compressor** — and
brotli q5 on the streams is one of the ground rules. The frames are built as text and handed to a
compressing writer instead, which is what the Rust port does one layer down. The library is good code
(UTF-8 straight into `IBufferWriter<byte>`, byte-literal prefixes, zero-allocation line splitting); it
is simply not shaped for a pipeline with a stage in it.

The answer to the second is the interesting one.

| 400 users, ONE core | python (one loop) | go | rust | tina | **F# (jit)** |
|---|---|---|---|---|---|
| aggregate P50 / P95 | 4 / 72 ms | 1 / 4 ms | 2 / 19 ms | 1 / 2 ms | **1 / 4 ms** |
| `POST /answer` TTFB P50 / P95 | 2 / 62 ms | 1 / 3 ms | 1 / 5 ms | 1 / 2 ms | **1 / 3 ms** |
| `/answer` whole stream, mean | ~1.1 s | 1.004 s | 1.013 s | 1.029 s | **0.99 s** |
| resident set | ~120 MB | 171 MB | **53 MB** | 207-216 MB | **118 MB** |
| server CPU, cores | ~0.89 (pinned) | ~0.10 | 0.110 | 1.049 (*idle too*) | **0.161** |
| requests / failures | — | — | — | — | **24,575 / 0** |

On latency it lands on Go's numbers and ahead of Rust's P95, on a first attempt with no tuning pass.
That is not a claim about the languages: it is what a mature server stack does with an app whose work
per request is a dictionary lookup, a memoised filter check and ~20 KB of markup.

### The codegen axis, which is the actual finding

Same source, three publishes. One core, `hey -n 3000 -c 4`, a warm-up pass discarded so the JIT column
is not charged for its own tiering:

| | JIT | ReadyToRun | **Native AOT** |
|---|---|---|---|
| deployable size | 7.2 MB *(+ a .NET install)* | 115.0 MB, 355 files | **15.9 MB, 2 files** |
| process start → first response | 681 ms | 618 ms | **553 ms** |
| corpus parse + prepare | 241 ms | 180 ms | **84 ms** |
| `GET /` identity | 4,372 req/s | 4,995 req/s | **10,975 req/s** |
| `GET /` brotli | 1,662 req/s | 1,609 req/s | **3,419 req/s** |
| `GET /filter/preview` brotli | 7,124 req/s | 5,863 req/s | **9,753 req/s** |
| resident set, idle | 96.5 MB | 97.3 MB | **66.2 MB** |
| idle CPU | 0.120 cores | 0.130 cores | **0.000 cores** |

**Native AOT is 2.5× the throughput of the JIT build on the page route and a third less memory**, and
its corpus prepare is 2.9× faster — most of what looked like a slow F# corpus loader was JIT warm-up.
Put beside the other ports' one-core per-route table, the AOT column reads: `GET /` identity 10,975
against Rust's 10,933 and Go's 1,337; `GET /` brotli 3,419 against Go's 785 and Rust's 955.

It also cost three fixes, none of them predictable from the documentation:

1. **`vswhere.exe` must be on PATH** or the native link step fails with "not recognized". Nothing to do
   with F#.
2. **Oxpecker and FSharp.Core emit aggregate trim/AOT warnings** (IL2104, IL3053). ILC compiles the app
   anyway; a project with `TreatWarningsAsErrors` fails a publish that otherwise works.
3. **Two things in the app died AT STARTUP while the build succeeded.** Oxpecker's `routef` builds its
   route template by reflecting over the handler's parameters, and F#'s `printfn` reflects over its
   format specifiers — `MethodInfo.MakeGenericMethod`, which AOT cannot do. Both have direct
   replacements (`route` + `TryGetRouteValue`, and string concatenation), and the app now uses them
   everywhere. **This is the shape of F# AOT trouble: not "it does not compile", but "it compiles, links,
   and throws on the first line that formats a string".**

### What the port measured about itself

- **Asset pre-compression at quality 11 was indefensible, and only measuring showed it.** Nine assets,
  1,973 KB: q5 saves 930 KB in 25 ms, q11 saves 951 KB in **1,484 ms**. 59× the time for the last 21 KB,
  and it dominated the whole startup. The default is 5, matching the streams.
- **On a one-core budget .NET uses workstation GC** even with `System.GC.Server=true` in the
  runtimeconfig. The startup line reports which collector is actually live, because the recipe cannot.
- **`ServerGarbageCollector` is not the property name** (it is `ServerGarbageCollection`); the
  misspelling is silently ignored, which is how this port spent its first hour on workstation GC.

### Two bugs the port surfaced

Both were invisible in a browser, which is the pattern the [earlier bug section](#bugs-the-port-surfaced-and-what-they-have-in-common) describes.

- **The view engine escapes `'` to `&#39;` in attribute values.** Correct HTML, decoded before datastar
  sees it, and the page works by hand. But the shared harness reads the page with regexes written
  against the literal quotes the other four ports emit, and it is declared unchanged across ports — so
  it read the variant query as `?squad&#39;)` and could not find the reveal's Next action at all. 16 of
  18 page loads failed the smoke test. The Go port fought the same class of problem from the other side:
  `html/template` treats `data-on:*` as JavaScript and rewrote `/` as `\/`.
- **`<path>` as a void element breaks the score dial.** Inside `<svg>` the HTML parser is in *foreign
  content*, where no element is void, so `<path ...>` with no closing tag swallows every sibling after it
  and the dial's `<text>` ends up inside the path. A render test caught this one before a browser did.

## Would I build the next one this way

For this app: the datastar version is nicer to reason about and slower to make pretty. The 2× line
count is real but front-loaded — it is mostly CSS and markup written once, against a Panel version
whose reactive glue was harder to follow and impossible to test. Adopting a base stylesheet closes a
quarter of the gap immediately.

The deciding question is not lines of code but **whether an app has state the server owns and the
client must be told about**. This quiz barely does — which is why Panel's websocket and datastar's
SSE end up equally idle, and why the client-interval timer wins. For something with live data, the
push half of datastar would start earning its keep, and the comparison would look different.
