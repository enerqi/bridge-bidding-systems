package outline

import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

/*
The notes' HEADINGS as a flat, searchable list - the model behind the editor's "go to heading" palette.

WHY IT EXISTS: this corpus is ~1000 headings across 19 chapters, and the way anyone navigates it is by
name ("Lebensohl", "2NT rebid") rather than by scrolling a file they first have to pick. Sublime Text's
`goto symbol` is the shape being copied: type a few letters, get a ranked list, press enter, the caret
lands on that heading. The corpus is small enough that the whole of it can be in the list, so the palette
searches EVERY chapter and not only the open one - which is the half a file-then-scroll workflow cannot do.

WHY A PACKAGE OF ITS OWN, with no engine in it: everything here is string work over the SOURCE text -
parsing headings out of a `.bml`, scoring a query against a name, ordering the result. That makes the whole
of it testable without a document, a window or a folder, which is the same argument `preview` makes for
`section_of_row`. The host is left with the DOM and the caret.

HOW IT RELATES TO `preview`: `preview.section_of_row` counts `*`/`**`/`***` headings to decide which
section a caret sits in. This counts headings too, but to a different end, and it goes one level DEEPER
(`****` as well): a section is a unit of layout, whereas a heading is a place someone wants to go. Jumping
to an `****` heading therefore lands the caret inside its `***` section, and the preview follows to the
section - which is the right answer for both.
*/

// The deepest heading the palette lists. `*****` and below are not in this corpus at all; `****` is (109
// of them), and they name real bidding situations, so leaving them out would lose the most specific
// destinations there are.
MAX_LEVEL :: 4

Heading :: struct {
	file:  string, // the chapter it is in: a file NAME (`slam-bidding.bml`), never a path
	text:  string, // the heading itself, the `*`s and the space after them stripped
	level: int, // 1..MAX_LEVEL
	row:   int, // 0-based line in that file's source - what the caret is moved to
	order: int, // its position in its own file, so ties can be broken by document order
}

/*
Every heading in one file's SOURCE, in document order.

The strings are SLICES OF `source` and of `file`: nothing is cloned, so the caller owns the lifetime, and
a caller that wants the list to outlive the text has to say so (`clone_headings`). The rows are 0-based
because that is what the plaintext widget's `selectionStart` counts in.
*/
headings :: proc(source: string, file: string, allocator := context.allocator) -> []Heading {
	found := make([dynamic]Heading, 0, 32, allocator)
	row := 0
	rest := source
	for {
		line := rest
		cut := strings.index_byte(rest, '\n')
		if cut >= 0 {
			line = rest[:cut]
		}
		if level, text := heading_of(strings.trim_right(line, "\r")); level > 0 && level <= MAX_LEVEL && text != "" {
			append(&found, Heading{file = file, text = text, level = level, row = row, order = len(found)})
		}
		if cut < 0 {
			break
		}
		rest = rest[cut + 1:]
		row += 1
	}
	return found[:]
}

/*
The heading this line is, or level 0 if it is not one.

A BML heading is a run of `*` at the start of the line followed by WHITESPACE - the same rule
`preview.heading_level` applies, and the same reason: `*bold*` is emphasis, not a heading, and the
whitespace is what tells them apart. Leading spaces are allowed before the run because the parser allows
them.
*/
heading_of :: proc(line: string) -> (level: int, text: string) {
	rest := strings.trim_left_space(line)
	stars := 0
	for stars < len(rest) && rest[stars] == '*' {
		stars += 1
	}
	if stars == 0 || stars >= len(rest) {
		return 0, ""
	}
	if rest[stars] != ' ' && rest[stars] != '\t' {
		return 0, ""
	}
	return stars, strings.trim_space(rest[stars + 1:])
}

/*
The nearest heading AT OR ABOVE `row`: what the caret is under.

This is what the preview scrolls to, and it is the counterpart of `preview.section_of_row` one level finer -
that answers "which SECTION" (`*`/`**`/`***`, because a section is the unit the fold keeps), this answers
"which HEADING", `****` included, because that is what the reader is looking at.

`ok = false` means there is nothing above the row - the preamble of a document, whose place is the top.
*/
heading_at_or_above :: proc(source: string, row: int) -> (heading: Heading, ok: bool) {
	for entry in headings(source, "", context.temp_allocator) {
		if entry.row > row {
			break
		}
		heading, ok = entry, true
	}
	return
}

// A list whose strings belong to it, for a caller that keeps the headings after the file's text is gone -
// which is what the host does: it reads 19 files, keeps the headings and drops the sources.
clone_headings :: proc(source_headings: []Heading, allocator := context.allocator) -> []Heading {
	owned := make([]Heading, len(source_headings), allocator)
	for entry, i in source_headings {
		owned[i] = entry
		owned[i].file = strings.clone(entry.file, allocator)
		owned[i].text = strings.clone(entry.text, allocator)
	}
	return owned
}

delete_headings :: proc(owned: []Heading, allocator := context.allocator) {
	for entry in owned {
		delete(entry.file, allocator)
		delete(entry.text, allocator)
	}
	delete(owned, allocator)
}

Match :: struct {
	using heading: Heading,
	score:         int,
}

/*
The headings a query names, best first.

WITH NO QUERY this is the palette's opening list: the ACTIVE file's own headings in document order, then
everything else. That ordering is the point of the feature - the heading you want is nearly always in the
chapter you are editing, and a palette that opened on an alphabetical list of the whole corpus would make
the common case the hardest one.

WITH A QUERY every heading is scored (`score_name`) and the survivors are ranked. Two adjustments sit on
top of the raw score, both small enough that a better name always wins: the active file gets a nudge (same
reason as above), and a shallower heading gets a smaller one (`* Slam bidding` is a more likely
destination than the fourth `**** Responses` in a file).

`limit <= 0` means no limit. The result is temp-friendly: it borrows the strings of `all`.
*/
rank :: proc(
	all: []Heading,
	query: string,
	active_file: string,
	limit := 0,
	allocator := context.allocator,
) -> []Match {
	matches := make([dynamic]Match, 0, len(all) if limit <= 0 else limit * 4, allocator)
	// `is_blank_query` rather than `trim_space`: `-` and `/` are separators here, so a query made only of
	// them names nothing and is the same as an empty one.
	trimmed := "" if is_blank_query(query) else strings.trim_space(query)
	for entry in all {
		if trimmed == "" {
			append(&matches, Match{heading = entry, score = 0})
			continue
		}
		if points, hit := score_name(trimmed, entry.text); hit {
			bonus := 0
			if active_file != "" && entry.file == active_file {
				bonus += 15
			}
			bonus += (MAX_LEVEL - entry.level) * 2
			append(&matches, Match{heading = entry, score = points + bonus})
		}
	}

	// STABLE, and by a total order that ends in document position: two headings with the same name in the
	// same file must not swap places between one keystroke and the next, or the row under the selection
	// changes while nobody is moving.
	active := active_file
	slice.stable_sort_by(matches[:], proc(a, b: Match) -> bool {
		return a.score > b.score
	})
	if trimmed == "" {
		slice.stable_sort_by(matches[:], proc(a, b: Match) -> bool {
			return a.file < b.file
		})
	}
	// The active file first, but ONLY on the opening list. A partition rather than a term in the comparator:
	// `slice.stable_sort_by` takes a plain proc with no captured state, so the file name - which is a
	// parameter - is not something the comparator can see.
	//
	// WHY NOT ONCE A QUERY IS TYPED: a partition is absolute, so the weakest match in the open chapter would
	// outrank the heading you spelled out in full in another one. Typing is evidence about WHICH heading, and
	// it has to beat evidence about which file; the `+15` above is that preference at the right strength - it
	// settles two equally good matches and nothing more.
	ordered := matches
	if active != "" && trimmed == "" {
		ordered = make([dynamic]Match, 0, len(matches), allocator)
		for entry in matches {
			if entry.file == active {
				append(&ordered, entry)
			}
		}
		for entry in matches {
			if entry.file != active {
				append(&ordered, entry)
			}
		}
	}
	if limit > 0 && len(ordered) > limit {
		resize(&ordered, limit)
	}
	return ordered[:]
}

/*
How well `query` matches `name`, and whether it matches at all.

A SUBSEQUENCE match, case-insensitively: every character of the query has to appear in the name, in order,
but not adjacently - `lbn` finds `Lebensohl`, `2nt` finds `2NT rebid after a double`. That is the rule
Sublime, VS Code and every palette since have taught people to expect, and a substring-only match would
refuse most of what a typist actually types.

PUNCTUATION AND SPACING IN THE QUERY ARE SEPARATORS, NOT CHARACTERS. The query is cut into TERMS on any run
of non-alphanumeric characters, and each term has to match as a subsequence, the terms in order. Nothing the
typist types ever has to match a dash, a slash or a space in the name.

WHY, and this was a real failure rather than a nicety: the corpus spells an auction `1H-1S`, `1H--1S`,
`1H/1S` and `1H - 1S`, and nobody types the punctuation - they type `1h 1s`. With the query's space treated
as a character to be matched, `1h 1s` found ONLY the one heading that happened to have a space further
along (`1H/1S ... Compromise`) and missed every `1H-1S` in the corpus. Now the space means "and then", which
is what a typist means by it, and the dash-count and slash-versus-dash differences stop mattering: `1h 1s`,
`1h-1s`, `1h/1s` and `1h1s` all find all of them.

The score is what makes the ranking useful rather than arbitrary, and it is built from where the matches
landed rather than how many there were:

  * the head of the name, and the start of a WORD in it, are worth much more than the middle of one -
    `2N` should find `2NT openings` ahead of `Responses to 2N`,
  * consecutive matches are worth more than scattered ones, so a typed prefix beats an accidental
    subsequence,
  * a run of skipped characters costs a little, capped, so a long name is not ruled out by its length,
  * an exact name is worth a large bonus - if you type the whole thing, you meant it - and exact is judged
    on the letters and digits alone (`1h 1s` IS `1H--1S`), for the reason above.

Greedy and leftmost: the first place each query character fits is where it is taken. That can miss the
best alignment in principle, but it is predictable, it is O(len(name)), and on names of this shape the
word-start bonus does the work the backtracking would.
*/
score_name :: proc(query: string, name: string) -> (score: int, ok: bool) {
	terms := query_terms(query, context.temp_allocator)
	if len(terms) == 0 {
		return 0, true // nothing but punctuation was typed, which names nothing and excludes nothing
	}
	if name == "" {
		return 0, false
	}
	name_runes := utf8.string_to_runes(name, context.temp_allocator)
	index := 0
	total := 0
	for term in terms {
		// `previous` resets per TERM, so the consecutive-match bonus does not run across the gap the
		// separator stands for: `1h 1s` scores as two runs of two, which is what it is.
		previous := -2
		for wanted in term {
			lowered := unicode.to_lower(wanted)
			hit := -1
			for index < len(name_runes) {
				if unicode.to_lower(name_runes[index]) == lowered {
					hit = index
					index += 1
					break
				}
				index += 1
			}
			if hit < 0 {
				return 0, false
			}
			total += 1
			switch {
			case hit == 0:
				total += 14
			case hit == previous + 1:
				total += 10
			case !is_word_rune(name_runes[hit - 1]):
				// A term landing after a dash, a slash or a space is the case this whole scheme exists
				// for, and it is worth as much as any other word start.
				total += 8
			}
			if gap := hit - previous - 1; gap > 0 && previous >= 0 {
				total -= min(gap, 4)
			}
			previous = hit
		}
	}
	// A shorter name matched by the same query is the closer answer: `2NT` over `2NT after a takeout
	// double`. Small, so it never outweighs where the matches landed.
	total += max(0, 12 - len(name_runes) / 4)

	// THE TWO TIERS THAT HAVE TO DOMINATE, and the reason they are added here rather than returned early:
	// the per-character bonuses ACCUMULATE, so a long name matched consecutively out-scores a short exact
	// one on raw points. Measured on this corpus - typing `2C Intermediate Opening`, its own heading, put
	// `2CD Intermediate Openings with 5--4 Minors` on top, because twenty consecutive characters are worth
	// more than nine. A flat "exact wins" constant is not enough either (that WAS the bug: 200 against a
	// ~210 accumulation), so both tiers are bonuses far outside the accumulating range.
	//   * you typed the whole name: nothing else can be the answer;
	//   * you typed the START of the name: much stronger evidence than the same letters found scattered.
	//
	// Both tiers are judged on the ALPHANUMERIC skeleton (`word_key`), so punctuation the typist did not
	// type cannot cost them the tier: `1h 1s` is exactly `1H--1S`, and `1h 1s comp` is a prefix of
	// `1H-1S Compromise`.
	query_key := word_key(query, context.temp_allocator)
	name_key := word_key(name, context.temp_allocator)
	switch {
	case query_key == name_key:
		total += 10_000
	case len(name_key) >= len(query_key) && name_key[:len(query_key)] == query_key:
		total += 1_000
	}
	return total, true
}

/*
The query cut into terms: runs of letters and digits, with every run of anything else dropped.

This is the one place the "punctuation is a separator" rule lives, and it applies to the QUERY only - the
name is still matched rune by rune, so a term is free to land either side of whatever the name spells its
gap with, and the word-start bonus is what notices that it did.
*/
query_terms :: proc(query: string, allocator := context.allocator) -> []string {
	terms := make([dynamic]string, 0, 4, allocator)
	start := -1
	for r, i in query {
		if is_word_rune(r) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			append(&terms, query[start:i])
			start = -1
		}
	}
	if start >= 0 {
		append(&terms, query[start:])
	}
	return terms[:]
}

// The letters and digits of a string, lower-cased: what `1H--1S`, `1H/1S` and `1h 1s` have in common. Used
// for the exact and prefix tiers only - the per-character scoring reads the name as it is written.
word_key :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(text), allocator)
	for r in text {
		if is_word_rune(r) {
			strings.write_rune(&b, unicode.to_lower(r))
		}
	}
	return strings.to_string(b)
}

// Is there anything in here to match on? A query of nothing but spaces and dashes is the same as no query at
// all, and what the palette should show for it is its opening list.
is_blank_query :: proc(query: string) -> bool {
	for r in query {
		if is_word_rune(r) {
			return false
		}
	}
	return true
}

// Is this a character a word can continue with? Everything else - a space, a `(`, a `-`, a suit glyph -
// makes the character after it the start of a word, which is what the word-start bonus keys on.
@(private)
is_word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r)
}
