# CSS approaches, for someone who does not write CSS all day

Why this app has three stylesheets you can swap between, what the differences actually are, and what
the phrase *"tokens for the design system, element/attribute selectors for the components"* means.

No CSS knowledge assumed beyond "it makes things look a certain way". `DESIGN.md` has the findings
and the verdict; this file is the explanation underneath them.

---

## 1. The one idea everything else hangs off

A stylesheet is a list of **rules**. Every rule has two halves:

```css
button { background: green; }
/* ^^^^^^  the SELECTOR: how the rule finds things */
/*         ^^^^^^^^^^^^^^^^^^^^  the DECLARATIONS: what it does to them */
```

The declarations are boring and much the same everywhere. **The selector is the whole argument.**
Every "CSS approach" is a different answer to one question: *how does a rule find the thing it
styles?*

There are only three answers available in the language, and every framework is built from them:

| you can match on | example selector | matches |
|---|---|---|
| the **element** (the HTML tag) | `button` | every button on the page |
| a **class** you wrote in the markup | `.candidate` | `<button class="candidate">` |
| an **attribute** | `[aria-busy="true"]` | anything carrying that attribute |

That's it. The rest of this file is about which of the three you lean on, and what each choice costs.

---

## 2. The four families

### Classless (also called "semantic")

Rules match **elements**. You write plain HTML and it comes out styled.

```html
<button>Skip</button>          <!-- looks like a button already -->
```

```css
button { padding: .5rem 1rem; border-radius: 6px; background: var(--primary); }
```

Examples: **Pico** (what we vendored, as `pico.classless.min.css`), Simple.css, MVP.css.

- **Good**: your HTML has no framework vocabulary in it at all. Nothing to learn, nothing to
  maintain, nothing extra sent over the wire.
- **Bad**: you can't opt out. *Every* `<button>` gets it. Your only tool for the exceptions is
  writing another rule that overrides it — and you're overriding rules you didn't write and can't
  see. (Section 6 is about how that goes wrong.)

### Class-based components

Rules match **classes**. Nothing is styled until you ask.

```html
<button class="button is-warning">Skip</button>
```

Examples: **Bulma** (our third variant), Bootstrap.

- **Good**: explicit. A bare `<button>` and a styled one can sit side by side, and no rule ever fires
  that you didn't request. Much easier to reason about.
- **Bad**: the framework's vocabulary lives in your HTML. In this app: 28 class words across 5
  template files, plus two `<div class="select">` wrapper elements Bulma requires *structurally* (it
  styles a wrapper *around* a dropdown, not the dropdown). Change framework later and every template
  changes.

### Utility classes

Rules match classes too, but each class does exactly **one** thing, so you compose the design in the
markup:

```html
<div class="flex items-center gap-2 rounded-lg bg-white p-4 shadow">
```

Example: **Tailwind**.

- **Good**: never write a stylesheet; no dead CSS.
- **Bad**: the design *is* the markup, and it needs a build step — a tool scans your templates and
  emits only the classes you used. This app has no build step for anything (see section 7), and
  templates that assemble class names dynamically are exactly what such a scanner can't see.

### Tokens only

Not components at all — just **named values**:

```css
:root { --primary: #14564a; --radius: 12px; }
```

Examples: Open Props, **Stellar** (Datastar's own, part of Datastar Pro).

- **Good**: gives you a coherent palette/scale to build from, imposes nothing.
- **Bad**: you still write every component yourself.

This one is a *different axis*, not a rung on the ladder — you can combine tokens with any of the
three above. Which is exactly what the recommendation is about.

---

## 3. What a "token" is, and what "design system" means here

A token is a **named value you define once and refer to everywhere**:

```css
:root {                              /* :root means "the whole document" */
  --primary: #14564a;                /* define */
  --suit-heart: #cc0000;
  --topbar-h: 3rem;
}

.accel   { color: var(--primary); }        /* use */
.hcolor  { color: var(--suit-heart); }
.sidebar { max-height: calc(100dvh - var(--topbar-h) - 2rem); }
```

Two reasons this matters more than it looks:

1. **One place to change.** The app's green appears in the app bar, the buttons, the focus rings, the
   accelerator chips and the dial. It is one line.
2. **The values become a system.** Not "some green here, another green there" — a defined set of
   colours, one spacing scale, one radius, one shadow. That set *is* the "design system": the
   vocabulary the whole UI is drawn from.

A real example from this app, which also demonstrates the next section. The font picker:

```css
:root                      { --ui-font: "Open Sans", "Segoe UI", system-ui, sans-serif; }
body[data-font="mono"]     { --ui-font: "Cascadia Code", Consolas, monospace; }
body[data-font="serif"]    { --ui-font: "Iowan Old Style", Georgia, serif; }
```

Everything on the page uses `var(--ui-font)`. The picker changes **one attribute** on `<body>`, the
token re-resolves, and the whole page re-fonts. No JavaScript touches any element, and no element has
a "font class" that has to be kept in sync.

That is the shape worth internalising: **state changes an attribute → an attribute selector swaps a
token → everything using the token follows.**

> A token set only becomes a *system* when the values encode an order. Two places where this app's do
> not yet — one shadow ladder claiming several light sources, and one font token doing the job of
> three — are written up in `DESIGN.md` under *Elevation and shadow* and *Type: three roles*. Both are
> worth reading as worked examples of the difference between "we have tokens" and "we have a system".

---

## 4. "Element/attribute selectors for the components"

The recommendation in `DESIGN.md` is: **tokens for the design system, element/attribute selectors for
the components, no component framework.** Unpacked:

- **tokens for the design system** — colours, fonts, spacing, radius, shadow live as named values, per
  section 3.
- **element/attribute selectors for the components** — the actual widgets are styled by matching what
  the HTML *already is* and what state it *already carries*, rather than by classes bolted on to
  describe appearance.

Concretely, three ways state reaches CSS in this app, none of them a framework class:

**(a) The element itself.** A disclosure is a `<details>`; a modal is a `<dialog>`; a keyboard hint is
a `<kbd>`. No `class="accordion"`, no `class="modal"` — the tag says what it is, and the stylesheet
matches the tag.

**(b) An attribute expressing state.** The countdown bar's fill:

```html
<div class="timer-fill" data-style:width="$_timeLeftPct + '%'"></div>
```

The server says 63% is left; the width follows. No class churn, nothing for CSS to be told twice.

**(c) An attribute expressing a *condition*, matched by CSS.** While an answer is in flight the choice
group is marked busy:

```html
<div class="candidates" data-attr="{'aria-busy': $_answering ? 'true' : 'false'}">
```

```css
.candidates[aria-busy="true"] { /* whatever "busy" should look like */ }
```

`aria-busy` is a real accessibility attribute — screen readers use it — and it doubles as the style
hook. One fact in the markup, serving two purposes, and no second bookkeeping of a `.is-busy` class
that could drift out of step with it.

There is still a place for classes: `.candidate`, `.panel`, `.timer-fill`, `.hcolor`. The difference
is that those are **our own names for our own things** — a heart symbol is `.hcolor` because that is
what bml calls it — not a vendor's vocabulary describing how something looks. `is-warning` describes
an appearance; `.candidate` describes a thing.

---

## 5. Why this suits Datastar specifically

Datastar has no CSS opinion at all — its repo mentions no framework. But it has a shape, and some CSS
approaches fit it and some fight it.

Datastar's whole model is: **the server owns the state, and state arrives in the browser as attributes
on server-rendered HTML.** `data-attr` sets attributes, `data-class` toggles classes, `data-style`
sets styles, all from signals.

So "state → attribute → selector" isn't a clever trick here, it's the same pipeline the framework
already is. Three consequences:

1. **Nothing has to be kept in sync.** The attribute *is* the state. Compare the alternative — some
   JavaScript adding and removing `.is-busy` — and now two things describe one fact.
2. **Patches stay small and legible.** Every interaction re-sends a chunk of HTML ("fat morph"). The
   less presentation lives in the markup, the more that chunk reads as *content and state*, which is
   the property that makes view-source useful. Measured: Bulma's class words cost ~1.3KB raw per
   patch but only **~70 bytes** after compression — so the wire is not the argument. The templates
   are.
3. **No build step.** Datastar is one 34KB vendored file. Tokens plus element selectors need no
   tooling; Tailwind would reintroduce a build over the templates, in the stack whose selling point is
   not having one.

### The cautionary tale, because it cuts the other way

Classless frameworks style **elements and attributes globally**. That is the same surface datastar
uses for state. So they can collide.

This app set `aria-busy="true"` for accessibility. Pico reads `aria-busy` as *its loading component*:
it sets `white-space: nowrap` and inserts a spinner. On a grid of multi-line answer buttons, every
choice snapped to one line and its text spilled out of the box — for the two to three seconds the
toast sequence runs. It looked like the page breaking mid-answer, and only in that one variant.

The lesson worth carrying: **in a classless stylesheet, ARIA and data attributes are style hooks too.**
A class-based framework is immune to this by construction — nothing fires unless you name it.

---

## 6. Specificity, in plain terms — why an edit can do *nothing*

When two rules both apply, CSS picks a winner. Roughly: **more specific wins**, and only if they tie
does the later one win.

The rough ladder (each step beats everything below it):

1. `#an-id`
2. `.a-class`, `[an-attribute]`, `:not(...)`, `:hover`
3. `a-tag`

Two rules from this project, both of which appeared to do nothing at all:

```css
/* mine: one class + one tag */
.filter-help > summary { color: green; }

/* Pico's: one tag + one attribute-ish :not() + one tag  →  more specific, so it wins */
details summary:not([role]) { color: grey; }
```

```css
/* mine */
:root { --pico-primary: green; }

/* Pico's: a class-level :not() on top of :root  →  wins */
:root:not([data-theme=dark]) { --pico-primary: blue; }
```

No error, no warning, no visible change — the natural conclusion is "my edit was wrong", when in fact
it was simply out-ranked. Both fixes were to stop fighting:

- give the framework **its own variable** (`--pico-accordion-close-summary-color: var(--primary)`) —
  it already reads that, so no contest arises; or
- declare the tokens **one level down**, on `body`. Token values are inherited by everything inside,
  so `body` reaches every component without having to out-specify anything.

This is the hidden cost of classless CSS, and it's why `DESIGN.md` calls it "cheaper in markup, more
expensive in overrides".

---

## 7. What this app actually does

**Three complete stylesheets**, switchable live from the sidebar (*Appearance → Base CSS*, **debug
sessions only** now that Pico is the default — see DESIGN.md) with no reload and no server
involvement — one signal changes the `<link href>`:

| variant | file | what it is |
|---|---|---|
| Hand-rolled | `static/app.css` | our tokens + element/attribute/our-own-class selectors. No framework. |
| Pico classless | `static/app-pico.css` + `static/pico.classless.min.css` | a classless framework, plus an *adapter* holding everything it cannot know |
| Bulma | `static/app-bulma.css` + `static/bulma.min.css` | a class-based framework, same idea, plus class words in the templates |

An **adapter** is the second half of a framework variant: the framework styles the generic parts
(buttons, inputs, typography, dark mode), and the adapter styles everything specific to this app —
the layout, the collapsing sidebar, the score dial, the points gauge, the countdown bar, the toasts,
and the four suit colours. That last group is ~300 lines and **no framework can supply it**, which is
the single most useful number in the comparison.

Measured, counting code lines only (comments stripped, so all three are compared alike):

| | our CSS | framework file | compressed | framework words in our HTML |
|---|---|---|---|---|
| Hand-rolled | 629 | — | — | none |
| Pico | 564 | 71 KB | 9.9 KB | none |
| Bulma | 536 | 678 KB | 44 KB | 28 words, 5 files, 2 wrapper elements |

Both frameworks land within 30 lines of each other, and neither saves much, because the ~300-line core
is untouchable either way. Current verdict: **Pico, narrowly** — same size, 10× smaller download, no
vocabulary in the markup. Nothing is adopted; the picker keeps all three side by side, which is what
let the four "only visible when you play it" Pico problems be found at all.

## 8. Choosing, if you ever do this again

- **Small app, you control the markup, no build step** → tokens + element/attribute selectors. What
  `app.css` already is. Fewest moving parts, and nothing can silently claim an attribute you were
  using for something else.
- **You want ready-made components and don't mind class words in templates** → class-based (Bulma).
  Safest against collisions; the most predictable to debug.
- **You want styling for free and will accept overriding rules you can't see** → classless (Pico).
  Cheapest markup; budget time for specificity fights and for the framework having opinions about
  `<dialog>`, `<details>` and attributes.
- **Big team, design system already in Tailwind, build step exists** → Tailwind. Not otherwise.
- **Component libraries built on web components** (Shoelace, Material Web) → avoid here. They hide
  their internals in "shadow DOM", which datastar's attributes cannot reach — precisely the wall the
  Panel version of this quiz hit, and a large part of why this port exists.

---

## Glossary

| term | plain meaning |
|---|---|
| **selector** | the part of a CSS rule that decides what it applies to |
| **declaration** | one `property: value` pair inside a rule |
| **token** / custom property | a named value (`--primary: #14564a`), used as `var(--primary)` |
| **`:root`** | the whole document; the usual place to define tokens |
| **inherit** | a value passed down from an element to everything inside it — how tokens spread |
| **specificity** | how CSS decides which of two competing rules wins (section 6) |
| **classless / semantic CSS** | styles plain HTML by matching tags |
| **utility CSS** | one class per single style declaration |
| **adapter** | our stylesheet that sits on top of a framework and adds what it cannot know |
| **reset / normalize** | a small stylesheet that only flattens browser differences |
| **ARIA attribute** | an attribute conveying state/meaning to assistive technology (`aria-busy`, `aria-expanded`) |
| **fat morph** | datastar patching a large chunk of the page at once, letting the browser diff it |
| **shadow DOM** | a component's private DOM; outside CSS and outside datastar's attributes |

Further reading in this repo: `DESIGN.md` (findings and verdict, including every framework quirk that
cost adapter lines), `COMPARISON.md` (measurements and the bug list), `README.md` (architecture).
