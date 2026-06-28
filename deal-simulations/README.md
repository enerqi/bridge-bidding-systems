# deal-simulations

Monte-Carlo bridge deal generation for testing this bidding system. A *condition* describes a
hand/auction situation (e.g. "North opens a strong 1C, South has a game-forcing 1NT response");
random deals are generated and the matching ones kept (reject sampling); the kept deals are rendered
to HTML (BBO handviewer) or fed to stats scripts.

There are now **two engines** for this:

- **Norn (native, default)** — this bidding system ported to Odin in `odin-sims/`, running on the
  [`norn`](file:///C:/Users/Enerqi/dev/norn) hand-generation library. No `deal.exe` needed, ~2–3×
  faster, and it emits line / pretty / BBO-handviewer / full-HTML-page output directly. Verified
  identical to `deal.exe` over 20000 random deals (see "Parity" below).
- **Legacy** — Thomas Andrews' `deal` (`F:\bin\deal319`) interpreting the Tcl condition scripts in
  `tcl-sims/`. Kept as the cross-check ground truth and for ad-hoc Tcl experiments. See
  `deal-generator-notes.md`, and `~/dev/norn/deal319-reference.md` for engine internals.

## Layout

| Path | What |
|------|------|
| `odin-sims/` | the **Norn consumer** — an Odin project. `bidding/` is one package (this system's predicates + the named-scenario registry); `sim.odin` is the generator/exporter program, `parity.odin` the deal.exe cross-check. Depends on the `norn` library via an Odin collection. |
| `tcl-sims/` | the **legacy Tcl** — `deal-utils.tcl` (the ~85-proc predicate library) + ≈111 condition scripts (one situation each). |
| `run-deal.py` | legacy: run one `tcl-sims/` script → deals → HTML (handviewer iframes). |
| `regen-html-deals.py` | legacy: batch `run-deal.py` over every `tcl-sims/*.tcl`. |
| `2m-stats.py`, `55-minor-stats.py` | parse a generated `deals.txt` (line format) for distribution stats. |
| `deals.txt` | a large sample of generated deals in line format (input to the stats scripts). |
| `html/` | generated HTML pages (output of the Norn `regen-norn` recipes). |
| `parse-deal/` | a Rust line-format parser (built output gitignored). |

## Quick start (from the repo root, via `just`)

Norn (native):

```sh
just regen-norn                       # every scenario -> deal-simulations/html/<name>.html (48 deals)
just regen-norn-some 1c-any,2c-opener # just those two -> html/
just run-norn 2c-opener               # one scenario -> ./2c-opener.html
```

Inside `odin-sims/` there is its own `just` for development: `just run --scenario 1c-any -n 12`,
`just build`, `just test`, `just lint`, `just parity`. (`just ols-config` regenerates the editor's
`ols.json` for the `norn:` collection; set `NORN_HOME` if the norn checkout isn't at `~/dev/norn`.)

Legacy (deal.exe):

```sh
just regen                            # every tcl-sims script -> HTML on the web server
just run-scratch 2c-opener.tcl        # one script -> ./2c-opener.tcl.html
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

## Parity

`odin-sims/parity.odin` + `parity.tcl` are the cross-check: the Odin side generates N random deals
and a per-deal accept/reject verdict; `deal.exe` runs the equivalent Tcl over the *same* deals; the
two verdict streams must be byte-identical. Every predicate family was verified 20000/20000, and the
hand-written scenario compositions spot-checked the same way. Run via `cd odin-sims && just parity`
(then feed `parity_candidates.txt` to `deal.exe -i parity.tcl`).
