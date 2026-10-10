package scenario_dsl

/*
	parse.odin — text to `Program`.

	A HAND-WRITTEN RECURSIVE-DESCENT PARSER over a line-oriented file, which is what the language's shape
	asks for: the outer level is lines (a header, then `key: value` body lines), and only the right-hand
	side of a seat line is an expression. So the outer level is a line loop and the inner one is the
	classic precedence climb — `or` binds loosest, then `and`, then `not`, then atoms and parentheses.

	EVERY FAILURE CARRIES A POSITION and parsing CONTINUES to the next scenario where it can. A file with
	two scenarios and a typo in the first should still give you the second, and should tell you about the
	typo once, with a line and column — the same bargain `bridge-markup` makes for `.bml`.
*/

import "base:runtime"
import "core:strconv"
import "core:strings"

@(private)
Parser :: struct {
	source:      string,
	file:        string,
	line_index:  int, // 0-based index of the line being read
	lines:       []string,
	diagnostics: ^[dynamic]Diagnostic,
	allocator:   runtime.Allocator,
	// The tree under construction for the seat line being parsed.
	nodes:       [dynamic]Node,
	// Where in the current line the cursor is, for column reporting.
	text:        string,
	col:         int,
	// The line being parsed is a PARTNERSHIP line, where the one-hand atoms are refused.
	pair:        bool,
}

/*
Parse a whole file's worth of text into scenarios.

Returns what it could parse plus every diagnostic it found — never one or the other. A file that is
entirely wrong yields no programs and several diagnostics; a file with one bad scenario yields the rest.
*/
parse :: proc(
	source: string,
	file: string,
	allocator := context.allocator,
) -> (
	programs: []Program,
	diagnostics: []Diagnostic,
) {
	found := make([dynamic]Program, 0, 4, allocator)
	problems := make([dynamic]Diagnostic, 0, 4, allocator)

	lines := strings.split_lines(source, context.temp_allocator)
	p := Parser {
		source      = source,
		file        = file,
		lines       = lines,
		diagnostics = &problems,
		allocator   = allocator,
	}

	for p.line_index < len(lines) {
		line := strings.trim_space(strip_comment(lines[p.line_index]))
		if line == "" {
			p.line_index += 1
			continue
		}
		if !strings.has_prefix(folded(line), "scenario") {
			report(&p, p.line_index, 1, "expected a `scenario` line to start a scenario")
			p.line_index += 1
			continue
		}
		if program, ok := parse_scenario(&p); ok {
			append(&found, program)
		}
	}
	return found[:], problems[:]
}

// Everything from an unquoted `#` to the end of the line is a comment. Checked against quotes so a `#`
// inside a description is text, which matters because bridge descriptions contain them rarely but do.
@(private)
strip_comment :: proc(line: string) -> string {
	in_quotes := false
	for i in 0 ..< len(line) {
		switch line[i] {
		case '"':
			in_quotes = !in_quotes
		case '#':
			if !in_quotes {
				return line[:i]
			}
		}
	}
	return line
}

@(private)
report :: proc(p: ^Parser, line_index: int, col: int, message: string) {
	append(
		p.diagnostics,
		Diagnostic {
			// THE FILE NAME IS CLONED, like the message. It was borrowed from the caller's `file` argument,
			// which in the loader is a temp-allocated `fullpath` — so `destroy_loaded` freeing it was a
			// free of memory this package never owned. It showed up as a HEAP CORRUPTION exit
			// (0xC0000374) on the first run that produced a diagnostic at all, which is exactly the sort
			// of bug a happy path never finds.
			pos = {file = strings.clone(p.file, p.allocator), line = line_index + 1, col = col},
			message = strings.clone(message, p.allocator),
		},
	)
}

/*
One scenario: the header line, then the indented body until the next `scenario` or the end of the file.

The body is read as `key: value`, and only three kinds of key exist — `tags`, a seat name, and a
partnership (`north-south` / `east-west`). An
unknown key is a diagnostic rather than silently ignored: a misspelled `tag:` that did nothing would be a
scenario quietly missing from a group, which is exactly the class of bug nobody notices.
*/
@(private)
parse_scenario :: proc(p: ^Parser) -> (program: Program, ok: bool) {
	header_index := p.line_index
	header := strings.trim_space(strip_comment(p.lines[header_index]))
	p.line_index += 1

	rest := strings.trim_space(header[len("scenario"):])
	if rest == "" {
		report(p, header_index, 1, "a scenario needs a name: `scenario <name> \"<description>\"`")
		skip_body(p)
		return {}, false
	}

	name, description := split_name_and_description(rest)
	if name == "" {
		report(p, header_index, 1, "a scenario needs a name before its description")
		skip_body(p)
		return {}, false
	}

	nodes := make([dynamic]Node, 0, 16, p.allocator)
	rules := make([dynamic]Seat_Rule, 0, 4, p.allocator)
	tags := make([dynamic]string, 0, 4, p.allocator)
	double_dummy: Maybe(Double_Dummy)
	p.nodes = nodes

	for p.line_index < len(p.lines) {
		raw := strip_comment(p.lines[p.line_index])
		line := strings.trim_space(raw)
		if line == "" {
			p.line_index += 1
			continue
		}
		if strings.has_prefix(folded(line), "scenario") {
			break // the next scenario; this one is finished
		}

		colon := strings.index_byte(line, ':')
		if colon < 0 {
			report(p, p.line_index, 1, "expected `key: value` — a seat, a partnership, `double-dummy:` or `tags:`")
			p.line_index += 1
			continue
		}
		key := folded(strings.trim_space(line[:colon]))
		value := strings.trim_space(line[colon + 1:])
		value_col := strings.index(raw, value) + 1 if value != "" else colon + 2

		switch {
		case key == "double-dummy":
			if _, already := double_dummy.?; already {
				report(p, p.line_index, 1, "a scenario has one `double-dummy:` line")
			} else if dd, dd_ok := parse_double_dummy(value); dd_ok {
				double_dummy = dd
			} else {
				report(
					p,
					p.line_index,
					value_col,
					"expected `double-dummy: <north-south|east-west> make <game|slam|grand>`",
				)
			}
		case key == "tags":
			for tag in strings.split(value, ",", context.temp_allocator) {
				trimmed := strings.trim_space(tag)
				if trimmed != "" {
					append(&tags, strings.clone(trimmed, p.allocator))
				}
			}
		case:
			seat, is_seat := seat_of(key)
			pair := false
			if !is_seat {
				seat, pair = pair_of(key)
			}
			if !is_seat && !pair {
				report(
					p,
					p.line_index,
					1,
					"unknown key — expected a seat (north/east/south/west), a partnership (north-south/east-west), `double-dummy` or `tags`",
				)
				p.line_index += 1
				continue
			}
			if value == "" {
				report(p, p.line_index, value_col, "this line has no condition")
				p.line_index += 1
				continue
			}
			p.text = value
			p.col = value_col
			p.pair = pair
			if root, expr_ok := parse_expression(p); expr_ok {
				append(&rules, Seat_Rule{seat = seat, pair = pair, root = root})
			}
			p.pair = false
		}
		p.line_index += 1
	}

	if len(rules) == 0 {
		report(p, header_index, 1, "a scenario needs at least one seat condition")
		delete(nodes)
		delete(rules)
		for tag in tags {
			delete(tag, p.allocator)
		}
		delete(tags)
		return {}, false
	}

	return Program {
			name = strings.clone(name, p.allocator),
			description = strings.clone(description, p.allocator),
			tags = tags[:],
			rules = rules[:],
			nodes = p.nodes[:],
			double_dummy = double_dummy,
			source = strings.clone(p.file, p.allocator),
			allocator = p.allocator,
		},
		true
}

// `north-south make slam`: a side, `make` (or `makes`), and game / slam / grand. `small slam` and
// `grand slam` are the same goals spelled out, since that is how people say them.
@(private)
parse_double_dummy :: proc(value: string) -> (dd: Double_Dummy, ok: bool) {
	words := strings.fields(folded(value), context.temp_allocator)
	if len(words) < 3 || (words[1] != "make" && words[1] != "makes") {
		return {}, false
	}
	switch words[0] {
	case "north-south":
		dd.side = .North_South
	case "east-west":
		dd.side = .East_West
	case:
		return {}, false
	}
	goal := strings.join(words[2:], " ", context.temp_allocator)
	switch goal {
	case "game":
		dd.goal = .Game
	case "slam", "small slam", "small-slam":
		dd.goal = .Slam
	case "grand", "grand slam", "grand-slam":
		dd.goal = .Grand
	case:
		return {}, false
	}
	return dd, true
}

// Skip to the next scenario after a bad header, so one broken scenario costs one diagnostic rather than
// one per line of its body.
@(private)
skip_body :: proc(p: ^Parser) {
	for p.line_index < len(p.lines) {
		line := strings.trim_space(strip_comment(p.lines[p.line_index]))
		if line != "" && strings.has_prefix(folded(line), "scenario") {
			return
		}
		p.line_index += 1
	}
}

// `1c-then-5hearts "strong 1C; South 5+ hearts"` — the name is the first word, the description is the
// quoted remainder. An unquoted remainder is taken whole, because insisting on quotes for a description
// nobody else parses would be ceremony.
@(private)
split_name_and_description :: proc(rest: string) -> (name: string, description: string) {
	space := strings.index_any(rest, " \t")
	if space < 0 {
		return rest, ""
	}
	name = rest[:space]
	description = strings.trim_space(rest[space:])
	if len(description) >= 2 && description[0] == '"' && description[len(description) - 1] == '"' {
		description = description[1:len(description) - 1]
	}
	return
}

// ---------------------------------------------------------------------------------------------------
// The expression grammar
//
//   expression := term   ( "or"  term )*
//   term       := factor ( "and" factor )*
//   factor     := "not" factor | "(" expression ")" | atom
//   atom       := name | "balanced" | "holds" "(" suit "," rank ")" | quantity ( cmp int | "in" a ".." b )

@(private)
add_node :: proc(p: ^Parser, node: Node) -> int {
	append(&p.nodes, node)
	return len(p.nodes) - 1
}

@(private)
parse_expression :: proc(p: ^Parser) -> (root: int, ok: bool) {
	left := parse_term(p) or_return
	for {
		save := p.text
		save_col := p.col
		word, has_word := peek_word(p)
		if !has_word || folded(word) != "or" {
			p.text = save
			p.col = save_col
			break
		}
		take_word(p)
		right := parse_term(p) or_return
		left = add_node(p, Or_Node{left = left, right = right})
	}
	return left, true
}

@(private)
parse_term :: proc(p: ^Parser) -> (root: int, ok: bool) {
	left := parse_factor(p) or_return
	for {
		save := p.text
		save_col := p.col
		word, has_word := peek_word(p)
		if !has_word || folded(word) != "and" {
			p.text = save
			p.col = save_col
			break
		}
		take_word(p)
		right := parse_factor(p) or_return
		left = add_node(p, And_Node{left = left, right = right})
	}
	return left, true
}

@(private)
parse_factor :: proc(p: ^Parser) -> (root: int, ok: bool) {
	skip_spaces(p)
	if word, has_word := peek_word(p); has_word && folded(word) == "not" {
		take_word(p)
		child := parse_factor(p) or_return
		return add_node(p, Not_Node{child = child}), true
	}
	if strings.has_prefix(p.text, "(") {
		advance(p, 1)
		inner := parse_expression(p) or_return
		skip_spaces(p)
		if !strings.has_prefix(p.text, ")") {
			report(p, p.line_index, p.col, "expected `)`")
			return 0, false
		}
		advance(p, 1)
		return inner, true
	}
	return parse_atom(p)
}

@(private)
parse_atom :: proc(p: ^Parser) -> (root: int, ok: bool) {
	skip_spaces(p)
	start_col := p.col
	word, has_word := take_word(p)
	if !has_word {
		report(p, p.line_index, start_col, "expected a condition")
		return 0, false
	}
	lowered := folded(word)

	// ONE-HAND WORDS ON A PARTNERSHIP LINE are refused here rather than evaluated: a side's 26 cards are
	// never "balanced", and a named helper asked about them would answer with something that reads like a
	// verdict and means nothing. A seat line is where they belong, and the message says so.
	if p.pair && (lowered == "balanced" || is_vocabulary_word(word)) {
		report(
			p,
			p.line_index,
			start_col,
			fmt_message(p, "`%s` describes one hand — put it on a seat line, not a partnership line", word),
		)
		return 0, false
	}

	if lowered == "balanced" {
		return add_node(p, Balanced_Node{}), true
	}
	if lowered == "holds" {
		return parse_holds(p, start_col)
	}
	if quantity, is_quantity := quantity_of(lowered); is_quantity {
		return parse_comparison(p, quantity, start_col)
	}

	// A NAME FROM THE CONSUMER'S VOCABULARY, resolved now rather than at run time.
	if index, known := find_in_vocabulary(word); known {
		return add_node(p, Named_Node{name = strings.clone(word, p.allocator), index = index}), true
	}
	report(
		p,
		p.line_index,
		start_col,
		fmt_message(p, "unknown condition `%s` — not a quantity, and not in this system's vocabulary", word),
	)
	return 0, false
}

@(private)
is_vocabulary_word :: proc(word: string) -> bool {
	_, known := find_in_vocabulary(word)
	return known
}

@(private)
parse_holds :: proc(p: ^Parser, start_col: int) -> (root: int, ok: bool) {
	skip_spaces(p)
	if !strings.has_prefix(p.text, "(") {
		report(p, p.line_index, p.col, "`holds` takes a suit and a rank: `holds(spades, ace)`")
		return 0, false
	}
	advance(p, 1)
	suit_word, _ := take_word(p)
	suit, is_suit := suit_of(folded(suit_word))
	if !is_suit {
		report(p, p.line_index, p.col, "expected a suit — clubs, diamonds, hearts or spades")
		return 0, false
	}
	skip_spaces(p)
	if strings.has_prefix(p.text, ",") {
		advance(p, 1)
	}
	rank_word, _ := take_word(p)
	rank, is_rank := rank_of(folded(rank_word))
	if !is_rank {
		report(p, p.line_index, p.col, "expected a rank — ace, king, … or 2..10")
		return 0, false
	}
	skip_spaces(p)
	if !strings.has_prefix(p.text, ")") {
		report(p, p.line_index, p.col, "expected `)`")
		return 0, false
	}
	advance(p, 1)
	return add_node(p, Holds_Node{suit = suit, rank = rank}), true
}

@(private)
parse_comparison :: proc(p: ^Parser, quantity: Quantity, start_col: int) -> (root: int, ok: bool) {
	skip_spaces(p)

	// `hcp in 15..17`
	if word, has_word := peek_word(p); has_word && folded(word) == "in" {
		take_word(p)
		low, low_ok := take_int(p)
		if !low_ok {
			report(p, p.line_index, p.col, "expected the low end of the range")
			return 0, false
		}
		skip_spaces(p)
		if !strings.has_prefix(p.text, "..") {
			report(p, p.line_index, p.col, "expected `..` between the ends of the range")
			return 0, false
		}
		advance(p, 2)
		high, high_ok := take_int(p)
		if !high_ok {
			report(p, p.line_index, p.col, "expected the high end of the range")
			return 0, false
		}
		if low > high {
			report(p, p.line_index, start_col, "the range is the wrong way round — the low end must come first")
			return 0, false
		}
		return add_node(p, Compare_Node{quantity = quantity, value = low, is_range = true, high = high}), true
	}

	op, has_op := take_comparison(p)
	if !has_op {
		report(p, p.line_index, p.col, "expected a comparison (`>= 15`) or a range (`in 15..17`)")
		return 0, false
	}
	value, value_ok := take_int(p)
	if !value_ok {
		report(p, p.line_index, p.col, "expected a number after the comparison")
		return 0, false
	}
	return add_node(p, Compare_Node{quantity = quantity, op = op, value = value}), true
}

// ---------------------------------------------------------------------------------------------------
// The cursor
//
// `p.text` is what is LEFT of the line and `p.col` is where that starts, so every diagnostic can name a
// column without the scanner carrying an index as well.

@(private)
advance :: proc(p: ^Parser, n: int) {
	count := min(n, len(p.text))
	p.text = p.text[count:]
	p.col += count
}

@(private)
skip_spaces :: proc(p: ^Parser) {
	for len(p.text) > 0 && (p.text[0] == ' ' || p.text[0] == '\t') {
		advance(p, 1)
	}
}

@(private)
is_word_byte :: proc(c: byte) -> bool {
	return c == '_' || c == '-' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private)
peek_word :: proc(p: ^Parser) -> (word: string, ok: bool) {
	save := p.text
	save_col := p.col
	word, ok = take_word(p)
	p.text = save
	p.col = save_col
	return
}

@(private)
take_word :: proc(p: ^Parser) -> (word: string, ok: bool) {
	skip_spaces(p)
	end := 0
	for end < len(p.text) && is_word_byte(p.text[end]) {
		end += 1
	}
	if end == 0 {
		return "", false
	}
	word = p.text[:end]
	advance(p, end)
	return word, true
}

@(private)
take_int :: proc(p: ^Parser) -> (value: int, ok: bool) {
	skip_spaces(p)
	end := 0
	if end < len(p.text) && (p.text[end] == '-' || p.text[end] == '+') {
		end += 1
	}
	digits := end
	for end < len(p.text) && p.text[end] >= '0' && p.text[end] <= '9' {
		end += 1
	}
	if end == digits {
		return 0, false
	}
	value, ok = strconv.parse_int(p.text[:end])
	advance(p, end)
	return
}

// Longest first, so `>=` is not read as `>` followed by a stray `=`.
@(private)
take_comparison :: proc(p: ^Parser) -> (op: Comparison, ok: bool) {
	skip_spaces(p)
	pairs := []struct {
		text: string,
		op:   Comparison,
	} {
		{">=", .Greater_Equal},
		{"<=", .Less_Equal},
		{"!=", .Not_Equal},
		{"==", .Equal},
		{">", .Greater},
		{"<", .Less},
		{"=", .Equal},
	}
	for pair in pairs {
		if strings.has_prefix(p.text, pair.text) {
			advance(p, len(pair.text))
			return pair.op, true
		}
	}
	return {}, false
}

// A message with one substitution, in the parser's own allocator (diagnostics outlive the parse).
@(private)
fmt_message :: proc(p: ^Parser, format: string, argument: string) -> string {
	parts := strings.split(format, "%s", context.temp_allocator)
	if len(parts) != 2 {
		return format
	}
	return strings.concatenate({parts[0], argument, parts[1]}, context.temp_allocator)
}
