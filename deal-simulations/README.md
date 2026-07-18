# deal-simulations

Monte-Carlo bridge deal generation for testing this bidding system. A *condition* describes a
hand/auction situation (e.g. "North opens a strong 1C, South has a game-forcing 1NT response");
random deals are generated and the matching ones kept (reject sampling); the kept deals are rendered
to HTML (BBO handviewer) or fed to stats scripts.

There are now **two engines** for this:

- **Norn (native, default)** — this bidding system ported to Odin in `odin-sims/`, running on the
  [`norn`](file:///C:/Users/Enerqi/dev/norn) hand-generation library. No `deal.exe` needed, ~2–3×
  faster, and it emits line / pretty / BBO-handviewer / full-HTML-page output directly. The port was
  verified identical to `deal.exe` over 20000 random deals (the parity harness used for that has since
  been retired — the port is done).
- **Legacy** — Thomas Andrews' `deal` (`F:\bin\deal319`) interpreting the Tcl condition scripts in
  `tcl-sims/`. Kept for posterity / ad-hoc Tcl experiments.

## Layout

| Path | What |
|------|------|
| `odin-sims/` | the **Norn consumer** — an Odin project. `bidding/` is one package (this system's predicates + the named-scenario registry); `sim.odin` is the generator/exporter program. Depends on the `norn` library via an Odin collection. |
| `tcl-sims/` | the **legacy Tcl** — `deal-utils.tcl` (the ~85-proc predicate library) + ≈111 condition scripts (one situation each), plus the `run-deal.py` / `regen-html-deals.py` runners. |
| `tcl-sims/run-deal.py` | legacy: run one `tcl-sims/` script → deals → HTML (handviewer iframes). |
| `tcl-sims/regen-html-deals.py` | legacy: batch `run-deal.py` over every `tcl-sims/*.tcl`. |

## Quick start (from the repo root, via `just`)

Norn (native):

```sh
just regen-norn                       # every scenario -> deal-simulations/html/<name>.html (48 deals)
just regen-norn-some 1c-any,2c-opener # just those two -> html/
just run-norn 2c-opener               # one scenario -> ./2c-opener.html
```

Inside `odin-sims/` there is its own `just` for development: `just run --scenario 1c-any -n 12`,
`just build`, `just test`, `just lint`. (`just ols-config` regenerates the editor's
`ols.json` for the `norn:` collection; set `NORN_HOME` if the norn checkout isn't at `~/dev/norn`.)

### Analyse a real hand (photo / PBN → interactive advisor)

Separate from the scenario generator, `odin-sims/` turns any deal into an interactive card page. Give it a
**declarer + dummy** (two hands, defenders unknown) and it acts as a **2-hand advisor** — how likely each
contract is to make (from sampling the unknown defenders), the best line per suit, and where a blind guess
costs you. Give it a **complete four-hand deal** and it shows the **exact double-dummy** result (par + what
each side can make) plus the per-suit CCA tables. Run these from inside `odin-sims/`:

```sh
# From a PHOTO/screenshot of a hand diagram (uses the sibling hand-ocr project):
just ocr-analyse hand.png                 # -> hand.html  (open it in a browser)
just ocr-pbn hand.png                     # just print the recognised PBN, don't analyse

# From a PBN deal you already have (a string, a file, or piped in):
just analyse-pbn --sample 400 '[Deal "N:AKQ32.AK2.A32.A32 - Q.QJT98.KQJ.KQJT -"]'
just analyse-pbn --sample 400 --file board.pbn --html out.html
```

A **PBN** deal either marks the two unknown defender hands with `-` (the declarer+dummy advisor case) or
lists all four hands (the exact double-dummy case) — the tool picks the right mode per board. A standard
multi-board `.pbn` file works too — every `[Deal]` tag becomes one board in a
carousel; the other tags (`[Board]`, `[Dealer]`, …) are ignored. **LIN files are not read** (LIN can only
express a complete four-hand deal; use PBN). The card page has a built-in **Help "?"** button explaining
every number in plain terms. A real photo needs hand-ocr's vision extra once: `(cd "$HAND_OCR_DIR" && just
sync-vision)` (hand-ocr is a separate sibling repo; `HAND_OCR_DIR` defaults to `~/dev/bridge-hand-ocr`).

Legacy (deal.exe):

```sh
just _py-regen                        # every tcl-sims script -> HTML on the web server
just _py-run-scratch 2c-opener.tcl    # one script -> ./2c-opener.tcl.html
```

## Condition idiom (legacy Tcl)

Every script in `tcl-sims/` is the same shape — source the helpers, then a `main { }` body run once
per random deal (reject sampling):

```tcl
set script_path [file dirname [file normalize [info script]]]
source $script_path/deal-utils.tcl

main {
  if {![is_strong_1c north]} { reject }                        ;# opener
  if {[hcp south] < 8 || ![has_side_major south]} { reject }   ;# responder relationship
  accept
}
```

The Norn port mirrors each script's `main` body as a `norn.Predicate` over a whole `Deal`, collected
in the `bidding` package's scenario registry (`odin-sims/bidding/scenarios.odin`). The scenario
`name` matches the `.tcl` basename so the two corpora stay diff-able. **109 of 111** scripts are
ported; `scratch.tcl` (a dev scratchpad) and `slam-hands-mixed.tcl` (uses `rand()` inside the
predicate, so it isn't a deterministic condition) are intentionally not.

Properties that made the port faithful:
- **Pure reject sampling.** No script uses predeal, `stack_*`, `smartstack`, or double-dummy
  (`tricks`/`dds`) — a plain generate-and-test loop is an exact replacement.
- **Multi-seat conditions are common** — many test North (opener) *and* South (responder),
  occasionally East/West (fit, combined hcp). Norn predicates take the whole `Deal`, not one hand.

The port was validated against `deal.exe` with a parity harness (generate the same deals on both
sides, diff the accept/reject verdict streams; verified 20000/20000). That harness has been retired
now the port is complete; `tcl-sims/` is kept for posterity should a re-check ever be wanted.
