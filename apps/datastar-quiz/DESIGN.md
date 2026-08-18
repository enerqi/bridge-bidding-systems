# UI, components and styling

Notes on how this app should look and why, what replacing panel's widgets actually cost, and where
a CSS framework — including datastar's own Stellar — would fit. Companion to `README.md`, which
covers the architecture.

## Datastar has no styling opinion

Zero CSS ships with datastar, and there is not one reference to tailwind / bootstrap / bulma / pico
anywhere in the `~/dev/datastar` checkout. It is a behaviour layer over `data-*` attributes. The
choice is ours — but two of its mechanics constrain it.

**1. Shadow DOM is a hard no.** `patch_elements` morphs the light DOM and cannot reach inside a
shadow root. This is the same wall the panel app hit from the other side: see the comment at
`apps/quiz/quiz_app.py:746` — `css_classes` + `raw_css` don't pass "through shadow dom used by
material template", so each button needed its own `stylesheets=[…]` override. A web-component
library (Material Web, Shoelace / Web Awesome) puts us back there: styling through `::part` and
custom properties, and no patching into component internals.

**2. Datastar already owns behaviour.** A framework whose components are JavaScript duplicates that
layer and fights the morph. Datastar provides `data-ignore-morph`, `data-preserve-attr` and
`data-ignore` (see `library/src/plugins/watchers/patchElements.ts`, `library/src/engine/engine.ts`)
precisely to babysit DOM that something else mutates — anything that adds classes, moves nodes to
`<body>` or injects wrappers after render will need that babysitting. Classless CSS mutates nothing.

A quieter third factor: fragments travel over SSE on **every** interaction, so class vocabulary is
payload. Not decisive at this size, but utility-class CSS makes every patch bigger.

## Visual language

The domain is literally playing cards, which suggests a split rather than a single style:

- **Chrome flat / material.** App bar, drawer, controls, elevation-as-shadow. Conventional, cheap,
  accessible, stays out of the way.
- **Skeuomorphism only where the domain is cards.** The prompt and the answer choices are the one
  place a card face (parchment, subtle inner border, lift on hover) earns its keep — it reinforces
  "these are calls at a bridge table". That is what `--face` is for.

Full skeuomorphism (felt, wood, embossing) fights the thing that matters most here: **the four suit
colours are fixed by the domain**, so every surface behind them must be near-neutral. That was the
argument against the original seagreen quiz card — decorative, and the only surface that made suit
colours hard to read. It is now white with a green top rule: green lives on the app bar and as an
accent, and the suits are the only saturated colour on screen.

## The answer choices — buttons, but sized and keyed properly

First instinct was that these should be a radio group (`role="radiogroup"`, arrow traversal). On
reflection that is wrong: a radiogroup implies *staged* selection with a separate submit, and here a
click commits immediately and irreversibly. Immediate-commit choices are buttons. What they were
missing was not different roles but three concrete things — two of them defects:

1. **The targets moved between questions.** `flex-wrap` + `space-evenly` sized buttons by text
   length, so the button under the cursor was somewhere else next question. The time bonus rewards
   answering fast, so this cost mis-clicks. **Fixed**: a grid of equal columns
   (`repeat(auto-fit, minmax(16rem, 1fr))`) — position now depends only on how many choices exist.
2. **No keyboard path.** **Fixed**: digits 1–9 as accelerators, shown as a `<kbd>` badge on each
   button so they are discoverable — one `data-on:keydown__window` on the choice group, mapping the
   digit to an index, guarded against firing into a focused form control or while an answer is
   already in flight. Both guards were subtly wrong at first; see *Double-bound activation* and the
   two entries after it, below.
3. **No group semantics.** **Fixed**: `role="group"` with a label — honest for a set of buttons,
   where `radiogroup` would have lied about the interaction.

## Layout convention

The sidebar is not navigation, it is settings, and the convention for settings is a **utility
drawer** opened deliberately — which is why the hamburger reads oddly: it looks like nav and reveals
config. The score is now persistent in the app bar, so the drawer can default closed. The main
column should also be capped at a comfortable measure; long auctions at 2rem stretched across a
1900px monitor are worse to scan, not better.

## Contrast: a measured problem

bml's suit colours are right for bml's context (antiquewhite page, body text size) but not for a
near-white card face. Computed WCAG contrast on `--face`, before and after darkening:

| glyph | bml value | on `--face` | now | on `--face` |
|---|---|---|---|---|
| ♦ | Orange `#FFA500` | 1.92:1 ✗ | `--suit-diamond` `#b35300` | 4.92:1 ✓ |
| ♣ | MediumSeaGreen `#3CB371` | 2.59:1 ✗ | `--suit-club` `#1e7a45` | 5.21:1 ✓ |
| ♥ | Red `#FF0000` | 3.89:1 (large only) | `--suit-heart` `#cc0000` | 5.73:1 ✓ |
| ♠ | Black | 20.44:1 ✓ | `--suit-spade` black | 20.44:1 ✓ |

All four now clear 4.5:1 — AA for normal text, not just the 3:1 large-text threshold, which matters
because the filter status line renders these small. `tests/test_suit_colours.py` computes the ratios
rather than matching colour names, so the invariant survives a repalette.

The class NAMES are still bml's (`.ccolor` / `.dcolor` / `.hcolor` / `.scolor`), so `bml2html`'s
markup and this CSS agree — but the VALUES have deliberately diverged: **`bml.css` is unchanged**, so
the system notes iframe still shows the lighter originals. Darkening those too would be a change in
the bml repo, and would bring the two back into step.

## Replacing panel's widgets: what it cost

| panel component | replicating it |
|---|---|
| Button, Checkbox, IntSlider, Progress | trivial — native elements are lighter and better |
| Card (collapsed) | trivial — `<details>`, plus `data-preserve-attr` so morphs keep it open |
| Modal | trivial — native `<dialog>` |
| MaterialTemplate | easy but bulky: ~500 lines of CSS. Volume, not difficulty |
| Notifications | easy to draw, **fiddly to choreograph** (below) |
| Dial | moderate — SVG arc with `stroke-dasharray` / `dashoffset` and colour bands, ~20 lines |
| LinearGauge with milestones | moderate — bar plus absolutely-positioned ticks |
| AutocompleteInput | **the only real loss.** `<datalist>` gives the dropdown free, but not `search_strategy="includes"`, not styled/highlighted matches, and not "type a prefix, press Enter, resolve to the full topic name" — that resolution moved server-side |
| `description=` tooltips | not replicated. Panel renders markdown in a hover tooltip; substituted a `<details>` "Filter syntax". Native `title=` is too weak; the Popover API is the modern answer |

So the widgets were mostly basic — HTML has had them for decades. **The hard parts were the things
that don't look like components:**

- **Notification choreography.** Panel queues stacked toasts with independent durations; here one
  shows at a time because the sequencing lives in the SSE stream. Matching panel exactly needs a
  client-side queue with per-toast timers — real client state, which is what this architecture is
  trying to avoid.
- **Input semantics.** `value` vs `value_throttled` looks like a detail until the failure shows up:
  `data-on:change` on a range input fires per keypress with arrow keys, and every change **restarts
  the quiz** — keyboard use destroyed your score. **Fixed** with `__debounce.400ms`; four rapid
  presses now produce one request. A bug, not a preference.
- **Motion.** **Fixed**: `prefers-reduced-motion: reduce` now collapses every transition and
  animation — the 100ms timer bar, the dial sweep, the toast pop and the sidebar collapse.
- **Blocking feedback.** The 4.2s centre-screen answer reveal was panel's default made literal.
  **Fixed**: a wrong answer now parks on an inline reveal (`reveal.html.j2`) — the prompt stays, the
  right answer is ticked, your choice is crossed, and `POST /next` advances when you are ready. The
  next question's clock starts when it is served, so reading the reveal costs no bonus. Toasts also
  moved out of the centre to the bottom-right corner, so they no longer cover what they comment on.
- **Gradients on growing elements rescale.** The points bar painted its red-to-green gradient on the
  *fill*, whose width is the score — so the whole ramp was squeezed into whatever had been earned and
  100/1000 points looked as green as 1000/1000. A gradient that encodes a value has to live on the
  fixed-size track, with the unearned remainder masked from the right. Same class of mistake as the
  nav-collapse bug: the thing being sized was not the thing being measured.
- **Double-bound activation.** A trap worth recording: the reveal's Next button had both
  `data-on:click` and an Enter-handling `data-on:keydown__window`. A focused button activates on
  Enter natively, so both fired — and the second request *superseded and aborted the first after the
  server had already advanced the question*, leaving the browser on a stale reveal. Window keydown
  handlers acting on Enter/Space must exclude `BUTTON` targets; pinned by a test. The general lesson
  is that "mutate then stream" means an aborted request still leaves the mutation applied.
- **A countdown that outlived its question.** The timer bar kept draining after an answer was
  scored — down to empty behind the revealed answer, and through the two or three seconds of toasts
  on a correct one. The interval gated on `$_playing`, which is only false when the whole *quiz*
  ends; the condition it actually wanted was "a live, unanswered question is being timed". That is
  now `_ticking` (`session.on_the_clock`) on the server, with `$_answering` covering the window
  between the keypress and the patch that ends it, and the interval **assigns only while ticking** so
  the bar freezes at the value the bonus was scored from rather than resetting. The server had the
  matching bug: `percent_time_left()` kept counting against `question_start`, so a reload while parked
  on the reveal reported *less* time than the answer was actually scored with — it is frozen at the
  moment of scoring (`freeze_question_clock`), and the held-SSE mode stops pushing there too, because
  the two push models must agree about when the bar is stopped or the mode becomes visible to the
  player.
- **A shortcut that works in the happy path and dies in a state nobody tried.** The digit
  accelerators (1-9 answer) appeared broken. They were not: they went inert in two states, and
  neither logged anything. **(a)** The guard excluded form controls by `evt.target.tagName`, which
  only sees the element the event fired on — and a `<select>` keeps focus once clicked, so choosing a
  font or a stylesheet silently disabled every accelerator for the rest of the session. Now
  `closest('input, select, textarea, [contenteditable]')` (which also covers a control inside a
  wrapper, e.g. Bulma's `<div class="select">`), and both appearance pickers `blur()` on change — the
  slider and the filter box deliberately do not, because you keep arrowing and typing in those.
  **(b)** `!$_answering` blocks the keys for the whole answer stream, which is 2.5-3.5s of toast
  pauses on a correct answer. That one **stays**: the server mutates before it streams, so once the
  toasts are playing the *next* question is already live, and a keypress accepted there would answer
  a question the player has not been shown. `aria-busy` on the group now says so out loud.
  Rewritten as ONE handler on the group mapping digit → index, rather than five identical
  `__window` listeners (five registrations and five teardowns per patch, five copies of the guard).
  **(c)** …and "exclude form controls" turned out to be the *next* version of the same bug. It
  excluded **any** control, including the ones with no claim on the key: nudge the difficulty slider
  — a range input keeps focus by design, or you could not arrow it — and 1-9 were dead for the rest
  of the session again, same silent failure, different control. The exclusion is now two named lists
  in `render.py`, so three templates cannot drift: `TYPING_TARGETS` (text inputs, `select`,
  `textarea`, `contenteditable`) for the digits and `s`, and `ACTIVATION_TARGETS` for the reveal's
  Enter/Space, which additionally keeps checkboxes and radios because **Space activates them** —
  otherwise one keystroke both ticks a box and advances the question. The general rule, third time
  of asking: a control swallows a keystroke when it has a *use* for that key, not because it is a
  control. (Rendered via jinja globals, and a test asserts they resolve: an out-of-scope global
  renders as the empty string, and `closest('')` throws — which swallows every keystroke instead.)
- **…and the last two were not the app at all.** Same report — "the digit shortcuts randomly stop
  working, the mouse still works, a reload does not bring them back" — and two more causes, neither
  of which any guard in this codebase can see, because in both the keydown never reaches our
  document:
  **(d) the System Notes `<iframe>`.** Click inside it to scroll or follow a link and focus moves to
  another (cross-origin) document, while every accelerator here is a `__window` listener on ours. The
  mouse is unaffected because a click is delivered by position, not by focus. Reproduced in Firefox
  and Chrome; fixed by taking focus back when the pointer returns to the question card, and only from
  an iframe, so a half-typed filter box is left alone.
  **(e) a browser extension, and the likeliest one is Vimium.** It binds **1-9 as count prefixes**
  (`3j` scrolls three lines), so it swallows exactly the digits, leaves the mouse alone, and keeps
  doing it across reloads — the whole symptom. It is invisible from the page: no event arrives, so
  there is nothing to log and no state to inspect. Confirmed the way these things have to be, by
  elimination: a private window (no extensions) plays fine.
  There is nothing to fix here and nothing worth building — a hidden focus trap that put the page in
  Vimium's "insert mode" would fight our own typing guards for the sake of one extension. The fix is
  the extension's own exclusion list (Vimium options → *Excluded URLs and keys* → the quiz's URL, keys
  blank for all of them). Worth knowing because it looks exactly like (a)-(d) and is not.
- **`data-indicator` is per requesting element.** Moving that handler off the buttons took the
  in-flight flag with it: the buttons kept `data-indicator="_answering"`, the group had none, so a
  *keyboard* answer set the signal for nobody — choices never greyed out and the guard above could
  never be true, which put the double-answer window straight back. Whatever element starts the
  request needs its own indicator.
- **A hyphenated `data-attr` key never reaches the DOM.** `data-attr:aria-busy` is kebab-then-camel
  converted to `ariaBusy`, and nothing appears — no attribute, no error. The object form
  (`data-attr="{'aria-busy': …}"`) keeps the literal name. Same family as the `data-bind:filterText`
  trap, and the fourth time this project has been bitten by attribute-key conversion. Values matter
  too: a boolean `true` renders `aria-busy=""`, and an empty string is not a valid ARIA state, so
  enumerated ARIA attributes are stated as `'true'` / `'false'` strings.

## The flat-card problem, and why no colour fixes it

The answer cards were **1.03:1** against the surface they sat on, and the quiz card 1.08:1 against the
page — three surfaces inside the top 8% of the luminance range. They read as paint rather than as
things you press, and hunting for a better card colour is a dead end for two measurable reasons:

- **`--face` is pinned by the domain.** The four suit colours are contrast-tested against it (all
  ≥4.9:1, `tests/test_suit_colours.py`); darkening the face puts clubs and diamonds under AA.
- **Contrast up there is gamma-compressed.** A fill has to fall to ~`#dde7e2` before it reaches even
  1.23:1 against the face — by which point it is not white paper any more. There is no value that is
  both "still looks like a card" and "visibly different".

So separation comes from two places that are *not* the card's fill:

1. **A recessed well.** `.candidates` is a tinted, inset-shadowed panel, so the near-white cards are
   raised out of something. Ladder: page → card → well → face, each step 1.1-1.24:1. It also groups
   the five choices as a unit, which is what the shake and the ring flash now animate against.
2. **A 3:1 boundary on the cards** (`--card-edge`, 3.17:1 light / 3.52:1 dark). This is what WCAG 2.2
   SC 1.4.11 asks of a non-text control boundary, and unlike a fill difference it survives a cheap
   monitor, sunlight and colour-vision differences. **A border is the accessible answer to "these two
   surfaces look the same"** — fill contrast at these luminances cannot get there at all.

Dark mode had the same flatness (three surfaces within 0.8 percentage points) and gets the ladder
**inverted**, which is the convention there: deep page, lighter card, well darker again, face the
lightest thing on screen. `--face` is unchanged in both palettes, on purpose.

All of it is pinned by `tests/test_surfaces.py`, across all three stylesheets and both palettes,
including a test named for the temptation it exists to block: *the face did not move to fix this*.

Found while looking at the result: Bulma's `.tag is-light` in its dark theme is a light chip with
light text, so the digit accelerators were white circles with an invisible number. Fixed in the
adapter. It had been there all along — the new card surfaces are what made it visible.

## Elevation and shadow: one sun, or none

A shadow is a claim about a light source. Once two elements on the same page make *different* claims,
the depth stops reading as depth and starts reading as decoration — which is where this app was.
Audited 2026-08-06, Pico variant, light palette, computed values off the live page, **before** the
ladder below:

| element | computed `box-shadow` |
|---|---|
| `.sidebar .panel` | `0 8px 16px -2px rgb(0 0 0 / 10%)`, `0 0 0 1px rgb(0 0 0 / 2%)` |
| `#quiz` (the main card) | **identical to the panel** |
| `.candidates` (the well) | `inset 0 2px 6px rgb(0 0 0 / 10%)` |
| `.candidate` (an answer card) | **none** (the hand-rolled sheet gives it `0 2px 6px rgb(0 0 0 / 25%)`) |
| `.topbar` | **none** (hand-rolled: `0 2px 8px rgb(0 0 0 / 25%)`) |
| `.main > .notes` | Pico's own: six stacked layers, x-offset up to 8px, tinted `rgb(129 145 181 / …)` |
| `.timer` | none |

Two things fall out of that, and only one of them is a bug.

**The side panels and the main card are not inconsistent — they share `--panel-shadow`.** What differs
is how much of it you can see. With `y = 8px`, `blur = 16px`, `spread = -2px`, the shadow reaches about
**14px below** the box and about **6px to each side**: correct for an overhead light, and the reason
the panels look like they only cast downward. On a 290px sidebar panel those 6px are a sliver; on the
964px quiz card the same 6px runs along four times as much perimeter and reads as a halo. *Bigger
objects sell the same shadow better* — worth knowing before "fixing" a shadow that is already shared.

**The real defects are elsewhere:**

1. **Two light directions.** Ours cast straight down in neutral grey; Pico's `.notes` casts
   down-and-**right** in blue-grey. One page, two suns, two shadow hues. Every other framework surface
   in this app is overridden in the adapter; this one was not.
2. **No elevation ladder.** Alphas across the app run 10% → 12% → 22% → 25% → 30% → 35% → 45%, offsets
   0-10px, and the mobile drawer is `0 0 40px` — *offsetless*, i.e. lit from nowhere. Each value was
   chosen locally and is defensible alone; together they encode no order of depth.
3. **The answer cards are flat in the Pico variant.** The one surface the player actually presses has
   no lift, while `juice.css` animates a hover lift and a press shadow — starting from nothing.

**What shipped:** one light, overhead, and a four-rung ladder in all three sheets. Every rung is
`x = 0` and `blur = 2 × offset`, and each is a *direct* cast plus a tighter *ambient* one at half the
offset (contact occlusion — the thing that makes an object look like it is touching a surface rather
than hovering over it). The cast takes the ink's hue (`--shadow-rgb: 18 33 26`) rather than pure
black, because a neutral-black shadow over a tinted page reads as dirt.

| rung | what is on it |
|---|---|
| `--elev-inset` | the choice well (`.candidates`) — recessed, not raised |
| `--elev-1` | things resting on a surface: **the answer cards**, the two disclosures, a pressed card |
| `--elev-2` | the panels, the quiz card, the app bar |
| `--elev-3` | what floats above them: toasts, and a card lifted under the cursor |
| `--elev-4` | what covers them: the topics dialog, the mobile drawer |

Consequences worth naming: the answer cards now have a **resting** shadow in every variant (they were
flat in Pico and Bulma while `juice.css` animated a lift and a press *from nothing*); the drawer is lit
from above like everything else instead of `0 0 40px`; and Pico's `.notes` shadow is overridden like
every other framework surface, so nothing is lit from the left any more. The hover lift and the press
are rungs too — hover is rung 3, press drops back to rung 1, so with a mouse the press is a visible
fall and on a touch screen (no hover to fall from) the transform carries it.

Dark is a different problem, not a darker version of the same one: a cast shadow barely registers on a
dark ground, so elevation there is carried by **lightening the surface** (the inverted ladder above)
and the ladder mostly holds an edge — the alphas roughly double and rung 1's hairline flips from a dark
ring to a light one. The geometry is identical in both palettes, so nothing changes rung when the
scheme flips.

`tests/test_elevation_and_type.py` pins the ladder (both palettes, all three sheets: one light source,
blur = 2× offset, rungs that climb, dark casting harder than light) and — the part that matters for
keeping it — **the discipline**: any `box-shadow` that reads as depth must name a rung. Rings, insets
and coloured glows are exempt, because none of them is an object above a surface.

## A theme switch, and why the media query had to go

The app had a full dark palette and no way to ask for it. It lived in
`@media (prefers-color-scheme: dark)`, which answers to the OS and to nothing else — and *a media
query cannot be overridden*. The only way to bolt a manual switch onto one is to write the whole
palette a second time under a class or an attribute and then keep two copies in step forever, which
is precisely the duplication that lets a palette drift.

So both palettes moved into **`light-dark()` pairs** on the same declaration:

```css
:root { color-scheme: light dark; --face: light-dark(#fdfcf7, #1d2724); }
:root[data-theme="dark"]  { color-scheme: only dark; }
:root[data-theme="light"] { color-scheme: only light; }
```

`light-dark()` resolves against the element's **computed `color-scheme`**, so forcing a palette is
one declaration rather than a second copy of forty. Three things follow from that, and they are the
reasons to prefer it over a `.dark` class:

- **The browser's own surfaces move too** — canvas, scrollbars, form controls, `<dialog>`. A class
  cannot do that; it is also exactly the black-rim bug from earlier in this file, arriving from the
  other direction.
- **`auto` is a real third state, not a synonym for light.** It is the absence of `data-theme`, which
  leaves `color-scheme: light dark` in charge — the OS's answer, following it when the machine
  switches at sunset, and correct on the first paint with **no JavaScript**. Every "flash of the
  wrong theme" is a page that resolves this in a script instead.
- **Pico and Bulma read the same `data-theme` attribute natively**, so their own dark themes follow
  the toggle without being told about it.

Three details that cost a debugging round each:

1. **`data-theme` goes on `<html>`, not `<body>`.** The canvas takes its scheme from the root, and
   the Pico adapter paints `html` from `--pico-background-color` — with the attribute one level down,
   the page *behind* the app kept the OS palette while everything inside it switched. (`:root:has(body[data-theme])`
   also works and was the first attempt; the root is simply where the attribute belongs, and it is
   where both frameworks document it.)
2. **`only dark`, not `dark`.** A bare `color-scheme: dark` still permits the UA to pick light for a
   light-only widget; `only` is the forcing.
3. **The signal is `false` when auto**, not `''`. Datastar removes an attribute set to false; an
   empty string *sets* `data-theme=""`, which matches neither forcing but reads as "themed" to Pico.

The control is one button — **auto → light → dark**, cycling, `◐ / ☀ / ☾`, with the state in its
`aria-label` because the glyph alone is a rebus. It is never disabled: unlike Skip, changing the
palette is not a move in the game, so it works mid-answer too.

**Where it goes took two tries, and the second one is the rule this file already had.** It shipped
next to Skip, which is wrong twice over: this app sorts controls by *when you touch them*, and the
right-hand cluster is live game state plus the one in-play action — a preference does not belong in
it — and Skip is the one control that *spends* something, so a mis-tap there costs a skip. The app
bar is two clusters split by `.topbar-spacer`: **chrome on the left** (hamburger, title), **game on
the right** (score, gauge, streak, Skip). The toggle is chrome, so it sits with the hamburger, 763px
from Skip at 1200px wide. Not in the drawer either, though — that is the third option and it fails
the actual requirement: the drawer starts closed, and "this is too bright *right now*" is fixed the
moment it is noticed, not two taps later.

**Remembered, in a cookie rather than in `localStorage`** — two reasons, and the second is the one
that is easy to get wrong:

- **First paint.** A cookie is *on the request*, so the server renders `data-theme` into the document
  and the remembered palette is correct in the first frame. `localStorage` can only be read after JS
  runs: one frame of the OS palette on every load for anyone who chose against it. Reading it in a
  blocking `<head>` script is the fix everyone reaches for, and it is exactly the `<script>` this app
  has a test against.
- **Scope.** `localStorage` is keyed by **origin** — scheme + host + *port* — so `localhost:5006` and
  `localhost:5008` are separate stores, as are `localhost` and `127.0.0.1`. Cookies are keyed by host
  and **path** and *ignore the port*, so one choice covers every instance on the machine, and a
  prefixed deployment is separated by its path (the same scoping the session cookie already uses).

The browser writes it (`document.cookie` in the toggle's own expression, a year, `SameSite=Lax`,
path-scoped) and the server only reads it back — no round trip, no new route, and the server still
has no opinion about the palette. `render.theme_from` treats the cookie as what it is, user input:
anything that is not one of the three states is `auto`, because that value is interpolated into an
attribute. (`data-persist` would be the datastar-native answer to this and to `$_font` / `$_juice` /
the drawer; it is Pro-only, so those three still reset on reload.)

`tests/test_theme.py` pins the mechanism, the control, that placement (the toggle before the spacer,
Skip after it) and the round trip; `tests/palette.py` is the shared resolver the contrast tests now
use, since "the dark palette" is no longer a region of the file.

## Type: three roles, and only one of them may have personality

Font choice in a game is usually argued as "readable vs fun", which is the wrong axis. The useful split
is by **role**, because the three roles have different failure modes and only the last is free:

1. **HUD / under the clock** — score, points, streak, countdown. This is *scanned*, not read. Wants a
   humanist sans: large x-height, open apertures, unambiguous `1 l I` and `0 O`. Geometric faces
   (Futura-likes) look clean and glance badly, because `o c e` converge on a circle.
   **Tabular lining numerals are non-negotiable** — a proportional `1` makes a changing score jitter
   sideways. Already set (`font-variant-numeric: tabular-nums`) on the HUD, the timer and the streak.
2. **Content** — the prompt and the five answers. Same legibility rules; line length and leading matter
   more than the face does. Under a countdown this is HUD-adjacent, so it should stay boring.
3. **Display / theme** — title, streak chip, the finale. Recognised by *shape*, one to three words,
   seen over and over. This is where personality is affordable.

The evidence worth carrying:

- Decorative or unfamiliar faces cost roughly **10-20% reading speed in running text** and close to
  nothing on short repeated labels. That asymmetry *is* the argument for the split above: theme the
  chrome, not the question.
- **Rounded terminals** carry a measured semantic association — friendly, young, casual. It is the
  cheapest "this is a game, not a form" signal available, and costs no legibility if the face is
  otherwise humanist. (This is why the `rounded` option exists in the picker.)
- **Dyslexia-specific fonts are not supported by the evidence.** Controlled work (Rello &
  Baeza-Yates, 2013, and later Dyslexie / OpenDyslexic replications) finds no reliable advantage over
  a good plain sans; what does help is larger size, more line spacing, a shorter measure and an
  off-white ground. This app already does the last one — `--face` is `#fdfcf7`, deliberately not white.
- Genre convention is real (blackletter = fantasy, mono = terminal, rounded = casual). For a U16 bridge
  quiz the honest register is *friendly but competent*: humanist or rounded-humanist, not display.
- One or two families, maximum. Hierarchy comes from weight and size, not from more fonts.

**The domain constraint that outranks all of it:** the suits are *text* glyphs (`♠♥♦♣`, with
`font-variant-emoji: text` forcing presentation — see the contrast section). A face that does not
contain them falls back silently, so the suit can render in a different font from the bid beside it —
and two picker entries, Nunito and Cascadia Code, are exactly where that is not guaranteed.

**What shipped:** the token is split in two, in all three sheets.

- **`--ui-font`** is what you read — prompt, answers, controls — and is still what the Appearance
  picker changes, because a reading face is a legitimate preference and taking that away to make a
  point about theming would be a worse app.
- **`--display-font`** is the game's voice: the app bar title, the HUD score, toasts, the finale
  figures, and (under the toggle) the streak chip and the floating points. It defaults to a
  rounded-humanist stack — Nunito, falling back to Trebuchet MS, which Windows always has — and the
  picker does **not** move it. That is the whole benefit: personality sits where it costs nothing and
  stays put while the reading face changes underneath it.
- **`--suit-symbols`** (`"Segoe UI Symbol", "Noto Sans Symbols2", "DejaVu Sans"`) is spliced into
  every stack **immediately before the generic**, which makes the suit fallback deterministic instead
  of last-resort. Position matters and is easy to get wrong: *a generic family always matches*, so
  anything written after `sans-serif` is unreachable — and the token itself must contain no generic,
  or a serif stack would quietly end up falling back to a sans.

**What it cost, immediately:** "Segoe UI Symbol" carries the *party popper* as well as the suits — in
**monochrome** — so the finale's poppers and confetti came out as black line art the first time the
goal was crossed after the change. The two wants are opposite and both now explicit: the suits want a
text face (they are coloured by CSS, and an emoji glyph ignores `color` — the original VS16 bug in
this app), while `.pop` and `.confetti-bit` name a colour emoji stack plus `font-variant-emoji: emoji`.
Worth keeping as the general shape of the problem: **naming a fallback font is naming it for every
glyph in the stack**, not only the ones you were thinking about. The reveal's ✓ and ✗ are the same
question answered the other way — they stay on the text face on purpose, because CSS colours them.

`tests/test_elevation_and_type.py` pins all of it: both roles declared, every stack naming the symbol
fonts in a reachable position, no picker option touching `--display-font`, the chrome actually using
it (declared-but-unused is how a two-role system quietly becomes a one-role system again), the party
on a colour face, and the reveal marks given no face of their own.

## The game-feel experiment (`$_juice`)

The quiz already had the mechanics of a game — points, streak, time bonus, milestones that pay for
skips — and none of the *feedback* of one. Three effects, all behind one toggle (*Appearance → Game
feel*, on by default), all in `static/juice.css`, every rule scoped to `body.juice`. With it off, the
app renders exactly as it did; a test asserts that, because one unscoped rule would quietly make it a
fourth stylesheet variant for everybody.

1. **Hit-stop, then shake, on the reveal.** The wrong card freezes for 90ms — doing *nothing* is the
   effect; the pause is what turns the shake into an impact rather than a transition — then shakes for
   260ms while the ✗ punches in. The right answer lands 300ms later, so the two read as "wrong…
   *and here is what it was*" instead of both moving at once. The other cards dim to 35%.
   **On the card, never the page.** A question every ~15s makes screen shake nauseating, and shaking
   the specific card is also the more informative choice.
2. **The score floats off the card you picked.** `+22`, then `+15` for the streak bonus, then `+15`
   for time — each appended to that card as its beat arrives, stacking into a rising column. The
   server can aim them because *the choice is in the URL it was called on* (`/answer/<qid>/<index>`),
   so `nth-child(index + 1)` targets the right card with no client-side memory of the last click.
   Ladder-mode deductions float too, in red. This is the effect that repays the 2.5-3.5s the toast
   sequence costs: the points now appear where the action was, not only in the corner.
3. **A streak chip that grows and warms.** A run was previously invisible outside one toast that then
   vanished. It scales with the streak (`data-style:transform`, transitioned in CSS, so each correct
   answer is a visible step), warms green → amber → gradient at 3 and 6, and is hidden entirely at
   zero — a chip reading "0×" is worse than no chip. `Math.min($_streak, 8)` caps the growth before
   it reflows the app bar. `_streak` is patched with the *first* beat of the stream rather than the
   view patch at the end, or the chip changed two seconds late and read as belonging to the next
   question.

Three decisions worth keeping:

- **The floaters are streamed whether or not the experiment is on**, because `$_juice` is a local
  signal the server never sees, and CSS hides them when it is off. ~60 bytes per scoring beat to keep
  the choreography in one place instead of splitting it across a client-side effect.
- **No JavaScript of ours.** All three are CSS plus existing datastar attributes; pinned by a test,
  because "game feel" is exactly the thing that grows a helper script.
- **`prefers-reduced-motion` keeps the information, drops the motion**: the floaters still appear and
  the marks still land, they just do not travel. The number and the tick are the message; the
  animation is not.

Added in the second pass, both of which lean on the new card edge:

4. **Press and hover.** Nothing acknowledged a card before you committed. Hover lifts it 2px and turns
   the edge to the accent green; `:active` pushes it down 1px and scales to 0.985 with the shadow
   pulled tight, over 60ms — the physical read of "this went down". Both gated on `:not(:disabled)`,
   because a card that lifts under the cursor while it is refusing input is a lie.
5. **The correct card rings.** A correct answer had no beat of its own *on the card*: the corner toast
   said so, the floater gave the number, and then the next question arrived. Now the card you got right
   flashes a green ring for the length of the celebration — and it does it with
   `body.juice .candidate:has(.floater.gain)`, no JavaScript and no extra signal. The server already
   appends the floater to the card it was earned on, so the card styles **itself** from the presence of
   its own child. Same "the state is already in the DOM" move as `[aria-busy]`, one level down. Not
   `:has(.floater)`, which would ring a red ladder deduction green.

6. **The finale.** Crossing the points goal is the payoff for several minutes of play, and it was three
   static emoji and a sentence. It is now a sequence, which is the whole trick — a sequence reads as an
   event, everything-at-once reads as a page load:

   | at | what |
   |---|---|
   | 0ms | the card lands (scale + fade), via `.card:has(.finale)` |
   | 120ms | the party emoji pop in, staggered, then settle into a slow wobble |
   | 150ms | confetti bursts upward and falls |
   | 400ms | the numbers assemble, digit by digit, from alternating sides |

   Plus: the goal-crossing floater is gold, bigger and slower (`.floater.final`), and the points gauge
   pulses once it is full (`data-class="{full: $_pointsPct >= 100}"` — no new server signal, the
   percentage it already sends is the condition).

   Three things worth keeping from building it:

   - **CSS cannot count, so the server numbers the pieces.** Every stagger is
     `calc(<base> + var(--i) * <step>)`, and `--i` is rendered into each span. That is also why the
     party emoji and every *digit* are their own elements — a single text node cannot be staggered,
     and "fragments forming numbers" needs one box per character.
   - **The confetti is fixed, not random.** The server renders this screen, so a reload should show the
     same party rather than re-rolling it; the offsets are also spread by hand, because a formula
     (`i * 37 % 100`) produces a visibly *combed* burst.
   - **A transformed ancestor breaks `position: fixed`.** The confetti was fixed to the viewport and
     came out mispositioned and mis-stacked, because the card's own entrance animation is a `transform`,
     which makes it a containing block. Absolute against the card says what is actually happening.

On a phone the score animation needed different numbers, not just smaller ones. Measured at 390×844:
the choice cards are **48px** tall and one per row, so a 25.6px number rising 68px left its own card and
landed on the card **above** it. Keyframes cannot be parameterised, so the rise and the peak are custom
properties (`--float-rise`, `--float-peak`) that a `max-width: 560px` block overrides — 34px and 1.15rem
— and several beats spread *sideways* there rather than stacking upward, because the rising column only
works when there is room above the card. Verified: 1px above its own card, no overlap.

7. **The countdown gets urgent.** The last band of the timer was the dullest thing on screen: `.spent`
   (under 17%) paints it **grey** in all three sheets, which reads as "this is over". It is not — the
   time bonus is continuous (`round(base * percent_left / 100)`), so there are points on the table
   right down to zero. Under the toggle that band turns `--suit-heart` red and throbs on a 620ms beat.
   Two halves, because *the fill runs out of width before the question runs out of time*: the fill
   brightens while there is some of it, and the **track** glows via
   `.timer:has(.timer-fill.spent.ticking)`, so a zero-width bar still says something (`overflow:
   hidden` clips children, not the element's own shadow). No new threshold and no new server signal —
   the bands are already classes on the fill. The one addition is `ticking`
   (`$_ticking && !$_answering`, the same condition the drain interval assigns under): without it a bar
   frozen in the last band keeps throbbing behind the reveal, hurrying you along on a question you have
   already answered. Reduced motion keeps the red and drops the beat.

8. **The milestone sweep.** The points gauge carries the notches, so it is the thing that says *where*
   the next skip is — and it was the one part of the HUD that said nothing when one was collected. The
   award arrived as a corner toast, third or fourth in a chain of them, while the bar it was measured
   against sat still and merely got longer. Now a shine crosses the gauge on that beat: the server
   appends a `.meter-sweep` span when `toast.awards_skip` (a FLAG on the toast, not a match on the
   words "+1 SKIP!", so a copy edit cannot silently drop it), the animation is 780ms, and the next view
   patch takes the element away with no cleanup — exactly the floaters' lifecycle.

   The shine is **white at low alpha**, not a colour: the track is a red-to-green gradient, so a tinted
   sweep would read as a different *score* on the way past. And it starts and ends off the ends of the
   bar, which is what makes it a pass rather than a fade — `.meter` is `overflow: hidden` in all three
   sheets, so the bar clips it for free. Under reduced motion there is no travel to keep and no state
   left behind when it ends, so it becomes one brief flush of the bar instead.

Everything to here is CSS. The next thing is not, and it is the reason the "no JavaScript of ours" rule
needed re-reading rather than repeating:

## Sound (`$_sound`)

Off by default, and it is the only appearance preference that is: the others change how the page looks
to whoever asked for them, while audio arrives in whatever room the laptop is in. Five beats — the
verdict chime, a low thud for a wrong answer, an arpeggio when a milestone pays for a skip, a fanfare
at the finale, and a tick through the last three seconds of the countdown.

**The sounds are synthesised, not shipped.** `sfx.py` builds five WAVs from `math.sin` at import (8 kHz,
8-bit, mono, ~20 KB the lot) and `GET /sfx/<name>` serves them from memory. No binary assets in a
documentation repo, no licence to track, no regeneration step: change a number and the next request
serves the new sound. They are cached for a year and the page appends `?v=<build stamp>`, so an edited
synth arrives as a new URL rather than waiting out a cache.

Four things that fell out of building it:

- **Turning it on is what fetches it.** The five `<audio>` elements have no `src` at all — the URL comes
  from `data-attr:src="$_sound ? … : false"`. With sound off (the default) the page is still the three
  requests COMPARISON.md measures; with it on, `preload="auto"` fetches all five at once, long before
  the first beat.
- **They live OUTSIDE `#app`.** Inside the morph target they would be replaced on every interaction:
  re-fetched constantly and cut off mid-play. Out in the document they load once and survive every
  patch — the same reasoning that put the held timer stream's `data-init` on `<body>`.
- **A beat is an APPEND, not a morph.** The trigger is a one-line span with
  `data-init="$_sound && document.getElementById('sfx-correct')?.play()"`, appended to a `#sfx` sink
  that is cleared at the start of each answer stream. Morphing it in would have been the obvious move
  and would have been wrong: two identical consecutive beats (two right answers) render identical
  markup, an idempotent morph leaves the element alone, and `data-init` would never run a second time.
  Appending sidesteps the question — an appended element is always new. Verified in the browser, twice
  in a row.
- **The tick's rate limit is the sample.** It rides the existing 100ms countdown interval, and ten
  ticks a second is a buzz. `play()` on an element that is already playing does nothing, so `tick` is a
  45ms blip padded with silence out to a full second: the audio's own length spaces the ticks and no
  timer state is kept anywhere. Measured in a real browser — 25 calls at 100ms produce 3 sounds.

So the rule the game-feel layer states as "no JavaScript of ours" survives, read properly: `play()` in a
datastar attribute is the same kind of thing as every other handler in this app, and a helper *script*
is what is being avoided. The visible cost of holding that line is that there is no volume control —
setting `.volume` needs a real module — so the levels are baked into the samples instead. The tick is
also client-timer only: in `DSQUIZ_TIMER=stream` the interval attribute does not exist, and a tick there
would be an element patch per second per tab, which is a cost the comparison should not absorb quietly.

Not built: sound for the skip button and for arriving at a new question (both are actions the player
took, and the app is already noisier than it was); anything that needs an `AudioContext`.

## Where each control lives (the HUD)

The sidebar was doing three unrelated jobs, and it showed: live state (the score), an in-play action
(**Skip**), and configuration. Two concrete consequences —

- the score was rendered **twice**, once in the app bar and once in a `#score` panel below it;
- **spending a skip meant opening a settings drawer**, because Skip sat next to the controls that
  *restart the quiz*.

Sorted by when you touch it:

| zone | holds | visibility |
|---|---|---|
| app bar, left (chrome) | nav toggle, title, **theme toggle** | always |
| app bar, right (HUD) | score, points gauge with its milestone notches, streak, **Skip** (+ `s`) | always |
| play area | question card, timer, toasts | always |
| drawer | difficulty, filter, topics, ladder, target, Restart, Appearance, debug | **closed by default** |

The bar is **two** clusters, not one, split by `.topbar-spacer` — and the split is the same rule as
the table: the left is view chrome, the right is live game state. That distinction only started
earning its keep when the theme toggle arrived and was put on the wrong side of it (see *A theme
switch* above): a preference sitting in the game cluster, next to the one control that spends a
resource.

The gauge earns HUD space because of the *notches* — each one is a skip you can earn, so the bar
answers "how close am I to another skip". The raw numbers do not, which is why the duplicate panel went
rather than the bar. The dial survives, folded, in a `Progress` group: it is pleasant but spends a lot
of space on one number.

**Inside the drawer, the order is the order of the questions**: how hard (difficulty), how it is
scored (ladder mode, target percentage), *which* auctions (Topics), and only then the pattern
language — the bidding-tree filter, folded away behind **Advanced**. Topics and the filter answer the
same question at very different prices: a topic is a name you recognise ("Weak twos"), the filter is
a syntax with six rules and its own help panel. The filter box sat at the top for months because it
was built first, which is the wrong reason for anything to be first. The status line ("the whole
system, 1652 auctions") stays *outside* the fold — it reports the working set, which is worth seeing
whether or not you are editing a pattern.

**The phone drawer stretched its panels to fill the screen.** Reported as "collapsing `Progress`
saves nothing" and "opening it is mostly whitespace", and both are the same line of CSS: the drawer
is `display: grid`, and as a phone overlay it is `position: fixed; top: 3rem; bottom: 0` — a grid
with a **definite height**. The default `align-content: normal` acts as stretch, so every scrap of
leftover space was handed to the auto rows. Measured at 390x800: the *collapsed* Progress group was
**145px** against a natural 48, an open one carried ~90px of dead air under the dial, and the debug
buttons came out as tall slabs. `align-content: start` and they take their own height, with the
drawer scrolling if they exceed it. The desktop column is `sticky` with an auto height, which is why
none of this was visible there — a layout bug that only exists at one size, in the one place the
tests could not see it.

**A fat morph closes anything the browser was holding open.** Every disclosure in the drawer — the
`Progress` dial, *Advanced*, *Filter syntax*, *Appearance*, and the two note panels — snapped shut on
every answer, skip, settings change and restart, because `open` is state the PLAYER set and the
server renders markup that has never heard of it. The morph then removes the attribute it cannot see
a reason for. `data-preserve-attr="open"` is the fix and it was already in the codebase — on exactly
one `<details>`, which is why exactly one survived and the rest read as a random bug. All seven carry
it now, pinned by a test that walks the templates.

**Restart closes the drawer, but only where the drawer covers the quiz.** Below 900px it is a fixed
overlay, so "start again" that leaves it open costs a second tap to see the new question; above it,
the drawer is a column beside the quiz and closing it would just take the controls away. So it is
conditional, client-side (`window.matchMedia`), and reads the same width the CSS repositions at —
`render.DRAWER_OVERLAY_QUERY`, one constant, with a test that it matches the `@media` block in all
three sheets. Only the explicit button does it: the sliders and checkboxes restart the quiz too, and
you may be adjusting several in a row.

The drawer starting closed is the other half. Everything left in it restarts the quiz, and it was also
the tallest thing on the page — the reason the whole document used to scroll. `_navOpen` defaults to
`false` in *both* the declared signals and `data-init`, or the drawer flashes open before init runs.

Narrow screens shed HUD pieces in a deliberate order: the gauge first (the points number says the same
thing less precisely), then the score's font size. **Skip and the streak never drop** — one is an
action, the other is the reason to keep going.

## Responsiveness, measured on a phone

Emulated 390×844 (CDP device metrics, touch on — the MCP browser window itself cannot go below ~487px,
so window resizing alone would have been a lie). Before, at that size:

| | before | after |
|---|---|---|
| hamburger tap target | **33×15px** | 44×44 |
| Skip tap target | **70×27px** | 76×44 (coarse pointer) |
| auction / choice type | 32px / 32px | 22px / 21px |
| choice height | 103px (text wrapped to 3 lines) | 48px |
| page height | 1207px (≈360px of scroll) | 879px (≈35px) |
| horizontal overflow | none at any width | none |

**And the mobile drawer had never worked.** `@media (max-width: 900px) { .sidebar { position: fixed } }`
sat *above* the base `.sidebar { position: sticky }` in `app.css` — same specificity, later wins — so
the off-canvas drawer never applied and the sidebar stayed a sticky 320px column on a phone. Pico and
Bulma happened to declare their mobile block after their base rules, so **only the default variant was
broken**, and nothing failed because every rule was individually correct. Now pinned by a test that
compares the two positions in the file rather than the rules themselves.

Three more found by looking at the result, all of them "the rule was right, the context wasn't":

- **The HUD gauge read as full at every score.** The track carries the red-to-green gradient and the
  mask covers what has *not* been earned, so making the mask translucent — which I did, to stop an
  opaque pale-green block looking like a stray rectangle on the green bar — let the gradient show
  through the empty part. The fix is an opaque colour that *belongs to the bar* (`--primary-dark`), so
  unearned reads as a groove in it. Transparency was never the answer; the wrong palette was.
- **The topics picker opened behind the drawer on a phone.** The Topics button lives *in* the drawer,
  which is a `z-index: 30` overlay at that width, and the dialog was `20` — so tapping Topics looked
  like a no-op. It is `50` now, and opening it closes the drawer on narrow screens, because a dialog
  stacked on the thing you opened it from is worse than either alone.
- **…and in the Bulma variant it opened below the fold.** A non-modal `<dialog open>` is
  `position: absolute` in normal flow, and the Bulma adapter never positioned it: measured `top: 819px`
  in an 844px viewport. Pico hid the same omission by centring dialogs for us, and the desktop page was
  tall enough to look fine.
- **…and its buttons were sliced off the bottom.** Nineteen topics in one column is ~880px of list,
  and the *whole card* was the scroller, so Apply / Clear / Close sat below the fold of the dialog —
  the actions of a dialog are the last thing that should need scrolling to. The card is a flex column
  now: `.topics-scroll` holds the list, the status line and the legend, and the actions sit outside
  it. Two non-obvious parts, both of which cost a debugging round: a flex item needs `min-height: 0`
  or it refuses to shrink below its content and grows the card instead of scrolling; and
  `align-items: stretch` has to be *stated*, because Pico's own `dialog` rule is a centring flex
  overlay and inheriting its `center` made the children shrink-to-fit — a 208px topic list inside an
  896px card.
- **Clear left every box ticked.** `$topics = {}` is the obvious code and does nothing: the boxes
  bind one signal each (`data-bind:topics.<slug>`), so `topics` is a *namespace*, not a value —
  assigning an object replaces the branch the bindings watch instead of writing the leaves they are
  bound to. `@setAll(false, {include: /^topics\./})` walks the tree and writes each leaf. It is
  followed by a preview refresh, because the status line is rendered from the ticks and otherwise
  kept saying "N auctions match" under an empty list.
- **Close is CANCEL, and so is Escape.** The picker's first line promises that nothing changes until
  Apply — so abandoning it has to abandon the ticks too, or you reopen to find a selection the app is
  not using, under a status line contradicting the drawer. `/filter/topics-reset` patches the `topics`
  branch back to the filter in force and blanks the picker's status. It patches *only* that branch:
  `bound_signals` also carries `filterText`, which is a draft the player may be part-way through
  typing in the drawer behind the dialog. Escape is wired by hand, because a non-modal `<dialog open>`
  gets no Escape handling from the browser — and it is the one window keydown that is deliberately
  *not* focus-aware, since dismissing is global by convention.
- **A dialog on top of the quiz has to take the keyboard with it.** With the picker open, `1`
  answered the question behind it, `s` spent a skip and Enter advanced the reveal — none of those keys
  reach a control the focus guard would catch, because a checkbox has no claim on a digit, which is
  exactly why the narrowed guard lets it through. Every window keydown now also tests `!$_topicsOpen`.
- **The streak chip says "streak".** A bare "3×" is a rebus, and the panel that used to explain it
  (`Progress`) is collapsed by default, so the app bar has to stand on its own. The word folds away
  under 560px where the bar has no room for it; the `aria-label` carries the meaning at every width,
  so what it means never depends on the space.
- **The topics fit on one screen now.** The list is
  `grid-template-columns: repeat(auto-fit, minmax(13rem, 1fr))` in a card whose width is *stated*
  (`min(56rem, 92vw)`) rather than left to shrink-to-fit — a grid of `1fr` tracks is perfectly happy
  at one column, which is why widening the `max-width` alone changed nothing. Measured at 1400×950:
  three columns, all nineteen visible, nothing scrolls. At 390×700 it is one column and the list
  scrolls, with the buttons still on screen.

The layout itself had no horizontal overflow at any width from 360 to 1900, drawer open or closed, so
the scrollbar that prompted this was not the grid. What could still cause one, and is now defended:
the confetti drifted in `vw` from a `left: 50%` origin *inside the card*, so with the drawer open —
which shifts the card's centre right — the party could spill past the window edge; the drift is a
percentage of the card now. Long unbroken tokens in bml descriptions get `overflow-wrap: anywhere`, and
the app bar's flex children get `min-width: 0` with an ellipsis on the title, so a long variant name
cannot push the page wider.

### Second pass: the app bar, and the countdown the URL bar was eating

Re-measured on the two widths that actually turn up — 390×844 (iPhone 12/13/14) and 360×740
(Galaxy S9) — because the first pass fixed the *type scale* and the tap targets and left the chrome
alone. Four faults, three of them invisible on a laptop and one of them invisible everywhere:

| | before | after |
|---|---|---|
| app bar height | **78px** | 62 |
| score | wrapped to 3 lines — `0/0`, `· 0`, `pts`, read vertically | one line |
| drawer top edge | 48px, i.e. 14px *behind* the 62px bar | flush |
| countdown | below the card, under the fold and under the phone's URL bar | pinned under the app bar |

- **The score wrapped, and that is what made the bar 78px tall.** It is a flex item with
  `min-width: 0` (given, correctly, so it could not push the page wider) and no `white-space`, so
  when the bar ran out of room it broke the number instead of the layout. A score is one line or it
  is not a score: `nowrap` and `flex: none`, and the *title* is the item that gives way — it has the
  ellipsis. Below 400px the correct/attempted **fraction** drops out too, which is the next rung of
  the ladder that already sheds the gauge at 760px. The points survive because they are what the
  skips are earned against, and the fraction is still on the drawer's dial. 400px was chosen so both
  common widths are on the same side of it: with the fraction in, the title measured 86–116px at
  360–390 and the bar read as five things fighting.
- **16px of the bar belonged to Pico.** Pico gives every `button` a `margin-bottom` of one spacing
  unit, and on a flex item that margin is part of the *bar's* height. Skip and the theme toggle had
  zeroed it; the hamburger had not, so a 44px target sat in a 62px bar that measured 78. Nothing on
  screen pointed at it — it is the kind of thing that is only ever found by adding up the children
  and finding they do not reach the parent. Now stated in all three sheets, so the variants measure
  the same whichever is selected.
- **`--topbar-h` had been wrong since the touch targets went in.** It said `3rem`, from when the bar
  really was 48px; the 44px hamburger plus 0.55rem of padding is 62. Two things are positioned from
  that token, so the mobile drawer had been opening 14px underneath the bar — the same "the rule is
  right, the context moved" shape as the drawer bug above. It is `3.875rem` now, and a coarse pointer
  lands on the same number (Skip and the theme toggle grow to the same 44px floor), so one value is
  right for both pointer types.
- **The countdown was in the worst place a phone has.** It sat below the question card in flow: with
  five choices it is already at the fold, and a phone's URL bar slides back over the bottom of the
  viewport the moment you scroll *up* — so the one element that is worthless off-screen was the one
  most likely to be off-screen, and covered by browser chrome when it wasn't. Below 900px `.main`
  becomes a flex column and the timer takes `order: -1` with `position: sticky; top: var(--topbar-h)`:
  visually above the question, pinned to the bar, 22px instead of 32. `order` and nothing else —
  the DOM order (and so the screen-reader order, and every template) is untouched, and the desktop
  layout keeps the bar under the question where the reveal appears beside it.

The theme toggle **stayed in the bar**, deliberately, against the first instinct to move it: the
squeeze was the wrapped score and Pico's margin, not the toggle, and with those gone the bar has room
at 360px. Moving it into the drawer would have paid for a fault it did not cause with the thing the
drawer is worst at — "this is too bright right now" is fixed the moment it is noticed.

What is left, and is a limit rather than a bug: **five choices plus the prompt do not always fit one
screen.** The vertical budget was trimmed where it was free — the bar gives back 16px, the sticky
countdown takes 32px of card-pushing margin out of the flow, and under 560px the grid gap, the
prompt's margin and the card minimum each come down a notch — but a five-line auction is five lines,
and shrinking type further trades a scroll for a squint. `tests/test_phone_layout.py` pins all of it.

## The debug panel

The panel app had `debug_enabled` and a row of buttons for reaching states that take minutes of honest
play (`quiz_app.py:93`). This one is the same idea with a kill switch: `+/-100 points`, `goal 200` /
`goal 1000`, `show reveal`, `show finale`, and a status line. `just dev` arms it (`DSQUIZ_DEBUG=1`),
`?debug` arms it per page load, `DSQUIZ_DEBUG=0` forbids both — which is what a deployment sets,
because these routes can rewrite the score.

Three decisions in it that were not obvious:

- **The points goal is per session, not a mutated module constant.** `engine.answer` takes it as an
  argument, so a 200-point goal also brings the skip milestones forward (they are fractions of the
  goal) and the whole ladder is exercisable in a minute. Two browsers against one process can disagree
  about the goal, which a global would not allow.
- **`show finale` goes through the real scoring path** — points to `goal - 1`, then answer the current
  question correctly, so `engine.answer` → `outcome.completed` → the toast chain → the completion
  screen all actually run. Setting `completion_wall` directly would show the screen while skipping
  everything that produces it, which is the opposite of useful when the screen is what you are testing.
- **The flag is decided on page load only.** The interactions POST to bare paths (`/answer/3/1`) with
  no query, so re-reading `?debug` per request switched the panel off on the first click. Page-load
  scoped gives it the same lifetime panel's `pn.state.location.search` had: `?debug` arms, a plain
  reload disarms.

It also immediately earned its keep: a 200-point goal exposed that the *toast stream* was still
computing `_pointsPct` against `engine.POINTS_GOAL` while `render.signals` used the session's goal, so
the gauge jumped backwards when the final patch landed.
The suit colours stay out of all of it — they are contrast-tested and they mean something, so
celebration happens in borders, chips and numbers.

## CSS framework options

> New to this vocabulary? `CSS_GUIDE.md` explains classless vs class-based vs utility vs tokens from
> first principles, what a token is, and why specificity can make an override silently do nothing.
> This section assumes it.

| Approach | Fit | Cost | Tried |
|---|---|---|---|
| **Classless / semantic** — Pico, Simple.css, MVP.css | Best. Styles the elements we already emit (`<dialog>`, `<details>`, labels, inputs); no JS; CSS-variable theming; light/dark free | Generic look; some fighting for the card faces and dial | **spiked**, `app-pico.css` |
| **Class-based, CSS-only** — Bulma | Very good. Never had JS, so *we* wire behaviour — exactly what datastar wants. Real component vocabulary | Class strings in every jinja partial | **spiked**, `app-bulma.css` |
| **Bootstrap, CSS-only subset** | Workable if `bootstrap.bundle.js` is skipped and `.modal.show` / `.collapse` are driven with `data-class` | Half the docs assume the JS; easy to drift into loading it | no |
| **Tailwind** | The de facto hypermedia pairing; datastar's own *"Yes, you want a build step"* essay is not hostile | Build tooling; class soup in fragments; bigger SSE patches | no |
| **Tokens only** — Open Props, **Stellar** | Closest to today's hand-rolled CSS; a palette / scale / shadow system without components | Every component still hand-written | no |
| **Web components** — Shoelace, Material Web | Workable (`data-attr` in, `data-on:sl-*` out) | Shadow DOM: the panel problem, re-acquired | no |

Whatever is adopted, the four suit colours stay our own tokens — no framework palette has a
4-colour deck, and they are the one part of the design that is not ours to choose.

**Settled: Pico is the default** (`render.DEFAULT_CSS`), and the *Base CSS* picker is now **debug
only** (`?debug`). Two reasons, and the second is the real one: Pico wins on maintenance rather than
looks — `<details>`, `<dialog>`, `<kbd>`, focus rings and the light/dark switch are the framework's
problem there — and a player cannot see the difference between the three, so offering the choice was
asking them to decide something with nothing on either side of it. The variants themselves stay: the
comparison is the point of the spike, and switching sheets live is how it is checked. Consequence
worth knowing: the static `href` in `<head>` must be the *default* sheet, not `app.css`, or the
browser paints one stylesheet and swaps to another a tick later — both it and the expression's
empty-signal branch are rendered from `render.stylesheet_href(DEFAULT_CSS)`, one source of truth.

## Where Stellar CSS fits

Stellar is **Star Federation's own CSS framework, part of Datastar Pro** — so it is the closest
thing to a datastar-endorsed answer, though it answers a narrower question than "which component
framework".

What it is: a configurable design system emitted as **CSS custom properties, no build step**.
`stellar.config.json` → `stellar gen` → `assets/stellar.css` (~12.8k custom properties), with an
interactive editor via `stellar serve` (:7331). Token categories cover colour (theme tokens plus
named ramps, chart colours, gradients), typography, a unified size scale, z-index / aspect ratio /
viewport bounds, borders / radii / shadows, and animation easings, durations and transform
magnitudes. It positions itself against Tailwind (utility bloat in markup) and Open Props
(non-configurable).

What it is **not**: a component library. It ships tokens, not buttons — the community guide's rule
is "Style raw tags first; reach for utilities, then components, only when elements cannot carry it".

So Stellar is **orthogonal to Pico/Bulma, not an alternative**: it would replace the hand-rolled
token block at the top of `app.css` (`--primary`, `--card`, `--side`, `--face`, `--ui-font`,
`--shadow`), giving a coherent scale for spacing, radii, shadows and motion — and leave every
component decision above still to make. Pairing Stellar (tokens) with classless CSS (element
styling) would cover both halves.

Before adopting, three things to check:

- **Cost and licence.** Datastar Pro is a one-time lifetime licence: Solo $349, Team $1,299,
  Enterprise custom, funding the Star Federation nonprofit and the open-source work. Redistribution
  or "making the software available to third parties in any form, outside of an 'end product'" is
  prohibited — worth confirming that committing a generated `stellar.css` into this repo counts as
  an end product, since the quiz is deployed publicly.
- **Alpha status.** Stellar is marked alpha, Rocket beta.
- **Rocket and shadow DOM.** Rocket is Pro's "JavaScript custom-element API for components". Whether
  it uses shadow DOM is not stated on the Pro page — and given constraint 1 above, that is the first
  question to ask before using it here.

Pro also bundles 10 extra attributes (`data-animate`, `data-persist`, `data-view-transition`,
`data-match-media`, `data-on-raf`, `data-on-resize`, `data-query-string`, `data-replace-url`,
`data-scroll-into-view`, `data-custom-validity`), 3 actions (`@clipboard()`, `@fit()`, `@intl()`), a
bundler and the Datastar Inspector. Several are directly relevant to the gaps above:
`data-view-transition` and `data-animate` for the question swap, `data-match-media` for
reduced-motion, `data-persist` for remembering the font / drawer choice across reloads (the free
version cannot, which is why `$_font` resets).

## Patch granularity and compression

Settled: **fat morph by default** (patch `#app`, the whole page below `<body>`), with brotli on
everything including the SSE streams. The Tao asks for it, it removes the class of bug where the
server forgets which fragment a change touched, and compression makes the bytes irrelevant — 23KB of
markup becomes 4.1KB on the wire, and the repetitive page compresses *better* (5.6×) than the document
does (4.4×). Click-to-updated-DOM is 8ms either way. Measurements and the proof that compression does
not buffer the stream are in `COMPARISON.md`.

Consequences to keep in mind when adding UI:

- Anything inside `#app` with `data-init` **re-runs on every patch**. Page-level one-shots (opening a
  held connection) belong on `<body>`.
- Client-owned drafts survive, because the morph only writes `input.value` when the value *attribute*
  changes. Do not render a draft into the `value` attribute server-side, or a patch will overwrite it.
- Never patch a draft as a *signal* outside its commit path.

## Two mistakes worth not repeating

**Declaring `color-scheme: light dark` without a dark palette.** It reads like a courtesy; it is a
claim. The browser takes it literally and paints every UA surface for dark mode on a dark-OS machine
— the canvas beyond the document (which reads as a black rim around the page) and the scrollbars —
while every colour we actually ship stays light. Both stylesheets now say `color-scheme: light`,
which is the truth. A genuine dark palette is separate work, and the test pinning this should be
replaced rather than deleted when someone does it.

**Letting the settings column set the page height.** The sidebar is the tallest thing here, so the
whole document scrolled — and the question moved out from under the cursor while the time bonus was
running. It now has its own scroll region: sticky under the app bar, capped to the viewport,
`scrollbar-width: thin`, `overscroll-behavior: contain`. Size that cap off a declared `--topbar-h`
rather than a guessed constant: the first attempt was 13px out, which was enough to put the page
scrollbar straight back.

## What the Pico A/B actually needed

Switching stylesheets is one signal; making the variant *comparable* took four adapter fixes, each of
which is a fair sample of what adopting any base stylesheet costs:

- **Pico ramps the root font size with the viewport** (100% → 131.25% at ≥1536px). On a wide monitor
  everything rendered ~31% larger than the hand-rolled sheet and the variant looked zoomed. Fluid
  typography is a reasonable default for a text site; here it makes the comparison meaningless, so
  `--pico-font-size` is pinned to 100%.
- **`body > header|main|footer` are page containers** in Pico: centred, padded, capped at 1450px. The
  app bar is chrome and wants the full width, and the layout below it is a plain div that is *not* so
  constrained — the two ended up misaligned until that was undone.
- **Every button is styled as the primary action.** Skip and Restart both came out Pico-blue, so
  `.warning` / `.danger` / `.light` needed restating.
- **`section` carries a `margin-bottom`** that lands on top of the sidebar grid's own `gap`, showing
  as double-width bands of page background between panels.

Four more surfaced only from *using* the variant rather than looking at it, which is the argument for
keeping the picker rather than deciding from a screenshot:

- **Pico reads `aria-busy="true"` as its loading component** — `white-space: nowrap` on the element
  plus a spinner `::before`. The choice group carries that attribute while an answer is in flight, so
  for the 2.5–3.5s the toast sequence runs, every candidate's text snapped to one line and spilled
  out of its box: buttons measured 122px tall before the answer and 74px with overflowing text during
  it. It read as the page breaking mid-answer, and only under Pico. The attribute is correct ARIA and
  stays; Pico's interpretation is overridden. **In a classless stylesheet, ARIA state attributes are
  also style hooks** — worth remembering before reaching for another one.
- **`<details>` gets a summary and a marker, but no surface.** Notation and System Notes were a
  heading and a chevron on the page background — present, unmissable in the DOM, invisible as panels.
  The hand-rolled sheet makes them cards; matched with Pico's own card tokens.
- **`dialog` *is* the overlay in Pico**, and the card is expected to be `dialog > article`. With no
  article, the topics picker rendered as a full-viewport translucent wash with bare content floating
  in it. Adding an `<article>` would hand Pico the card for free — not done, because Pico's overlay
  covers the viewport and swallows clicks, so the picker would be modal under one stylesheet and not
  the others, and the comparison is only worth something if the app behaves identically in all three.
- **Its card surface is squarer and flatter than Bulma's**, and side by side the Bulma panels simply
  looked better: Pico's card is a 0.25rem radius under a heavier layered shadow, and this adapter was
  drawing a hard 1px `--pico-muted-border-color` edge on top of that — three separate cues all saying
  "box". Bulma's `.box` is one wide low-opacity shadow (`0 .5em 1em -.125em / 10%`), a 2%-alpha ring
  instead of a border, and `--bulma-radius-large` = 0.75rem. That recipe is now stated outright in the
  Pico adapter as `--panel-radius` / `--panel-shadow`, so the two variants match exactly (12px,
  `0 8px 16px -2px`) and the surface no longer depends on which base stylesheet is loaded. The
  hand-rolled sheet is deliberately left as it was — 25px and a heavier single shadow are its own
  look, not a bug.
- **Two specificity traps, same shape.** Pico declares its closed-summary colour on
  `details summary:not([role])` (0,1,2) and its colour roles on `:root:not([data-theme=dark])`
  (0,1,1), so `.filter-help > summary { color }` (0,1,1) and `:root { --pico-primary }` (0,1,0) both
  did *nothing at all* — no warning, no visible change, easy to believe the edit was wrong rather
  than out-specified. The fixes are to hand the framework its own variable
  (`--pico-accordion-close-summary-color`) and to declare the colour tokens on `body`, where
  inheritance carries them without mirroring Pico's theme selectors. Until that was done the variant
  was two colour languages at once: Pico-blue Apply button, ticked checkboxes and focus rings under a
  green app bar. **Bulma has no equivalent problem** — its tokens sit on a plain `:root`, so the
  adapter's own `:root` block wins outright. That is the clearest single contrast between the two
  frameworks' theming models, and it favours Bulma.

None of these are Pico's fault; they are the tax on a stylesheet that has opinions about page
structure. Worth weighing against the 205 lines it saves.

## What the Bulma spike actually needed

Bulma 1.0.4, vendored, as a third option in the same picker (`static/app-bulma.css`). The point of
spiking a *class-based* framework after a classless one is that the cost lands somewhere different:
Pico needed adapter CSS and nothing else, Bulma needs adapter CSS **and markup**.

Counting code lines (comments and blanks stripped, so the three are comparable):

| | adapter | vendored | vendored, brotli |
|---|---|---|---|
| hand-rolled `app.css` | 629 | — | — |
| Pico + `app-pico.css` | 564 (−10%) | 71 KB | 9.9 KB |
| Bulma + `app-bulma.css` | 536 (−15%) | **678 KB** | 44 KB |

Pico's adapter was 490 (−22%) until the four *using it* findings below were fixed; putting the
disclosures, the dialog, the busy state and the colour roles right cost 74 lines. Both frameworks
converge on ~530-560 lines, which says the irreducible part of this app's CSS is about 300 lines and
the rest is controls either framework can mostly supply.

Plus, for Bulma only, **28 framework class tokens across 5 templates** and two `<div class="select">`
wrapper elements — markup that ships on every patch whichever stylesheet is selected. That is the
line worth measuring: the document went 19,347 → 20,631 bytes raw, but only 4,384 → 4,448 brotli, and one
interaction 4,129 → 4,215. **~1.3KB raw, ~70 bytes compressed** — the strings are repetitive, so
brotli eats them. (Measured before the digit-handler rewrite, which then gave ~360 raw bytes back by
replacing five per-button `keydown` attributes with one on the group: 20,268 raw / 4,490 brotli now.) The wire is not the argument against class-based CSS here; the templates are.

What Bulma gave, free and better than the hand-rolled version:

- **Theming is three numbers.** `--bulma-primary-h/s/l` re-tints every button, link, tag and their
  hover / active / invert shades. Pico's variables are per-role colours; this is one colour and
  derivations. It is the nicest thing in the framework.
- Buttons, inputs, tags, notifications and the card surface, all with a coherent scale — and `.tag`
  turned out to be exactly the right component for the digit accelerator.
- A full dark theme, so `color-scheme: light dark` stays honest with only our tokens re-picked.

What it charges, beyond the class strings:

- **No `<dialog>`, no `<details>`, no `<kbd>`.** Bulma's modal is a `.modal` / `.modal-background` /
  `.modal-card` structure toggled by `is-active` — three wrapper elements and a class where this app
  has one native element and `data-attr:open`. Keeping `<dialog>` is right (the framework's version
  moves view state back into class toggling), so its chrome is written out by hand.
- **Bullets exist only inside `.content`.** Every plain `<ul>` had none, and adopting `.content`
  restyles the headings, code and tables inside it too — so the markers are restored instead.
- **Headings reset to body size.** Each one is sized in the adapter.
- **No slider.** `bulma-slider` is a separate extension; the range inputs are themed by hand.
- **`box-sizing` misses the form controls.** Bulma ships `*, ::before, ::after { box-sizing:
  inherit }` off `html { border-box }`, and every element computes border-box *except* selects and
  inputs, which come out `content-box`. So `width: 100%` on a select plus Bulma's 38px arrow padding
  measured 300px inside a 250px column — 20px of horizontal scrollbar in the sidebar. One line of
  adapter CSS; twenty minutes to see.
- **`.select` sets `height: 2.5em` on the wrapper**, and that em resolves against the wrapper's font
  size while the select inside resolves its own — a 0.95rem label gave a 53px select in a 38px
  wrapper, overhanging the next control.
- **`:not(:last-child)` margins** on `.box`, `.panel` and `.notification` fight a grid `gap`. Exactly
  the tax Pico's `section` margin charged: this is what "a stylesheet with opinions about page
  structure" means, in both families.
- **678KB vendored**, because the CSS build is the whole framework. Trimming to the components used
  means Sass imports and a build step — the thing this app does not have.

Verdict, for the record: **Pico, but by less than it first looked.** Both leave the same irreducible
core untouched — layout, drawer, dial, gauge, timer, toasts, four suit colours, roughly 300 lines — so
the framework only competes over the controls and chrome, and after the fixes above the two adapters
are within 30 lines of each other. What still decides it:

- **for Pico**: no framework classes in the markup at all, and 71KB against 678KB (9.9 vs 44 brotli).
- **for Bulma**: theming is three h/s/l numbers on a plain `:root`, where Pico's colour roles hide
  behind `:root:not([data-theme=dark])` and its component styles behind
  `:not([role])`-style selectors that silently out-specify an adapter rule. Bulma never fought back.
- **against both**: each has strong opinions about page structure (`body > header` containers and
  `dialog`-as-overlay in Pico; `:not(:last-child)` margins and `.content`-only list markers in Bulma),
  and every one of those cost adapter lines to undo.

Bulma's colour system is the one thing worth stealing outright, and it can be stolen as tokens without
adopting the framework. Neither is adopted yet; the picker keeps all three side by side.

## Action list

Real bugs first; nothing here is done unless marked.

**Done.**

1. **Settings controls debounced** (`__debounce.400ms`) — arrow keys on a range input fired `change`
   per keypress and every change restarts the quiz, so holding an arrow wiped the score. Verified:
   four rapid presses now produce one request.
2. **Equal-width choice grid + digit accelerators + `role="group"`** — stable targets, playable from
   the keyboard.
3. **Suit colours darkened** to `--suit-club` `#1e7a45`, `--suit-diamond` `#b35300`,
   `--suit-heart` `#cc0000`, `--suit-spade` black: all ≥4.9:1 on `--face`, so AA for normal text and
   not just large. bml's own values were 2.6 / 1.9 / 3.9. A contrast-computing test pins this, rather
   than a colour-name match. **`bml.css` itself is unchanged** — the notes still use the light values,
   so the two have deliberately diverged; darkening bml would need a change in that repo.
4. **Neutral content surfaces** — the quiz card is white with a green top rule, sidebar a pale tint,
   green kept for the app bar and accents.
5. **`prefers-reduced-motion`** honoured for every transition and animation.
6. **Inline non-blocking answer reveal** plus corner toasts (see above).
7. App bar with nav toggle, single-track collapse (CSS regression test), suit glyphs as bml classes
   with VS16 removed, font picker, focus-visible rings, one-hue palette.

**Open.**

8. ~~Evaluate a base stylesheet (Pico first)~~ **spiked, both families, and DECIDED: Pico.**
   `render.DEFAULT_CSS = "pico"` is what every session starts with, and the `$_css` picker is now
   behind `?debug` — the three variants differ by details a player has no way to care about, so
   offering the choice was asking them to make a decision with nothing on either side of it. The
   hand-rolled sheet and Bulma stay on disk deliberately: the comparison is still the point of the
   spike (COMPARISON.md), switching sheets live is how it is checked, and they are the base to
   re-experiment from. Findings in the two sections above.
9. ~~A real dark palette~~ **done**, and since ~~OS-only~~ **switchable** — see *A theme switch, and
   why the media query had to go* below. The suits are re-picked rather than reused: black is 1.37:1
   on a dark card face, an invisible spade, so it becomes near-white as four-colour decks do in dark
   themes; the other three lighten until each clears 4.5:1. Tested in both palettes.
10. ~~Consider `data-persist` (Pro) so the font and drawer choices survive a reload~~ **dropped, and
    worth saying why rather than leaving it on a list.** The **theme** never needed it — it is
    remembered in a cookie the toggle writes itself, which also buys a correct first paint that
    `data-persist` (client-side, post-hydration) would not. What is left resetting on a reload is
    `$_font`, `$_juice`, `$_css`, `$_sound` and the drawer, and every one of those *starts at the
    value you want*: the reset is invisible unless you deliberately chose the non-default, and the
    session-backed alternative is server state for something the server has no opinion about. If it
    ever does bite, the cookie the theme uses is the pattern to copy — not a Pro licence.
11. ~~An elevation ladder~~ **done**: `--elev-inset` / `--elev-1..4` in all three sheets — one
    overhead light, `blur = 2 × offset`, ambient + direct, ink-hued. Replaces seven ad-hoc alphas, the
    offsetless drawer, Pico's left-lit blue `.notes` shadow and the flat answer cards. Pinned by
    `tests/test_elevation_and_type.py`, including the rule that a cast shadow must name a rung.
12. ~~Split `--ui-font` from `--display-font`~~ **done**: the picker still changes the *reading* face;
    the chrome (app bar, HUD, toasts, finale, and under the toggle the streak chip and the floaters)
    is on a rounded-humanist display face that does not move. `--suit-symbols` now sits before the
    generic in every stack, so a face lacking `♠♥♦♣` falls back somewhere chosen rather than
    somewhere arbitrary. Same test file.

## Sources

- [The Tao of Datastar](https://data-star.dev/guide/the_tao_of_datastar) — state/behaviour doctrine
- [Datastar Pro](https://data-star.dev/pro) — Stellar CSS, Rocket, extra plugins, licence and pricing
- [understand-stellar](https://github.com/cablehead/understand-stellar) and its
  [how-to](https://github.com/cablehead/understand-stellar/blob/main/how-to.md) — Stellar token
  categories and generation pipeline
- [datastar](https://github.com/starfederation/datastar) — `patchElements.ts` for morph control
  attributes; no CSS ships with it
