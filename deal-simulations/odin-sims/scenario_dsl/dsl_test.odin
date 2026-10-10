package scenario_dsl

/*
	dsl_test.odin — the language, without a window or a bidding system in the way.

	The vocabulary is INJECTED, so these tests supply their own two-entry one rather than importing
	`bidding`: what is under test is the language, and a test that needed this repository's bidding system
	to run would be testing the wrong thing. The real vocabulary is wired at startup by the consumer.

	★ THE ONE THAT MATTERS is `test_a_parsed_condition_agrees_with_the_compiled_one` at the bottom — the
	parity oracle. Every other test here says the parser did what the grammar says; that one says the
	INTERPRETED scenario accepts exactly the deals a hand-written Odin predicate accepts, over a seeded
	run. It is the same trick that verified the whole deal.exe → norn port, and it is what turns "does my
	expression mean what I think" from an opinion into a test.
*/

import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "norn:cli"
import "norn:norn"

// ---- a vocabulary to parse against ---------------------------------------------------------------

@(private = "file")
big_hand :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.hcp(hand) >= 16
}

@(private = "file")
five_spades :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.suit_length(hand, .Spades) >= 5
}

@(private = "file")
install_test_vocabulary :: proc() {
	@(static) entries := [2]Vocabulary_Entry{}
	entries[0] = {"is_big", "16+ hcp", big_hand}
	entries[1] = {"is_five_spades", "5+ spades", five_spades}
	set_vocabulary(entries[:])
}

@(private = "file")
parse_one :: proc(t: ^testing.T, source: string) -> (program: Program, ok: bool) {
	install_test_vocabulary()
	programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
	for diagnostic in diagnostics {
		testing.expectf(t, false, "unexpected diagnostic: %s", diagnostic_text(diagnostic, context.temp_allocator))
	}
	if len(programs) != 1 {
		testing.expectf(t, false, "expected one scenario, parsed %d", len(programs))
		return {}, false
	}
	return programs[0], true
}

// ---- the grammar ---------------------------------------------------------------------------------

@(test)
test_a_scenario_parses_its_header_body_and_tags :: proc(t: ^testing.T) {
	program, ok := parse_one(
		t,
		`scenario my-1c "strong 1C; South 5+ hearts"
  tags: mine, slam
  north: is_big
  south: hearts >= 5
`,
	)
	if !ok {return}
	testing.expect_value(t, program.name, "my-1c")
	testing.expect_value(t, program.description, "strong 1C; South 5+ hearts")
	testing.expect_value(t, len(program.tags), 2)
	testing.expect_value(t, program.tags[0], "mine")
	testing.expect_value(t, program.tags[1], "slam")
	// TWO SEAT RULES, which AND together — the compiled registry's `&&`, said in the grammar.
	testing.expect_value(t, len(program.rules), 2)
	testing.expect_value(t, program.rules[0].seat, norn.Seat.North)
	testing.expect_value(t, program.rules[1].seat, norn.Seat.South)
}

// The operators, checked by what they ACCEPT rather than by the shape of the tree: a test that asserted
// node indices would pin the parser's internals rather than the language's meaning.
@(test)
test_the_operators_mean_what_they_say :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		expression: string,
		hcp:        int,
		spades:     int,
		expected:   bool,
	} {
		{"hcp >= 15", 15, 3, true},
		{"hcp >= 15", 14, 3, false},
		{"hcp in 15..17", 16, 3, true},
		{"hcp in 15..17", 18, 3, false},
		{"hcp > 10 and spades >= 5", 12, 5, true},
		{"hcp > 10 and spades >= 5", 12, 4, false},
		{"hcp > 20 or spades >= 5", 12, 5, true},
		{"not hcp > 20", 12, 5, true},
		{"not (hcp > 10 or spades >= 5)", 12, 5, false},
		// PRECEDENCE: `or` binds loosest, so this is `a or (b and c)` and the low hcp cannot fail it.
		{"hcp >= 30 or spades >= 5 and hcp >= 10", 12, 5, true},
		{"is_big", 16, 3, true},
		{"is_big", 15, 3, false},
		{"is_big and is_five_spades", 16, 5, true},
	}
	for c in cases {
		source := strings.concatenate({"scenario x \"y\"\n  north: ", c.expression, "\n"}, context.temp_allocator)
		programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
		if len(diagnostics) != 0 || len(programs) != 1 {
			testing.expectf(t, false, "%q did not parse", c.expression)
			continue
		}
		program := programs[0]
		summary := norn.Deal_Summary{}
		summary[.North] = hand_with(c.hcp, c.spades)
		got := evaluate(summary, &program)
		testing.expectf(
			t,
			got == c.expected,
			"%q with %d hcp and %d spades gave %v",
			c.expression,
			c.hcp,
			c.spades,
			got,
		)
	}
}

/*
A hand with a chosen hcp AND a chosen spade length — the two things the cases above vary.

WRITTEN TWICE. The first version put the honours in SPADES, so "15 hcp with 3 spades" asked for more
points than three spade cards can hold (A+K+Q is 9) and five cases failed against a language that was
working correctly. Honours go wherever there is room now: each suit takes them from the top while points
remain, and the shape is fixed first so the two are independent.
*/
@(private = "file")
hand_with :: proc(hcp: int, spades: int) -> norn.Hand_Summary {
	hand: norn.Hand
	counts := [4]int{}
	counts[0] = spades // spades
	rest := 13 - spades
	for i in 1 ..< 4 {
		share := rest / (4 - i)
		counts[i] = share
		rest -= share
	}

	suits := [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}
	honours := []norn.Rank{.Ace, .King, .Queen, .Jack}
	values := []int{4, 3, 2, 1}
	low := []norn.Rank{.Two, .Three, .Four, .Five, .Six, .Seven, .Eight, .Nine, .Ten}

	remaining := hcp
	placed := 0
	for suit, s in suits {
		used := [4]bool{} // which honours this suit has already spent
		lows := 0
		for _ in 0 ..< counts[s] {
			// THE BEST AFFORDABLE honour, not the next one in order. Taking them strictly A-K-Q-J meant a
			// suit that could not afford a King stopped placing honours entirely, stranding the last two
			// points and making several cases unbuildable — which read as the language being wrong.
			best := -1
			for value, h in values {
				if !used[h] && value <= remaining && (best < 0 || value > values[best]) {
					best = h
				}
			}
			rank: norn.Rank
			if best >= 0 {
				rank = honours[best]
				remaining -= values[best]
				used[best] = true
			} else {
				rank = low[lows]
				lows += 1
			}
			hand[placed] = norn.make_card(suit, rank)
			placed += 1
		}
	}
	return norn.summarize(hand)
}

@(test)
test_holds_and_balanced_read_norns_own_definitions :: proc(t: ^testing.T) {
	program, ok := parse_one(t, "scenario x \"y\"\n  north: holds(spades, ace) and not balanced\n")
	if !ok {return}
	testing.expect_value(t, len(program.rules), 1)
	testing.expect_value(t, len(program.nodes), 4) // holds, balanced, not, and
}

// ---- diagnostics ---------------------------------------------------------------------------------

// A BAD SCENARIO COSTS ONE DIAGNOSTIC AND DOES NOT EAT THE NEXT ONE. That is the bargain the header
// promises, and the reason parsing continues rather than stopping at the first problem.
@(test)
test_a_broken_scenario_does_not_lose_the_ones_after_it :: proc(t: ^testing.T) {
	install_test_vocabulary()
	programs, diagnostics := parse(
		`scenario broken "this one is wrong"
  north: hcp >= banana

scenario fine "this one is not"
  north: hcp >= 12
`,
		"test.scenario",
		context.temp_allocator,
	)
	testing.expect(t, len(diagnostics) > 0, "the bad condition should be reported")
	testing.expect_value(t, len(programs), 1)
	if len(programs) == 1 {
		testing.expect_value(t, programs[0].name, "fine")
	}
}

// EVERY DIAGNOSTIC CARRIES A PLACE. A scenario file is edited by hand, so "something is wrong" without a
// line is barely better than nothing.
@(test)
test_a_diagnostic_names_its_line_and_column :: proc(t: ^testing.T) {
	install_test_vocabulary()
	_, diagnostics := parse(
		"scenario x \"y\"\n  north: hcp >= 12\n  south: not_a_thing\n",
		"mine.scenario",
		context.temp_allocator,
	)
	testing.expect_value(t, len(diagnostics), 1)
	if len(diagnostics) != 1 {return}
	testing.expect_value(t, diagnostics[0].pos.line, 3)
	testing.expect(t, diagnostics[0].pos.col > 1, "the column should point at the word, not the line start")
	text := diagnostic_text(diagnostics[0], context.temp_allocator)
	testing.expect(t, strings.contains(text, "mine.scenario:3:"), text)
	testing.expect(t, strings.contains(text, "not_a_thing"), text)
}

// An unknown KEY is reported rather than ignored: a misspelled `tag:` that did nothing would be a
// scenario quietly missing from a group, which is the class of bug nobody notices.
@(test)
test_an_unknown_key_is_reported :: proc(t: ^testing.T) {
	install_test_vocabulary()
	_, diagnostics := parse(
		"scenario x \"y\"\n  tag: mine\n  north: hcp >= 12\n",
		"f.scenario",
		context.temp_allocator,
	)
	testing.expect_value(t, len(diagnostics), 1)
}

// A range the wrong way round is a mistake about the RANGE, so it is reported once as one.
@(test)
test_a_backwards_range_is_one_diagnostic :: proc(t: ^testing.T) {
	install_test_vocabulary()
	programs, diagnostics := parse("scenario x \"y\"\n  north: hcp in 17..15\n", "f.scenario", context.temp_allocator)
	testing.expect_value(t, len(diagnostics), 2) // the range, and then "no seat condition"
	testing.expect_value(t, len(programs), 0)
	testing.expect(t, strings.contains(diagnostics[0].message, "way round"), diagnostics[0].message)
}

// ---- the parity oracle ---------------------------------------------------------------------------

// The compiled form of the scenario written as text below. Deliberately hand-written, in Odin, the way
// every entry in `bidding/scenarios.odin` is.
@(private = "file")
compiled :: proc(summary: norn.Deal_Summary) -> bool {
	north := summary[.North]
	south := summary[.South]
	return(
		norn.hcp(north) >= 16 &&
		norn.suit_length(south, .Hearts) >= 5 &&
		norn.hcp(south) >= 8 &&
		norn.hcp(south) <= 11 \
	)
}

/*
★ AN INTERPRETED SCENARIO ACCEPTS EXACTLY WHAT THE COMPILED ONE ACCEPTS.

The point of the whole package, and the only test here that could catch the language MEANING something
other than it reads. Both conditions see the same deals — one seeded stream, replayed — and every single
verdict has to match, not merely the totals: two conditions can accept the same NUMBER of deals while
disagreeing about which.
*/
@(test)
test_a_parsed_condition_agrees_with_the_compiled_one :: proc(t: ^testing.T) {
	program, ok := parse_one(
		t,
		`scenario parity "strong North, South 5+ hearts and 8-11"
  north: hcp >= 16
  south: hearts >= 5 and hcp in 8..11
`,
	)
	if !ok {return}

	// The same deals for both, by summarising each one once and asking both conditions about it.
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 20260902)
	interpreted_accepts := 0
	compiled_accepts := 0
	for _ in 0 ..< 20_000 {
		summary := norn.summarize_deal(norn.deal_hands())
		from_text := evaluate(summary, &program)
		from_code := compiled(summary)
		testing.expectf(
			t,
			from_text == from_code,
			"the two disagreed: text said %v, code said %v",
			from_text,
			from_code,
		)
		if from_text {interpreted_accepts += 1}
		if from_code {compiled_accepts += 1}
	}
	testing.expect_value(t, interpreted_accepts, compiled_accepts)
	// And it is not vacuously equal because neither ever fires.
	testing.expect(t, compiled_accepts > 0, "the condition never accepted anything — the oracle proves nothing")
}

// ---- loading from a directory --------------------------------------------------------------------

/*
A DIRECTORY OF FILES, END TO END: parse, own, and hand back `cli.Scenario` values.

It also frees what it loaded, and that half is not ceremony — it is the regression test for a real crash.
The diagnostics' file names were BORROWED from the loader's temp-allocated directory entries while
`destroy_loaded` freed them, so the first run that produced a diagnostic at all exited with heap
corruption (0xC0000374). A happy path never finds that; a test that loads a BROKEN file and then destroys
the result does.
*/
@(test)
test_a_directory_of_scenario_files_loads_and_frees :: proc(t: ^testing.T) {
	install_test_vocabulary()

	temp, temp_err := os.temp_directory(context.temp_allocator)
	if temp_err != nil {return}
	folder, join_err := filepath.join({temp, "scenario-dsl-load-test"}, context.temp_allocator)
	if join_err != nil {return}
	_ = os.make_directory(folder)
	defer os.remove_all(folder)

	good, _ := filepath.join({folder, "good.scenario"}, context.temp_allocator)
	bad, _ := filepath.join({folder, "bad.scenario"}, context.temp_allocator)
	if os.write_entire_file(
		   good,
		   transmute([]u8)string("scenario mine \"my own\"\n  tags: mine\n  north: is_big\n"),
	   ) !=
	   nil {
		return
	}
	if os.write_entire_file(bad, transmute([]u8)string("scenario broken \"no\"\n  north: hcp >= nonsense\n")) != nil {
		return
	}

	loaded := load_directories({folder})
	// FREED HERE, deliberately inside the test rather than left to the process: the free is what crashed.
	defer destroy_loaded(&loaded)

	testing.expect_value(t, len(loaded.scenarios), 1)
	if len(loaded.scenarios) == 1 {
		testing.expect_value(t, loaded.scenarios[0].name, "mine")
		testing.expect_value(t, loaded.scenarios[0].description, "my own")
		// It is INTERPRETED, which is what makes it usable beside the compiled registry.
		testing.expect(t, cli.is_interpreted(loaded.scenarios[0]), "a loaded scenario must carry a program")
		testing.expect_value(t, len(loaded.tags[0]), 1)
		testing.expect_value(t, loaded.tags[0][0], "mine")
	}
	// The broken file is reported, with the file it came from, and does not stop the good one loading.
	testing.expect(t, len(loaded.diagnostics) > 0, "the broken file should be reported")
	if len(loaded.diagnostics) > 0 {
		testing.expect(
			t,
			strings.contains(diagnostic_text(loaded.diagnostics[0], context.temp_allocator), "bad.scenario"),
			"a diagnostic should name the file it came from",
		)
	}
}

// A directory that is not there is a normal state for a list of places to look, not an error.
@(test)
test_a_missing_directory_is_not_an_error :: proc(t: ^testing.T) {
	install_test_vocabulary()
	loaded := load_directories({"C:/no/such/place/at/all", ""})
	defer destroy_loaded(&loaded)
	testing.expect_value(t, len(loaded.scenarios), 0)
	testing.expect_value(t, len(loaded.diagnostics), 0)
}

// ---- the round trip ------------------------------------------------------------------------------

/*
`parse -> write -> parse` reaches the same tree, over expressions that exercise every printing decision:
the precedence both ways round, `not` over a compound, a range, `holds`, `balanced` and a name.

WHY THE SECOND PARSE rather than a string comparison against the source. The unparser prints what the
tree MEANS, one way — a range where the file wrote two comparisons, brackets where the shape needs them
rather than where they were typed — so the text is deliberately not the input. What must survive is the
MEANING, and the only honest way to ask that is to read the printed text back and compare the trees.

The comparison is over the printed form of BOTH, which is a canonical form: two trees that print the
same accept the same hands, and a printer bug that lost a node would have to lose it identically on the
second pass to hide here.
*/
@(test)
test_a_program_survives_being_written_out_and_read_back :: proc(t: ^testing.T) {
	install_test_vocabulary()
	expressions := []string {
		"hcp >= 15",
		"hcp in 15..17",
		"balanced and hcp in 15..17",
		"is_big or is_five_spades",
		"is_big and (is_five_spades or hearts >= 5)",
		"(is_big or is_five_spades) and hcp <= 20",
		"not (is_big and balanced)",
		"not is_big or hearts != 4",
		"holds(spades, ace) and holds(clubs, king)",
		"longest >= 6 and controls in 2..4 and not balanced",
	}
	for expression in expressions {
		source := strings.concatenate(
			{"scenario round-trip \"a description\"\n  tags: mine, slam\n  north: ", expression, "\n"},
			context.temp_allocator,
		)
		first, ok := parse_one(t, source)
		if !ok {continue}
		defer destroy_program(&first)

		printed := write_program(&first, context.temp_allocator)
		second_programs, diagnostics := parse(printed, "printed.scenario", context.temp_allocator)
		for diagnostic in diagnostics {
			testing.expectf(
				t,
				false,
				"the printed form of %q did not parse: %s",
				expression,
				diagnostic_text(diagnostic, context.temp_allocator),
			)
		}
		if len(second_programs) != 1 {
			testing.expectf(t, false, "the printed form of %q gave %d scenarios", expression, len(second_programs))
			continue
		}
		second := second_programs[0]
		defer destroy_program(&second)

		testing.expect_value(t, second.name, first.name)
		testing.expect_value(t, second.description, first.description)
		testing.expect_value(t, len(second.tags), len(first.tags))
		testing.expectf(
			t,
			write_program(&second, context.temp_allocator) == printed,
			"%q did not survive the round trip: %q",
			expression,
			printed,
		)
	}
}

// The printer's own output, for the two decisions a round trip cannot see because both sides make them:
// that a range prints as a range, and that the brackets are the ones the SHAPE needs rather than the ones
// that were typed. A test that only round-tripped would pass on a printer that bracketed everything.
@(test)
test_the_printer_spells_the_tree_the_short_way :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		written:  string,
		expected: string,
	} {


		// Redundant brackets go: `and` binds tighter than `or` already.
		{"(is_big and balanced) or is_five_spades", "is_big and balanced or is_five_spades"},
		// And they appear where the shape needs them, whether or not the author typed them.
		{"is_big and (balanced or is_five_spades)", "is_big and (balanced or is_five_spades)"},
		{"not (is_big or balanced)", "not (is_big or balanced)"},
		{"hcp in 8..11", "hcp in 8..11"},
		{"hcp != 10", "hcp != 10"},
	}
	for c in cases {
		source := strings.concatenate({"scenario p\n  north: ", c.written, "\n"}, context.temp_allocator)
		program, ok := parse_one(t, source)
		if !ok {continue}
		defer destroy_program(&program)
		printed := write_program(&program, context.temp_allocator)
		testing.expect_value(
			t,
			printed,
			strings.concatenate({"scenario p\n  north: ", c.expected, "\n"}, context.temp_allocator),
		)
	}
}

// ---- partnership lines ---------------------------------------------------------------------------

// Cards placed by hand rather than dealt, so every combined number below can be checked on paper. Short
// "hands" are fine: nothing a partnership line reads needs thirteen cards.
@(private = "file")
two_sides :: proc() -> (summary: norn.Deal_Summary) {
	// North: S AK2, H A - 11 hcp, 5 controls.  South: S QJ543, C AK - 10 hcp, 3 controls.
	summary[.North].suits[.Spades] = {.Ace, .King, .Two}
	summary[.North].suits[.Hearts] = {.Ace}
	summary[.South].suits[.Spades] = {.Queen, .Jack, .Five, .Four, .Three}
	summary[.South].suits[.Clubs] = {.Ace, .King}
	// East: H KQJ - 6 hcp. West: nothing. So north-south must not see these, and east-west must.
	summary[.East].suits[.Hearts] = {.King, .Queen, .Jack}
	return
}

/*
A PARTNERSHIP LINE READS THE SIDE'S TWO HANDS AS ONE.

Every case mixes the two hands on purpose: 21 hcp is neither hand's count, eight spades is neither hand's
length, and the two aces in the `holds` case sit in different hands — so a line that read only its first
seat would fail them all.
*/
@(test)
test_a_partnership_line_reads_both_hands_as_one :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		line:     string,
		expected: bool,
	} {
		{"north-south: hcp = 21", true},
		{"north-south: hcp >= 22", false},
		{"north-south: spades >= 8", true}, // 3 opposite 5: the fit
		{"north-south: spades >= 9", false},
		{"north-south: longest = 8", true}, // the longest COMBINED suit
		{"north-south: controls = 8", true},
		{"north-south: holds(hearts, ace) and holds(clubs, ace)", true}, // one ace in each hand
		{"north-south: holds(hearts, king)", false}, // East's card, not this side's
		{"east-west: hcp = 6", true},
		{"east-west: hearts = 3 and spades = 0", true},
		// Lines AND, partnership and seat alike.
		{"north: hcp = 11\n  north-south: hcp = 21", true},
		{"south: hcp = 11\n  north-south: hcp = 21", false},
	}
	summary := two_sides()
	for c in cases {
		source := strings.concatenate({"scenario x \"y\"\n  ", c.line, "\n"}, context.temp_allocator)
		programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
		if len(diagnostics) != 0 || len(programs) != 1 {
			testing.expectf(t, false, "%q did not parse", c.line)
			continue
		}
		program := programs[0]
		got := evaluate(summary, &program)
		testing.expectf(t, got == c.expected, "%q gave %v", c.line, got)
	}
}

// A ONE-HAND WORD ON A PARTNERSHIP LINE IS A DIAGNOSTIC, at the word, never a quiet evaluation: a side's
// 26 cards are never "balanced", and a named helper asked about them would answer with something that
// reads like a verdict.
@(test)
test_one_hand_words_are_refused_on_a_partnership_line :: proc(t: ^testing.T) {
	install_test_vocabulary()
	lines := []string{"north-south: balanced", "east-west: is_big", "north-south: hcp >= 20 and not balanced"}
	for line in lines {
		source := strings.concatenate({"scenario x \"y\"\n  ", line, "\n"}, context.temp_allocator)
		programs, diagnostics := parse(source, "f.scenario", context.temp_allocator)
		testing.expectf(t, len(programs) == 0, "%q should not have produced a scenario", line)
		// The word, and then "a scenario needs at least one seat condition".
		testing.expectf(t, len(diagnostics) == 2, "%q: expected 2 diagnostics, got %d", line, len(diagnostics))
		if len(diagnostics) == 0 {continue}
		testing.expectf(
			t,
			strings.contains(diagnostics[0].message, "one hand"),
			"%q: %s",
			line,
			diagnostics[0].message,
		)
		// The column is the word's, not the line's: two spaces of indent, 1-based, after the last space.
		word_col := strings.last_index(line, " ") + 4
		testing.expectf(
			t,
			diagnostics[0].pos.col == word_col,
			"%q: column %d, expected %d",
			line,
			diagnostics[0].pos.col,
			word_col,
		)
	}
	// And the same words stay legal on a seat line beside a partnership line.
	_, ok := parse_one(t, "scenario x \"y\"\n  north: balanced and is_big\n  north-south: hcp >= 25\n")
	testing.expect(t, ok, "one-hand words on a seat line must still parse")
}

@(test)
test_a_side_that_is_not_a_partnership_is_an_unknown_key :: proc(t: ^testing.T) {
	install_test_vocabulary()
	_, diagnostics := parse(
		"scenario x \"y\"\n  north-east: hcp >= 20\n  north: hcp >= 12\n",
		"f.scenario",
		context.temp_allocator,
	)
	testing.expect_value(t, len(diagnostics), 1)
	if len(diagnostics) == 1 {
		testing.expect(t, strings.contains(diagnostics[0].message, "north-south"), diagnostics[0].message)
	}
}

// The compiled forms, written the way `bidding/scenarios.odin` writes them — the first is
// `slam-hands-32-plus-hcp` verbatim.
@(private = "file")
compiled_32_plus :: proc(b: norn.Deal_Summary) -> bool {
	return norn.hcp(b[.North]) + norn.hcp(b[.South]) >= 32
}

@(private = "file")
compiled_fit_and_stopper :: proc(b: norn.Deal_Summary) -> bool {
	ns_spades := norn.suit_length(b[.North], .Spades) + norn.suit_length(b[.South], .Spades)
	ns_hearts := norn.suit_length(b[.North], .Hearts) + norn.suit_length(b[.South], .Hearts)
	ew_controls := norn.controls(b[.East]) + norn.controls(b[.West])
	ew_spade_ace := norn.holds(b[.East], .Spades, .Ace) || norn.holds(b[.West], .Spades, .Ace)
	return(
		norn.hcp(b[.North]) >= 12 &&
		norn.hcp(b[.North]) + norn.hcp(b[.South]) >= 24 &&
		(ns_spades >= 8 || ns_hearts >= 8) &&
		(ew_spade_ace || ew_controls >= 5) \
	)
}

/*
★ THE PARITY ORACLE, FOR PARTNERSHIP LINES. Same shape as the seat-line oracle above — one seeded stream,
every verdict compared — over the scenario that motivated the feature (`slam-hands-32-plus-hcp`, which
had no text form) and over one that mixes a seat line, a fit and the defending side's holdings.
*/
@(test)
test_a_partnership_condition_agrees_with_the_compiled_one :: proc(t: ^testing.T) {
	cases := []struct {
		source:   string,
		compiled: proc(b: norn.Deal_Summary) -> bool,
	} {
		{"scenario slam-hands \"N-S 32+\"\n  north-south: hcp >= 32\n", compiled_32_plus},
		{
			"scenario fit \"x\"\n  north: hcp >= 12\n  north-south: hcp >= 24 and (spades >= 8 or hearts >= 8)\n  east-west: holds(spades, ace) or controls >= 5\n",
			compiled_fit_and_stopper,
		},
	}
	for c in cases {
		program, ok := parse_one(t, c.source)
		if !ok {continue}

		state: rand.Xoshiro256_Random_State
		context.random_generator = norn.seeded_xoshiro(&state, 20261003)
		accepted := 0
		disagreements := 0
		for _ in 0 ..< 20_000 {
			summary := norn.summarize_deal(norn.deal_hands())
			from_text := evaluate(summary, &program)
			if from_text != c.compiled(summary) {
				disagreements += 1
			}
			if from_text {accepted += 1}
		}
		testing.expectf(
			t,
			disagreements == 0,
			"%q: %d deals where text and code disagreed",
			program.name,
			disagreements,
		)
		testing.expectf(t, accepted > 0, "%q never accepted anything — the oracle proves nothing", program.name)
	}
}

// The printer names a side the way the parser reads it, and keeps it apart from the seat lines.
@(test)
test_a_partnership_line_prints_and_reads_back :: proc(t: ^testing.T) {
	source := "scenario p\n  north: is_big\n  north-south: hcp >= 32 and (spades >= 8 or hearts >= 8)\n  east-west: holds(spades, ace)\n"
	program, ok := parse_one(t, source)
	if !ok {return}
	defer destroy_program(&program)
	printed := write_program(&program, context.temp_allocator)
	testing.expect_value(t, printed, source)

	again, again_ok := parse_one(t, printed)
	if !again_ok {return}
	defer destroy_program(&again)
	testing.expect_value(t, len(again.rules), 3)
	testing.expect(
		t,
		!again.rules[0].pair && again.rules[1].pair && again.rules[2].pair,
		"the pair flags did not survive",
	)
	testing.expect_value(t, again.rules[2].seat, norn.Seat.East)
}

// ---- the double-dummy line -------------------------------------------------------------------------

// `double-dummy: <side> make <goal>` is recorded on the program (the consumer links the solver), prints
// back as it was meant, and a bad or second one is a diagnostic rather than silently ignored.
@(test)
test_a_double_dummy_line_is_recorded_and_printed :: proc(t: ^testing.T) {
	cases := []struct {
		line:  string,
		want:  Double_Dummy,
		print: string,
	} {
		{"north-south make slam", {.North_South, .Slam}, "north-south make slam"},
		{"East-West makes game", {.East_West, .Game}, "east-west make game"},
		{"north-south make grand slam", {.North_South, .Grand}, "north-south make grand"},
		{"north-south make small slam", {.North_South, .Slam}, "north-south make slam"},
	}
	for c in cases {
		source := strings.concatenate(
			{"scenario dd \"x\"\n  north: hcp >= 15\n  double-dummy: ", c.line, "\n"},
			context.temp_allocator,
		)
		program, ok := parse_one(t, source)
		if !ok {continue}
		defer destroy_program(&program)
		got, has := program.double_dummy.?
		testing.expectf(t, has && got == c.want, "%q read as %v", c.line, program.double_dummy)
		printed := write_program(&program, context.temp_allocator)
		testing.expectf(
			t,
			strings.contains(
				printed,
				strings.concatenate({"  double-dummy: ", c.print, "\n"}, context.temp_allocator),
			),
			"%q printed as %q",
			c.line,
			printed,
		)
		// And the printed form reads back the same.
		again, _ := parse(printed, "printed.scenario", context.temp_allocator)
		if len(again) == 1 {
			back, back_has := again[0].double_dummy.?
			testing.expectf(t, back_has && back == c.want, "%q did not survive the round trip", c.line)
			destroy_program(&again[0])
		}
	}

	none, ok := parse_one(t, "scenario plain \"x\"\n  north: hcp >= 15\n")
	if ok {
		_, has := none.double_dummy.?
		testing.expect(t, !has, "no line, no double-dummy requirement")
		destroy_program(&none)
	}

	install_test_vocabulary()
	for bad in ([]string {
			"  double-dummy: north make slam\n", // a seat is not a side
			"  double-dummy: north-south slam\n", // no `make`
			"  double-dummy: north-south make partscore\n", // no such goal
			"  double-dummy: north-south make slam\n  double-dummy: east-west make game\n", // two
		}) {
		source := strings.concatenate({"scenario dd \"x\"\n  north: hcp >= 15\n", bad}, context.temp_allocator)
		programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
		testing.expectf(t, len(diagnostics) == 1, "%q gave %d diagnostics", bad, len(diagnostics))
		for &program in programs {
			destroy_program(&program)
		}
	}
}
