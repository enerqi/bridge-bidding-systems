# datastar-quiz

A [Datastar](https://data-star.dev) + [Litestar](https://litestar.dev) port of the Panel bidding
quiz in `apps/quiz/`, kept beside it so the two architectures can be run side by side.

> **State of play** (2026-08-05, all uncommitted). Complete and working: the quiz loop, the bid-filter
> subsystem with per-keystroke server validation, the topics picker, both `?swedish` and squad variants,
> the completion screen, fat morph + brotli, light and dark palettes with an **auto / light / dark
> toggle in the app bar** (`light-dark()` pairs and one `color-scheme` forcing, no JS and no flash —
> see `DESIGN.md`), and a hand-rolled / Pico / Bulma CSS spike behind `?debug` (Pico is the default;
> the spikes are measured in `DESIGN.md`), plus a
> game-feel layer (`$_juice`: hit-stop and shake on the reveal, score floating off the card you
> picked, an escalating streak chip, press/hover, a ring on the card you got right, a throbbing
> countdown in the last band, a shine across the points gauge when a milestone pays for a skip — one
> toggle, one stylesheet, no JS), on a four-rung elevation ladder and
> a surface ladder that separate the answer cards from what they sit on. **Sound** is a separate
> toggle and the only one that starts OFF (`$_sound`): five WAVs synthesised at import by `sfx.py` and
> served from `/sfx/<name>`, played by `data-init` on a one-shot element — no audio files, no helper
> script, and nothing fetched at all until the box is ticked.
> Two bugs fixed since (COMPARISON.md 15 and 16): a page whose session had been replaced could score
> an answer against a question it had never shown, because question nonces were per session and two
> sessions both started at 1; and the keyboard accelerators go quiet after a click inside the System
> Notes iframe, which puts focus in another document where our `__window` listeners cannot see it.
> **Sessions are now keyed by (browser, variant)**, so `?swedish` parks the squad quiz rather than
> ending it: both keep their score, both can be open at once, and each tab's action URLs say which
> system they belong to. Still one cookie under one name — nginx pins a player to a worker by hashing
> it.
> 619 tests (`just dsquiz test`); `just dsquiz qa` is clean — lint, format **and** typecheck. (The 16
> ty diagnostics an earlier version of this banner admitted to are gone: three were jinja's
> unannotated `Environment.globals`, the other thirteen were `re.search(...).group(1)` in tests,
> which is a type error every time it is written and now goes through `tests/markup.py:found`.)
> A second phone pass fixed the app bar (a wrapped score, and 16px of it
> that belonged to Pico's button margin), corrected `--topbar-h` — which the mobile drawer had been
> hanging 14px behind — and moved the countdown above the question and stuck it to the bar, out from
> under the phone's URL bar (DESIGN.md, "Second pass"). Everything below is described as it actually behaves, not as
> planned — `COMPARISON.md` has the measurements and every bug the port surfaced, `DESIGN.md` the
> UI/UX reasoning and the open list.
>
> Genuinely open, none blocking: verifying the OpenTelemetry path against a live Jaeger; **running it
> on the box** — `just deploy` ships the tree and `DEPLOY.md` walks the takeover of
> `/bridge-system-quiz/` step by step; the app runs there under supervisord and the nginx swap is
> written against the live config; darkening `.ccolor`/`.dcolor`
> in the external `bml.css` so the System Notes iframe matches this app's darker suit colours;
> row-level extras nobody has asked for.
> The two push models (`DSQUIZ_TIMER`) and the two morph modes (`DSQUIZ_MORPH`) both exist on purpose
> — they are the experiment, not leftovers.

Nothing under `apps/quiz/` is modified. `quiz.py` and `bidfilter.py` are panel-free, so this app
imports them as-is (`corpus.py` puts that directory on `sys.path`); the root `pyproject.toml` and
`uv.lock` are untouched too — this is its own uv project.

```shell
just serve         # granian --reload, http://localhost:5008  (panel is on 5006: `just quiz` at the repo root)
just dev           # same + DSQUIZ_DEBUG=1: the debug panel (points, goal, jump to reveal/finale)
just serve-streamed   # same, but DSQUIZ_TIMER=stream: the held-SSE countdown instead of the client interval
just serve-prod    # granian, no reload
just serve-uvicorn # pure-python fallback via the litestar CLI (see the FreeBSD note below)
just serve-deployed   # exactly what the box runs: uvicorn, --no-dev, DSQUIZ_PREFIX + DSQUIZ_DEBUG=0
just deploy        # copy the app + apps/quiz + the bml corpus/tools to X:/quiz-ds/ (DEPLOY.md)
just test
just qa            # format + lint + typecheck; also `just format`, `just lint`, `just typecheck`
just routes
just vendor-datastar   # re-copy static/datastar.js from ~/dev/datastar/bundles/

just measure        # payload sizes + SSE frame pacing, against a running server (--base URL)
```

Env flags: `DSQUIZ_MORPH=fat|fragment` (how much DOM a patch carries), `DSQUIZ_TIMER=client|stream`
(which push model drives the countdown), `DSQUIZ_OTEL=1` (tracing), `DSQUIZ_PORT`,
`DSQUIZ_PREFIX=bridge-system-quiz` (mount the app under a path rather than at the root of a host — it
prefixes the routes *and* every URL the templates emit; see `DEPLOY.md`),
`DSQUIZ_DEBUG=1|0` (the debug panel: `1` arms it for every session — what `just dev` sets — `0`
forbids it outright, and unset lets `?debug` arm it per page load).

**The debug panel** (`just dev`, or `?debug` on the URL) is the panel app's `debug_enabled` idea:
+/−100 points, set the points goal to 200 or 1000, jump to the reveal, jump to the finale. The goal is
*per session* rather than a mutated module constant, and it feeds `engine.answer`, so a 200-point goal
also brings the skip milestones forward — the whole ladder in a minute. `show finale` goes through the
real scoring path (`engine.answer` → `outcome.completed` → the toast chain), because a faked
`completion_wall` would show the screen while skipping everything that produces it. Since the routes
can rewrite the score, **set `DSQUIZ_DEBUG=0` on anything public** — `?debug` is a URL anyone can type.

With `DSQUIZ_DEBUG=1` the app also answers `/.well-known/appspecific/com.chrome.devtools.json`, which
Chrome probes on every page load with devtools open (and repeatedly in device-simulation mode). That
turns a stream of 404 tracebacks into a feature: devtools offers to connect the page to this folder, so
edits made in the Styles panel are written back to `static/*.css` instead of being lost on reload. It is
debug-only because the payload is an absolute filesystem path. Unrelated 404s (a missing source map, a
favicon probe) are now answered as plain 404s rather than logged with a stack trace.

`qa` is astral ruff (format + lint) and astral ty, with the `[tool.ruff]` block taken from
`~/dev/gc-pyproject` — refresh it with `uv run gc-ruff-sync` from a checkout that has
`GITLAB_TOKEN` set. Two local additions: `INP001` is ignored because these are deliberately flat
modules rather than a package, and `[tool.ty.environment] extra-paths = ["../quiz"]` tells ty about
the `sys.path` shim `corpus.py` performs at runtime.

Note that `target-version = "py314"` means ruff rewrites `except (A, B):` to PEP 758's
`except A, B:` — valid on 3.14 only, which is what `requires-python` pins.

Dependencies are major-version pinned (`==2.*`) once past 1.0, `>=` for 0.x. **granian** is the
server locally (`--reload` from the `granian[reload]` extra, dev-only), but it is an *extra* rather
than a dependency, and **uvicorn** — the slower, pure-python one — is the dependency. That inversion
is deliberate: granian ships no FreeBSD wheels (manylinux / musllinux / macos / win_amd64 only), so
naming it a dependency would make `uv sync` on the deployment box build it from the sdist with a rust
toolchain. This way the box runs a flagless `uv sync --no-dev`, and locally the dev group pulls
granian in anyway, so `just serve` and `just serve-uvicorn` both work straight out of `uv sync`.

From the repo root, add `mod dsquiz 'apps/datastar-quiz'` to the justfile for `just dsquiz serve`.

## What the experiment is about

Panel is a stateful server **plus** a stateful client: a Bokeh document of widget models synced
over a websocket, with the server reaching into client state (`button.disabled`,
`skip_button.disabled`, `open_modal()`). Datastar keeps one model — the server's — and ships HTML
views of it. So the point of the port is not moving state to the server; it is **deleting the
client model**.

Datastar's own guidance (`data-star.dev/guide/the_tao_of_datastar`):

> Most state should live in the backend. Since the frontend is exposed to the user, the backend
> should be the source of truth for your application state.

> A good rule of thumb is to _only_ use signals for user interactions (e.g. toggling element
> visibility) and for sending new state to the backend (e.g. by binding signals to form input
> elements).

## Where state lives

| Where | What | Why |
|---|---|---|
| Server (`state.Session`, keyed by `(dsq_sid cookie, variant)`) | current `Question` incl. `answer_candidate`, a process-unique `qid` nonce, score/streak/points/milestones, skips, timers, applied filter + its working set | signals are readable in devtools **and** uploaded with every request, so an answer in a signal is a cheat code; the working set is a slice of the per-process `.bml` corpus and cannot travel |
| Client, bound signals (uploaded) | `$difficulty`, `$ladderMode`, `$targetOn`, `$targetPct`, `$filterText`, `$topics.*` | these *originate* in the browser: `data-bind` is datastar's form encoding. `$filterText` is the uncommitted draft — Panel's `value_input` vs `value` split, now server vs client |
| Client, local signals (`_` prefix, never uploaded) | `$_topicsOpen`, `$_answering`, `$_timeLeftPct`, the appearance preferences `$_theme` / `$_font` / `$_css` / `$_juice` / `$_sound`, plus server-owned display values `$_points`, `$_scorePct`, … | view toggles, request lifecycle, and numbers the server already told the browser (echoing them back would be waste). `$_sound` also gates a *fetch*: the `<audio>` elements get their `src` from it, so sound off costs nothing at all |

Sessions are process-local, so one worker (or sticky routing) — the same constraint Panel had
(see the `session_key_func` notes at `apps/quiz/quiz_app.py:49`). The escape hatch is Redis, not
signals. The cookie identifies the **browser** and the variant is the other half of the key, so one
player can have both systems going at once; the variant comes from the page's own action URLs rather
than from the cookie, because a cookie cannot tell two tabs apart. Because the session identity is
*our own cookie*, affinity can be done properly
(`hash $cookie_dsq_sid consistent` in nginx) rather than by client IP, which is what Panel is stuck
with; `DEPLOY.md` covers both, and what a shared store would remove.

## How the pieces map

| Panel | here |
|---|---|
| `param.rx(question)` + view functions mutating cached widgets | `#quiz` element patch |
| `pn.state.notifications.*` + `await asyncio.sleep(...)` chain | one long SSE response from `POST /answer`, same sleeps, `#toasts` patched per beat |
| `with hold(): button.disabled = True` + "clicks too quickly" guard | `data-indicator` + `data-attr:disabled` for the visual, `qid` nonce server-side for correctness (a reload cannot defeat it) |
| `TimeBonus` 100ms periodic callback | `data-on-interval` walks `$_timeLeftPct` down locally *while `$_ticking`* — a live, unanswered question — so the bar freezes when the answer lands instead of draining behind the reveal; the bonus that scores is recomputed from `question_start` server-side |
| `Dial` / `LinearGauge` | hand-built SVG arc + a bar with milestone ticks, driven by signals |
| `AutocompleteInput` + `value_input` watcher | `data-bind` + debounced `@get('/filter/preview')`; validation never leaves `bidfilter` |
| `template.open_modal()` | `<dialog data-attr:open="$_topicsOpen">` — no round trip for opening a panel |
| `pn.Card(collapsed=True)` | `<details>` + `data-preserve-attr="open"` |
| the sidebar holding score + Skip + settings together | three zones by *when you touch them*: a HUD in the app bar (score, points gauge, streak, **Skip** and `s`), the play area, and a drawer that starts **closed** and holds only what restarts the quiz. The score used to be rendered twice and spending a skip meant opening the settings drawer |
| `MaterialTemplate` | hand-written CSS — the cost side of the trade, 629 code lines. Pico classless plus an adapter does it in 564, Bulma plus an adapter in 536 *and* 28 class tokens in the templates. **Pico is the default**; switching between all three live is a debug-session control now, because the difference is invisible to a player |
| Bokeh diffing its document model | fat morph: send `#app` whole and let the morph work out the difference, brotli making the bytes a non-issue |
| `session_key_func` per variant | the same idea, spelled out: the store is keyed by **(browser, variant)**, the cookie carries the browser and each page's action URLs carry its variant (`render.variant_query`). So the two systems coexist, and a squad tab left open cannot answer into the swedish quiz. It began as "the query *replaces* the session", which is what made a background tab dangerous — COMPARISON.md 15 |
| `add_periodic_callback` pushing the timer | either push model: client interval (default) or a held SSE stream via `DSQUIZ_TIMER=stream`. Measured side by side in `COMPARISON.md` |

Interactions patch **`#app` — the whole page below `<body>`** ("fat morph", as the Tao advises), plus
the server-owned signals. `DSQUIZ_MORPH=fragment` restores the original `#quiz`-only patching for
comparison. Responses are brotli-compressed, **including the SSE streams**, which is what makes a
whole-page patch cheap: 23KB raw becomes 4.1KB on the wire, and the stream still arrives frame by
frame. Numbers and the flushing proof are in `COMPARISON.md`; re-measure with `just measure`.

## Presentation

`COMPARISON.md` holds the measured Panel-vs-datastar findings: line counts, wire sizes, the two
push models side by side, and every bug the port surfaced with what they had in common.

`DESIGN.md` holds the UI/UX and styling thinking: what visual language fits, why the answer choices
are the wrong component, what replacing panel's widgets actually cost, the CSS-framework options and
where datastar's own Stellar CSS fits — plus the open action list (some of it real bugs).

`DEPLOY.md` holds the nginx + supervisord configuration for both this app and the panel one, the
session-affinity story (`ip_hash` for panel, `hash $cookie_dsq_sid` for this one), what survives a
restart and what does not, and how to stop needing affinity at all. Untested in production.

`CSS_GUIDE.md` is the tutorial underneath that: what classless / class-based / utility / token-only CSS
actually mean, what a "token" is, what *"tokens for the design system, element/attribute selectors for
the components"* means in practice, why that shape suits datastar, and how CSS specificity makes an
edit silently do nothing. Written for someone who does not write CSS all day; read it before
`DESIGN.md`'s framework sections if those read as jargon.

**Suit colours use bml's class names, with darker values.** `render.suits` (a jinja filter) wraps
each glyph in `.ccolor` / `.dcolor` / `.hcolor` / `.scolor`, as `bml2html` emits — but the values are
darkened (`--suit-*` in `app.css`), because bml's MediumSeaGreen and Orange measure 2.6:1 and 1.9:1
on a near-white card face and fail even large-text AA. All four now clear 4.5:1, computed by
`tests/test_suit_colours.py`. `bml.css` itself is unchanged, so the System Notes iframe still shows
the lighter originals — the two have deliberately diverged.

Getting there needed the glyphs to *stop* being emoji. The panel app wrote
`heart_emoji_black = "♥️"` with the U+FE0F variation selector, which requests emoji presentation:
hearts and diamonds were drawn by the colour emoji font while spades and clubs stayed text glyphs
and inherited the element's `color` — a white spade on the dark card. An emoji glyph also ignores
`color`, so no stylesheet could have coloured all four. The glyphs here are plain
(`♠ ♥ ♦ ♣`), with `font-variant-emoji: text` to keep them that way, and the quote box and answer
buttons are a pale card face so black spades and green clubs read against it.

**Fonts** default to `'Open Sans'` (what `bml.css` sets) falling back to Segoe UI, and the sidebar
has a picker: `$_font` → `data-attr:data-font` on the body → `--ui-font` per `body[data-font=…]`.
Local signal, so switching costs no request.

**App bar** carries the nav toggle and a live score. Collapsing the sidebar is
`$_navOpen` → `data-class="{'nav-closed': !$_navOpen}"` — the useful half of what panel's
MaterialTemplate gave, in two lines and no round trip. Palette is one hue family
(`--primary` / `--card` / `--side` / `--face`) rather than panel's green-card-on-lightblue.

## Gotchas found the hard way

Each of these was a real bug in this app first, and each has a test pinning it. `COMPARISON.md` lists
all ten found during the port and what they had in common; these four are the datastar-specific ones:

1. **Attribute keys are lowercased by the HTML parser.** `data-bind:filterText` binds
   `filtertext` — a *second* signal — while the server keeps writing `filterText`. Datastar's
   convention is kebab-case keys, converted with `camel` (`library/src/utils/text.ts`). So
   `data-bind:filter-text`.
2. **`kebab` also splits letter/digit boundaries.** A topic slug `1c_opening` becomes the signal
   `1COpening`, so the server has to compute the key rather than assume it
   (`render.topic_signal_key`).
3. **A leading underscore cannot survive an attribute key** (`_answering` → `Answering`), which
   silently promotes a local signal to an uploaded one. Underscore signals must use the value
   form: `data-indicator="_answering"`, and be declared in the `data-signals` object.
4. **An undeclared signal reads as `''`, and `data-attr` treats `''` as "set the attribute"**
   (`plugins/attributes/attr.ts`). An undeclared `$_topicsOpen` therefore left `<dialog open>`
   — the picker was stuck open. Hence `render.local_ui_signals()`.

Two more worth knowing: `read_signals` returns `None` unless the request carries the
`Datastar-Request` header (real datastar fetches always do; test clients must add it), and
first-paint values must be server-rendered into `value` / `checked` attributes — otherwise the
browser's own default (a range input's midpoint, an unchecked box) is what the binding uploads.

## Layout

```
app.py        routes; every handler mutates the session then streams the patches
state.py      msgspec session structs + the cookie-keyed store
engine.py     rules only: points, toasts, milestones, completion (no HTTP, no HTML)
corpus.py     imports apps/quiz's quiz.py + bidfilter.py; caching and filter checks
render.py     jinja env, fragments, signal payloads, datastar naming helpers
sfx.py        the five sound effects, synthesised at import (no audio files); GET /sfx/<name>
templates/    shell + the patchable fragments
static/       vendored datastar.js (no CDN) + app.css, juice.css (the game-feel layer),
              and the two framework spikes:
              app-pico.css / pico.classless.min.css, app-bulma.css / bulma.min.css
telemetry.py  optional OTel, env-gated (DSQUIZ_OTEL)
tests/        rules parity with the panel source, routes/SSE, signal naming, import isolation
```

`engine.points` is asserted against Panel's own `points` — lifted out of `quiz_app.py`'s AST so
the comparison is against the running code without importing panel (`tests/test_engine.py`).

## Not done

The held-SSE timer variant (one long-lived connection pushing the countdown, instead of the local
interval) is the phase-3 comparison and is not built. OTel is wired but only smoke-checked.
