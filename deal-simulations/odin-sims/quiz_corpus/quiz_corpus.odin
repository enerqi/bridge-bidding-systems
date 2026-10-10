/*
A bidding quiz's questions, read out of a `.bml` document: every bid-table row as an auction and
what it means.

A port of the python quiz's extraction (`bridge-system-apps/apps/quiz/quiz.py`: `load_bid_tables`,
`prettify_bid_table_nodes`, `collect_bid_table_auctions`, `parse_bids_from_headers`), over the Odin
BML parser instead of the python one. The python is the reference: `quiz_corpus_test.odin` holds this
to its output, auction for auction, over every `.bml` file in the corpus. Where a step below looks
odd - the string surgery on `bidrepr`, the substring test for missing context - it is because the
python does exactly that, and the quiz ports were all built against what it produces.

What the workbench uses it for: the quiz page is one HTML template with a slot for the corpus, so
generating a quiz for the open file is this package plus a JSON writer - no compiler, no python.

The JSON is the shape the python exporter writes (`apps/datastar-quiz/tools/export_corpus.py`), which
is what the quiz's `corpus.load_system` reads.
*/
package quiz_corpus

import "core:encoding/json"
import "core:strings"
import bml "markup:."
import "markup:bids"

// One question's worth: the auction, and the row's description as written (bml markup and all).
Auction :: struct {
	sequence:    []string,
	description: string,
}

// One quiz system, as the exporter writes it.
System :: struct {
	variant:          string,
	title:            string,
	bml_file:         string,
	system_notes_url: string,
	auctions:         []Auction,
}

@(private)
Header :: struct {
	kind: bml.Content_Kind,
	text: string,
}

@(private)
Table :: struct {
	root:    ^bml.Node,
	headers: []Header,
}

/*
Every auction in the document, in document order: each bid table walked depth first, every row
(branches as well as leaves), each completed with the bids its section headings imply.

Everything returned is allocated from `allocator`. The document is not modified - the python
rewrites `bidrepr` in place; here the prettified form is computed on the side.
*/
extract :: proc(doc: ^bml.Document, allocator := context.allocator) -> []Auction {
	out := make([dynamic]Auction, allocator)
	pretty := make(map[^bml.Node]string, allocator = context.temp_allocator)
	for table in bid_tables(doc, context.temp_allocator) {
		context_bids := bids_from_headers(table.headers, context.temp_allocator)
		collect(table.root, context_bids, &pretty, &out, allocator)
	}
	return out[:]
}

/*
The bid tables, each with the stack of headings above it.

A heading pops every heading at its own level or deeper and then pushes itself - so the stack is the
path from H1 down, as far as the document has gone.
*/
@(private)
bid_tables :: proc(doc: ^bml.Document, allocator := context.allocator) -> []Table {
	tables := make([dynamic]Table, allocator)
	stack := make([dynamic]Header, allocator)
	for block in doc.blocks {
		#partial switch block.kind {
		case .H1, .H2, .H3, .H4:
			for len(stack) > 0 && block.kind <= stack[len(stack) - 1].kind {
				pop(&stack)
			}
			append(&stack, Header{kind = block.kind, text = block.text})
		case .Bidtable:
			headers := make([]Header, len(stack), allocator)
			copy(headers, stack[:])
			append(&tables, Table{root = block.tree, headers = headers})
		}
	}
	return tables[:]
}

@(private)
collect :: proc(
	node: ^bml.Node,
	context_bids: []string,
	pretty: ^map[^bml.Node]string,
	out: ^[dynamic]Auction,
	allocator := context.allocator,
) {
	if node.desc != bml.ROOT_SENTINEL {
		append(
			out,
			Auction {
				sequence = completed_sequence(node, context_bids, pretty, allocator),
				description = python_description(node.desc, allocator),
			},
		)
	}
	for child in node.children {
		collect(child, context_bids, pretty, out, allocator)
	}
}

/*
The description as the python's node holds it: the author's rows joined by the two characters `
`.

The Odin node joins them with a real newline (`bml.DESC_ROW_SEPARATOR`). The quiz renders the
python's form - `render` turns the escaped pair into a line break - so that is what the corpus
carries.
*/
@(private)
python_description :: proc(desc: string, allocator := context.allocator) -> string {
	out, _ := strings.replace_all(desc, bml.DESC_ROW_SEPARATOR, `\n`, allocator)
	return out
}

/*
A row's auction, with any section-heading bids the table itself leaves out put in front.

A heading bid is MISSING when no call in the row's sequence contains it as a substring (the python's
test, kept: `1H` is "present" in `1HS`). Missing bids are then put in front only if they rank below
the sequence's first bid - a section `1C--1D` with a table starting `1H` gets `1C 1D` prepended; one
whose table restates the opening does not. A sequence with no bid in it at all takes them as they
are.
*/
@(private)
completed_sequence :: proc(
	node: ^bml.Node,
	context_bids: []string,
	pretty: ^map[^bml.Node]string,
	allocator := context.allocator,
) -> []string {
	sequence := pretty_sequence(node, pretty, allocator)

	missing := make([dynamic]string, context.temp_allocator)
	for bid in context_bids {
		present := false
		for call in sequence {
			if strings.contains(call, bid) {
				present = true
				break
			}
		}
		if !present {
			append(&missing, bid)
		}
	}
	if len(missing) == 0 {
		return sequence
	}

	sequence_bids := bid_tokens(sequence, context.temp_allocator)
	prefix: []string
	if len(sequence_bids) > 0 {
		first := sequence_bids[0]
		below := make([dynamic]string, context.temp_allocator)
		for bid in bid_tokens(missing[:], context.temp_allocator) {
			if bids.bid_less_than(bid, first) {
				append(&below, bid)
			}
		}
		prefix = below[:]
	} else {
		prefix = missing[:]
	}
	if len(prefix) == 0 {
		return sequence
	}

	completed := make([]string, len(prefix) + len(sequence), allocator)
	for bid, index in prefix {
		completed[index] = strings.clone(bid, allocator)
	}
	copy(completed[len(prefix):], sequence)
	return completed
}

// The row's sequence, each call in its prettified spelling. Memoised per node: every row shares its
// ancestors' calls.
@(private)
pretty_sequence :: proc(node: ^bml.Node, pretty: ^map[^bml.Node]string, allocator := context.allocator) -> []string {
	depth := 0
	for walk := node; walk != nil && walk.parent != nil; walk = walk.parent {
		depth += 1
	}
	out := make([]string, depth, allocator)
	index := depth - 1
	for walk := node; walk != nil && walk.parent != nil; walk = walk.parent {
		text, found := pretty[walk]
		if !found {
			text = prettify_bidrepr(walk.bidrepr, context.temp_allocator)
			pretty[walk] = text
		}
		out[index] = strings.clone(text, allocator)
		index -= 1
	}
	return out
}

/*
The python's `do_prettify_bidrep`, step for step. Its four regular expressions, by hand:

	([A-Za-z])\(       ->  \1 (        a space between a letter and an opening bracket
	\)(\d[A-Za-z])     ->  ) \1        a space between a closing bracket and a bid
	(\s)P(\s)          ->  \1Pass\2    a lone P is Pass - NON-OVERLAPPING, as `re.sub` scans
	(P) )P )X --       ->  (Pass) ) Pass ) X <space>
*/
prettify_bidrepr :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(text) + 8, context.temp_allocator)

	// 1. letter then `(`
	for index in 0 ..< len(text) {
		ch := text[index]
		strings.write_byte(&b, ch)
		if is_ascii_letter(ch) && index + 1 < len(text) && text[index + 1] == '(' {
			strings.write_byte(&b, ' ')
		}
	}
	step := strings.clone(strings.to_string(b), context.temp_allocator)

	// 2. `)` then digit+letter
	strings.builder_reset(&b)
	for index in 0 ..< len(step) {
		ch := step[index]
		strings.write_byte(&b, ch)
		if ch == ')' && index + 2 < len(step) && is_ascii_digit(step[index + 1]) && is_ascii_letter(step[index + 2]) {
			strings.write_byte(&b, ' ')
		}
	}
	step = strings.clone(strings.to_string(b), context.temp_allocator)

	// 3. whitespace, P, whitespace. A match consumes its trailing whitespace, so in ` P P ` only the
	// first P is replaced - the second's leading space has already been used.
	strings.builder_reset(&b)
	for index := 0; index < len(step); {
		if index + 2 < len(step) && is_space(step[index]) && step[index + 1] == 'P' && is_space(step[index + 2]) {
			strings.write_byte(&b, step[index])
			strings.write_string(&b, "Pass")
			strings.write_byte(&b, step[index + 2])
			index += 3
			continue
		}
		strings.write_byte(&b, step[index])
		index += 1
	}
	step = strings.to_string(b)

	// 4. the plain replacements, in the python's order
	step, _ = strings.replace_all(step, "(P)", "(Pass)", context.temp_allocator)
	step, _ = strings.replace_all(step, ")P", ") Pass", context.temp_allocator)
	step, _ = strings.replace_all(step, ")X", ") X", context.temp_allocator)
	step, _ = strings.replace_all(step, "--", " ", context.temp_allocator)
	return strings.clone(step, allocator)
}

/*
The bids a section's headings imply, in order, without repeats.

Only a heading that looks like an auction counts: one with a `-` and a call next to a dash
(`1C--1HS`, `1HS--2M`). `Good-Bad` does not. The heading is case-folded the way the call model does
(everything up except a lowercase `m`, which means "a minor"), dashes become spaces and `NT`
becomes `N`; every word that is a real bid - not a pass or a double, and not prose - is kept.
*/
bids_from_headers :: proc(headers: []Header, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for header in headers {
		text := header.text
		if !strings.contains(text, "-") || !(has_separator_bid(text) || has_prefix_separator_bid(text)) {
			continue
		}
		folded := fold_case(strings.trim_space(text), context.temp_allocator)
		folded, _ = strings.replace_all(folded, "-", " ", context.temp_allocator)
		folded, _ = strings.replace_all(folded, "NT", "N", context.temp_allocator)
		for part in strings.fields(folded, context.temp_allocator) {
			if !bids.is_bid_token(part) {
				continue
			}
			seen := false
			for already in out {
				if already == part {
					seen = true
					break
				}
			}
			if !seen {
				append(&out, strings.clone(part, allocator))
			}
		}
	}
	return out[:]
}

// `\-\(?[1-7][CDHSNMm*]+` - a call straight after a dash.
@(private)
has_separator_bid :: proc(text: string) -> bool {
	for index in 0 ..< len(text) {
		if text[index] != '-' {
			continue
		}
		at := index + 1
		if at < len(text) && text[at] == '(' {
			at += 1
		}
		if at + 1 < len(text) && is_level(text[at]) && is_denomination(text[at + 1]) {
			return true
		}
	}
	return false
}

// `[1-7][CDHSNMm*]+\)?\-` - a call straight before a dash. The denomination run is maximal: the
// character after it is not in the class, so it must be the `)` or the `-`.
@(private)
has_prefix_separator_bid :: proc(text: string) -> bool {
	for index in 0 ..< len(text) {
		if !is_level(text[index]) {
			continue
		}
		at := index + 1
		run_start := at
		for at < len(text) && is_denomination(text[at]) {
			at += 1
		}
		if at == run_start {
			continue
		}
		if at < len(text) && text[at] == ')' {
			at += 1
		}
		if at < len(text) && text[at] == '-' {
			return true
		}
	}
	return false
}

// `bmlbids.bid_tokens`: every whitespace-separated word of every string that is a real bid.
@(private)
bid_tokens :: proc(texts: []string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for text in texts {
		for word in strings.fields(text, context.temp_allocator) {
			if bids.is_bid_token(word) {
				append(&out, word)
			}
		}
	}
	return out[:]
}

// `bmlbids.fold_call_case` for text of any length (the call model's version works in a fixed buffer
// sized for one call, and a heading is longer).
@(private)
fold_case :: proc(text: string, allocator := context.allocator) -> string {
	out := make([]u8, len(text), allocator)
	for index in 0 ..< len(text) {
		ch := text[index]
		out[index] = ch == 'm' || ch < 'a' || ch > 'z' ? ch : ch - 'a' + 'A'
	}
	return string(out)
}

@(private)
is_level :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch >= '1' && ch <= '7'
}

@(private)
is_denomination :: #force_inline proc "contextless" (ch: u8) -> bool {
	switch ch {
	case 'C', 'D', 'H', 'S', 'N', 'M', 'm', '*':
		return true
	}
	return false
}

@(private)
is_ascii_letter :: #force_inline proc "contextless" (ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

@(private)
is_ascii_digit :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

// Python's `\s` on ASCII text. A non-ASCII space never sits next to a lone `P` in a bid.
@(private)
is_space :: #force_inline proc "contextless" (ch: u8) -> bool {
	switch ch {
	case ' ', '\t', '\n', '\r', '\f', '\v':
		return true
	}
	return false
}

//
// The corpus file
//

// A topic for the quiz's picker: a name, the filter patterns it stands for, and a line of help.
Topic :: struct {
	name:        string,
	patterns:    []string,
	description: string,
}

// What the exporter writes per system, field for field (`corpus.load_system` reads exactly this).
Exported_System :: struct {
	variant:           string,
	title:             string,
	bml_file:          string,
	system_notes_url:  string,
	auctions:          []Auction,
	topics:            []Topic,
	/*
	The notes THEMSELVES, as a whole html document, for the quiz's "System Notes" panel - which otherwise
	embeds `system_notes_url`, a published page. A quiz made from any `.bml` file has no published page to
	point at, so it carries its own. Not a field the quiz engine reads: the page's script lifts it out and
	gives the panel a local copy (`host.js`), and `system_notes_url` then names that copy.
	*/
	system_notes_html: string,
}

// What `system_notes_url` says when the notes travel inside the page: the quiz page's script maps it to
// the embedded copy. Index `i` is the system's position in the corpus.
EMBEDDED_NOTES_URL :: "/__quiz/notes/%d"

/*
A quiz system for one parsed document.

`bml_file` names it (`nt-bidding.bml`); its stem is the variant key and, when the document has no
`#+TITLE`, the title too. `notes_url` is what the quiz's "System Notes" panel embeds - "" for none.
*/
system_for_document :: proc(
	doc: ^bml.Document,
	bml_file: string,
	notes_url := "",
	topics: []Topic = nil,
	notes_html := "",
	allocator := context.allocator,
) -> Exported_System {
	stem := bml_file
	if dot := strings.last_index_byte(stem, '.'); dot > 0 {
		stem = stem[:dot]
	}
	title := doc.meta["TITLE"] or_else ""
	if title == "" {
		title = stem
	}
	return Exported_System {
		variant = strings.clone(stem, allocator),
		title = strings.clone(title, allocator),
		bml_file = strings.clone(bml_file, allocator),
		system_notes_url = strings.clone(notes_url, allocator),
		auctions = extract(doc, allocator),
		topics = topics,
		system_notes_html = notes_html,
	}
}

// The corpus as the quiz page reads it: a JSON array of systems.
corpus_json :: proc(systems: []Exported_System, allocator := context.allocator) -> (text: string, ok: bool) {
	data, error := json.marshal(systems, {use_spaces = false}, allocator)
	return string(data), error == nil
}
