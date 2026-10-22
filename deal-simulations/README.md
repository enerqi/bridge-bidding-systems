# deal-simulations

Monte-Carlo bridge deal generation for testing this bidding system. A *condition* describes a
hand/auction situation (e.g. "North opens a strong 1C, South has a game-forcing 1NT response");
random deals are generated and the matching ones kept (reject sampling); the kept deals are rendered
to HTML (BBO handviewer) or fed to stats scripts.

## The simulator moved: Bridge Workbench

The current engine - this system's scenarios ported to Odin on the [`norn`](https://github.com/enerqi/norn)
library, the `sim` generator, the single-deal advisor and the desktop workbench - lived in `odin-sims/` here
until 2026-10-22. It is now its own repository, **[enerqi/bridge-workbench](https://github.com/enerqi/bridge-workbench)**
(`~/dev/bridge-workbench`), history included. The `w:/deals` regeneration recipes went with it, since they are
its command line:

```sh
# from the bridge-workbench checkout
just gen-all-cards        # every scenario as a card page -> $DEALS_OUTPUT_DIR/<name>.html (default w:/deals/)
just gen-some 1c,2c       # just those two
just gen-one 2c           # one scenario -> ./2c.html (the dir you invoked just from)
just --list               # everything else
```

The workbench reads these notes (its notes editor, its quiz button, its corpus tests) but nothing here builds
against it.

## Legacy: deal.exe + Tcl (`tcl-sims/`)

What is left here is the older engine: Thomas Andrews' `deal` (`F:/bin/deal319`) interpreting the Tcl
condition scripts in `tcl-sims/`. No longer the simulator; kept as the historical cross-check the Odin port
was verified against, and for ad-hoc Tcl experiments.

| Path | What |
|------|------|
| `tcl-sims/` | `deal-utils.tcl` (the ~85-proc predicate library) + ≈111 condition scripts (one situation each), plus the runners below. |
| `tcl-sims/run-deal.py` | run one `tcl-sims/` script → deals → HTML (handviewer iframes). |
| `tcl-sims/regen-html-deals.py` | batch `run-deal.py` over every `tcl-sims/*.tcl`. |

From the repo root:

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
in the workbench's `bidding` package's scenario registry (`bidding/scenarios.odin` there). The scenario
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
