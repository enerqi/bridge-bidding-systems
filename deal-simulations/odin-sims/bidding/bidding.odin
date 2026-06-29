package bidding

/*
	Package `bidding` — the "Weak Strong Club" bidding system, expressed as deal predicates plus the
	named-scenario registry. The Odin port of `deal-simulations/tcl-sims/deal-utils.tcl`.

	WHY THIS IS A PACKAGE (rather than folded into a program's `package main`)
	------------------------------------------------------------------------
	It is a reusable library consumed by MORE THAN ONE program: both `sim` (the deal generator /
	HTML exporter) and `parity` (the deal.exe cross-check harness) import it. A package gives them a
	single, separately-compiled unit with a clean `bidding.` qualifier — instead of duplicating the
	predicates or coupling them into one binary. That is the Odin justification for a package: code
	SHARED/linked across programs. (Were there only one program, this code would simply live in that
	program's own `package main` files — in Odin you organize within a program by FILE, not by
	carving taxonomy sub-packages like `conditions/` + `scenarios/`.)

	It depends only on the `norn` library — the system-agnostic hand-generation engine (`norn:norn`)
	and the reusable scenario CLI framework (`norn:cli`) — via `-collection:norn=...`. Everything
	system-specific lives here, organized by file:

	  bidding.odin       this doc + the cross-cutting predicates (is_flattish, is_strong_1c)
	  openers.odin       opening-bid predicates
	  preempts.odin      preempt / offense / losers predicates
	  shapes.odin        shape & honour-combination vocabulary
	  swedish_club.odin  the artificial 1C / 1D response tree
	  competitive.odin   overcalls & multi-seat competitive judgements
	  helpers.odin       small shared helpers (honour combos, notrump shape+range)
	  scenarios.odin     the named-scenario registry ([]cli.Scenario)

	Each condition takes a `norn.HandSummary` and returns whether it qualifies, so it composes directly into
	a `norn.Predicate` over a `Deal` (typically applied to one seat).
*/

import "norn:norn"

// A "flattish" hand: balanced or semi-balanced. (deal-utils `flattish`.)
is_flattish :: proc(hand: norn.HandSummary) -> bool {
	return norn.is_balanced(hand) || norn.is_semibalanced(hand)
}

// Would this hand open an artificial strong 1C? (deal-utils `is_strong_1c`.)
//
// 16+ high-card points; 21+ always qualifies, while 16–20 must be unbalanced (a flat 16–20 is
// shown some other way, e.g. a strong notrump).
is_strong_1c :: proc(hand: norn.HandSummary) -> bool {
	points := norn.hcp(hand)
	if points < 16 {
		return false
	}
	if points >= 21 {
		return true
	}
	return !is_flattish(hand)
}
