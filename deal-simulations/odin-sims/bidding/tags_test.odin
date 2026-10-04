package bidding

/*
	tags_test.odin — what keeps `taggings` and `registry` from drifting apart.

	The tag table is keyed by scenario NAME, which is the only key available without rewriting every
	literal in `scenarios.odin` (see the header of `tags.odin`). The price of a name key is that a rename
	silently unclassifies a scenario and a typo classifies nothing, with no symptom anywhere: the row just
	stops appearing under its group. These tests are what makes that a build failure instead.
*/

import "core:testing"
import "norn:cli"

// EVERY SCENARIO IS CLASSIFIED, AND NOTHING IS CLASSIFIED THAT IS NOT A SCENARIO. Adding to `registry`
// therefore fails here until the new scenario has been put in a group — which is the intent rather than a
// side effect. A default group would be a way for a hundred scenarios to end up in "other" one at a time.
@(test)
test_every_scenario_is_tagged :: proc(t: ^testing.T) {
	for scenario in registry {
		found := tags_for(scenario.name)
		testing.expectf(
			t,
			len(found) > 0,
			"scenario %q is in the registry but has no entry in `taggings` — classify it in tags.odin",
			scenario.name,
		)
	}

	for tagging in taggings {
		_, known := cli.lookup(registry, tagging.scenario)
		testing.expectf(
			t,
			known,
			"`taggings` names %q, which is not in the registry — a rename or a typo",
			tagging.scenario,
		)
	}
	testing.expect_value(t, len(taggings), len(registry))
}

// EVERY TAG USED IS A DECLARED TAG. The picker lists `tags`, so a scenario carrying a name that is not in
// that list belongs to a group with no way to select it — invisible, and exactly the shape a typo takes.
@(test)
test_every_tag_used_is_declared :: proc(t: ^testing.T) {
	for tagging in taggings {
		for used in tagging.tags {
			declared := false
			for tag in tags {
				if tag.name == used {
					declared = true
					break
				}
			}
			testing.expectf(
				t,
				declared,
				"%q carries the tag %q, which is not in `tags` — no picker row would ever select it",
				tagging.scenario,
				used,
			)
		}
	}

	// And the other way: a declared tag nothing carries is a row in the picker that always yields an
	// empty list. Not fatal, but it is always a mistake rather than a plan.
	for tag in tags {
		used := false
		for tagging in taggings {
			for carried in tagging.tags {
				if carried == tag.name {
					used = true
					break
				}
			}
		}
		testing.expectf(t, used, "the tag %q is declared but no scenario carries it", tag.name)
	}
}

// THE PRIMARY SPLIT IS A PARTITION: exactly one of `basic` / `swedish-club` on every scenario. That is
// what makes those two a real answer to "whose system is this" rather than two more topics — with both,
// or neither, the question has no answer for that row.
@(test)
test_the_primary_split_is_a_partition :: proc(t: ^testing.T) {
	for tagging in taggings {
		sides := 0
		for carried in tagging.tags {
			if carried == "basic" || carried == "swedish-club" {
				sides += 1
			}
		}
		testing.expectf(
			t,
			sides == 1,
			"%q carries %d of {basic, swedish-club}; it must carry exactly one",
			tagging.scenario,
			sides,
		)
	}
}

// The OR rule, which is the whole semantics of selecting groups: no tags selected admits everything, and
// any overlap admits the scenario. Asserted on real entries rather than a fixture, so a table edit that
// broke the meaning would show up here too.
@(test)
test_no_tags_selected_admits_everything :: proc(t: ^testing.T) {
	for scenario in registry {
		testing.expect(t, has_any_tag(scenario.name, {}), "an empty selection is not a filter")
	}

	// Every scenario is admitted by the union of the two halves of the partition, and that IS the registry.
	both := []string{"basic", "swedish-club"}
	admitted := 0
	for scenario in registry {
		if has_any_tag(scenario.name, both) {
			admitted += 1
		}
	}
	testing.expect_value(t, admitted, len(registry))

	// And a single group is a proper subset — a filter that admits everything would pass the test above
	// while filtering nothing at all.
	only_club := []string{"swedish-club"}
	narrowed := 0
	for scenario in registry {
		if has_any_tag(scenario.name, only_club) {
			narrowed += 1
		}
	}
	testing.expect(t, narrowed > 0 && narrowed < len(registry), "swedish-club should be some of the registry")
}
