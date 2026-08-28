package outline

import "core:testing"

// The heading rule, including the two lines that look like headings and are not: `*bold*` (no whitespace
// after the run) and a bare `*` on its own.
@(test)
test_a_heading_needs_a_star_run_and_whitespace :: proc(t: ^testing.T) {
	cases := []struct {
		line:  string,
		level: int,
		text:  string,
	} {
		{"* 1C opening", 1, "1C opening"},
		{"** Responses", 2, "Responses"},
		{"*** 2N rebid", 3, "2N rebid"},
		{"**** After a double", 4, "After a double"},
		{"  ** indented", 2, "indented"},
		{"*bold* text", 0, ""},
		{"*", 0, ""},
		{"**", 0, ""},
		{"1C = strong", 0, ""},
		{"", 0, ""},
		{"*\ttab after the star", 1, "tab after the star"},
	}
	for c in cases {
		level, text := heading_of(c.line)
		testing.expectf(t, level == c.level, "%q should be level %d, not %d", c.line, c.level, level)
		testing.expectf(t, text == c.text, "%q should read %q, not %q", c.line, c.text, text)
	}
}

// Rows are 0-based and count EVERY line, blank ones included: the row is handed to the plaintext widget's
// caret, so an off-by-one lands on the wrong line of somebody's notes.
@(test)
test_headings_carry_their_row_and_document_order :: proc(t: ^testing.T) {
	source := "#+TITLE: Notes\n\n* One\n\n1C = strong\n\n** Two\n\n*** Three\r\n\n***** too deep\n"
	found := headings(source, "notes.bml", context.temp_allocator)
	testing.expect_value(t, len(found), 3)
	testing.expect_value(t, found[0].text, "One")
	testing.expect_value(t, found[0].row, 2)
	testing.expect_value(t, found[0].level, 1)
	testing.expect_value(t, found[0].order, 0)
	testing.expect_value(t, found[1].text, "Two")
	testing.expect_value(t, found[1].row, 6)
	// A CRLF file: the `\r` is not part of the heading's text, or every name in the corpus would end in one.
	testing.expect_value(t, found[2].text, "Three")
	testing.expect_value(t, found[2].row, 8)
	testing.expect_value(t, found[2].file, "notes.bml")
}

// What the caret is under, which is what the preview is scrolled to. `****` counts here (a reader looking at
// one wants to see it), and a row above every heading has no answer rather than a wrong one.
@(test)
test_the_heading_at_or_above_a_row_is_the_caret_s_own :: proc(t: ^testing.T) {
	source := "#+TITLE: Notes\n\n* One\n\n1C = strong\n\n** Two\n\n**** Deep\n\n2C = weak\n"
	cases := []struct {
		row:  int,
		text: string,
	}{{0, ""}, {1, ""}, {2, "One"}, {4, "One"}, {6, "Two"}, {7, "Two"}, {8, "Deep"}, {10, "Deep"}, {99, "Deep"}}
	for c in cases {
		heading, ok := heading_at_or_above(source, c.row)
		if c.text == "" {
			testing.expectf(t, !ok, "row %d is above every heading, got %q", c.row, heading.text)
			continue
		}
		testing.expectf(t, ok, "row %d should be under %q", c.row, c.text)
		testing.expectf(t, heading.text == c.text, "row %d is under %q, not %q", c.row, heading.text, c.text)
	}
}

// The subsequence rule, which is what makes typing three letters useful.
@(test)
test_a_query_matches_as_a_subsequence :: proc(t: ^testing.T) {
	_, hit := score_name("lbn", "Lebensohl")
	testing.expect(t, hit, "lbn should find Lebensohl")

	_, exact := score_name("2nt", "2NT openings")
	testing.expect(t, exact, "the match is case-insensitive")

	_, missing := score_name("xyz", "Lebensohl")
	testing.expect(t, !missing, "a character that is not there cannot match")

	// Order matters: the same letters backwards are not a subsequence.
	_, backwards := score_name("nbl", "Lebensohl")
	testing.expect(t, !backwards, "a subsequence is in order or it is not a match")
}

// PUNCTUATION AND SPACING ARE SEPARATORS, which is the rule that makes this corpus searchable at all: an
// auction is spelled `1H-1S`, `1H--1S`, `1H/1S` or `1H - 1S` depending on the chapter, and what a typist
// enters is `1h 1s`. Before this, that query matched only the ONE heading with a space further along in it.
@(test)
test_spacing_and_punctuation_do_not_have_to_be_typed :: proc(t: ^testing.T) {
	// Every spelling of the auction, found by every spelling of the query - including no separator at all.
	for query in ([]string{"1h 1s", "1h-1s", "1h/1s", "1h1s", "1H  1S", "1h - 1s"}) {
		for name in ([]string{"1H-1S", "1H--1S", "1H/1S", "1H - 1S", "1H-1S Compromise"}) {
			_, hit := score_name(query, name)
			testing.expectf(t, hit, "%q should find %q", query, name)
		}
	}

	// The ORDER still matters: the terms have to appear in the order they were typed.
	_, backwards := score_name("1s 1h", "1H-1S")
	testing.expect(t, !backwards, "the terms are a sequence, not a set")

	// And the exact/prefix tiers are judged on the letters and digits, so the heading that IS the auction
	// beats the one that merely starts with it - which is the ranking the failure report was about.
	exact, _ := score_name("1h 1s", "1H--1S")
	prefixed, _ := score_name("1h 1s", "1H/1S Weak Compromise")
	elsewhere, _ := score_name("1h 1s", "Responses after 1H when partner bids 1S")
	testing.expectf(
		t,
		exact > prefixed,
		"the auction itself (%d) should beat a heading starting with it (%d)",
		exact,
		prefixed,
	)
	testing.expectf(t, prefixed > elsewhere, "a prefix (%d) should beat a scattered match (%d)", prefixed, elsewhere)
}

// A query of nothing but separators is no query: the palette shows its opening list rather than an
// arbitrarily ordered corpus.
@(test)
test_a_query_of_only_punctuation_is_the_opening_list :: proc(t: ^testing.T) {
	all := corpus(t)
	for query in ([]string{"", " ", " - ", "--", "/"}) {
		testing.expectf(t, is_blank_query(query), "%q holds nothing to match on", query)
		listed := rank(all, query, "nt.bml", 0, context.temp_allocator)
		testing.expect_value(t, len(listed), len(all))
		testing.expectf(t, listed[0].file == "nt.bml", "%q should open on the active file", query)
	}
}

// The ranking, which is the half that decides whether the palette is usable. Each of these is a case where
// the wrong answer would be at the top with a naive "matched / did not match".
@(test)
test_the_score_prefers_word_starts_and_prefixes :: proc(t: ^testing.T) {
	better :: proc(t: ^testing.T, query, winner, loser: string) {
		high, hit := score_name(query, winner)
		low, also := score_name(query, loser)
		testing.expectf(t, hit && also, "%q should match both %q and %q", query, winner, loser)
		testing.expectf(t, high > low, "%q: %q (%d) should beat %q (%d)", query, winner, high, loser, low)
	}
	// A prefix beats a match buried in the middle of a word.
	better(t, "2n", "2NT openings", "After 2C, negative")
	// A word start beats the middle of a word.
	better(t, "sig", "Signals", "Designations")
	// Consecutive beats scattered.
	better(t, "slam", "Slam bidding", "Signals, leads and a majority")
	// The shorter of two names matched the same way.
	better(t, "lebensohl", "Lebensohl", "Lebensohl after a takeout double of our 1N")
	// And an exact name is the top of the range.
	exact, _ := score_name("Lebensohl", "Lebensohl")
	near, _ := score_name("Lebensohl", "Lebensohl 2")
	testing.expectf(t, exact > near, "an exact name (%d) should beat a near one (%d)", exact, near)
}

// With no query the palette opens on the file being edited, in document order, and everything else after
// it. This is the behaviour asked for: the heading you want is nearly always in the chapter you are in.
@(test)
test_an_empty_query_lists_the_active_file_first :: proc(t: ^testing.T) {
	all := corpus(t)
	listed := rank(all, "", "slam.bml", 0, context.temp_allocator)
	testing.expect_value(t, len(listed), len(all))
	testing.expect_value(t, listed[0].file, "slam.bml")
	testing.expect_value(t, listed[0].text, "Slam bidding")
	testing.expect_value(t, listed[1].text, "Blackwood")
	testing.expect_value(t, listed[2].text, "Responses")
	testing.expect(t, listed[3].file != "slam.bml", "the active file's headings are all of them, then the rest")
}

// The same name in two files: both are offered, the active file's copy first, which is why the host shows
// the file name on every row.
@(test)
test_a_duplicate_name_is_offered_from_both_files :: proc(t: ^testing.T) {
	all := corpus(t)
	listed := rank(all, "responses", "nt.bml", 0, context.temp_allocator)
	testing.expect(t, len(listed) >= 2, "both files hold a `Responses` heading")
	testing.expect_value(t, listed[0].file, "nt.bml")
	testing.expect_value(t, listed[0].text, "Responses")
	testing.expect_value(t, listed[1].file, "slam.bml")
}

// A limit is what the host draws: 12 rows, not 1000. It is applied AFTER the ranking, or the best answer
// could be cut before it was compared.
@(test)
test_the_limit_keeps_the_best_matches :: proc(t: ^testing.T) {
	all := corpus(t)
	listed := rank(all, "b", "", 2, context.temp_allocator)
	testing.expect_value(t, len(listed), 2)
	full := rank(all, "b", "", 0, context.temp_allocator)
	testing.expect_value(t, listed[0].text, full[0].text)
	testing.expect_value(t, listed[1].text, full[1].text)
}

// Cloning is what lets the host keep the list after the files' text is gone. The strings must be its own -
// this is the test that fails if `clone_headings` ever goes back to copying the slices.
@(test)
test_cloned_headings_own_their_strings :: proc(t: ^testing.T) {
	source := "* One\n** Two\n"
	found := headings(source, "notes.bml", context.temp_allocator)
	owned := clone_headings(found, context.allocator)
	defer delete_headings(owned, context.allocator)
	testing.expect_value(t, len(owned), 2)
	for entry, i in owned {
		testing.expect_value(t, entry.text, found[i].text)
		testing.expect(t, raw_data(entry.text) != raw_data(found[i].text), "a clone must not share its bytes")
		testing.expect(t, raw_data(entry.file) != raw_data(found[i].file), "the file name is cloned too")
	}
}

// Two files' worth of headings, in the shape the host builds: file by file, each in document order.
@(private = "file")
corpus :: proc(t: ^testing.T) -> []Heading {
	slam := headings("* Slam bidding\n** Blackwood\n** Responses\n", "slam.bml", context.temp_allocator)
	nt := headings("* 1N openings\n** Responses\n*** Stayman\n", "nt.bml", context.temp_allocator)
	all := make([dynamic]Heading, 0, len(slam) + len(nt), context.temp_allocator)
	append(&all, ..slam)
	append(&all, ..nt)
	return all[:]
}
