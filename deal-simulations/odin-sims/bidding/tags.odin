package bidding

/*
	tags.odin — the scenario GROUPS: which sets each named scenario belongs to.

	WHY THIS IS A SEPARATE TABLE rather than a fourth field on `cli.Scenario`. Two reasons, one
	mechanical and one about ownership:

	  * Odin has no partial positional literal — `Foo{a, b}` against a four-field struct is an error,
	    not a default — so a field on `cli.Scenario` rewrites all 110 literals in `scenarios.odin`
	    for a property that is not the scenario's definition. (Measured, not assumed: the compiler
	    says "Too few values in structure literal, expected 4, got 3".)
	  * WHICH GROUPS EXIST IS THIS SYSTEM'S EDITORIAL JUDGEMENT, not the framework's. `norn:cli` knows
	    what a scenario IS; that "1c-strong-2s" belongs with the swedish-club machinery is a claim about
	    this repository's bidding system. The same argument that keeps `suit_book` out of norn.

	THE COST of a table keyed by NAME is drift: a renamed scenario silently loses its tags, and a typo
	tags nothing. `test_every_scenario_is_tagged` is what pays it — every tagging must name a real
	scenario AND every scenario must be tagged, so adding one to `registry` fails the build until it has
	been classified. That is the point: the classification is a decision somebody makes, not a default.

	TWO AXES, and they are different kinds of question:

	  * WHOSE SYSTEM IS THIS - `basic` or `swedish-club`, exactly one of the two on every scenario. The
	    split people actually want: the auctions any system has, against this one's own machinery.
	  * WHAT IS IT ABOUT - `competitive`, `preempt`, `slam`. Cross-cutting, so a scenario carries none or
	    several, and `defence-vs-high-preempts` is honestly all three.

	SELECTED TAGS COMBINE WITH *OR*, and the text filter narrows what they leave (see `visible_scenarios`
	in `workbench.odin`). Tags widen, typing narrows. `swedish-club` AND `competitive` as an intersection
	would be a near-empty list nobody asked for; picking two groups means wanting to see both.
*/

// The groups, in the order the picker lists them: the two halves of the primary split first, then the
// topics. The description is what the picker shows beside the name — a group nobody can identify is a
// group nobody selects.
Tag :: struct {
	name:        string,
	description: string,
}

tags := []Tag {
	{"basic", "auctions any system has"},
	{"swedish-club", "this system's own machinery"},
	{"competitive", "both sides bidding"},
	{"preempt", "preempts, and bidding over them"},
	{"slam", "the slam zone"},
}

// One scenario's groups. `scenario` is the name in `registry`, which is the key the two tables share.
Scenario_Tags :: struct {
	scenario: string,
	tags:     []string,
}

// Every scenario in `registry`, classified. Ordered as the registry is, so the two read side by side.
taggings := []Scenario_Tags {
	{"1c-any", {"swedish-club"}},
	{"1c-any-1n", {"swedish-club"}},
	{"1c-any-1n-unbal", {"swedish-club"}},
	{"1c-any-2cd", {"swedish-club"}},
	{"1c-any-2h-or-2n", {"swedish-club"}},
	{"1c-any-2h-candidates", {"swedish-club"}},
	{"1c-any-2s", {"swedish-club"}},
	{"1c-any-3n-plus", {"swedish-club"}},
	{"1c-any-3x-response", {"swedish-club"}},
	{"1c-any-preempted", {"swedish-club", "competitive", "preempt"}},
	{"1c-any-long-suit-preempted", {"swedish-club", "competitive", "preempt"}},
	{"1c-strong", {"swedish-club"}},
	{"1c-19plus-or-marmic", {"swedish-club"}},
	{"1c-strong-19plus-unbal", {"swedish-club"}},
	{"1c-strong-19plus-asymmetric-10plus-card-two-suiter", {"swedish-club"}},
	{"1c-strong-21plus-unbal", {"swedish-club"}},
	{"1c-strong-(overcall)", {"swedish-club", "competitive"}},
	{"1c-strong-preempted", {"swedish-club", "competitive", "preempt"}},
	{"1c-strong-minor-opening-positive", {"swedish-club"}},
	{"1c-strong-1d", {"swedish-club"}},
	{"1c-strong-1d-1h-1s-likely", {"swedish-club"}},
	{"1c-strong-1n", {"swedish-club"}},
	{"1c-strong-1n-unbal", {"swedish-club"}},
	{"1c-strong-1n-2c-2s-minor-response", {"swedish-club"}},
	{"1c-strong-2cd", {"swedish-club"}},
	{"1c-strong-extras-2cd", {"swedish-club"}},
	{"1c-strong-2h-or-2n", {"swedish-club"}},
	{"1c-strong-2s", {"swedish-club"}},
	{"1c-strong-responder-bal-gf", {"swedish-club"}},
	{"1c-strong-responder-14plus-bal-gf", {"swedish-club"}},
	{"1c-strong-1hs-support", {"swedish-club"}},
	{"1c-strong-1hs-support-unbal", {"swedish-club"}},
	{"1d-unbalanced-opener", {"swedish-club"}},
	{"1d-unbalanced-opener-gf-two-suiter", {"swedish-club"}},
	{"1d-unbalanced-opener-slam-try-two-suiter", {"swedish-club", "slam"}},
	{"1d-any-invitish-no-major-or-inverted", {"swedish-club"}},
	{"1d-any-splinter-preempt-wjs", {"swedish-club", "preempt"}},
	{"1d-weak-minor-minors", {"swedish-club"}},
	{"1d-then-1x-interference", {"swedish-club", "competitive"}},
	{"1d-then-1x-interference-6major", {"swedish-club", "competitive"}},
	{"1minor-(1s)", {"swedish-club", "competitive"}},
	{"1minor-(overcall)", {"swedish-club", "competitive"}},
	{"1major-any", {"basic"}},
	{"1major-light-any", {"basic"}},
	{"1major-inviteish", {"basic"}},
	{"1major-game-force", {"basic"}},
	{"1major-gf-3plus-card-support", {"basic"}},
	{"1major-invite-4plus-card-support", {"basic"}},
	{"1major-10plus-splinterable", {"basic"}},
	{"1major-minisplinter-or-single-suit-invite", {"basic"}},
	{"1major-slam-try", {"basic", "slam"}},
	{"1major-max-6-carder-maybe-1nt", {"basic"}},
	{"1n-opener", {"basic"}},
	{"1n-slam-try", {"basic", "slam"}},
	{"1n-two-suiter", {"basic"}},
	{"1n-unbalanced", {"basic"}},
	{"2c-opener", {"swedish-club"}},
	{"2c-any-slam-try", {"swedish-club", "slam"}},
	{"2c-any-two-suiter-slam-try", {"swedish-club", "slam"}},
	{"2c-any-unbalanced", {"swedish-club"}},
	{"2c-positive-nine-plus-major-cards", {"swedish-club"}},
	{"2c-positive-two-suiter", {"swedish-club"}},
	{"2c-positive-unbalanced", {"swedish-club"}},
	{"2c-unbal-slam-try", {"swedish-club", "slam"}},
	{"2d-precision-any", {"swedish-club"}},
	{"2d-precision-any-10-plus", {"swedish-club"}},
	{"2d-precision-any-18-plus", {"swedish-club"}},
	{"2d-intermediate-any", {"swedish-club"}},
	{"2d-intermediate-under-invite", {"swedish-club"}},
	{"2d-intermediate-with-4cM", {"swedish-club"}},
	{"2d-intermediate-strong", {"swedish-club"}},
	{"2d-intermediate-good-6carder-GF", {"swedish-club"}},
	{"2d-intermediate-twoish-suiters-GF", {"swedish-club"}},
	{"2d-intermediate-unbal-slam-try", {"swedish-club", "slam"}},
	{"2hs-opener", {"basic", "preempt"}},
	{"2hs-5card-opener", {"basic", "preempt"}},
	{"2hs-5-or-6-card-opener", {"basic", "preempt"}},
	{"2hs-any-12-plus", {"basic", "preempt"}},
	{"2hs-any-20-plus", {"basic", "preempt"}},
	{"2hs-unbalanced-16-plus", {"basic", "preempt"}},
	{"2n-opener", {"basic"}},
	{"2n-slam-try", {"basic", "slam"}},
	{"2n-two-suiter", {"basic"}},
	{"2n-unbalanced", {"basic"}},
	{"3n-opener", {"basic", "preempt"}},
	{"3x-preempt", {"basic", "preempt"}},
	{"4x-preempt", {"basic", "preempt"}},
	{"4n-opener", {"basic"}},
	{"5m-opener", {"basic", "preempt"}},
	{"extreme-offensive-opener", {"basic", "preempt"}},
	{"8plus-pt-mixed", {"basic", "preempt"}},
	{"slam-makes-dd", {"basic", "slam"}},
	{"slam-hands-32-plus-hcp", {"basic", "slam"}},
	{"slam-hands-35-plus-hcp", {"basic", "slam"}},
	{"acol-lessons-balanced", {"basic"}},
	{"roman-2c-related", {"swedish-club"}},
	{"defence-vs-3s-or-4s-preempt", {"basic", "competitive", "preempt"}},
	{"defence-vs-high-preempts", {"basic", "competitive", "preempt"}},
	{"defense-vs-all-preempts", {"basic", "competitive", "preempt"}},
	{"defence-vs-mini-nt", {"basic", "competitive"}},
	{"defence-vs-weak-nt", {"basic", "competitive"}},
	{"defence-vs-weak-nt-invitational", {"basic", "competitive"}},
	{"defence-vs-intermediate-nt", {"basic", "competitive"}},
	{"defence-vs-strong-nt", {"basic", "competitive"}},
	{"defence-vs-prepared-minor", {"basic", "competitive"}},
	{"defence-vs-prepared-minor-with-majors", {"basic", "competitive"}},
	{"defence-vs-strong-club-unbal-or-major", {"basic", "competitive"}},
	{"unbalanced-overcalls", {"basic", "competitive"}},
	{"unbalanced-two-suiter-overcalls", {"basic", "competitive"}},
	{"unbalanced-intermediate-two-suiter-overcall", {"basic", "competitive"}},
}

// The groups a scenario belongs to, or nothing if it is not in the table. A linear scan, like
// `cli.lookup`: 110 entries answered per row per redraw is tens of microseconds, and an index would be a
// second structure to keep in step for no measurable gain.
tags_for :: proc(scenario: string) -> []string {
	for tagging in taggings {
		if tagging.scenario == scenario {
			return tagging.tags
		}
	}
	return nil
}

// Does this scenario carry any of `wanted`? The OR in "tags widen": an empty `wanted` is not a filter at
// all and admits everything, which is what makes "no group selected" mean "all of them" rather than none.
has_any_tag :: proc(scenario: string, wanted: []string) -> bool {
	if len(wanted) == 0 {
		return true
	}
	carried := tags_for(scenario)
	for want in wanted {
		for tag in carried {
			if tag == want {
				return true
			}
		}
	}
	return false
}
