package dd

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
import "core:slice"
import "core:strings"

import dds "dds:."
import "norn:norn"

// One-time DDS setup: size the per-thread transposition tables and build its constant lookups. MUST
// be called before any solve. `threads = 0` lets DDS pick a count from the core count.
init :: proc(threads: i32 = 0) {
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
to_table_deal :: proc(board: norn.Deal) -> dds.Table_Deal {
	td: dds.Table_Deal
	ds := norn.summarize_deal(board)
	for seat in norn.Seat {
		for suit in norn.Suit {
			dds_suit := dds.Suit(3 - int(suit))
			mask := u32(ds[seat].suits[suit]) << 2
			td.cards[dds.Hand(int(seat))][dds_suit] = transmute(dds.Holding)mask
		}
	}
	return td
}

// Per-board double-dummy table cache (single slot). The filter and the annotator both want the SAME
// CalcDDtable result for the SAME accepted board — the filter solves it during reject-sampling, the
// annotator again at render — so without sharing, every accepted deal of a filtered+annotated
// scenario is solved twice. `solve_table` memoises the last board's table and returns it unchanged
// on a repeat call for an identical board.
//
// Safe as a package global: every scenario that reaches DDS runs SINGLE-THREADED (the export/freq
// partition serialises DDS scenarios — the same non-reentrancy reason DDS itself needs), so only one
// thread touches this.
//
// NEVER needs invalidation. The cache key is the full 52-card board value, so a HIT occurs only on a
// byte-identical deal, which by definition has the identical DD table; a MISS (any other board, incl.
// across scenarios, or when a non-CalcDDtable filter like ns_makes_strain left the slot holding an
// earlier board) just recomputes. board and table are written together after a successful solve, so a
// valid hit can never return a mismatched table. Nothing to clear "after annotation".
@(private)
g_cache_board: norn.Deal
@(private)
g_cache_table: dds.Table_Results
@(private)
g_cache_valid: bool

// Solve — or reuse — the full double-dummy table for `board`. Returns a pointer to the cached table;
// ok=false only if DDS itself failed. The pointer stays valid until the next distinct board is solved.
@(private)
solve_table :: proc(board: norn.Deal) -> (table: ^dds.Table_Results, ok: bool) {
	if g_cache_valid && board == g_cache_board {
		return &g_cache_table, true
	}
	td := to_table_deal(board)
	if dds.CalcDDtable(td, &g_cache_table) != .NO_FAULT {
		g_cache_valid = false
		return nil, false
	}
	g_cache_board = board
	g_cache_valid = true
	return &g_cache_table, true
}

// A `norn.Deal_Annotator`: append the deal's double-dummy summary after its rendered board, in a
// form valid for the active `format`. Annotation is format-specific by nature — an HTML caption
// would corrupt a PBN tag or a machine-parsed line — so this switches on the format and emits
// nothing for the machine formats whose grammar has no room for it:
//   - Html_Handviewer : a visible caption div (par + makeable contracts) plus a greppable trick-table comment
//   - Html_Cards      : the same, as a `.par` caption the carousel pairs with its board (plus the comment)
//   - Pretty  : a plain trailing "Par (NS): ..." line (the layout is human-facing already)
//   - Pbn     : a PBN `{ ... }` inline comment (the only annotation PBN's grammar accepts)
//   - Line / Numeric / Handviewer : nothing — these are consumed by parsers; any extra text breaks them
annotate :: proc(builder: ^strings.Builder, board: norn.Deal, format: norn.Output_Format) {
	// Classify the format. A FULL switch (no #partial) is deliberate: if norn gains a new
	// Output_Format, this fails to compile until the new format is put on one side or the other, so
	// annotation can never silently skip — or corrupt — a format nobody classified here.
	switch format {
	case .Line, .Numeric, .Handviewer:
		return // machine-parsed output: no annotation, skip the solve entirely
	case .Html_Handviewer, .Html_Cards, .Pretty, .Pbn:
	// annotated below
	}

	// Reuse the filter's solve of this same board where possible (see solve_table): filter and
	// annotator otherwise each CalcDDtable the accepted deal. The full table is 5 x 4 = 20 strain x
	// declarer trick counts; the annotator needs all of them (it prints the whole grid + par).
	res, ok := solve_table(board)
	if !ok {
		if format == .Html_Handviewer || format == .Html_Cards {
			strings.write_string(builder, "<!-- dd error: solve failed -->")
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

	// Also a full switch: the machine formats are unreachable here (filtered above) but listed so a
	// newly added annotating format must add its own emission case rather than fall through silently.
	switch format {
	case .Html_Handviewer, .Html_Cards:
		// Visible caption. The two HTML formats wrap it differently: the iframe `Html_Handviewer` tucks
		// the caption under the iframe above with a negative top margin (inline-styled so norn's page
		// CSS needs no change); the `Html_Cards` carousel gives each caption a `.par` class its script
		// pairs with the board above and its stylesheet already positions.
		if format == .Html_Handviewer {
			strings.write_string(
				builder,
				`<div style="max-width:900px;margin:-3.5rem auto 0;text-align:center;color:#555;font-size:0.9rem">`,
			)
		} else {
			strings.write_string(builder, `<div class="par">`)
		}
		strings.write_string(builder, "Par: ")
		write_par(builder, ns_par, have_par)
		strings.write_string(builder, " &mdash; NS make:")
		write_makeable(builder, res)
		strings.write_string(builder, "</div>")
		// Machine-readable form: full trick table as a comment (strain x N/E/S/W).
		strings.write_string(builder, "<!-- dd tricks[strain]NESW")
		for strain in dds.Strain {
			fmt.sbprintf(builder, " %s:", strain_label(strain))
			for hand in dds.Hand {
				fmt.sbprintf(builder, "%d/", res.resTable[strain][hand])
			}
		}
		strings.write_string(builder, " -->")

	case .Pretty:
		strings.write_string(builder, "\n  Par: ")
		write_par(builder, ns_par, have_par)
		strings.write_string(builder, " - NS make:")
		write_makeable(builder, res)

	case .Pbn:
		// Braces must NOT go through a printf format string — Odin's fmt reads `{` as an argument
		// reference — so the PBN `{ ... }` comment delimiters are written literally.
		strings.write_string(builder, " { par ")
		write_par(builder, ns_par, have_par)
		strings.write_string(builder, "; NS make:")
		write_makeable(builder, res)
		strings.write_string(builder, " }")

	case .Line, .Numeric, .Handviewer:
	// unreachable: filtered out by the classifier switch above
	}
}

// One makeable contract: the highest level NS can make in a strain (level = the better of N/S
// declarer tricks minus the 6-trick book), tagged with its bridge score for ranking.
@(private)
Makeable_Contract :: struct {
	strain: dds.Strain,
	level:  i32,
	score:  i32,
}

// Write the contracts NS can make double-dummy as " <level><strain>" tokens, ordered BEST-SCORING
// first (6NT before 6S before 6C before 1H, etc.); "nothing" if none reach the 1-level.
@(private)
write_makeable :: proc(builder: ^strings.Builder, res: ^dds.Table_Results) {
	list: [dds.DDS_STRAINS]Makeable_Contract
	n := 0
	for strain in dds.Strain {
		best := max(res.resTable[strain][.North], res.resTable[strain][.South])
		if best >= 7 { 	// 7 tricks = a 1-level contract; below that there is nothing to make
			level := best - 6
			list[n] = Makeable_Contract{strain, level, contract_score(strain, level)}
			n += 1
		}
	}
	if n == 0 {
		strings.write_string(builder, " nothing")
		return
	}
	// Best score first. n <= 5, so the sort is trivial; ties (e.g. 6H vs 6S, same score) keep an
	// arbitrary-but-deterministic order, which is fine — they are genuinely equal.
	slice.sort_by(list[:n], proc(a, b: Makeable_Contract) -> bool {return a.score > b.score})
	for m in list[:n] {
		fmt.sbprintf(builder, " %d%s", m.level, strain_label(m.strain))
	}
}

// Duplicate-bridge score for making `level` (bid = tricks - 6, made exactly) in `strain`, NOT
// vulnerable and undoubled — matching the neutral vulnerability the par call uses. Only ever compared
// against other contracts to ORDER the makeable list, so the absolute value need not be authoritative
// (overtricks, doubling, vulnerability are irrelevant to the ranking of max-level makeables).
@(private)
contract_score :: proc(strain: dds.Strain, level: i32) -> i32 {
	trick_pts: i32
	switch strain {
	case .Clubs, .Diamonds:
		trick_pts = level * 20
	case .Hearts, .Spades:
		trick_pts = level * 30
	case .NT:
		trick_pts = 40 + (level - 1) * 30
	}
	bonus: i32 = 300 if trick_pts >= 100 else 50 // game vs part-score (not vulnerable)
	if level == 7 {
		bonus += 1000 // grand slam (not vulnerable)
	} else if level == 6 {
		bonus += 500 // small slam (not vulnerable)
	}
	return trick_pts + bonus
}

// Short label for a DDS strain (suit letter, or NT), used in the caption and the trick-table comment.
@(private)
strain_label :: proc(strain: dds.Strain) -> string {
	switch strain {
	case .Spades:
		return "S"
	case .Hearts:
		return "H"
	case .Diamonds:
		return "D"
	case .Clubs:
		return "C"
	case .NT:
		return "NT"
	}
	return "?"
}

// A `norn.Deal_Filter`: keep the board only if North-South can make a game double-dummy — 3NT (9
// tricks), 4 of a major (10), or 5 of a minor (11) — with either N or S declaring. A summary
// predicate can't ask this; it needs the solved trick counts. Use as a scenario's second stage so
// DDS runs only on the deals that already passed the bidding predicate.
ns_makes_game :: proc(board: norn.Deal) -> bool {
	res, ok := solve_table(board)
	if !ok {
		return false
	}
	return(
		ns_makes(res, .NT, 9) ||
		ns_makes(res, .Spades, 10) ||
		ns_makes(res, .Hearts, 10) ||
		ns_makes(res, .Diamonds, 11) ||
		ns_makes(res, .Clubs, 11) \
	)
}

// A `norn.Deal_Filter`: keep the board only if North-South can make a small slam (12+ tricks) in
// some strain double-dummy, with either N or S declaring. Pair it with slam-zone scenarios so the
// export shows deals that actually play for slam, not just ones that bid like it.
ns_makes_slam :: proc(board: norn.Deal) -> bool {
	res, ok := solve_table(board)
	if !ok {
		return false
	}
	for strain in dds.Strain {
		if ns_makes(res, strain, 12) {
			return true
		}
	}
	return false
}

// True if North or South, as declarer, takes at least `need` tricks in `strain` (double-dummy).
@(private)
ns_makes :: proc(res: ^dds.Table_Results, strain: dds.Strain, need: i32) -> bool {
	return res.resTable[strain][.North] >= need || res.resTable[strain][.South] >= need
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
ns_makes_strain :: proc(board: norn.Deal, strain: dds.Strain, tricks: i32) -> bool {
	return declarer_makes(board, strain, .North, tricks) || declarer_makes(board, strain, .South, tricks)
}

// SolveBoard core for `ns_makes_strain`: does `declarer`'s side take `tricks`+ in `strain`? DDS's
// `SolveBoard` scores the side ON LEAD, and a contract's opening lead comes from declarer's LHO (the
// next hand clockwise), so we solve with `first = LHO`, read the LEADING side's max tricks, and the
// declaring side's tricks are `13 - that`. This matches `resTable[strain][declarer]` exactly. (Using
// TARGET_FIND_MAX; a `.One` + `target` solve could early-exit but complicates the make/beat logic.)
@(private)
declarer_makes :: proc(board: norn.Deal, strain: dds.Strain, declarer: dds.Hand, tricks: i32) -> bool {
	dl: dds.Deal
	dl.trump = strain
	dl.first = dds.Hand((int(declarer) + 1) % 4) // opening leader = declarer's LHO
	dl.remainCards = to_table_deal(board).cards // [Hand][Suit]Holding, same layout as Table_Deal.cards
	fut: dds.Future_Tricks
	if dds.SolveBoard(dl, dds.TARGET_FIND_MAX, .One, .Auto_Skip_Single, &fut) != .NO_FAULT ||
	   fut.cards == 0 {
		return false
	}
	return 13 - fut.score[0] >= tricks // declaring side's tricks = 13 - leading side's max
}

// Write one side's par: the NS-view score plus its par contract(s). `have` is false when SidesParBin
// failed, in which case we emit "n/a" rather than garbage.
@(private)
write_par :: proc(builder: ^strings.Builder, m: ^dds.Par_Results_Master, have: bool) {
	if !have {
		strings.write_string(builder, "n/a")
		return
	}
	fmt.sbprintf(builder, "NS %d", m.score)
	for i in 0 ..< m.number {
		if i == 0 {
			strings.write_string(builder, " [")
		} else {
			strings.write_string(builder, ", ")
		}
		write_contract(builder, m.contracts[i])
	}
	if m.number > 0 {
		strings.write_string(builder, "]")
	}
}

// Write a structured par contract, e.g. "4S NS", "3NT NS+1", "5Cx EW-2". A doubled sacrifice (par
// only ever doubles a non-making contract) is flagged by `underTricks > 0`: append "x" and the
// undertricks; a making contract shows its overtricks (if any) instead.
@(private)
write_contract :: proc(builder: ^strings.Builder, c: dds.Contract_Type) {
	fmt.sbprintf(builder, "%d%s", c.level, denom_label(c.denom))
	if c.underTricks > 0 {
		strings.write_string(builder, "x") // doubled sacrifice
	}
	fmt.sbprintf(builder, " %s", seats_label(c.seats))
	if c.underTricks > 0 {
		fmt.sbprintf(builder, "-%d", c.underTricks)
	} else if c.overTricks > 0 {
		fmt.sbprintf(builder, "+%d", c.overTricks)
	}
}

// Contract_Denom label. NB its ordering differs from dds.Strain (NT is 0 here), hence a separate map.
@(private)
denom_label :: proc(d: dds.Contract_Denom) -> string {
	switch d {
	case .NT:
		return "NT"
	case .Spades:
		return "S"
	case .Hearts:
		return "H"
	case .Diamonds:
		return "D"
	case .Clubs:
		return "C"
	}
	return "?"
}

// Declaring seat(s) of a par contract (a single hand or a partnership).
@(private)
seats_label :: proc(s: dds.Seat) -> string {
	switch s {
	case .N:
		return "N"
	case .E:
		return "E"
	case .S:
		return "S"
	case .W:
		return "W"
	case .NS:
		return "NS"
	case .EW:
		return "EW"
	}
	return "?"
}
