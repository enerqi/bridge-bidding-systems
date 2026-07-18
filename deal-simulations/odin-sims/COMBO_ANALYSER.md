# `combo` — naive card-combination analyser — handoff notes

Per-suit **trick-chance tables** for the North-South pair + a combined **P(≥ target tricks)**, shown
next to the DDS par as a make-chance guide. Source doc: `Naive card combination analyser.md`.
Inspiration: <https://bridge.esmarkkappel.dk/main/main.html> (a much simpler version of it).

> ## ★★ NEXT-SESSION HANDOFF (2026-07-16)
>
> The 2-hand advisor + the image/PBN pipeline are feature-complete. This session shipped: misguess-tax
> **(2b) joint-compounding** + **Ten..King geometry** + same-suit; **golden test** (`just test-golden`,
> pins `data-sim` + `data-sim-guess`); **Option C1** narratable guess clause in the per-suit tooltip;
> the **hand-ocr pipeline** (`just ocr-analyse`/`ocr-pbn`, `tools/ocr-analyse.sh`); a **`parse_boards`
> `[Dealer]`/`[Declarer]` false-match bugfix**; **4-hand (Stage B1)** exact-DD deals; the **exact-DD
> contract explorer (Stage B2)** on full deals; and the README
> **layman quickstart (Stage C)**. Tests: combo 41, dd 25, norn 97; lints + golden clean. See the dated
> sections below (search "DONE 2026-07-16").
>
> **NEXT (pick up here), in priority order:**
> 1. **Stage B2 — DONE 2026-07-16.** Full 4-hand deals now drive a live EXACT double-dummy explorer:
>    `dd.exact_grid(deal)` builds a `Grid_Result` spiked at each strain's NS DD trick count (n=1);
>    `render_full_deal_body` bakes it via `write_exact_sim_json` (`{n:1,exact:true,lvl,strain,g}`,
>    preselecting NS's best-making contract) onto a hidden `.sim-exact` div — dd.annotate owns `.par`, so
>    the grid rides its own element and render.odin now reads `el._sim` from any `[data-sim]` in the slide.
>    `simBand` gates on `sim.exact`: "Double-dummy (exact): N♠ makes/fails", no ±/deal-count, no tax rung,
>    recon says "double-dummy" not "simulated". 2-hand path untouched (browser-verified both). Test
>    `test_exact_grid_spikes` (dd 25). See "Stage B2" DONE section below.
> 2. **Fuller layman USER GUIDE (Stage C+).** The README "Analyse a real hand" quickstart is in; a
>    standalone `USING.md` (screenshots of the card page, what each row/colour/band means in plain terms,
>    the photo workflow) would help non-devs. The in-app Help "?" modal already covers the numbers. Low
>    urgency — only if a real end user needs onboarding.
> 3. **Misguess-tax fallbacks #2/#3** (analytic estimator / full PIMC) — only if the tax proves too crude
>    on real boards. **Option C2 (reference library) / C3 (entry model)** stay demoted (DDS covers realism).
>
> **Verify commands:** `just lint`, `just test-combo` (41), `just test-dd` (25, ~3 min single-thread),
> `just test-golden`, `just ocr-analyse --demo` (pipeline plumbing). Browser: serve a page via
> `python -m http.server` (file:// is blocked) + playwright. **Uncommitted at handoff** (user manages
> commits): norn `render.odin`; odin-sims `dd/tax*.odin`, `dd/sample*.odin`, `pbn_analyse.odin`, `justfile`,
> `tools/ocr-analyse.sh`, `tests/golden*`, this doc; `deal-simulations/README.md`.

**Phase 1 AND Track 1 (the interactive client-side redesign) are DONE** — built, vetted, tested, wired,
and eyeballed in-browser. **Phase 2 (real single-dummy lines) is COMPLETE — all four bricks built + tested:** brick 1 (fixed-line
evaluator, `combo/single_dummy.odin`), brick 2 (candidate-line generator + Pareto/best-line,
`combo/lines.odin`), brick 3 (optimal single-dummy SEARCH, `combo/single_dummy_opt.odin`), brick 4
(objective layer + combination DP, `combo/combine.odin`). 37 combo tests pass, lint clean. **NB while
building brick 3 a Phase-1 overcount bug was found + fixed** (running suits; see "Phase-1 bug fixed"
below). **PROPER JOINT MODEL now DONE (2026-07-04):** the independent per-suit convolution is replaced by
a constrained joint convolution (`suit_joint_table` + `joint_total`, East holds 13 / tricks capped at 13);
`analyse_ns` and the card page (baked `data-*-tot`/`-totsd`) use it — see the joint-model DONE item under
TODO. **FULLY WIRED into the card page** (`combo.annotate` Html_Cards + norn `render.odin`):
- `combo.annotate` emits SIX JSON blobs on the `.combo` div, for BOTH partnerships (the page flips
  N/S↔E/W): `data-{ns,ew}` = per-suit census `p[k]` (ceiling), `data-{ns,ew}-sd` = per-suit achievable
  single-dummy line (`write_suits_json_sd`, now the brick-2 `best_line_by_mean` — fast + coherent with
  the DP, not brick-3 which only helps rare long suits), `data-{ns,ew}-atl` = the **adaptive P(≥t) make
  curve** (`adaptive_at_least_curve` = brick-4 residual-target DP, `write_curve_json`).
- The CCA overlay shows the double-dummy CEILING vs single-dummy ACHIEVABLE: per-suit rows + black
  `tot`/`≥k` (census), blue `sd` row (achievable shape), blue `≥sd` row = the **adaptive-optimum
  P(≥k)** (brick-4). Headline `P(≥ t): DD X% · SD Y%` (SD from the curve); inline one-liner shows the
  analysed side + DD/SD + `E[tot] dd/sd`.
- **Per-suit blind numbers + recommended line** (added on request): each suit row's `E` column shows
  `double-dummy / blind` expected tricks (the blue blind figure = `etr` of the per-suit `data-*-sd`),
  and a `line` column names the recommended blind play (`data-{ns,ew}-lines` = `best_line_by_mean`'s
  name per suit → `cash`/`finesse`/`duck`). Directly shows the per-suit tax (e.g. ♦ 0.5/0.1 finesse =
  offside most layouts). The label is a SIMPLIFIED single pick from the 3 heuristic lines — it can't
  express a compound line (e.g. "duck then finesse"); the help says so ("the general idea, not an exact
  recipe"). **Hovering the line word** shows a fuller, cards-specific narration (`data-{ns,ew}-tips` =
  `describe_suit_line` per suit, e.g. "Cash your winners from the top: A K Q J 10 9. After those, the
  opponents 8 and lower take the rest." / "Lead a low card toward your A, then finesse: play the Q…").
  Rendered as a fixed dark tooltip (`.cca-tip`, delegated mouseover); holding-aware but still narrates
  only the ONE chosen heuristic. NOTE per-suit `E`s still may not sum exactly to `tot E` — the free-entry
  per-suit model can over-credit tricks within one deal, and the joint total caps the running trick count
  at 13. The LENGTH independence is now fixed by the constrained joint convolution (2026-07-04); only the
  free-entry over-count (which the cap absorbs) remains. See the joint-model DONE item below.
- **N/S ↔ E/W toggle** and **IMPs ↔ MPs objective toggle** (2 button-pairs in the CCA head) + a
  **Help "?"** modal (layman's terms: table, ceiling-vs-realistic w/ swatches, slider, N/S vs E/W, IMPs
  vs MPs, small print). Fixed a blue-on-blue unreadable highlight (`.ct td.hl` now out-specifies the SD
  rows).
- **IMPs vs MPs** is computed CLIENT-SIDE off the adaptive `≥k` curve (`atl`), no contract/vul/field
  input needed: IMPs → play for the slider target (safety, maximise make); MPs → chase overtricks while
  better-than-even, i.e. aim for the highest `k ≥ target` with `atl[k] ≥ 0.5`. The headline + highlighted
  column follow the objective (target under IMPs, the overtrick "aim" under MPs). `combine.odin` has the
  library objectives (`objective_imps` = at_least; `objective_matchpoints(field)` — the full field-based
  MP eval, for a future server-side version). Verified (playwright): NS board 1 IMPs make-10 SD 100% →
  MPs aim-12 SD 81% (chases 2 overtricks, both >50%); target-11 board DD 84.3%/SD 24.9%; E/W flip + help.

## What it computes (read this — it is the most-misread part)

For each of the 4 suits, given NS's known cards, the opponents' cards split unknown between E/W. The
tool enumerates **every** E/W split, solves each **double-dummy** (all cards visible, best-play vs
best-defence minimax), weights by the a-priori split probability, and **tallies**:

> `p[k]` = weighted fraction of E/W layouts whose double-dummy result is exactly `k` tricks.

It is a **census of per-layout optima, NOT a line you play**. Each tally entry is optimal play *for
that layout*; the spread over k comes from the layout varying, not from anyone misplaying. So it
**upper-bounds** "how often I really take k" — a real declarer commits to one blind line and does
worse. Read `p[k]` as "how often are k tricks even *available* double-dummy", not "how often I'll
make k". (Full explanation in the `combo.odin` header — the `WHAT p[k] IS` and 3-assumptions sections.)

### The three "naive" assumptions

1. **Free entries** — declarer leads every trick from either hand at will; defenders only follow. This
   is why suits can be solved in isolation, and why a normal DDS solve (which respects entries) can't
   be used. Model: `DECLARER LEADS EVERY TRICK` (includes ducking; does not gift declarer a defender lead).
2. **Suit independence** — the 4 suits are combined by convolution (add tricks); no squeezes/discards.
3. **Perfect information (double-dummy)** — per layout, all 4 hands face-up. Cuts both ways: declarer
   never misguesses a finesse (optimistic for NS), defence never misdefends (pessimistic — e.g. `Q985`
   opp stiff `K` reads ~1 trick because best defence nails the ace-timing every layout it can). Also
   **no contract in view**: defenders just minimise *that suit's* tricks — no "take it or it runs",
   no "duck to beat the contract". Par (`dd`) shares assumption 3; combo drops entries + interaction on top.

**TEMPO caveat (why the TOTAL reads high — the practically important one).** Assumptions 1+2 let NS take
all its tricks *without ever surrendering the lead*. Real play is a race: developing tricks usually means
**losing the lead first** (a failing finesse, an early duck), and the moment the defenders are in they
**cash their own winners** — possibly beating the contract before NS runs its suits. A defender ace in the
4th suit IS counted as a defender trick in that suit (NS isn't credited it), but the model never lets it be
cashed *in tempo* while NS develops — the cross-suit race doesn't exist here. So the summed total is an
**upper bound that doesn't know who gets in first** ("13 tricks" can really be fewer). This is a MODEL
property (entries + independence), NOT the vacant-space weighting — the joint-convolution fix does **not**
address it; only whole-deal play (`dd` par) does. When combo and par disagree on the total, **par wins**.
Surfaced to users in the CCA help "?" modal's small print (norn `render.odin`).

## Where the code lives

New **solver-free** package (no DDS dep) in `odin-sims`; composed with `dd` at the `sim.odin` layer.

| File | What |
|------|------|
| `odin-sims/combo/combo.odin` | **All the work.** `suit_dd_tricks`/`play_card` (single-suit minimax, memoised on the 4-mask `Suit_Layout`), `dd_tricks` (public single-layout probe), `Suit_Joint_Table`/`suit_joint_table` (per-suit `count[east_len][tricks]`) + `marginal_from_table` + `joint_total` (the CONSTRAINED joint convolution) + `suit_trick_distribution` (now a marginal wrapper), `sd_joint_total` (achievable SD total), `convolve` (legacy/field only), `analyse_ns`/`analyse_deal_ns`, `p_at_least`, `expected_tricks`, `format_analysis` (text table), `annotate` (the `norn.Deal_Annotator`, bakes `data-*-tot`/`-totsd`). `g_binom` Pascal table via `@(init)`. Extensive header docs. |
| `odin-sims/combo/combo_test.odin` | 9 tests: minimax on known layouts (AKQ→3, AK-opp-xx→2, AQ finesse on/offside→2/1, void→0), distributions sum to 1, solid/void/whole-suit certain, finesse two-sided, combined normalised + monotone tail. |
| `odin-sims/combo/joint_test.odin` | **Joint-convolution coverage (rewritten 2026-07-04).** 4 tests pinning `joint_total`: per-suit marginal is exact hypergeometric (unchanged by the joint fix); a mirror-length deal keeps `total` normalised with `E[tot]` == Σ per-suit means (cap never bites → linearity); a constructed deal (N=all spades, S=all hearts) forces two suits to share East's 13-card budget and caps 26→13, giving a Vandermonde-exact point mass at 13 (`test_joint_length_constraint_and_cap`); a strong deal stays normalised but E[tot] < Σ per-suit means (the residual free-entry over-count the cap absorbs, `test_strong_deal_is_capped`). |
| `odin-sims/combo/single_dummy.odin` | **Phase 2, brick 1 (DONE).** The FIXED-LINE single-dummy evaluator. `Sd_Line` (a blind declarer strategy = `lead` + `partner` procs, choosing cards from PUBLIC info only; `lead` and `Sd_View` carry a 0-based `trick_no` so PHASED/compound lines can switch behaviour round by round — added for Option A), `Sd_View` (declarer-visible state, excludes the E/W split), `sd_deal_tricks` (play one layout out, declarer forced by the line, defenders double-dummy min — `sd_from_lead`/`sd_trick`, both threading `trick_no`), `sd_line_distribution` (enumerate splits like Phase 1, vacant-space weights → real achievable `Suit_Trick_Dist`), `sd_census_gap` (line mean vs Phase-1 census mean = the "double-dummy tax"), and one shipped reference line `line_top_down` (cash highest, partner low — not optimal, a baseline). Header explains why scoring a FIXED line is exact/cheap while the optimal-line SEARCH is the hard next piece. |
| `odin-sims/combo/single_dummy_test.odin` | 6 tests: top-down solid→3 / two-tops→2 exact, dist sums to 1, `sd_mean ≤ census_mean` (tax ≥ 0) over several holdings, top-down leaves the AQ-opp-xx finesse (gap > 0.35), a bespoke finesse line recovers ~all the census there (residual tax = the cash-first singleton-K drop it forgoes). |
| `odin-sims/combo/lines.odin` | **Phase 2, brick 2 (DONE) + Option A compound lines (DONE).** The candidate-line generator, now FIVE `Sd_Line`s. Beside `line_top_down`: `line_finesse` (lead low toward the honour hand; partner inserts the cheapest card beating RHO — finesse/cover, via `rho_rank`), `line_duck_one` (concede round 1, then cash), plus the Option-A additions `line_finesse_other` (the finesse the OTHER way — lead toward the weaker honour hand; distinct guess on a two-way, dedups into `line_finesse` when one-way) and `line_duck_then_finesse` (COMPOUND/phased: `trick_no==0` duck both hands, `trick_no>=1` finesse — the canonical entry-preserving manoeuvre). Shared building blocks `finesse_lead_toward`/`finesse_insert`/`strong_honour_seat`. `Line_Result`, `candidate_lines` (→ `[5]Sd_Line`), `suit_candidate_lines` (score all on a holding), `pareto_lines` (drop dominated + de-dup clones on the P(≥k) tail — `line_dominates`/`dist_near_equal`), `best_line` (max P(≥target), tie→mean). NOTE brick 1's `sd_trick` gained a `last_rank` param so the finesse partner sees the RHO's actual card. |
| `odin-sims/combo/lines_test.odin` | 8 tests: every candidate is a distribution; `line_finesse` beats `line_top_down` on AQ-opp-xx (P(≥2) + mean); `best_line(target=2)` picks the finesse; the Pareto frontier is non-empty + internally non-dominated; it collapses to 1 line on a solid AKQ; **Option A:** the two compound lines are registered; `line_finesse_other` is a distinct, worse distribution on a one-way AQ (finesses the wrong way); `line_duck_then_finesse` still takes all 3 on a solid AKQ (the duck cannot be overtaken). |
| `odin-sims/combo/single_dummy_opt.odin` | **Phase 2, brick 3 (DONE).** The OPTIMAL single-dummy search — partial-observability minimax over declarer's belief. Declarer nodes pick ONE card per info set (`opt_solve`/`opt_trick`, no strategy fusion); defender nodes (`opt_defender`/`assign_rec`) do an exact assignment-min over which card each world plays, pooling worlds by observed rank (captures **false-carding**). Returns a trick-DISTRIBUTION `Vec` (max/min on its mean) so brick 4 can re-score under other objectives. `canonical_plays` collapses card-equivalent choices (both sides); a **transposition memo** (`opt_key`, keyed on the weighted world-set) makes it ~1000× faster (37s→11ms on a 10-card two-way). `sd_optimal_distribution`/`sd_optimal_expected_tricks` return `(dist, exact)`; on budget/`ASSIGN_CAP` overflow (short holdings, many missing) it falls back to brick-2 `best_line_by_mean` with `exact=false`. |
| `odin-sims/combo/single_dummy_opt_test.odin` | 4 tests: running suit AKQJT9/87654 = exactly 6 (== fixed census); best-candidate ≤ optimal ≤ census on a two-way holding; a genuine two-way queen guess (AJ975/KT864) has optimal STRICTLY < census (0.11, the blind guess); a short holding overflows and falls back to a valid distribution. |
| `odin-sims/combo/combine.odin` | **Phase 2, brick 4 (DONE) + joint adaptive DP (2026-07-04).** The objective layer + combination DP. `Objective` = a weight vector `w[t]`; constructors `objective_at_least`/`_imps`/`_expected_tricks`/`_matchpoints(field)`. `apply_objective` scores a total. **INDEPENDENT primitives** (per-suit marginals, synthetic-hand-safe): `best_fixed_combination` (exhaustive one-line/suit → `Line_Combination`), `dp_value`, `gather_candidates`, `convolve`. **JOINT (whole-deal) path** (length-constrained, full hands): `Line_Joint`/`gather_candidate_tables` (per-line `sd_line_joint_table`), `dp_value_joint` (residual-target DP + East-length axis), `optimal_adaptive_value` and `adaptive_at_least_curve` (the card page's `data-*-atl`). Candidates from brick 2. |
| `odin-sims/combo/combine_test.odin` | 5 tests: `apply_objective(at_least)` == P(≥target) tail + total sums to 1; the DP picks the spade finesse when target 11 needs the extra trick; best combination beats all-top-down; adaptive ≥ fixed always and == fixed for the linear E[tricks] objective; matchpoints value in [0,1]. |
| `odin-sims/sim.odin` | `import "combo"`; `dd_and_combo_annotate` (calls `dd.annotate` then `combo.annotate`); registered for scenario `1major-game-force`. |
| `odin-sims/justfile` | `lint` checks `combo`; `just test-combo` runs its tests. |
| `norn/norn/render.odin` | **Lib changes.** (Phase 1) carousel grouping generalised to grab EVERY sibling up to the next `.compass`; `.combo` CSS folded under the Par toggle. (Track 1) client-side combo: JS `convolve`/`comboTotal`/`tail`/`ctTableHTML`/`comboLine`, the **CCA overlay** (`.cca-panel` + `renderCca`/`hlCca`/`setCca`, wired into `show`), the toolbar **CCA button**, keydown guard for focused inputs, and `<meta charset="utf-8">`. Inline `.combo` is a one-line summary; the full `.ct` table + the **per-board target slider** live in the overlay footer (`nc-cca-target`, defaults from the board's `.par[data-target]`). (Joint model 2026-07-04) `side()` now prefers the **baked joint totals** `data-*-tot`/`-totsd` over `comboTotal`; `convolve`/`comboTotal` demoted to a fallback for old pages. |
| `odin-sims/dd/dd.odin` | (Track 1) `ns_par_target_tricks` + `data-target` on the `Html_Cards` `.par` div — the NS par trick count that seeds each board's combo slider default. |

## Architecture (the pipeline)

1. **`suit_dd_tricks(layout, memo)`** — max NS tricks in one suit, one fully-known layout, minimax
   (we maximise, defenders minimise, declarer always leads). Memo keyed on the 4-hand `[4]u16`
   because the position value depends only on the four holdings (declarer always regains the lead).
2. **`suit_trick_distribution(north, south)`** — submask-enumerate the missing cards as East's holding
   (2^m, m≤8), solve each, weight by `C(26-m,13-a)/C(26,13)` (vacant spaces, 13/13), normalise → `p[]`.
3. **`analyse_ns` / `convolve`** — fold the 4 per-suit `p[]` into the total (point-mass-at-0 seed).
   `p_at_least(target)` = tail sum. Only ONE line per suit here (the DD max), so the "best combination
   of lines" reduces to plain convolution — the interesting multi-line choice is Phase 2.

Seat indices `SEAT_N/E/S/W = 0/1/2/3` match `norn.Seat`. Suit holding `u16` bit `r` = rank `r`
(Two=0..Ace=12) = exactly `norn.Hand_Summary.suits[suit]`, so NS masks drop straight in.

## Output / wiring

`combo.annotate` emits for **Html_Handviewer** (static `<pre>` text table under the board), **Html_Cards**
(raw per-suit `p[k]` as JSON on a `.combo` sibling — TWO blobs: `data-suits` = Phase-1 census ceiling,
`data-suits-sd` = Phase-2 achievable optimal single-dummy; the norn card page convolves both and renders
the DD-vs-SD table interactively, see Track 1 + the header-status "WIRED" note), and **Pretty** (static
text table). Machine formats (Line/Numeric/Handviewer/Pbn) emit nothing. Text formats pass `target=0` → no highlighted
make-line, the `>=k` row lets the reader read off any level; the card page makes the target a slider.

Text table (Handviewer/Pretty) = one row/suit of P(exactly k)%, an `E[tr]` mean column, then `tot`
(combined) and the `>=k` cumulative tail. The card page's client-side `.ct` table mirrors this layout.

### Dev / test commands (this session)

```
cd deal-simulations/odin-sims
just test-combo                       # 41 combo tests (Phase 1 + Phase 2 bricks 1-4 + Option A + joint model)
just test-dd                          # 11 dd tests (DDS-sampling; forced single-thread — DDS not reentrant)
just lint                             # bidding + combo + dd + sim + pbn_analyse
odin build sim.odin -file -collection:norn=~/dev/norn -collection:dds=~/dev/odin-dds -o:speed -out:target/release/sim.exe
./target/release/sim.exe -S 1major-game-force -n 3 -f pretty --dd --seed 42     # see dd par + combo table
./target/release/sim.exe -S 1major-game-force -n 3 -f html-cards --dd --seed 7 -o out.html
# 2-hand advisor (declarer + dummy). Sampling needs the dds collection (the recipe links it):
just analyse-deal --sample 400 '[Deal "N:AQJ2.AKQ.AKQ.J32 - 543.432.432.AKQ4 -"]'          # text, auto-contract
just analyse-deal --sample 400 --html out.html '[Deal "N:... - ... -"]'                     # interactive page
just analyse-deal --sample 400 --contract 4S --void E:H --lead W:AC '[Deal "N:... - ... -"]' # conditioned (single board)
just analyse-deal --file session.pbn --sample 400 --html out.html                           # multi-board carousel
just analyse-deal 'https://play.intobridge.com/hand?lin=...'                                # paste a BBO/IntoBridge hand URL (LIN)
```
**Playwright verify gotcha:** playwright blocks `file://`. Serve the html:
`python -m http.server 8733 --directory <dir>` then navigate `http://127.0.0.1:8733/…`. Verified this
session: each slide = `[compass, par, combo]`, 0 orphans, Par toggle hides `.combo`.

## TODO — next phase

- [x] **Interactive redesign (the big one) — DONE (Track 1).** Distributions now emit **client-side**:
      `combo.annotate` for `Html_Cards` writes ONLY the raw per-suit `p[k]` arrays as a `data-suits`
      JSON blob (`write_suits_json`/`write_prob` in `combo.odin`); nothing baked. The card page's script
      (`render.odin`, norn lib) convolves them, and a **"tricks ≥" range slider** (per board, in the CCA
      popup — see below) drives a live `P(≥ target)` (highlighted target column + headline).
      `suit_trick_distribution → p[]` stayed the
      seam — only `format_analysis`(text formats) vs JSON(cards) diverged. **UX (per user):** the board
      is vertically tight, so INLINE the `.combo` is just a one-line summary (`CCA  P(≥t)=… · E[tot]=…`);
      the full per-suit table lives in a **CCA overlay panel** — a `position:fixed` drawer (out of page
      flow, so the page never gains a scrollbar; the table fits its natural size, no internal scroll in
      practice), toggled by a **CCA** toolbar button, showing the ACTIVE board and re-rendering on nav.
  - **Target is PER BOARD, defaulting to that board's NS par trick count.** `dd.annotate` tags the
    `.par` caption with `data-target="<tricks>"` (`ns_par_target_tricks`: a MAKING NS-declared par
    contract's level+6, else NS's best makeable strain — handles EW-sacrifice pars); the card page reads
    it per board (`el._target`, fallback 9). The **slider lives at the BOTTOM of the CCA popup beside the
    `P(≥ n tricks)` headline** (not the toolbar); it adjusts ONLY the active board and follows the board
    on nav. Arrow-key nudgeable when focused (keydown guard yields to focused inputs; else arrows drive
    the carousel). Also fixed: `<meta charset="utf-8">` in both HTML page headers (suit glyphs were
    mojibake over http). Target-from-par is now the DEFAULT. **Selectable line/suit still TODO** → Phase 2.
  - **Panel placement (`positionCca`, JS)** — natural content size, anchored BOTTOM-LEFT. The `.ct`
    table is a CONSTANT width across boards (cells are `box-sizing:content-box` + `min-width:3ch/5ch`, so
    a `"100"` cell and a `"·"` cell floor to the same size) → the panel never resizes as you flip slides,
    and no width/height overrides means no forced internal scrollbar. On wide screens the centred board
    leaves a left gutter so bottom-left already clears the (centred) par/combo captions; as the screen
    narrows the board slides left under the panel, and once the panel would COVER a caption it is LIFTED
    to sit just above it (over the felt) — par score stays visible. (Earlier gutter/below-board branches
    were removed: they resized the panel per slide and spawned an ugly internal scrollbar.) NOTE
    `positionCca` must run AFTER the slide's `scale(0.9→1)` transition settles — measuring the par caption
    mid-transition drifted the panel per board / clipped par. So `renderCca(pos)` splits rebuild from
    placement: NAV (`show`) rebuilds now but positions once via `setTimeout(…, 380)` (`ccaPosT`), while
    the no-transition callers (opening the panel, resize) pass `pos=true` to place immediately.
- **Phase 2 — single-dummy LINES (the real "best combination of plays").** Phase 1 has one line
      per suit (the DD max, a census). The doc's actual ask — finesse vs safety-play trade-offs, "best
      line to make the total" — is a **single-dummy** problem: pick ONE blind strategy per suit, evaluate
      across layouts → a real distribution; then a **DP over candidate lines per suit** maximising the
      objective (residual-target DP = adaptive optimum). Built in bricks:
  - [x] **Brick 1 — fixed-line evaluator (DONE).** `combo/single_dummy.odin`: score ANY hand-given
        blind line (`Sd_Line`) exactly across all layouts with double-dummy defence → a real
        `Suit_Trick_Dist`; `sd_census_gap` reports the double-dummy tax vs Phase 1. This is exact and
        cheap because a FIXED line has no hidden-info coupling (each layout plays out independently, the
        line is self-consistent as one pure function of public cards). Shipped one baseline line
        (`line_top_down`); 6 tests. This is the scoring oracle every later brick calls.
  - [x] **Brick 2 — candidate-line generator (DONE).** `combo/lines.odin`: generic `line_finesse`
        (lead low toward the honour hand, partner inserts cheapest card beating RHO) + `line_duck_one`
        (concede round 1 then cash) beside `line_top_down`; `suit_candidate_lines` scores all,
        `pareto_lines` keeps the non-dominated frontier on the P(≥k) tail, `best_line` picks the max
        P(≥target). 5 tests. Still generic heuristics, NOT the per-holding optimum (that's brick 3). Next
        candidates to add when useful: finesse from the OTHER side (two-way), deeper ducks, safety plays.
  - [x] **Brick 3 — optimal-line SEARCH (DONE).** `combo/single_dummy_opt.odin`: partial-observability
        minimax — declarer picks one card per belief (no strategy fusion), defenders do an exact
        assignment-min pooling worlds by observed rank (models false-carding). Card-equivalence +
        transposition memo keep it tractable; EXACT only when NS holds most of the suit (few missing) —
        else it falls back to brick-2 `best_line` (`exact=false`). Returns a distribution so brick 4 can
        re-score it. Verified: two-way queen guess AJ975/KT864 → optimal 4.89 < census 5.0 (the blind
        guess). **Objective:** currently mean tricks (max/min key); brick 4 generalises to `U` (below).
        Known limit: short holdings (many missing) overflow → fallback; a golden/perf pass could raise
        the exact ceiling (better pruning, alpha-beta on the mean, tighter equivalence).
  - [x] **Brick 4 — objective layer + residual-target DP (DONE).** `combo/combine.odin`: `Objective`
        = a weight vector `w[t]`, so every goal (make / E[tricks] / matchpoints-vs-field) plugs in as
        DATA. `best_fixed_combination` (one line/suit, exhaustive) gives a reportable line-per-suit +
        total dist; `optimal_adaptive_value` is the residual-target DP (adaptive optimum ≥ fixed). 5
        tests. IMPs `objective_imps(contract, vul)` not yet added (needs a score table) — the seam is
        ready (`objective_*` constructor returning `w`).

  **Phase 2 is now COMPLETE (bricks 1–4).** Remaining is WIRING, not new theory — see below.
  - **Objective-function factoring (design note — do this from the start).** The DP must NOT hardwire
    `P(total ≥ target)`. That tail sum is only ONE objective — a rough IMPs/"just make it" proxy. The
    right play depends on the SCORING, because the utility of the whole trick distribution changes shape:
    - **IMPs / rubber → maximise `E[score]`.** Making is a big cliff (game/slam + vul bonuses),
      overtricks worth little, undertricks costly. ≈ maximise `P(≥ contract)` with a small size tilt.
      The current `P(≥ target)` proxy is fine here — safety plays (surrender an overtrick to secure the
      contract) fall out.
    - **Matchpoints → maximise `E[matchpoints]` = beat the FIELD.** Score is ranked, not summed. If the
      field sits in the same contract, "making flat" scores nothing extra — you must out-trick them, so
      a line that risks the contract for an overtrick can be +EV. Frequency of each trick count matters,
      not a single threshold. Needs a **field belief** (a reference distribution over what the field
      takes / what contract they are in).
    - **Total-tricks / par (Phase 1) → no objective**, just "what is available." Neutral reference.

    So structure Phase 2 as three separable pieces:
    1. **Line evaluation** → the full total-trick distribution `P(total = t)` for a chosen line-set.
       Objective-FREE (this is where the single-dummy solver + convolution live).
    2. **Objective** = a pluggable scalar functional `U(distribution) → number`:
       - IMPs: `U = Σ_t P(t)·imp_score(t, contract, vul)`
       - Matchpoints: `U = Σ_t P(t)·E[matchpoints | we take t]` — needs the field model
       - "Make it" (default): `U = P(total ≥ target)` (today's behaviour)
    3. **DP maximises `U`**, not a fixed tail — same machinery, swap the functional.

    **Field-model reuse for MPs:** the simplest field belief is "field also plays DD-optimal in the same
    contract" → your matchpoint ≈ `P(you > field) + ½·P(you = field)`, a comparison of your line's
    distribution against a reference distribution. **Phase 1's census IS that reference** ("what the
    field can extract double-dummy"), so MPs reuses it directly — the overtrick-risk behaviour then
    emerges from the DP (it picks a riskier line when the safe line only ties the field but the risky
    one sometimes beats it). **Ship order:** default `U = P(≥ target)` (IMPs proxy, matches par, simplest);
    add `E[score]` and MPs as later objective plug-ins — no solver rework, just a different `U` (+ a
    field-belief input for MPs).
- [x] **Target-from-par — DONE (Track 1).** The card page's per-board slider defaults to the NS par
      trick count via `dd`'s `data-target` (see the Track-1 block above). The TEXT formats still pass
      `target=0` (no coupling needed there — the `>=k` row shows every level).
- [ ] (Maybe) golden test for the `Html_Cards`/`Html_Handviewer` `annotate` output — none yet, eyeball only.
      For `Html_Cards` a golden would assert the `data-suits` JSON shape (the client JS is unit-testable
      separately if ever extracted).
- [x] **13/13 vacant-space weighting — ANALYSED; safety-net then SUPERSEDED by the joint model 2026-07-04.**
      (The clamp `convolve` described here now survives only in `combine.odin`'s field model + the JS
      fallback; `analyse_ns` and the card page use `joint_total` — see the PROPER joint model item below.)
      Each suit's split is weighted with a FRESH 13/13 vacant space. That per-suit marginal
      is EXACT (the hypergeometric `C(m,a)C(26-m,13-a)/C(26,13)` — `test_vacant_space_marginal_is_exact_
      hypergeometric`). The problem was the CONVOLUTION folding the four suits into `Deal_Analysis.total`:
      it treats the suits as INDEPENDENT, so a strong NS is credited near-max tricks in every suit at once
      and the per-suit means can sum to **> 13** (impossible — total tricks ≤ 13). The convolution then
      puts mass on impossible totals > 13. **Old behaviour:** `convolve` DROPPED that mass → the total
      under-normalised (`sum < 1`, `P(≥0) < 1`; shipped `pretty`/`handviewer` `>=k` row started at **99,
      not 100**), `E[tot]` biased low, and for very strong NS the whole total COLLAPSED toward 0 (an
      honour-loaded 5-3-3-2/2-4-4-3 gave `sum≈0`, per-suit means 16). **Safety net (DONE):** `convolve`
      now CLAMPS the >13 overflow onto index 13 — mass is conserved (`sum == 1` always, no division, no
      collapse), the impossible surplus parks on "NS take all 13", and the shipped `>=k` row starts at
      **100** again. It keeps a valid distribution but does **not** fix the mean bias (the clamped mass on
      13 is a crude stand-in). Only **mirror-length** deals (Σ per-suit max ≤ 13) are truly exact
      (`test_mirror_deal_total_is_exact`); `test_strong_deal_clamps_impossible_mass` locks the safety-net
      behaviour. The CARD PAGE convolves client-side in JS (not via `analyse_ns`); its `convolve` in norn
      `render.odin` got the **same clamp** (mirrored 2026-07-04) — verified in-browser: all 24 board totals
      (N/S + E/W, census + SD) sum to 1, CCA renders, 0 JS errors.
- [x] **PROPER joint model — DONE (2026-07-04).** The independent convolution is replaced by a CONSTRAINED
      joint convolution in `combo.odin`: `suit_joint_table(north, south)` builds a per-suit
      `Suit_Joint_Table` (`count[east_len a][tricks k]` — RAW split counts, keyed on East's length, NOT
      vacant-space-weighted); `joint_total(tables)` is a DP over the four suits carrying **East's running
      0..13 card count** (only `e == 13` states kept at the end, so a split is counted iff East can still
      fit it — forbids the jointly-impossible length combos) AND capping NS's running trick total at 13.
      State `h[east_len][tricks]`, O(suits·14⁴), trivial. Each e==13 assignment is one of the C(26,13)
      equally-likely deals → normalising by C(26,13) always gives sum==1 (no drop, no collapse). This is
      the EXACT joint distribution up to the free-entry per-suit over-count (assumption 1, which the cap
      absorbs). `analyse_ns` now sets `a.total = joint_total(...)` and derives per-suit rows via
      `marginal_from_table` (still the exact hypergeometric — the joint fix changes ONLY the total).
      `suit_trick_distribution` is now a thin `marginal_from_table(suit_joint_table(...))` wrapper (single
      source). **SD side:** `sd_line_joint_table`/`sd_best_joint_table` (single_dummy.odin) +
      `sd_joint_total` (combo.odin) do the same for the achievable single-dummy total.
      **Card page:** the annotator BAKES both joint totals — `data-{ns,ew}-tot` (census) and
      `data-{ns,ew}-totsd` (SD) — and the norn `render.odin` `side()` reads them directly (client-side
      `comboTotal`/`convolve` kept only as a fallback for old pages). Verified: all board totals sum to 1,
      SD mean ≤ census mean, joint differs from the old independent convolution (shape correction),
      CCA renders, 0 JS errors. **PRECONDITION:** `joint_total` needs FULL 13-card hands (real deals
      always are); partial hands break the e==13 normalisation. Covered by the rewritten `joint_test.odin`.
  - [ ] (Maybe) the residual **free-entry** over-count (assumption 1) still lets a strong hand's per-suit
        means over-sum, so the cap parks surplus at 13 and E[tot] < Σ means (`test_strong_deal_is_capped`).
        Fixing THAT needs whole-deal play with entries (i.e. `dd` par), out of scope for the naive model.
  - [x] **Joint DP for the adaptive `atl` curve — DONE (2026-07-04).** `combine.odin` now has
        `dp_value_joint` (the residual-target DP with a SECOND axis = East's running 0..13 card count) +
        `gather_candidate_tables` (per candidate line, a `Line_Joint` = name + `sd_line_joint_table`).
        State `g[east_len][tricks]`; terminal `g4[e][a] = obj[a]` only on `e==13`; recursion
        `g_i[e][a] = max_L Σ_{a_i,k} count_L[a_i][k]·g_{i+1}[e+a_i][min(a+k,13)]`; answer `g0[0][0]/C(26,13)`.
        The LINE CHOICE conditions on BOTH `e` and `a` (declarer counts tricks AND the length each defender
        has shown), keeping it an adaptive optimum. `optimal_adaptive_value` + `adaptive_at_least_curve`
        (the card page's `data-*-atl`) route through it. `best_fixed_combination`/`dp_value` (independent
        convolution) kept as the model-agnostic objective-layer primitive (works on synthetic/partial
        holdings the tests use). **PRECONDITION:** full 13-card hands (like `joint_total`). Verified: atl
        monotone, in [0,1], atl[0]==1, atl[t] ≤ census tail everywhere (DD-tax direction); CCA `≥sd` row +
        IMPs/MPs unregressed in-browser. 38 combo tests pass (rewrote `test_adaptive_bounds_and_linear` to a
        full cap-free hand, added `test_adaptive_curve_valid`).

## ★ the 2-hand (declarer + dummy) advisor — LARGELY COMPLETE (status 2026-07-12)

> **READ THIS FIRST (next-session handoff).** This section was "the headline next project"; it is now
> mostly BUILT. Current state:
>
> **DONE + verified (in-browser + tests):**
> - **2-hand input**: PBN reader (`norn/pbn.odin` `parse_pbn_deal`/`Parsed_Board`), `combo.analyse_parsed_board`
>   + `sd_bundle_parsed_board`, CLI `pbn_analyse.odin`, face-down partial render.
> - **DDS-sampling engine** (`dd/sample.odin`): the honest whole-hand make-% (the 2-hand "par" combo lacks).
>   `sample_grid` (one `CalcDDtable`/layout → every contract), `sample_contract`, `sample_lead_grids`,
>   `best_contract`, constrained sampling (`Sample_Constraints{shape, held}` via reject sampling).
> - **Card page UI** (`norn/render.odin`, CCA overlay): green **whole-hand verdict band**, **contract
>   picker** (♠♥♦♣NT + trick slider), **opening-lead picker** (`data-sim-leads`, single-declarer), the
>   reconciliation strip, help paragraphs. Guarded so normal sim/dd pages are unchanged.
> - **CLI** (`pbn_analyse`): `--sample [--contract|auto] [--seed] [--void|--len|--lead] [--html] [--file|stdin]`,
>   **multi-board** carousel (every `[Deal]` tag → one page / a report per board).
> - Tests: combo 41, bidding 19, **dd 24** (incl. 4 PIMC spike + 10 misguess-tax), norn 97; all lints
>   clean; sim leak-clean. Plus `just test-golden` (exe-level data-sim / data-sim-guess fixture diff).
>
> **REMAINING (all the priority items below are now DONE — 2026-07-16):**
> 1. **Achievable single-dummy** — the honest "a human misguesses" number BELOW the DD-census ceiling
>    (all sampling is currently per-layout double-dummy = a ceiling). Whole-deal POMDP; the one big item.
>    **MISGUESS-TAX ESTIMATOR (candidate #1) BUILT 2026-07-14 (`dd/tax.odin` + `dd/tax_test.odin`) and
>    WIRED 2026-07-15** — geometric two-way-guess identification + a −1-on-misguess strata tax, reuses
>    sample.odin's loop with no extra solves. Validated: docks a real two-way Q (3NT ceiling 71% →
>    achievable 36%, tax 35) yet keeps the spike's cold slam/3NT boards at 100% where naive PIMC undershot
>    to 80/94. See "misguess-tax estimator — CANDIDATE #1 BUILT" below. **WIRED: 4th reconciliation rung
>    now shows in `pbn_analyse` text ("achievable (blind play) 36% · taxed 35 pts by the QS guess") AND on
>    the card page green band ("· achievable 36% playing blind (Q♠ guess, −35)"). Baked into `data-sim` as
>    `ach`/`taxpts`/`pvt`; `sample_board` computes `bs.tax`/`bs.tax_ok` once, shown only on the exact
>    baked (strain, level) with no lead condition + only when a guess exists (guess-free → achievable ==
>    ceiling, rung suppressed). Help modal updated.** DONE. **(2b) COMPOUNDING FIX + GEOMETRY BROADEN
>    2026-07-16:** board achievable is now the best fixed blind commit POLICY across ALL pivots jointly
>    (`joint_achievable_pct` — compounds independent knife-edge guesses, two-pivot 6S board → joint ~30% vs
>    single-worst ~50%); pivot range broadened Jack..King → **Ten..King** (real two-way ten finesse +
>    same-suit doubles). dd **24** tests pass, lint clean.
>    **Prior spike 2026-07-13 (`dd/pimc.odin` + `dd/pimc_test.odin`) — do NOT productionise as-is; see the
>    "PIMC spike findings" block below.** A minimal PIMC play-out (blind declarer, DD defenders) was
>    built and measured: (a) COST ~22–56 s/board single-thread (11k–27k DDS solves), 50–500× the
>    ceiling's 0.1–1 s — breaks the instant-bake model unless batched via `SolveAllBoards`; (b) QUALITY —
>    naive PIMC UNDERSHOOTS (procrastination on DD-value ties: a cold slam reads 80–86%, not 100%), so its
>    raw gap is a pessimistic floor, not the honest achievable, until a context-aware play heuristic is
>    added. Conclusion: full PIMC is a genuine multi-week engine (batching + a play heuristic), not a
>    quick win. Prefer the **misguess-tax estimator** (cheap approximation) or **ship the ceiling as-is**
>    (labelled a ceiling, which is what serious tools report). **DECIDED: next session builds the
>    misguess-tax estimator — see "NEXT SESSION — misguess-tax estimator" in the PIMC spike findings
>    subsection below; start with candidate design #1 (per-layout DD-vs-fixed-guess delta).**
> 2. **Option C narratable lines — C1 DONE 2026-07-16.** Per-suit line tooltip now names the blind two-way
>    guess + its marginal cost ("Blind two-way guess for the Q♠ — a misguess costs about 34%"). combo stays
>    SOLVER-FREE: pbn_analyse bakes `data-sim-guess` on the `.par` div, render.odin merges it into the suit
>    tip client-side, gated to the declaring side. Browser-verified. C2 (reference library) / C3 (entry
>    model) demoted off the critical path — DDS-sampling already covers realism. See "Option C — C1 ... DONE".
> 3. **Golden test — DONE 2026-07-16.** `just test-golden` diffs the baked `data-sim` AND `data-sim-guess`
>    against `tests/golden/` (byte-stable via the seeded RNG). Optional per-declarer base-grid selector
>    stays low value (the lead picker already fixes declarer).
>
> **Uncommitted at handoff:** norn `render.odin`; odin-sims `dd/tax.odin`, `dd/tax_test.odin`,
> `dd/sample.odin`, `dd/sample_test.odin`, `pbn_analyse.odin`, `justfile`, `tests/golden-sim-json.sh`,
> `tests/golden/*`, this doc. Build/verify commands unchanged (see "Dev / test commands" and the justfile:
> `just test-dd` / `test-combo` / `test-golden`, `just analyse-deal …`).
>
> The detailed, dated build log for all of the above is in the "Suggested build order" subsection's
> nested bullets further down. The prose below predates the build and describes the design/rationale.

**Original framing (design rationale, pre-build).** Everything above (Phase 1, Phase 2 bricks 1–4, the
joint model) is COMPLETE and shipped; what follows was the next direction of work.

**Why now.** A separate `hand-ocr` feature will produce not only full 4-hand deals but — importantly —
**declarer + dummy only**: two hands, 26 cards known, the other 26 split unknown between the defenders.
combo is *already* the right engine for that input. `analyse_ns(north, south)` consumes **only the two
NS holdings** — the unknown-E/W-split is its founding premise. A declarer+dummy pair is exactly 26 known
/ 26 unknown, and it is two FULL 13-card hands, so `joint_total`'s "full 13-card partnership"
precondition already holds. **The analysis core needs no rework to accept a 2-hand input.** What is
missing is (a) plumbing, (b) rendering, and (c) two realism gaps that matter far more once the 4-hand
DDS par cross-check is gone.

### What is ready vs missing for a 2-hand feature

**Ready (works from two hands today, at the library level):** per-suit DD census, single-dummy
achievable best line, recommended blind line + narration, `P(≥ t)`, IMPs/MPs objective, joint total.
`analyse_ns` → `format_analysis` already prints a text table from just the two hands.

**The input format is PBN.** The `hand-ocr` tool emits LIN (4 hands) or PBN (2 OR 4 hands); the 2-hand
user flow is ocr → **PBN** → odin-sims+norn. So norn ingests PBN, and — for declarer+dummy — a PARTIAL
PBN (two hands present, two written `-`). Two structural facts drove the first build step: norn's `Deal`
is a fixed `[Seat]Hand` of `[13]Card` (a partial board was not representable), and norn only WROTE pbn
(`render_deal_pbn`), it had no reader.

**Missing / to build:**
1. **A 2-hand entry point — PBN reader DONE (2026-07-10).** `norn/norn/pbn.odin`: `parse_pbn_deal(text)
   -> (Parsed_Board, Pbn_Parse_Error)`. `Parsed_Board{ deal: Deal, known: bit_set[Seat] }` is the
   partial-board representation — every SPECIFIED hand filled as a full 13 cards, seats written `-`
   left out of `known`. A 4-hand tag yields `known == {N,E,S,W}` (drop-in to dd/combo/render); a
   declarer+dummy tag yields just those two seats. Strict parse (4 fields; each `-` or a full 13-card
   `S.H.D.C` hand; all cards distinct) with a typed error enum; accepts a full `[Deal "..."]` line or a
   bare `N:...` value; `seat_from_letter` added to `deal.odin` for the prefix seat. 15 tests
   (`pbn_test.odin`, incl. writer round-trip + the 2-hand case); 97 norn tests pass, lint clean.
   **Analysis wiring DONE (2026-07-10):** `combo.analyse_parsed_board(board) -> (Deal_Analysis, side,
   ok)` (combo.odin) picks the fully-known partnership (`NS_SIDE`/`EW_SIDE`) from `known`, summarises
   those two seats, and runs `analyse_ns` — the census path now works end-to-end from a 2-hand PBN
   string. `ok` is false unless EXACTLY one partnership is known (a 4-hand board routes through
   `analyse_deal_ns`; a lone hand / non-partnership pair is refused). **SD companion DONE (2026-07-10):**
   `combo.sd_bundle_parsed_board(board) -> (Sd_Bundle, side, ok)` mirrors it for the achievable
   single-dummy side (per-suit best-line marginals, recommended line names, SD combined total `totsd`,
   adaptive make curve `atl` — the card page's blue `sd`/`>=sd` rows), sharing the `parsed_board_partnership`
   resolver. So both the DD ceiling and the SD achievable now compute end-to-end from a 2-hand PBN. 3
   combo tests (41 total pass). **CLI driver DONE (2026-07-10):** `odin-sims/pbn_analyse.odin` — a
   standalone `-file` program (like `sim.odin`/`bench.odin`), recipe `just analyse-deal`. Reads a PBN
   from a positional arg, `--file <path>`, or stdin (`hand-ocr … | pbn_analyse`), runs
   `parse_pbn_deal` → `analyse_parsed_board` + `sd_bundle_parsed_board`, and prints the DD census table
   (`format_analysis`) plus an SD summary: `P(>= target)` DD-vs-SD, `E[tot]` DD/SD, and the recommended
   per-suit line with DD/SD expected tricks. `--target n` highlights a level (no DDS par with two hands,
   so the target is the user's contract, defaulting 0). `Sd_Bundle` was made public (now a returned
   type). Verified live: an AQ-finesse holding shows the census spread, `finesse` line, and SD mean <
   DD (the blind-guess tax). NOTE the string-arg form is subject to PowerShell/nu stripping the inner
   `"` — `--file`/stdin are the robust inputs (the parser also accepts a bare `N:...` value without the
   `[Deal "…"]` wrapper). **RENDER DONE (2026-07-11) — the 2-hand advisor is complete end-to-end.**
   `pbn_analyse --html <out.html>` writes the full interactive card page for the 2-hand board:
   declarer + dummy shown, the two defenders drawn **face-down** (`?`), and the CCA overlay working
   (per-suit census + SD rows, the finesse/cash/duck line recommendation, the P(≥t) slider). Reuses the
   norn page shell + `combo.annotate` UNCHANGED via two tricks: (1) `norn.render_deal_html_cards` gained
   a `known: bit_set[Seat]` param (default all four = normal board; a subset renders face-down seats +
   a reduced stats box, see `HTML_CARDS.md`); (2) the `.combo` blob is annotated from a SYNTHESISED deal
   that duplicates the known pair into BOTH partnerships, so the page's N/S↔E/W toggle shows the
   known-side analysis either way (there is only one known side). No DDS par with two hands, so the CCA
   slider target is seeded from a hidden `.par[data-target]` (the driver's `--target`, else the rounded
   SD expected total). Verified in-browser (playwright): board + face-down defenders render, CCA opens,
   per-suit ♠ finesse shows DD 3.3 / SD 3.2, slider + toggles work, 0 JS errors. 97 norn + 41 combo
   tests still pass.
2. **DDS / par is UNAVAILABLE with two hands.** `dd.annotate` (par, makeable) needs all four hands —
   DDS cannot solve unknown defenders. Consequences: no par caption; the card page's per-board target
   (which defaults from `dd`'s `data-target`) has no seed → falls back to the hardcoded 9 (already
   coded), but the user should instead **set the contract / target manually**. combo's own DD-census row
   still computes (it is combo's per-layout minimax, NOT DDS) — only the whole-deal par/makeable is lost.
3. **The render is a 4-hand compass.** The card page assumes a full `Deal` and draws N/E/S/W; per-seat
   focus shows ONE hand and collapses the other three to pills (which implies known-but-hidden). There is
   no "2 known + 2 UNKNOWN" layout. A render mode is needed: declarer + dummy shown, defenders
   face-down / "?". (Tracked on the `HTML_CARDS.md` side.)
4. **The reality-check anchor is gone.** With four hands, `dd` par was ground truth ("when combo and par
   disagree, par wins" — see the TEMPO caveat). Solo, combo's optimistic total (free entries + suit
   independence + no tempo race) is **unchecked** — the same over-count, but no par to catch it. This
   raises the stakes on the two realism tracks below.

### Two realism tracks (the actual new theory/engineering)

Both address "combo over-estimates," which is tolerable next to a 4-hand par caption but not when combo
is the ONLY number on screen.

**Track 1 — within combo, per-suit: finish the single-suit line model.**
- **Do we have every blind line per suit? No.** The shown answer is the best of **FIVE curated
  heuristics** (`candidate_lines`: `line_top_down`, `line_finesse`, `line_finesse_other`,
  `line_duck_one`, `line_duck_then_finesse`). Not exhaustive — it is missing **safety plays**
  (`line_safety_N`, deferred), deeper / multi-round ducks, and conditional (tree-shaped) lines. A
  provably-optimal single-suit search DOES exist (brick 3, `sd_optimal_distribution`) but is (a) exact
  only on long holdings (few missing cards; random suits are usually short → it falls back to the curated
  five), (b) a decision TREE, not narratable, and (c) NOT wired into the shown output. **Near-term wins:**
  wire brick-3 where it is exact; add safety plays to the candidate set.
- **Option C — entry-aware lines (per-suit realism + narration).** Every line above assumes
  **assumption 1: FREE ENTRIES** (unlimited leads from either hand). That is the single biggest source
  of the tool's optimism. Option C parameterises line choice by ENTRIES — "entries to North / entries
  to South" — so a repeated finesse costs the repeated entries it really needs, and it pairs with a
  suit-combination reference library for provably-optimal, entry-parameterised, fully-narratable
  per-suit lines. See the expanded **Option C** section below.
  - **RECOMMENDATION REVISED (2026-07-11), read the "Option C vs DDS-sampling" trade below.** Option C
    was flagged as the FIRST realism deliverable when DDS-sampling looked slow/risky. Two findings
    changed that: (1) DDS-sampling can be **precomputed/baked at export** (see Track 2) → the perf/risk
    that favoured C evaporated; (2) entries are inherently a **cross-suit** resource (a side entry lives
    in another suit), so Option C's per-suit entry budget is itself an APPROXIMATION — the thing
    DDS-sampling does correctly. So Option C's surviving unique value is **narration** ("finesse the Q,
    then duck"), NOT realism. Do it as later per-suit polish; don't over-invest in the entry model.

**Track 2 — beyond combo, multi-suit: the DDS-sampling single-dummy engine (the big one).**
combo has NO cross-suit play by construction: **assumption 2** (suit independence, folded by convolution)
forbids **squeezes, endplays, throw-ins, dummy reversals, cross-ruffs, entry / communication management,
and the tempo race** — every one is cross-suit. Squeezes and endplays would GAIN tricks (combo
under-counts those layouts); the dominant error is the opposite, the tempo/entry OVER-count. None of it
is reachable by extending combo.

The principled whole-hand answer for a 2-hand input:

> **Monte-Carlo the unknown 26 cards into E/W (constrained to the known cards) → run a REAL full-deal
> double-dummy solve (the `dds` collection is already linked) on each sampled layout for the analysed
> contract → aggregate into a make-% + trick histogram.**

Each sampled layout is a true solve, so **every cross-suit technique comes for free** (squeezes,
endplays, entries, tempo are all handled inside the per-layout solve). The aggregate is a genuine
whole-hand make-probability — **the honest number a player wants, and the reality anchor combo lacks
solo**.

**IT CAN BE PRECOMPUTED / BAKED — this is the key reframing (2026-07-11).** The card page is already
GENERATED offline and combo/dd already BAKE their results into `data-*` attributes. DDS-sampling fits
the same slot: run the samples **when the HTML is written** (CLI/`pbn_analyse` side), bake the make-% +
histogram into a `data-*` blob, and the page stays **static and instant** — a baked annotation like
dd's par caption, NOT a runtime engine. This removes the interactivity/perf risk that once made it look
"heavy". Concrete numbers:
- **Samples needed = variance, not coverage.** The space is C(26,13) ≈ 10.4M layouts; you cover a
  negligible fraction and it doesn't matter. Monte-Carlo make/no-make std error ≈ √(p(1−p)/N): N=100 →
  ±5%, N=400 → ±2.5%, N=1000 → ±1.6%. **~200–500 samples pins the make-% to a few percent** — enough
  for advice (a few more help the histogram tails).
- **~1 DDS solve/sample** (the target strain+declarer), **~2–10 ms single-thread**, **~1–2 ms amortized**
  via dds's bulk multithreaded API (`SolveAllBoards`, ~200 boards/call). So **~0.1–1 s per board at
  export**, invisible to the viewer.
- **Sampling method: constrained + variance-reduced.** Deal only layouts consistent with the known
  cards (and later any shown voids / bidding / opening-lead inferences). **norn already generates
  constrained deals** — predeal the 26 known cards, deal the remaining 26 to E/W N times. Free reuse:
  **norn deals the samples, dds solves them.** Dealing uniformly from the constrained set already weights
  by the a-priori (vacant-space) split odds; stratifying on the pivotal unknown (e.g. which defender
  holds a missing K) cuts variance further.
- **PER-BOARD, not global.** The sample set is specific to the two known hands, so it is baked per board
  (like dd par), not shared across boards.

**The one caveat: ceiling vs achievable, again.** Per-layout DDS = "makeable IF you saw that layout" →
the aggregate is a whole-hand DOUBLE-DUMMY census (a *ceiling*, but one that already has
entries/squeezes/tempo baked in per solve — far better than combo's per-suit ceiling). The true
achievable SINGLE-DUMMY number (ONE fixed blind strategy across all samples) is a whole-deal POMDP,
much harder. Ship the DD-census make-% as the honest ceiling (what serious tools report as "X% over N
simulations"); the achievable-SD refinement is a later, optional step.

#### PIMC spike findings (2026-07-13) — `dd/pimc.odin`, `dd/pimc_test.odin`

The achievable-SD "later step" was SPIKED to measure it before committing. `pimc.odin` is a minimal
PIMC (Perfect-Information Monte-Carlo) play-out — the industry estimator (GIB/Jack): the two known hands
are declarer+dummy; each outer sample deals the unknown 26 to the defenders (constrained, reusing the
`sample.odin` predeal path); the deal is then PLAYED OUT with a **blind declarer** (at each of declarer's
own plays it samples K worlds consistent with what it can see — the outstanding cards are known, only the
E/W split is hidden; it `SolveBoard`s each and votes the best-mean card) against **double-dummy
defenders** (they see the true world — a conservative lower bound on achievable). It is NOT wired to any
output; it exists only for these two numbers, and is deliberately left as the simplest correct baseline.

**Cost (the wall).** Declarer makes 26 plays/deal, so cost ≈ `n_outer·(26·K + 26)` DDS solves. Measured
at ~**2.1 ms/solve single-thread**: 3NT board, n=60 K=8 → **11,024 solves, 22 s/board**; n=100 K=12 →
**26,690 solves, 56 s/board**. sample.odin's ceiling is **1 solve/layout, 0.1–1 s/board** → PIMC is
**50–500× heavier**. It CANNOT ride the "instant baked" model as-is. The only route to a bakeable
~5–10 s/board is batching the K inner solves through `dds.SolveAllBoards` (200/call, multithreaded inside
DDS) — a real harness, not a knob. And you can't just shrink K/n: quality degrades (below).

**Quality (the surprise).** Naive PIMC UNDERSHOOTS the truth. On a COLD 6S slam (ceiling 100%, 15 top
tricks, makes 12 on every break) it read **80–86%**, mean **11.7–11.8** — the blind declarer throws a
trick it never should. Cause: DD-value TIES. Every double-dummy-equivalent line scores the same, so
cashing a winner and passively conceding tie; the blind declarer procrastinates and bleeds the 15→12
margin until it can't recover. A crude global tie-break (prefer the higher card = cash top-down) recovered
the slam to **92%** but made the 3NT board WORSE (85%→73%) — the right tie-break is context-dependent
(cash when cashing, duck when ducking), i.e. a genuine play heuristic, not a one-liner. So the spike's
raw gaps (3NT 100→85, cold 100→86) are a **pessimistic FLOOR inflated by procrastination**, not the
honest achievable — the real number sits higher, between this floor and the ceiling.

**Verdict.** Full PIMC is BOTH expensive (needs `SolveAllBoards` batching) AND finicky (needs a
context-aware play heuristic to not undershoot) — a multi-week engine, not the "later, optional step" the
prose above implies. Cheaper alternatives now look better: a **misguess-tax estimator** (ceiling minus
the expected loss at the identifiable blind two-way decisions — no play-out, no procrastination
pathology, export-cheap, approximate) or simply **shipping the DD-census ceiling labelled as a ceiling**
(what serious tools report). Recommendation: do not build full PIMC now; keep `pimc.odin` as the
reference/measurement harness. Tests: `just test-dd` (15, incl. 4 PIMC — `test_pimc_measure` prints the
cost/gap; the cold-slam test asserts only the undershoot direction). Uncommitted at handoff.

#### misguess-tax estimator — CANDIDATE #1 BUILT (2026-07-14), `dd/tax.odin` + `dd/tax_test.odin`

**Status: DONE (library level), NOT yet wired to the card page / CLI.** Candidate #1 (the per-layout
DD-vs-fixed-guess delta) is implemented as `misguess_tax(board, side, contract, n_samples, seed,
constraints) -> (Tax_Result, ok)`. It reuses sample.odin's exact sampling loop (same reject-sampling
constraints, seeded RNG, ONE CalcDDtable/layout — **no extra solves**, ~1× the ceiling cost).

**How it landed (differs slightly from the sketch below — read this).**
- **Guess identification is GEOMETRIC, from the two known hands, not from the DD grid.** Key realisation
  during the build: a genuine two-way finesse is *invisible* in the DD strata — double-dummy always
  guesses right, so E[tricks | honour with West] == E[tricks | honour with East]. You CANNOT detect the
  guess by stratifying the solved grid; you must read the *tenace geometry*. `two_way_guess_pivots`
  flags a missing honour C (**Ten..King**) iff (a) declarer holds BOTH immediate neighbours C+1 and C-1 (a
  tight tenace that traps C — excludes "solid tops" like AKQ-missing-J, whose lower neighbour is a
  defender card), AND (b) EACH declaring hand holds a card ranked above C (finessable from either side →
  genuinely two-way, not a forced one-way finesse).
- **Geometry range = Ten..King (broadened from Jack..King 2026-07-16).** The floor is the TEN: a two-way
  finesse for the ten (declarer holding J and 9 around it, a card above in both hands — e.g. K9 opp AJ
  missing QT) is a genuine binary guess, and it is the ONLY shape that yields two INDEPENDENT same-suit
  pivots (Q and T, separated by the held J). Deeper (a two-way nine) is essentially never trick-deciding,
  so the range stops at the ten. Enumerated boundary (tests `test_tax_pivot_geometry` /
  `test_tax_pivot_catalogue`): every textbook single-missing-honour two-way for J/Q is caught; a KING is
  NEVER two-way (needs the Ace above it in BOTH hands — impossible), so even AQ-opp-JT9 is correctly a
  one-way; missing-KQ / drop-vs-finesse percentage plays are NOT binary misguesses and stay untaxed
  (taxing them would corrupt cold contracts, and there is no single-dummy ground truth here to validate a
  looser filter against). The tight-tenace + above-in-both-hands filter thus captures exactly the set of
  genuine binary two-way guesses.
- **Same-suit multi-guess needs no special handling.** When a suit has two pivots (Q and T), the tight-
  neighbour geometry GUARANTEES a declarer card (the J) sits between them — adjacent missing honours fail
  the neighbour test — so they are independent finesses whose misguesses cost their own tricks. The joint
  model's additive −1-per-misguess is therefore exact for same-suit pivots, same as cross-suit ones
  (`test_tax_same_suit_double_pivot`).
- **Why only TWO-WAY guesses.** A one-way (forced) finesse is NOT a guess — declarer just takes it and
  wins exactly when the DD solver does — so the −1-on-misguess penalty would over-tax it. Restricting to
  two-way tenaces is what keeps a COLD contract cold (the estimator's whole advantage over naive PIMC).
- **The tax model (−1 on a wrong two-way guess is EXACT for a clean two-way finesse):** per pivot, split
  the sampled DD tricks by which defender holds C; committing to finesse toward defender d makes when
  C∈d and t≥need, OR when C∈other but t≥need+1 (an overtrick survives the one-trick misguess). Achievable
  facing that guess = the better commit direction (still reported per-pivot as `pivots[i].achievable`).
  **Board achievable = the best fixed blind commit POLICY across ALL pivots jointly (2b, DONE 2026-07-16):**
  each layout records the holder-pattern over every pivot; a policy fixes a direction per guess and a
  layout makes iff `t − #misguessed ≥ need` (each wrong guess −1, additive); take the policy with the best
  make fraction (2^n_pivots policies, n tiny — `joint_achievable_pct`). This COMPOUNDS independent guesses:
  two knife-edge two-way finesses on a cold ceiling drop it to ~25%, not the ~50% the single-worst view
  reported. Reduces to the single-pivot formula at n=1; achievable == ceiling at n=0. The −1 only bites at
  the knife edge (t==need), so a non-pivotal flagged guess is self-correctingly untaxed.

**Validated against the PIMC spike's boards (`test-dd`, 24 total incl. compound + geometry-catalogue + same-suit, lint clean):**
- **Two-way guess board `N:AJ54.AK2.A32.AK3 - KT32.543.654.542`, 3NT** (spades AJ54/KT32 miss Q9876, a
  two-way Q deciding the 9th trick): ceiling **71%**, achievable **36%**, tax **35 pts**, sole pivot =
  ♠Q. The blind declarer is right ~half the time — a real, sane tax. (This board is NOT stone cold: the
  whole-hand DD ceiling is ~71–80%, because some Q-with-length layouts beat even the two-way finesse.)
- **Cold slam `…6S` and cold 3NT `…AK32.AK2.A432.A2…`** (the spike's undershoot boards): **no two-way
  tenace flagged → achievable == ceiling == 100%, tax 0.** This is the headline win: naive PIMC
  UNDERSHOT these to 80% / 94% via DD-tie procrastination; the misguess-tax estimator keeps them cold.
- Ceiling matches `sample_contract` exactly (shared loop); seed-reproducible; achievable ≤ ceiling always.

**KNOWN LIMITATIONS / conservative by design.** Guesses looser than a tight two-sided tenace (e.g. AJ
missing KQ — two adjacent missing honours) are NOT flagged → left untaxed (slightly optimistic, but
deliberately kept ABOVE PIMC's pessimistic floor rather than risk over-taxing). Multiple pivotal guesses
now COMPOUND correctly (2b, best-policy joint — see above); the residual approximation is the additive
−1-per-misguess assumption (two guesses in the SAME suit may not lose independent tricks). The −1 penalty
assumes a clean one-trick finesse loss.

**WIRED 2026-07-15.** (1) DONE — `sample_board` computes `bs.tax` via `misguess_tax` (same board/seed/
constraints, one extra CalcDDtable pass, cheap vs the lead grids); `print_sample_verdict` prints the
achievable rung; `write_sim_json` bakes `ach`/`taxpts`/`pvt` into `data-sim`; `render.odin` `simBand`
shows "· achievable N% playing blind (Q♠ guess, −tax)" on the exact baked (strain, level) with no lead
condition, and only when a guess exists. Help modal explains it. **REMAINING:** (2) OPTIONAL: broaden
guess geometry (looser tenaces, key-K location) if validation on more boards shows systematic
over-optimism; (3) the analytic candidate #2 / full PIMC #3 remain the fallbacks if the tax proves too
crude; (4) DONE 2026-07-16 — golden test for the baked `data-sim` JSON shape: `just test-golden` builds
pbn_analyse, runs it on a fixed board+seed (the two-way ♠Q 3NT board, `--sample 120 --seed 7`), and diffs
the emitted `data-sim='...'` against `tests/golden/two_way_q_3nt.datasim.json` (seeded xoshiro makes it
byte-stable). Guards `write_sim_json` — incl. the `ach`/`taxpts`/`pvt` tax rung — from drifting out of
sync with render.odin's `simBand` parser. Regenerate the fixture after an intentional format change (recipe
in `tests/golden-sim-json.sh` header).

**BOARD-MATRIX VALIDATION 2026-07-15 (7 boards, --sample 400 --seed 7 unless noted).** No systematic
over-optimism found; the one soft spot is the already-documented compounding case.

| board | geometry / contract | ceiling | achievable | tax | pivot | verdict |
|---|---|---|---|---|---|---|
| A | two-way ♠Q, thin 3NT (`AJ54.AK2.A32.AK3 / KT32.543.654.542`) | 74% | 37% | 37 | ♠Q | ✓ sane; seed-stable 37–41% over seeds 1/7/42/99 |
| B | two-way ♠J, knife 3NT (`AQT4… / K932…`) | 100% | 50% | 50 | ♠J | ✓ whole contract rides the one guess → 50/50 |
| C | TWO two-way Q (♠+♥), cushioned 3NT (E[tr] 9.76) | 100% | 88% | 12 | ♠Q | ⚠ docks the DOMINANT guess only → optimistic; true achievable lower (both Qs guessable). Mild here because the cushion absorbs one misguess |
| D | two-way ♠Q but low need, 1NT | 100% | 100% | 0 | ♠Q | ✓ overtrick cushion self-corrects the misguess (non-pivotal → untaxed) |
| E | one-way K finesse (`AQ2… / 543…`) | 100% | — | — | none | ✓ 0 pivots (forced finesse is not a guess) |
| F | solid AKQ missing J, 6S | 100% | — | — | none | ✓ 0 pivots |
| K | AQ opp JT, missing K (`AQ32… / JT54…`) | — | — | — | none | ✓ a King is NEVER two-way (would need the Ace above it in BOTH hands — impossible), correctly not flagged |

Takeaways: single-guess boards are accurate + seed-stable; the cushion logic works (D, partial C);
controls (E/F/K) yield no false positives. The one gap this matrix found — **compounding** (N independent
pivotal guesses docked as if only the worst existed) — is now **FIXED (2b, DONE 2026-07-16)** by the joint
best-policy achievable. New knife-edge two-pivot board `N:AKQJ4.AJ4.AJ4.A2 - T9832.KT3.KT3.43`, 6S (solid
♠ trumps + two-way ♥Q AND ♦Q, no cushion): ceiling **100%**, each guess's marginal ~**50%**, joint
achievable **~30%** (both queens must be right), tax **70** — the single-worst view would have wrongly
reported ~50%. `test_tax_two_guesses_compound` (`test-dd`, now 24 tests, lint clean) pins it. Board C's
mild under-tax is likewise resolved by the joint model.

<details><summary>Original design sketch (pre-build) — kept for the candidate #2/#3 fallbacks</summary>

**Goal.** A cheap, export-friendly achievable-SD number that sits BELOW the DDS ceiling by (an estimate
of) the tricks a blind declarer loses to guesses double-dummy gets free — WITHOUT a full play-out (no
procrastination pathology, no `SolveAllBoards` harness). Approximate but honest-direction; a 4th
reconciliation rung `ceiling · blind(combo-SD) · simulated(DDS ceiling) · achievable(tax)`.

**What already exists to reuse (don't rebuild):**
- `dd/sample.odin` `sample_grid` — the per-layout DDS census (the ceiling), already baked as `data-sim`.
- combo's per-suit **blind SD** (`best_line_by_mean`, the blue `sd`/`≥sd` rows) — already a per-suit
  misguess estimate under FREE ENTRIES; the reconciliation strip already shows `ceiling · blind ·
  simulated`. The tax number is essentially "make-% under blind play", which combo approximates per-suit.
- `dd/pimc.odin` helpers (play-out, `build_deal`, `same_side`, sampling) if a bounded play-out is wanted.

**Three candidate designs, cheapest first (pick/prototype next session):**
1. **Per-layout DD-vs-fixed-guess delta (cheapest, pure sampling).** In `sample_grid`'s existing loop,
   for the chosen strain, alongside the DD max, also compute tricks when declarer commits to ONE fixed
   guess policy — e.g. solve with the key two-way finesse forced one way (via a `SolveBoard` from a
   position that has pre-committed the guess, or simpler: take min over the two "which defender holds the
   missing honour" strata). The make-% under the committed policy, averaged, is a floor; averaging the
   BETTER of the two commit directions per HAND (not per layout) ≈ achievable. One extra solve/layout at
   most → stays ~1–2× the ceiling cost, not 50×.
2. **Analytic two-way-guess census (no extra solves).** Enumerate the identifiable blind two-way guesses
   in the two known hands (missing Q with a two-way finesse, a key K to locate, guarded honours) — combo
   already reasons per-suit — and dock the ceiling by `Σ P(guess wrong) × P(that trick is the setting
   trick)`. Hardest part is "is this trick pivotal", which the sampled trick histogram (`hist[strain]`)
   gives: the tax bites only where the make margin is 0 (exactly `need` tricks). Cheap, most approximate.
3. **Bounded PIMC with a play heuristic (most faithful, most work).** Salvage `pimc.odin` by adding the
   context-aware tie-break the spike showed is needed (cash when cashing / duck when ducking), then batch
   via `SolveAllBoards`. This is the "real" achievable but is the multi-week path the spike advised
   against for now — listed for completeness.

Start with **#1** (reuses the sampling loop, bounded cost, sidesteps the tie pathology because each
layout is still a clean DD solve). Validate against the spike's `test_pimc_measure` boards (3NT two-way
guess: expect the tax to land the achievable meaningfully below 100 but ABOVE PIMC's pessimistic 85).

This is still a **new engine, not an extension of combo**, but the bake reframing makes it **cheaper and
lower-risk than first framed** (reuses norn deal-gen + dd's DDS binding). combo stays the fast,
solver-free per-suit view that *explains each suit's technique*; the DDS sampler is the whole-hand view
that gives the honest make-%.

</details>

### Option C vs DDS-sampling — the trade (read before picking)

They fix DIFFERENT things and answer DIFFERENT questions; they are **complementary, not rivals**.

| | Option C (lite) | DDS-sampling (baked) |
|---|---|---|
| Combo sins fixed (1 entries / 2 independence / 3 tempo) | 1, per-suit only | **1+2+3, whole-hand** |
| The headline "will it make?" | still an upper bound | **the honest answer** |
| Per-suit narratable lines | **yes** (its niche) | no (numbers only) |
| Runtime cost | instant (live in CCA) | instant (baked at export) |
| Export cost | ~0 | ~0.1–1 s/board |
| Effort | 1–2 sessions | ~1 week |
| Reuses | combo evaluator | norn deal-gen + dd's DDS |
| The catch | entry model is a per-suit FUDGE (entries are cross-suit) | ceiling, not achievable-SD (POMDP) |

- **Option C answers "how do I play each suit?"** (teaching / technique) — its lines are narratable and
  it's the ONLY source of "finesse the Q, then duck". But its realism gain is bounded and its entry
  model is an approximation of something (cross-suit entries) that only whole-deal play does correctly.
- **DDS-sampling answers "will this contract make?"** (evaluation / the honest verdict) — it fixes all
  three sins and restores the missing par anchor, and the bake reframing made it cheap + low-risk.
- **Revised order (flipped from the earlier "C first"): DDS-sampling first, Option C as later narration
  polish.** The bake removed C's cost/risk advantage; C's surviving justification is narration, not
  realism.

### UX — showing BOTH without confusing the user (one honesty ladder)

The three numbers are not parallel modes; they are **rungs of increasing honesty on the same deal**, and
the GAPS between them are the lesson (the entry/tempo/no-squeeze tax the CCA help already warns about in
words). The card page already teaches "ceiling vs realistic" with black/blue rows + swatches + a help
modal — DDS-sampling is **one more rung in that exact frame**:

| Rung | Question it answers | Trust | Colour |
|---|---|---|---|
| combo **census** | "what's available (cards seen), per suit" | best-case ceiling | black (exists) |
| combo **blind / +Option-C** | "playing blind per suit, with entries" | realistic per-suit | blue (exists) |
| **DDS-sim** | "will it actually make, whole hand" | **the honest verdict** | green (new) |

Layout: extend the CCA panel, don't split it — a **green "whole-hand (simulated): 4♥ makes 81% (±2%,
400 deals)" verdict band** on top, the existing **per-suit technique table** (combo + Option-C lines)
below, and a **reconciliation strip** (`ceiling 12.9 · blind 12.6 · simulated 10.4`) that SHOWS the tax
as the gap. Rules that keep the modes unambiguous:
- **Name by the QUESTION, not the algorithm** ("Whole-hand (simulated)" vs "Per-suit (technique)"); keep
  double-dummy / Monte-Carlo jargon in the help only.
- **Consistent colour + swatches** (black ceiling, blue blind, green simulated); add the green swatch as
  a third paragraph in the existing ceiling-vs-realistic help section.
- **Honest precision cue** on the sim ("81% (±2%, 400 deals)") — distinguishes a simulation from the
  exact combo numbers.
- **One-line trust rule** in the panel: *green = will it make; suit rows = how to play.*
- Swap the help's closing "trust par over combo" for "trust the **simulated whole-hand** number; the
  suit sums are an upper bound."
- **DDS needs a STRAIN** to solve, so the sim rung REQUIRES the strain+level **contract picker** (the
  slider's "tricks ≥ N" becomes "make 4♥"). Adding DDS-sampling therefore pulls in the contract picker
  that the 2-hand render TODO already wanted — they ship together.

### 2-hand vs 4-hand — what actually differs (a clarification worth keeping)

**For combo's own numbers: nothing.** `analyse_ns(N, S)` reads ONLY the two partnership hands and
averages over EVERY E/W split — it never looks at the actual defenders. So combo output is byte-identical
whether or not E/W are known; the 2-hand and 4-hand `.combo` blobs for the same N/S are the same, and
the only render difference is face-down vs shown defenders (the "minor HTML/UX difference").

**But the ANALYSIS AS A WHOLE differs fundamentally, because of what each view can condition on:**
- **combo is INHERENTLY the unknown-defenders analysis.** Averaging over all E/W splits IS the correct
  thing to do WHEN you don't know the defenders. On a 4-hand deal you DO know them, so the honest
  per-deal answer is not the average — it is the ONE actual layout, i.e. double-dummy on the real 52
  cards (`dd` par / makeable). Running combo on a 4-hand deal throws away the E/W information you have;
  its census becomes an a-priori "what could have been" sidebar to par, which is why the help says "when
  combo and par disagree, trust par". (combo restricted to the single actual split = plain double-dummy
  = `dd`. The average is combo's whole point, so a 4-hand board is really `dd`'s home.)
- **`dd` par exists ONLY with 4 hands** (DDS needs all 52). The 2-hand view structurally CANNOT have it.
- **DDS-sampling is the 2-hand analogue of par.** With 4 hands you don't sample — you solve the one known
  deal (that IS par). Sampling over E/W layouts is precisely the tool for when the defenders are unknown;
  it fills the exact gap the 2-hand view has. combo's census is already a crude, per-suit, entry-free
  version of that averaging; DDS-sampling is the correct whole-hand version.

So: 2-hand vs 4-hand is a **minor UX difference for combo**, but an **analytical difference for the tool**
— the 4-hand deal admits the exact per-deal truth (par) that the 2-hand deal cannot, and the 2-hand deal
is where averaging/sampling over defenders is the *right method* rather than a discard of known cards.
DDS-sampling is what makes the 2-hand view analytically first-class (its own "par").

### Suggested build order (revised 2026-07-11)

1. **DONE — 2-hand input + render.** PBN reader (`parse_pbn_deal`/`Parsed_Board`), analysis wiring
   (`analyse_parsed_board` + `sd_bundle_parsed_board`), CLI/HTML driver (`pbn_analyse`), face-down
   partial render. The 2-hand advisor runs end-to-end on the combo engine (see "Missing / to build" #1).
2. **DDS-sampling baked verdict + the strain+level contract picker** — the honest whole-hand make-% (the
   2-hand's "par"), precomputed at export, shown as the green top rung. Reuses norn deal-gen + dd's DDS.
   The contract picker ships with it (DDS needs a strain).
   - **ENGINE + CLI DONE (2026-07-11).** `dd/sample.odin`: `sample_contract(board, side, contract,
     n_samples, seed) -> (Sample_Result, ok)`. Predeals the two known hands to their seats, deals the
     remaining 26 to the defenders via `norn.deal_board_predealt` (a seeded xoshiro stream → reproducible;
     uniform over the free cards = a-priori vacant-space split odds), and bulk-solves each layout for the
     chosen strain with `dds.SolveAllBoardsBin` (200 deals/call, multithreaded inside DDS). Each sampled
     layout is solved for BOTH pair members as declarer and the better taken (the pair plays it from the
     stronger side → "can this pair make it", the honest whole-hand ceiling). Aggregates a trick histogram
     `hist[0..13]`, `make_count` (the ≥ level+6 tail), `make_pct`, binomial `stderr_pct` = √(p(1−p)/N)·100,
     and `mean_tricks`. `Contract` + `parse_contract("4H"/"3NT")` keep dds types out of callers.
     `contract_label` renders "4H". Single-threaded like all DDS here. **CLI DONE:** `pbn_analyse
     --sample <deals> --contract <4H> [--seed n]` prints the green verdict (`4S makes 2% (±1%, 500 deals)`,
     E[tricks] simulated) + a **reconciliation strip** `ceiling X (combo DD) > blind Y (combo SD) >
     simulated Z (DDS whole-hand)` — the entry/tempo/independence tax shown as the gap. `dd/sample_test.odin`
     (5 tests: parse, cold-slam=100%, hopeless<25%, seed-reproducible, rejects-unknown-side); `just test-dd`
     (forced `ODIN_TEST_THREADS=1` — DDS not reentrant). `pbn_analyse`/`dd` lint + the `analyse-deal` recipe
     now link the `dds` collection. Verified live: 6S cold hand → 100%; 20-HCP 4S → 2%, mean 8.80,
     reconciliation 8.93 > 8.82 > 8.80.
   - **GRID REFRAME (2026-07-11):** the core is now `sample_grid` (per layout ONE `dds.CalcDDtable` returns
     the whole 5-strain × 4-declarer trick table), so one solve/layout bakes EVERY contract — the picker
     needs exactly that. `Grid_Result{n, hist[strain][14]}`; `sample_contract`/`result_for` read one strain
     off it. `sample_grid`'s header now documents the **sampling variety** in full: uniform-constrained
     dealing (`deal_board_predealt`) draws each defender split at its true a-priori (vacant-space /
     hypergeometric) frequency and moves every missing honour between the defenders at the correct rate — no
     hand-picking; plain Monte-Carlo, unbiased, error ~1/√N. `test_sample_split_distribution_matches_apriori`
     PROVES it (empirical East-holding split vs exact `C(m,k)C(26-m,13-k)/C(26,13)`, 4000 deals). Stratified
     variance reduction noted as future, not needed.
   - **HTML BAKE + CONTRACT-PICKER UI DONE (2026-07-12).** `pbn_analyse --html --sample --contract` bakes the
     grid as a `data-sim` JSON blob (normalised per-strain `p[k]` + `n` + default level/strain) on the hidden
     `.par` div (`write_sim_json`; braces written literally — Odin fmt reads `{` as an arg ref). norn
     `render.odin`: a **green "Whole-hand (simulated)" verdict band** on top of the CCA body + a **strain
     picker** (♠♥♦♣NT) in the head; the EXISTING trick slider is the level (target = level+6, so "4♥" =
     "≥10 tricks in ♥"). The band shows `<contract> makes X% (±e%, N deals)` + a **reconciliation strip**
     `ceiling (combo DD) · blind (combo SD) · simulated (per-strain mean)` — the tax as the gap. Picker/band
     appear ONLY when a board carries `data-sim` (guarded by `el._sim`), so all normal sim/dd pages are
     unchanged. Help modal gained a green-rung paragraph + swatch. Verified in-browser (playwright): 2-hand
     page 4♠ 2% / 3NT 42% with live strain+slider switching and correct per-strain reconciliation; normal
     `1major-game-force` page band+picker hidden, CCA unregressed, 0 JS errors. 97 norn + dd/combo tests
     pass, lint clean.
   - **CONSTRAINED SAMPLING DONE (2026-07-12).** `sample_grid`/`sample_contract` take an optional
     `constraints: []Card_Constraint` (a DEFENDER shape inference: `{seat, suit, min, max}` card-count
     bounds — a void is `{max=0}`, a known 6-bagger `{min=6,max=6}`, "5+" `{min=5,max=13}`). Enforced by
     **reject sampling** (deal uniformly, discard layouts violating any constraint), which yields a uniform
     draw over the constrained set = the correct CONDITIONAL distribution given the inference, so splits,
     finesse odds, and honour locations all shift to their post-inference values (still a-priori-weighted,
     just conditioned). `SAMPLE_MAX_REDEAL=5000`/sample; an impossible set fails cleanly (ok=false), never
     hangs. CLI: `--void <seat>:<suit>` and `--len <seat>:<suit>:<n|n-m|n+>` (repeatable), validated to name
     a DEFENDER (not a known hand); the text report notes what was conditioned on. The constrained grid
     flows straight into the html bake / picker (no UI change — numbers are precomputed). Verified live: on
     a hand where the spade-K finesse decides 7NT, unconstrained **53%** → `--void E:S` (K forced onside)
     **100%** → `--void W:S` (offside) **0%** — textbook conditioning. `test_constrained_sampling_conditions`
     + `test_constrained_impossible_fails` (9 dd tests). This is the Track-2 "known voids / lead inferences"
     realism item.
   - **OPENING-LEAD / SPECIFIC-CARD CONSTRAINT DONE (2026-07-12).** Constraints refactored from a bare
     `[]Card_Constraint` into `Sample_Constraints{shape: []Card_Constraint, held: []Held_Card}` —
     `Held_Card{seat, card}` conditions on a defender holding an EXACT card (the opening lead, or any seen
     card). Same reject-sampling path. CLI `--lead <seat>:<card>` (rank-first card, e.g. `W:KS`; alias
     `--card`), validated to name a defender AND that the card is not already in a known hand. Verified:
     7NT with North's AQJ2 spade tenace, unconstrained **53%** → `--lead W:KS` (K onside — West plays
     before the tenace) **100%** → `--lead E:KS` (offside) **3%** — the textbook finesse swing.
     `test_held_card_conditions` (10 dd tests).
   - **LIVE IN-PAGE LEAD PICKER DONE (2026-07-12).** Confirmed the design finding — conditioning on a lead
     is a FILTER over the solved samples, not a re-solve. `dd.sample_lead_grids` does ONE sample pass and
     returns `Lead_Grids{base, seat[Seat][52]Lead_Card_Hist, n}`: the base best-of-pair grid PLUS, per
     DEFENDER seat per card, the best-of-pair trick histogram over the layouts where that defender holds the
     card (each sample tallies its 13 held cards per defender — no extra solves). `pbn_analyse --html`
     bakes it as `data-sim-leads` (per seat, card-label → `{n, g}`; `write_leads_json`/`write_g_object`
     shared with the contract grid). norn `render.odin`: a **lead dropdown** in the CCA head (53 options =
     none + 26 unknown cards × 2 defenders, labelled "E K♠"); picking one makes `simBand` read the sub-grid
     (`activeSimSrc`) instead of the base — the green band shows the conditioned make-%, the honest smaller
     sub-N + ±, and a blue "given E led K♠" note. Kept the model consistent with the CLI `--lead`
     (best-of-pair declarer; fixing declarer/leader is a documented future nicety, NOT done). Verified
     in-browser (7NT AQJ2 tenace): base **51% (400 deals)** → West led K♠ **100% (198)** → East led K♠
     **3% (202)**, sub-N sum = 400, note + honest ±. Picker hidden on normal sim/dd pages (guarded by
     `el._leads`); help modal has a lead paragraph. `test_lead_grids` (11 dd tests), 97 norn tests, lint
     clean.
   - **DECLARER/LEADER FIX DONE (2026-07-12) — the caveat above is now closed.** A known opening lead fixes
     the LEADER and hence the DECLARER (leader = declarer's LHO ⇒ declarer = leader's RHO = `(leader+3)%4`,
     always the leader's pair partner). So each lead sub-grid now tallies that SINGLE declarer's tricks, not
     best-of-pair — the honest "you are declarer and this was led" number. `base` stays best-of-pair (no
     lead ⇒ pair declares from its better side). The CLI `--lead` (Held_Card via sample_grid) is left as a
     more GENERAL card-location constraint that keeps best-of-pair (a card seen mid-play, not necessarily
     the opening lead); the opening-lead picker is the stricter model. No render change. Verified: the
     7NT numbers are unchanged on that (declarer-symmetric) hand; the fix bites on hands where the two pair
     members declare differently. `test_lead_grids` assertion made direction-agnostic (the swing is the
     point). 11 dd tests still pass.
   - **MULTI-BOARD INPUT DONE (2026-07-12).** `pbn_analyse` now parses EVERY `[Deal]` tag in the input (a
     hand-ocr session holds several) via `parse_boards` (scan for `[Deal` occurrences; a bare `N:...` value
     = one board). HTML renders them as ONE carousel page (`write_html` loops `render_board_body` between a
     single page shell; each board bakes its own `.par` target/sim/leads + `.combo` blob, so per-board CCA /
     contract picker / lead picker / auto-contract all work and the carousel nav updates the overlay to the
     active board). Text prints a `Board i of N` report per board. `run()` refactored around `sample_board`
     (per-board sampling + constraint validation + contract resolution, returns `Board_Sample`) shared by
     both paths. Constraints (`--void/--len/--lead`) require a SINGLE board (they name a specific board's
     seats/cards) — errored otherwise. **Two bugs fixed on the way:** (1) `dd.sample_lead_grids` now writes
     through a caller `^Lead_Grids` (it is ~118 KB; returning by value down the deeper call chain
     stack-overflowed → segfault); `Board_Sample.leads` is a heap pointer (`board_sample_free`). (2) the DDS
     `defer dd.shutdown()` was inside the `if sample>0` block scope so it fired right after `init` (before
     any sampling → segfault); moved to `run()` scope. Verified in-browser: a 2-board file → 2 slides,
     Board 1 auto-3NT 44% / Board 2 auto-6NT 100%, each its own picker + lead menu (53 opts; board 1
     correctly omits K♠ = a known card), nav switches the CCA. 11 dd + 97 norn tests, lint clean.
   - **REJECT-SAMPLING BUDGET raised 5000 → 50000 (2026-07-12).** A verification sweep found COMPOUND rare
     constraints (e.g. `--void E:H --lead W:AC` ≈ 0.1% of deals) exhausted the 5k per-sample redeal cap and
     failed ~2% of samples → the whole run errored. The common case (unconstrained / single void/length)
     finds a match on try 1, so a big cap is free there; 50k makes anything down to ~0.05% robust while a
     genuinely impossible set still terminates fast (~0.1 s) and fails cleanly. Error message reworded to
     "too rare or impossible". Verified: `--void E:H --lead W:AC` now samples (4S 0%, both conditions noted).
   - **AUTO-CONTRACT DONE (2026-07-12).** `--contract` is now OPTIONAL: omit it and `dd.best_contract(grid)`
     picks the contract maximising EXPECTED SCORE = P(make) × `contract_score` (neutral/undoubled; rewards
     making often AND being worth bidding — a cold 3NT beats 2NT, a 55% game beats a 95% part-score, a
     strong hand surfaces a slam). The CLI notes the auto-pick; the html bake seeds the picker's default
     strain+level from it (slider = level+6). Verified: weak-ish 4S hand auto-picks 3NT (43%), cold pair
     auto-picks 7NT (100%). `test_best_contract_prefers_value` (7 dd tests). `hand-ocr … | pbn_analyse
     --sample [--html out]` now needs no contract flag — the ocr→PBN→page pipe is friction-free on our side
     (stdin ingest already worked; hand-ocr itself is a separate in-progress tool). It ignores undertrick
     penalties, so it is a starting SUGGESTION the picker overrides, not a bidding oracle.
3. **Option C entry-aware / narratable per-suit lines** — later polish enriching the suit rows with
   real technique + prose; do NOT over-invest in the entry model (it is a per-suit approximation of the
   cross-suit reality DDS already captures).

Step 2 is a new engine but cheap-baked (reuses existing infra); step 3 is incremental on combo.

## Richer per-suit lines (Option A DONE; Option C ELEVATED — see the 2-hand section above)

The `line` column + hover tooltip narrate ONE of FIVE heuristics — three single-phase
(`line_top_down`/`line_finesse`/`line_duck_one`) plus the Option-A additions `line_finesse_other`
(two-way / other direction) and the COMPOUND `line_duck_then_finesse`. Remaining real technique
(safety plays, tree-shaped conditional lines, entry-aware optimal) is Options B/C below. Three ways to
go further, in feasibility order:

### Option A — expand the candidate compound lines — **DONE**

Added hand-written `Sd_Line` policies to brick 2. The DP (brick 4) + `best_line_by_mean` pick among
them automatically; the emit (`data-*-sd`, `-lines`, `-tips`) all flow through `best_line_by_mean`, so
**no wiring changes** — the new lines "just appear" as candidates, recommendations, and tooltips.
Verified in-browser data: `1major-game-force -n 12 --seed 7` shows both `finesse-other` and
`duck-then-finesse` selected on real deals, with correct tooltip narration. Verified in-browser
(playwright): CCA panel rebuilds on nav, board-5 club row shows the `duck-then-finesse` cell + hover
tooltip, N/S↔E/W and IMPs↔MPs toggles unregressed (0 JS errors). 37 combo tests pass, lint clean.

What shipped (of the plan below): **step 1 enabler** (`trick_no` threaded through `sd_deal_tricks`→
`sd_from_lead`/`sd_trick` into `lead(...)` and `Sd_View`); **step 2** `line_duck_then_finesse` (the
canonical duck-then-finesse) and `line_finesse_other` (the two-way / other-direction finesse); steps
**3** (registered in `candidate_lines`, now `[5]`), **4** (`describe_suit_line` cases — a shared
`describe_finesse` helper serves plain + compound finesse; `finesse-other` reuses the finesse prose;
`duck-then-finesse` prepends the duck sentence), **5** (3 new `lines_test.odin` tests). **Not built:**
`line_deep_finesse` (redundant — `line_finesse` already runs the lowest card beating RHO, i.e. a deep
finesse, and repeats it every trick under free entries) and `line_safety_N` (deferred as planned).

Original plan, for reference:
1. **Enabler — thread a trick/round index to the line.** `Sd_Line` procs are pure fns of public state,
   but they can't currently tell "which round is this" reliably from `played` alone (can't separate our
   spent cards from the opponents'). Fix: thread a `trick_no` (0-based) through the fixed-line evaluator
   (`sd_deal_tricks`→`sd_from_lead`/`sd_trick` in `single_dummy.odin`) into `lead(...)` and `Sd_View`.
   Small, localised change. This is what makes PHASED (compound) policies trivial to write.
2. **Add compound `Sd_Line`s** (in `lines.odin`), each a phase switch on `trick_no`:
   - `line_duck_then_finesse` — trick 0: duck (low from both); trick ≥1: the `line_finesse` rule. The
     user's canonical example.
   - `line_deep_finesse` — insert the LOWEST relevant honour (e.g. run the 10/J), not just the cheapest
     card that beats RHO — catches two missing honours.
   - `line_two_way_finesse` — finesse the OTHER side (add both directions as candidates; the DP/best_line
     picks, and on a genuine two-way it just exposes the guess — matches brick-3's finding).
   - `line_safety_N` (harder, later) — cash a top then duck to guarantee N tricks against a bad break.
3. **Register** in `candidate_lines()`. Done — DP/best_line/Pareto consume them.
4. **Describers** — extend `describe_suit_line` (`combo.odin`) with a case per new line. Phase structure
   makes narration easy: "Duck one round, then lead low and finesse the Q…". Keep the NO-apostrophe /
   no-double-quote rule (tips sit in a single-quoted HTML attribute).
5. **Tests** (`lines_test.odin`) — holdings where the compound strictly wins: e.g. a suit needing an
   entry-preserving duck before the finesse; a two-way holding where the other-way finesse is better.

Effort: ~one session. Always works (any holding), deterministic, every recommendation narratable.
Limitation: still a CURATED heuristic set, not provably optimal (that is brick 3 / Option C).

### Option B — extract the line from brick-3's optimal solver (parked)

`opt_solve` already computes the optimal action at each belief node but discards it. Capturing the
argmax → the optimal POLICY is moderate; but (1) brick 3 is EXACT only on long holdings (few missing) —
most random-deal suits are short and fall back, so no policy; and (2) the optimal policy is a TREE
(branches on defenders' cards), so honest narration must be CONDITIONAL ("duck; lead low; if the K
covers, win the A; else finesse"), which is fuzzy to render. Multi-session, partial coverage. Not next.

### Option C — entry-aware lines + a suit-combination REFERENCE library (ELEVATED — see the 2-hand section above)

**Status change:** Option C was "later; worth examining." It is now the **recommended first realism
deliverable for the 2-hand (declarer + dummy) advisor** — because with only two hands there is no `dd`
par to cross-check combo's optimism, and the FREE-ENTRIES assumption (assumption 1) is that optimism's
single biggest source. The entry-count refinement (below) is what makes the solo single-dummy numbers
materially honest. Read this section together with "★ NEXT MAJOR LINE OF WORK" above.

The principled "true optimal, fully described" route, and it aligns with our isolated-suit model. Many
bridge sources publish the known optimal line + expected tricks for every canonical holding:
- **Richard Pavlicek's suit-combination pages**, the **Official Encyclopedia of Bridge** suit-combination
  tables, **SuitPlay** (Jeroen Warmerdam's solver — computes the optimal line for any holding),
  **Bridge Encyclopedia / Bridatlas**, and various online "suit combination" lists/calculators.
- Approach: canonicalise a holding by TOPOLOGY (relative order of our vs. their cards — the same
  equivalence `canonical_plays` already uses), key into an imported/encoded table, and emit the known
  optimal line text + tricks. This gives provable optimality AND clean prose, per suit.
- **The entry-count refinement (user's idea, and the big win).** Real references parameterise lines by
  ENTRIES — how many times you can lead from each hand — because a repeated finesse needs repeated
  entries to the hand behind the tenace. Our whole model currently assumes **assumption 1: FREE ENTRIES**
  (unlimited leads from either hand). Adding a per-suit "entries to North / entries to South" input (or a
  small default like 1–2 each) and choosing the line accordingly would PARTLY RELAX that naive assumption
  — the single biggest source of the tool's optimism. So Option C is not just prettier text: entry-aware
  lines make the achievable (SD) numbers materially more realistic. The card page could expose entry
  counts as a per-board or per-suit control feeding the line choice.
- Effort: LARGE — sourcing/encoding the reference (watch data licensing if scraping), topology
  canonicalisation, entry-parameterised line selection, and reconciling with the convolution/DP. Weeks,
  a project of its own. Examine it once Option A's curated set stops being enough.

### hand-ocr pipeline + 4-hand deals DONE 2026-07-16

**Image / PBN → card page pipeline (Stage A).** `just ocr-analyse <image>` (→ `<base>.html`) and `just
ocr-pbn <image>` bridge the sibling **hand-ocr** repo (uv/Python, at `$HAND_OCR_DIR`, default
`~/dev/bridge-hand-ocr`) to pbn_analyse via `tools/ocr_analyse.py` (runs `uv run --project "$HAND_OCR_DIR"
python hand-ocr.py … | pbn_analyse.exe`).
`just ocr-analyse --demo` plumbing-tests it end-to-end (no vision deps). pbn_analyse reads a PBN string,
`--file`, or stdin, multi-board. **Bug fixed:** `parse_boards` matched bare `[Deal`, which also caught a
`.pbn` file's `[Dealer]`/`[Declarer]` tags → spurious duplicate boards; now matches `[Deal "` (`DEAL_TAG`).
**LIN is not read** (no reader; LIN can only express a complete deal — use PBN, whose `-` marks unknown
hands the 2-hand advisor needs).

**4-hand deals (Stage B1).** A fully-known PBN deal now takes the EXACT double-dummy path instead of
bailing "Not a 2-hand board": `board_fully_known` → `render_full_deal_body` (HTML) / `report_full_deal`
(text) reuse the sim card-page flow — `norn.render_deal_html_cards` (4 hands face-up) + `dd.annotate`
(one `CalcDDtable` of the ACTUAL deal → the `.par` caption: par + NS-makeable + the CCA slider
`data-target`) + `combo.annotate` on the real deal (both partnerships' CCA). DDS is inited when any
board is full (not only `--sample`). Page title reflects content (advisor / "Bridge deal analysis
(double-dummy + CCA)" / mixed). Verified: text (`Par: NS 990 [6NT NS] — NS make: 6NT 6S 5H 5C 5D`) + HTML
(4 hands face-up, both-sides CCA, exact `.par`, 0 JS errors). Golden + lints clean.

**Stage B2 — exact-DD contract explorer on full deals DONE 2026-07-16.** The B1 page rendered par +
makeable + CCA but the ♠♥♦♣NT picker, trick slider, and green band stayed dark (they only wake for a
`data-sim` grid). Now `dd.exact_grid(deal)` (`dd/sample.odin`) returns a `Grid_Result` whose every strain
is a SPIKE at the NS double-dummy trick count (`max(resTable[strain][N|S])`), `n=1` — the exact census, no
sampling; it reuses `solve_table`'s per-board cache (`dd.annotate` just solved the same deal).
`render_full_deal_body` bakes it via `write_exact_sim_json` (`{"n":1,"exact":true,"lvl","strain","g"}`,
preselecting NS's best-making contract) onto a hidden **`.sim-exact`** div — `dd.annotate` owns the `.par`,
so the grid rides its own element and `render.odin` now reads `el._sim` from ANY `[data-sim]` in the slide
(2-hand `.par` or full-deal `.sim-exact`). `simBand` gates on `sim.exact`: shows "Double-dummy (exact):
N♠ **makes/fails** (known deal, both defenders visible)", NO sampling ± / deal count, NO misguess-tax rung
(both defenders visible), and the recon strip reads "double-dummy" not "simulated". The picker + slider now
explore any contract's exact DD result and line it up against the per-level CCA rows. 2-hand path fully
untouched (browser-verified both: full-deal 6♠ makes / 7NT fails / 6NT makes; 2-hand still "simulated 72%
± · achievable 37% (Q♠ guess −35)"). Test `test_exact_grid_spikes` (dd now **25**). Golden + lints clean.

### Option C — C1 (narration only) DONE 2026-07-16

**SHIPPED.** The per-suit line tooltip now names the blind two-way guess and its cost. `pbn_analyse.odin`
bakes `data-sim-guess='{"side":"ns","suits":{"s":{"card":"QS","tax":34}}}'` on the hidden `.par` div
(`write_sim_guess_json` + `tax_has_narratable_guess` gate + `suit_key`), keyed by suit, DOMINANT pivot per
suit, `tax` = that guess's MARGINAL cost (ceiling − pivot.achievable, rounded); suits whose guess is
cushioned (marginal < 1) are omitted, and the whole attr is dropped when nothing is narratable.
`render.odin` reads it into `el._simGuess` and, in `ctTableHTML`, appends "Blind two-way guess for the
Q♠ — a misguess costs about 34%." to that suit's `data-tip` — but ONLY while the CCA view shows the
declaring side (`guess.side === ccaSide`). combo stays SOLVER-FREE (the dd→UI bridge lives entirely in
pbn_analyse + render, never combo). Browser-verified (playwright): ♠ row carries the clause, ♥/♦/♣ clean,
EW side suppresses it, 0 JS errors (favicon only). Golden `just test-golden` now pins BOTH `data-sim` and
`data-sim-guess` (`tests/golden/two_way_q_3nt.simguess.json`). Lints clean.

**Original committed plan (for reference):**

**Reframing (decided).** Option C originally bundled TWO realism deliverables — an entry-aware line model
and a provably-optimal suit-combination REFERENCE LIBRARY. **DDS-sampling already fixed the realism**
(sins 1+2+3, whole-hand — see the "Option C vs DDS-sampling" trade table: C's "surviving justification is
narration, not realism"). So the committed scope is **narration only**. The reference library (now C2) and
entry model (now C3) are demoted to low-ROI options, OFF the critical path.

**The gap C1 closes.** The per-suit `line` column + `data-{ns,ew}-tips` tooltip narrate the combo
HEURISTIC line ("finesse the Q") with NO hint that that suit carries a blind two-way guess the misguess-
tax already priced. The user reads "finesse the Q" and cannot tell it is the 50/50 costing the contract
35%. C1 ties the pretty prose to the validated tax so narration and numbers tell ONE story.

**C1 stages (small, ~1 session, no new correctness risk — grounded in already-validated tax pivots +
already-tested combo describers):**
1. **Thread tax → per-suit render.** `Board_Sample` already carries `bs.tax`/`bs.tax_ok`. Pass the pivot
   set into the per-suit annotation path at the `combo.annotate` call site in `pbn_analyse.odin` (~line
   737), or overlay after it. `tax.pivots[i].card` names the guessed suit(s) and `tax.tax_pts` the cost.
2. **Append a guess clause** in/around `describe_suit_line` (`combo/combo.odin:1360`) for any suit holding
   a tax pivot: e.g. "— blind two-way guess (~50/50); a misguess taxes the contract N%". Reuse the pivot
   card + `tax_pts`. Keep the NO-apostrophe / NO-double-quote rule (tips live in single-quoted HTML attrs).
3. **Emit.** Bake the clause into the existing `data-{ns,ew}-tips` strings server-side (simplest, no client
   change); the render.odin tooltip (`.cca-tip`) shows it for free. (Alt: a parallel `data-*-guess` attr
   the client merges — only if server-side bake is awkward.)
4. **Tests.** combo/lines test: the describer includes the guess clause IFF a pivot sits in that suit, and
   omits it otherwise (no false clause on guess-free suits). Extend `just test-golden` with a TIPS fixture
   on the two-way ♠Q board so the narration string is pinned byte-for-byte like `data-sim` already is.

**Explicitly NOT in C1:** the reference library (C2 — LARGE, licensing, realism now redundant → pursue
only for a teaching-grade "textbook optimal line is X" oracle); entry-aware line selection (C3 — medium,
realism redundant, per-suit entry budget is the cross-suit fudge DDS does correctly); Option B tree/
conditional narration (honest but fuzzy to render, partial coverage). These stay parked above.

## Phase-1 bug fixed while building brick 3 (affects shipped output)

`suit_dd_tricks`'s "opponents exhausted" shortcut returned `count(N) + count(S)` — the SUM of both NS
holdings. But in this 4-hand model both NS hands follow every trick (two NS cards spent per trick), so
once the opponents are void the tricks left are **`max(len N, len S)`**, not the sum. The old code
double-counted any suit running in BOTH hands after the defenders run out — e.g. AKQJT9 opposite 87654
(opponents holding just the two lowest) read **9** tricks when the true answer is **6**. Fixed in
`combo.odin` (and the identical shortcut in `single_dummy.odin`'s `sd_from_lead`). This LOWERS the naive
combo numbers on running suits — part of the old "overshoots par" gap was this bug, not just the naive
assumptions. Only long/running holdings were affected; all pre-existing (short-holding) tests were
unchanged. No golden test previously covered a long suit — the whole reason it slipped through.

## Verified results worth remembering

- `Q985` opp stiff `K`: E≈1.14 (p1=87%, p2=13%). NOT a bug/dumb play — the singleton **blockage** is
  real (free entries don't unblock a singleton), and the 13% two-trick cases are layouts where even
  best defence is *stuck* (ace-holder too short to both duck the K and keep the ace over the Q). Same 5
  cards `KQ985` solid-in-one-hand → E≈1.92: the ~0.8 gap IS the double-dummy cost of the block.
- The distribution varies over **layouts**, not play quality — perfect play both sides *per layout*.

## Future: splitting combo into norn vs odin-sims

When Phase 2 (or a later phase) stabilises and the analysis API stops changing, the package
should split along this boundary:

**Move to `~/dev/norn/combo/` (pure analysis — generic, no project coupling):**
- `suit_trick_distribution`, `dd_tricks`, `suit_dd_tricks` / `play_card` (Phase 1 core)
- `sd_line_distribution`, `sd_deal_tricks` (Phase 2 fixed-line evaluator)
- `sd_optimal_distribution` (Phase 2 optimal search)
- `Sd_Line`, `Sd_View`, `Line_Result`, `Suit_Trick_Dist`, `Deal_Analysis`
- `candidate_lines`, `suit_candidate_lines`, `pareto_lines`, `best_line`, `best_line_by_mean`
- `analyse_ns`, `analyse_deal_ns`, `convolve`, `p_at_least`, `expected_tricks`
- `adaptive_at_least_curve`, `best_fixed_combination`, `optimal_adaptive_value`
- All `Objective` / `objective_*` / `apply_objective` / `dp_value`
- `g_binom` and `init_binom`

This layer has zero deps outside norn and is useful to any program built on the library.

**Keep in `odin-sims/combo/` (rendering — tightly coupled to this project's card page):**
- `annotate` (references `norn.Output_Format.Html_Cards`, `norn.Deal_Annotator`)
- `write_suits_json`, `write_suits_json_sd`, `write_suits_lines_json`, `write_suits_tips_json`
- `write_curve_json`, `write_prob`, `write_pct`, `format_analysis`
- `describe_suit_line`, `describe_finesse`, `describe_cash`, `write_cards_desc`

These reference this project's specific `data-ns`, `data-ns-sd`, `data-ns-atl`, `data-ns-lines`,
`data-ns-tips` HTML attribute contract — not appropriate for norn.

**Why not now:** combo is still evolving; the analysis API (especially Phase 2 / optimal search)
will change. Moving to norn implies a stability contract. The rendering and analysis are
co-evolving. Revisit after Phase 3 (if any) is complete and the API has been stable for one
season of use. See `PERFORMANCE.md` §9 for threading implications of the same split.

## Performance / threading (see `PERFORMANCE.md`)

`combo.annotate(.Html_Cards)` is the render hot path — optimised 471 → **12.6 ms/deal**. Latest work: a
process-lifetime `thread.Pool` runs each deal's **16 per-suit tasks** (8 double-dummy census suits + 8
single-dummy candidate gathers, NS+EW) concurrently, assembled on the caller via the shared
`finish_census`/`finish_sd` seams; each worker keeps its minimax memos + a temp arena in thread-local storage
(zero heap allocs/deal, freed once by `combo.shutdown`). The serial reference (`-define:COMBO_THREADS=false`)
stays byte-identical — the parity gate. Full account (including the two measurement-falsified premises: the
convolution cost, and coarse-threading spawn overhead) in `PERFORMANCE.md` §0 / §9.4.

## Reference

- Suit-combination inspiration: <https://bridge.esmarkkappel.dk/main/main.html>.
- Companion handoff for the card page it renders into: `HTML_CARDS.md`.
- Vacant-space / split odds: <http://www.durangobill.com/BrSplitStats.html>.
