package deal_solve

/*
	dd — double-dummy analysis for the sim, bridging norn's card model to the odin-dds solver.

	This is the ONLY place the DDS dependency lives. norn stays solver-free by design (see its
	cards.odin header: "conversion happens at that boundary only") and its generation core exposes
	two engine-agnostic hooks — a `norn.Deal_Filter` and a `norn.Deal_Annotator`. This package
	supplies concrete ones backed by DDS; sim.odin passes them to `cli.main_program` as a
	`cli.Gen_Hooks`, and they fire only under the `--dd` flag.

	Lifecycle: DDS is statically linked, so it has no DllMain auto-init. `init` MUST run once at
	startup (before any solve) and `shutdown` once at exit — see sim.odin's main.

	Threading: `CalcDDtable`/`Par` share DDS's process-global transposition tables and are NOT safe
	to call concurrently. norn's batch HTML export forces single-threaded generation whenever a DD
	hook is set (see cli/run.odin), so the hooks here can assume they run one at a time — which is
	also what makes the single-slot `solve_table` cache below safe as a package global.
*/

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import dds "dds:."
import "norn:norn"
import "../par_caption"

/*
One-time DDS setup: size the per-thread transposition tables and build its constant lookups. MUST be
called before any solve. `threads = 0` lets DDS pick a count from the core count.

MEASURED COST, on a 24-core machine: `SetMaxThreads(0)` commits **172MB** at init and a real `--dd`
generation peaks at **542MB**, all of it held until `shutdown`. `DDS_MAX_MB` swaps that for
`SetResources(mb)` - the same budget, capped. The whole curve, 24 deals of `slam-makes-dd`, seed 11
(`just dds-timing`):

	  16MB   DDS DIES ("Memory::GetPtr: 0 vs. 0", immediately)
	  32MB   6.38s   35MB peak      <- starved: SLOWER than the cap saves
	  48MB   4.68s   43MB peak
	  64MB   4.74s   45MB peak
	 128MB   4.08s   72MB peak      <- 4% slower than default, 7.5x less memory
	 256MB   4.12s   85MB peak
	default  3.95s  542MB peak

So a cap is close to free above ~128MB and actively harmful below ~48MB, and 16MB is not a
configuration but a crash - hence the floor below, which refuses rather than letting the solver die
inside a batch.

An env var rather than an argument because it is a property of the MACHINE the process is running on
rather than of what any one caller is doing: every program here (sim, analyse_deal, the workbench)
wants the same answer, and none of them should have to have an opinion about it.
*/
init :: proc(threads: i32 = 0) {
	// Below this DDS does not run slowly, it dies mid-batch. Measured at 16MB; 32 is the smallest value
	// that completed, and it was slower than no cap at all.
	DDS_FLOOR_MB :: 32
	if capped := os.get_env("DDS_MAX_MB", context.temp_allocator); capped != "" {
		mb, ok := strconv.parse_int(capped)
		switch {
		case !ok || mb <= 0:
			fmt.eprintfln("deal_solve: DDS_MAX_MB=%q is not a positive number - using the default tables", capped)
		case mb < DDS_FLOOR_MB:
			fmt.eprintfln(
				"deal_solve: DDS_MAX_MB=%d is below the %dMB floor (the solver dies there) - using the default tables",
				mb,
				DDS_FLOOR_MB,
			)
		case:
			dds.SetResources(i32(mb), threads)
			return
		}
	}
	dds.SetMaxThreads(threads)
}

// Release DDS's memory. Call once at process exit, after the last solve.
shutdown :: proc() {
	dds.FreeMemory()
}

// Convert a norn `Deal` to a DDS `Table_Deal` (the 52 cards as [Hand][Suit]Holding). The mapping:
//   - Seats coincide: norn `Seat` and dds `Hand` are both N,E,S,W in that order -> identity.
//   - Suits run opposite: norn Clubs..Spades (0..3) vs dds Spades..Clubs (0..3) -> dds = 3 - norn.
//   - Ranks shift by 2: norn Two=0..Ace=12; a dds Holding sets bit r for rank r (deuce = bit 2,
//     ace = bit 14), so a norn per-suit rank mask is just `<< 2` into a Holding word.
// Built off the deal summary norn already computes, so this is a handful of shifts, no card rescan.
to_table_deal :: proc(deal: norn.Deal) -> dds.Table_Deal {
	td: dds.Table_Deal
	ds := norn.summarize_deal(deal)
	for seat in norn.Seat {
		for suit in norn.Suit {
			dds_suit := dds.Suit(3 - int(suit))
			mask := u32(norn.suit_mask(ds[seat], suit)) << 2
			td.cards[dds.Hand(int(seat))][dds_suit] = transmute(dds.Holding)mask
		}
	}
	return td
}

// Per-deal double-dummy table cache (single slot). The filter and the annotator both want the SAME
// CalcDDtable result for the SAME accepted deal — the filter solves it during reject-sampling, the
// annotator again at render — so without sharing, every accepted deal of a filtered+annotated
// scenario is solved twice. `solve_table` memoises the last deal's table and returns it unchanged
// on a repeat call for an identical deal.
//
// Safe as a package global: every scenario that reaches DDS runs SINGLE-THREADED (the export/freq
// partition serialises DDS scenarios — the same non-reentrancy reason DDS itself needs), so only one
// thread touches this.
//
// NEVER needs invalidation. The cache key is the full 52-card deal value, so a HIT occurs only on a
// byte-identical deal, which by definition has the identical DD table; a MISS (any other deal, incl.
// across scenarios, or when a non-CalcDDtable filter like ns_makes_strain left the slot holding an
// earlier deal) just recomputes. deal and table are written together after a successful solve, so a
// valid hit can never return a mismatched table. Nothing to clear "after annotation".
@(private)
g_cache_deal: norn.Deal
@(private)
g_cache_table: dds.Table_Results
@(private)
g_cache_valid: bool

// Solve — or reuse — the full double-dummy table for `deal`. Returns a pointer to the cached table;
// ok=false only if DDS itself failed. The pointer stays valid until the next distinct deal is solved.
@(private)
solve_table :: proc(deal: norn.Deal) -> (table: ^dds.Table_Results, ok: bool) {
	if g_cache_valid && deal == g_cache_deal {
		return &g_cache_table, true
	}
	td := to_table_deal(deal)
	if dds.CalcDDtable(td, &g_cache_table) != .NO_FAULT {
		g_cache_valid = false
		return nil, false
	}
	g_cache_deal = deal
	g_cache_valid = true
	return &g_cache_table, true
}

// A `norn.Deal_Annotator`: append the deal's double-dummy summary after its rendered deal, in a
// form valid for the active `format`. Annotation is format-specific by nature — an HTML caption
// would corrupt a PBN tag or a machine-parsed line — so this switches on the format and emits
// nothing for the machine formats whose grammar has no room for it:
//   - Html_Handviewer : a visible caption div (par + makeable contracts) plus a greppable trick-table comment
//   - Html_Cards      : the same, as a `.par` caption the carousel pairs with its deal (plus the comment)
//   - Pretty  : a plain trailing "Par (NS): ..." line (the layout is human-facing already)
//   - Pbn     : a PBN `{ ... }` inline comment (the only annotation PBN's grammar accepts)
//   - Line / Numeric / Handviewer : nothing — these are consumed by parsers; any extra text breaks them
annotate :: proc(builder: ^strings.Builder, deal: norn.Deal, format: norn.Output_Format) {
	// Classify the format. A FULL switch (no #partial) is deliberate: if norn gains a new
	// Output_Format, this fails to compile until the new format is put on one side or the other, so
	// annotation can never silently skip — or corrupt — a format nobody classified here.
	switch format {
	case .Line, .Numeric, .Handviewer, .Lin:
		// Machine-parsed output: no annotation, and skip the solve entirely. `Lin` belongs here even though
		// it is a record rather than a line - it has no comment syntax to put a par caption in, and a
		// viewer would take anything extra as a malformed token.
		return
	case .Html_Handviewer, .Html_Cards, .Pretty, .Pbn:
	// annotated below
	}

	// Reuse the filter's solve of this same deal where possible (see solve_table): filter and
	// annotator otherwise each CalcDDtable the accepted deal. The full table is 5 x 4 = 20 strain x
	// declarer trick counts; the annotator needs all of them (it prints the whole grid + par).
	res, ok := solve_table(deal)
	if !ok {
		if format == .Html_Handviewer || format == .Html_Cards {
			strings.write_string(builder, "<!-- deal_solve error: solve failed -->")
		}
		return
	}
	// Par from the full table. SidesParBin gives the STRUCTURED par (level/denom/seats + undertricks)
	// for each side; we render the declaring seats and doubling ourselves so a par that is a doubled
	// EW sacrifice reads as e.g. "5Cx EW-2" rather than a plain score. The two sides agree except on
	// rare deals; we show the NS-first result. Neutral vulnerability (deals carry v=- unless
	// --fixed-table), which matters because sacrifice economics are vulnerability-sensitive.
	sides: [2]dds.Par_Results_Master
	have_par := dds.SidesParBin(res, &sides, .None) == .NO_FAULT
	ns_par := &sides[dds.Side.NS]

	// Per-hand summaries feed the naive combined-OPC figure in the par guide.
	ds := norn.summarize_deal(deal)
	// The caption is WRITTEN by `par_caption`, from these numbers, so the shared-deals player (which has no
	// DDS) can write the same caption from numbers a link carries.
	tricks := caption_tricks(res)
	par := caption_par(ns_par)

	// Also a full switch: the machine formats are unreachable here (filtered above) but listed so a
	// newly added annotating format must add its own emission case rather than fall through silently.
	switch format {
	case .Html_Handviewer, .Html_Cards:
		par_caption.write_html_caption(builder, &tricks, &par, have_par, ds, cards = format == .Html_Cards)

	case .Pretty:
		strings.write_string(builder, "\n  Par: ")
		par_caption.write_par(builder, &par, have_par)
		strings.write_string(builder, " - NS make:")
		par_caption.write_makeable(builder, &tricks)
		par_caption.write_par_opc_guide(builder, &par, have_par, ds, "\n  ", false)

	case .Pbn:
		// Braces must NOT go through a printf format string — Odin's fmt reads `{` as an argument
		// reference — so the PBN `{ ... }` comment delimiters are written literally.
		strings.write_string(builder, " { par ")
		par_caption.write_par(builder, &par, have_par)
		strings.write_string(builder, "; NS make:")
		par_caption.write_makeable(builder, &tricks)
		par_caption.write_par_opc_guide(builder, &par, have_par, ds, "; ", false)
		strings.write_string(builder, " }")

	case .Line, .Numeric, .Handviewer, .Lin:
	// unreachable: filtered out by the classifier switch above
	}
}

// A `norn.Deal_Filter`: keep the deal only if North-South can make a game double-dummy — 3NT (9
// tricks), 4 of a major (10), or 5 of a minor (11) — with either N or S declaring. A summary
// predicate can't ask this; it needs the solved trick counts. Use as a scenario's second stage so
// DDS runs only on the deals that already passed the bidding predicate.
ns_makes_game :: proc(deal: norn.Deal) -> bool {
	return side_makes(deal, .North_South, .Game)
}

// A `norn.Deal_Filter`: keep the deal only if North-South can make a small slam (12+ tricks) in
// some strain double-dummy, with either N or S declaring. Pair it with slam-zone scenarios so the
// export shows deals that actually play for slam, not just ones that bid like it.
ns_makes_slam :: proc(deal: norn.Deal) -> bool {
	return side_makes(deal, .North_South, .Slam)
}

// The rest of the side x goal grid, as plain `norn.Deal_Filter`s (a filter carries no data, so each pair is
// its own proc). A scenario file's `double-dummy:` line picks one of these (see `makes_filter`).
ns_makes_grand :: proc(deal: norn.Deal) -> bool {return side_makes(deal, .North_South, .Grand)}
ew_makes_game :: proc(deal: norn.Deal) -> bool {return side_makes(deal, .East_West, .Game)}
ew_makes_slam :: proc(deal: norn.Deal) -> bool {return side_makes(deal, .East_West, .Slam)}
ew_makes_grand :: proc(deal: norn.Deal) -> bool {return side_makes(deal, .East_West, .Grand)}

// Which partnership a "makes" filter asks about, and what it must make: game (3NT, 4 of a major, 5 of a
// minor), a small slam (12 tricks) or a grand (13), in any strain, either hand declaring.
Makes_Side :: enum {
	North_South,
	East_West,
}

Makes_Goal :: enum {
	Game,
	Slam,
	Grand,
}

// The filter for a side and a goal.
makes_filter :: proc(side: Makes_Side, goal: Makes_Goal) -> norn.Deal_Filter {
	FILTERS :: [Makes_Side][Makes_Goal]norn.Deal_Filter {
		.North_South = {.Game = ns_makes_game, .Slam = ns_makes_slam, .Grand = ns_makes_grand},
		.East_West = {.Game = ew_makes_game, .Slam = ew_makes_slam, .Grand = ew_makes_grand},
	}
	filters := FILTERS
	return filters[side][goal]
}

// Does `side` make `goal` double-dummy? One table solve.
side_makes :: proc(deal: norn.Deal, side: Makes_Side, goal: Makes_Goal) -> bool {
	res, ok := solve_table(deal)
	if !ok {
		return false
	}
	switch goal {
	case .Game:
		return(
			pair_makes(res, side, .NT, 9) ||
			pair_makes(res, side, .Spades, 10) ||
			pair_makes(res, side, .Hearts, 10) ||
			pair_makes(res, side, .Diamonds, 11) ||
			pair_makes(res, side, .Clubs, 11) \
		)
	case .Slam, .Grand:
		need := i32(12 if goal == .Slam else 13)
		for strain in dds.Strain {
			if pair_makes(res, side, strain, need) {
				return true
			}
		}
	}
	return false
}

// True if either hand of `side`, as declarer, takes at least `need` tricks in `strain` (double-dummy).
@(private)
pair_makes :: proc(res: ^dds.Table_Results, side: Makes_Side, strain: dds.Strain, need: i32) -> bool {
	if side == .North_South {
		return res.resTable[strain][.North] >= need || res.resTable[strain][.South] >= need
	}
	return res.resTable[strain][.East] >= need || res.resTable[strain][.West] >= need
}

// Single-strain double-dummy test: true if NS can take `tricks`+ in ONE `strain`, N or S declaring.
//
// Cheaper than the CalcDDtable path for a filter that only cares about a single strain: a couple of
// `SolveBoard` calls solve just that strain instead of computing all 5 x 4 = 20 cells. It reproduces
// exactly the `resTable[strain][.North/.South]` values the CalcDDtable-based `ns_makes` reads (see
// `declarer_makes` for the mapping), so it stays consistent with those filters and the annotation.
//
// NOTE: this deliberately BYPASSES `solve_table`, so use it only for filter-ONLY scenarios. A scenario
// that also annotates already pays for the full CalcDDtable (the annotator needs the whole grid), and
// sharing that cached table is cheaper than extra SolveBoards. `ns_makes_strain` is not itself a
// `norn.Deal_Filter` (wrong arity) — wrap it, e.g.
//     ns_makes_4h :: proc(b: norn.Deal) -> bool { return ns_makes_strain(b, .Hearts, 10) }
// and register that in sim.odin's dd_filters. Like every DDS call it assumes single-threaded use.
ns_makes_strain :: proc(deal: norn.Deal, strain: dds.Strain, tricks: i32) -> bool {
	return declarer_makes(deal, strain, .North, tricks) || declarer_makes(deal, strain, .South, tricks)
}

// SolveBoard core for `ns_makes_strain`: does `declarer`'s side take `tricks`+ in `strain`? DDS's
// `SolveBoard` scores the side ON LEAD, and a contract's opening lead comes from declarer's LHO (the
// next hand clockwise), so we solve with `first = LHO`, read the LEADING side's max tricks, and the
// declaring side's tricks are `13 - that`. This matches `resTable[strain][declarer]` exactly. (Using
// TARGET_FIND_MAX; a `.One` + `target` solve could early-exit but complicates the make/beat logic.)
@(private)
declarer_makes :: proc(deal: norn.Deal, strain: dds.Strain, declarer: dds.Hand, tricks: i32) -> bool {
	dl: dds.Deal
	dl.trump = strain
	dl.first = dds.Hand((int(declarer) + 1) % 4) // opening leader = declarer's LHO
	dl.remainCards = to_table_deal(deal).cards // [Hand][Suit]Holding, same layout as Table_Deal.cards
	fut: dds.Future_Tricks
	if dds.SolveBoard(dl, dds.TARGET_FIND_MAX, .One, .Auto_Skip_Single, &fut) != .NO_FAULT || fut.cards == 0 {
		return false
	}
	return 13 - fut.score[0] >= tricks // declaring side's tricks = 13 - leading side's max
}

// DDS's trick table as `par_caption`'s. The enums mirror DDS's orders, so this is a value copy.
caption_tricks :: proc(res: ^dds.Table_Results) -> (tricks: par_caption.Tricks) {
	for strain in dds.Strain {
		for hand in dds.Hand {
			tricks[par_caption.Strain(strain)][par_caption.Hand(hand)] = int(res.resTable[strain][hand])
		}
	}
	return
}

// DDS's par result as `par_caption`'s.
caption_par :: proc(m: ^dds.Par_Results_Master) -> (par: par_caption.Par) {
	par.score = int(m.score)
	par.number = clamp(int(m.number), 0, len(m.contracts))
	for i in 0 ..< par.number {
		c := m.contracts[i]
		par.contracts[i] = {
			under_tricks = int(c.underTricks),
			over_tricks  = int(c.overTricks),
			level        = int(c.level),
			denom        = par_caption.Denom(c.denom),
			seats        = par_caption.Seats(c.seats),
		}
	}
	return
}

// The two `par_caption` helpers the rest of this package uses, in DDS's types.
@(private)
contract_score :: proc(strain: dds.Strain, level: i32) -> i32 {
	return i32(par_caption.contract_score(par_caption.Strain(strain), int(level)))
}

@(private)
strain_label :: proc(strain: dds.Strain) -> string {
	return par_caption.strain_label(par_caption.Strain(strain))
}
