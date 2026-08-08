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

Four patterns, worth carrying forward:

- **The thing being sized was not the thing being measured** (5, 6).
- **One gesture must not drive two handlers** (7, 8) — and note 7's deeper lesson: with
  mutate-then-stream, an aborted request still leaves the mutation applied.
- **Naming conventions are load-bearing** (1, 2, 3, 4). Datastar's attribute-key casing and the
  underscore-means-local rule are silent when violated: no error, just state that stops agreeing.
- **The nearest existing signal is not the right condition** (13, 14). `$_playing` for "is this
  question live", `evt.target.tagName` for "is the user typing" — both are *almost* the predicate you
  want, both are wrong in exactly the states that are hard to notice, and neither fails loudly.

## Would I build the next one this way

For this app: the datastar version is nicer to reason about and slower to make pretty. The 2× line
count is real but front-loaded — it is mostly CSS and markup written once, against a Panel version
whose reactive glue was harder to follow and impossible to test. Adopting a base stylesheet closes a
quarter of the gap immediately.

The deciding question is not lines of code but **whether an app has state the server owns and the
client must be told about**. This quiz barely does — which is why Panel's websocket and datastar's
SSE end up equally idle, and why the client-interval timer wins. For something with live data, the
push half of datastar would start earning its keep, and the comparison would look different.
