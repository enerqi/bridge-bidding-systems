package bidding

/*
	Package `bidding` — the "Weak Strong Club" bidding system, expressed as deal predicates plus the
	named-scenario registry. The Odin port of `deal-simulations/tcl-sims/deal-utils.tcl`.

	WHY THIS IS A PACKAGE (rather than folded into a program's `package main`)
	------------------------------------------------------------------------
	It was written as a reusable library consumed by more than one program: `sim` (the deal generator
	/ HTML exporter) plus the now-retired `parity` (deal.exe cross-check) harness both imported it. A
	package gives a single, separately-compiled unit with a clean `bidding.` qualifier instead of
	duplicating the predicates or coupling them into one binary — the Odin justification for a
	package is code SHARED/linked across programs. Only `sim` consumes it today, but the boundary is
	kept (cheap, and re-usable if another program is added). (Within a single program you organize by
	FILE, not by carving taxonomy sub-packages like `conditions/` + `scenarios/`.)

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

	Each condition takes a `norn.Hand_Summary` and returns whether it qualifies, so it composes directly into
	a `norn.Predicate` over a `Deal` (typically applied to one seat).
*/

import "norn:norn"

// A "flattish" hand: balanced or semi-balanced. (deal-utils `flattish`.)
is_flattish :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.is_balanced(hand) || norn.is_semibalanced(hand)
}

// Would this hand open an artificial strong 1C? (deal-utils `is_strong_1c`.)
//
// 16+ high-card points; 21+ always qualifies, while 16–20 must be unbalanced (a flat 16–20 is
// shown some other way, e.g. a strong notrump).
is_strong_1c :: proc(hand: norn.Hand_Summary) -> bool {
	points := norn.hcp(hand)
	if points < 16 {
		return false
	}
	if points >= 21 {
		return true
	}
	return !is_flattish(hand)
}
