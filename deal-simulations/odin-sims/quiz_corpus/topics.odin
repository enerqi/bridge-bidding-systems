/*
A quiz's TOPICS: named bidding-tree filters for the quiz page's topic picker.

Two sources, in this order:

  - the document's own, written in the `.bml` as metadata lines:

		#+TOPIC: Stayman = 1N-2C
		#+TOPIC: Transfers = 1N-2DH, 1N-(X)-2DH

    `Name = pattern, pattern`. A pattern is what the quiz's filter box takes, so a topic can be tried
    there first. They are read from the source TEXT - the document and the files it `#INCLUDE`s - not
    from the parse: both BML parsers treat a block starting `#+KEY:` as metadata and drop the whole
    block, so a block of topic lines renders as nothing and the published html is unchanged, but the
    parsers' metadata keeps only the FIRST value per key. Keep topic lines in a block of their own (a
    blank line before and after) for the same reason - anything else in that block is dropped too.

  - the GENERIC defaults below, offered for every file. The quiz page itself drops any topic, default or
    not, that does not select enough auctions to quiz on (it holds the matcher; this package does not),
    so a generic topic only appears where it means something. A document topic with the same name as a
    default replaces it.
*/
package quiz_corpus

import "core:fmt"
import "core:strings"

import bml "markup:."

// A `#+TOPIC:` line that could not be read, for the workbench to report.
Topic_Problem :: struct {
	file: string, // "" for the document itself, else the included file's name
	line: int, // 1-based, in that file
	text: string,
	why:  string,
}

// The metadata key, without the `#+` and `:`.
TOPIC_KEY :: "TOPIC"

/*
The `#+TOPIC:` lines of a document and of the files it includes (one level, as `#INCLUDE` itself is).

`resolve` reads an included file, as it does for `bml.parse`; nil means includes are not followed.
*/
read_topics :: proc(
	source: string,
	resolve: bml.Include_Resolver = nil,
	user: rawptr = nil,
	allocator := context.allocator,
) -> (
	topics: []Topic,
	problems: []Topic_Problem,
) {
	found := make([dynamic]Topic, allocator)
	bad := make([dynamic]Topic_Problem, allocator)
	scan_topics(source, "", &found, &bad, allocator)
	if resolve != nil {
		for line in strings.split_lines(source, context.temp_allocator) {
			name, is_include := include_target(line)
			if !is_include {
				continue
			}
			if text, ok := resolve(name, user, context.temp_allocator); ok {
				scan_topics(text, name, &found, &bad, allocator)
			}
		}
	}
	return found[:], bad[:]
}

/*
The topics a quiz offers: the document's, then every default the document has not replaced.
*/
topics_for_quiz :: proc(document_topics: []Topic, allocator := context.allocator) -> []Topic {
	out := make([dynamic]Topic, allocator)
	append(&out, ..document_topics)
	for default in DEFAULT_TOPICS {
		replaced := false
		for own in document_topics {
			if strings.equal_fold(own.name, default.name) {
				replaced = true
				break
			}
		}
		if !replaced {
			append(&out, default)
		}
	}
	return out[:]
}

@(private)
scan_topics :: proc(
	text, file: string,
	found: ^[dynamic]Topic,
	bad: ^[dynamic]Topic_Problem,
	allocator := context.allocator,
) {
	number := 0
	for raw in strings.split_lines(text, context.temp_allocator) {
		number += 1
		line := strings.trim_right(raw, "\r")
		value, is_topic := topic_value(line)
		if !is_topic {
			continue
		}
		topic, why := parse_topic(value, allocator)
		if why != "" {
			append(
				bad,
				Topic_Problem {
					file = file,
					line = number,
					text = strings.clone(strings.trim_space(line), allocator),
					why = why,
				},
			)
			continue
		}
		append(found, topic)
	}
}

// `#+TOPIC: <value>`, with leading space allowed as the parsers allow it.
@(private)
topic_value :: proc(line: string) -> (value: string, ok: bool) {
	trimmed := strings.trim_left_space(line)
	prefix := "#+" + TOPIC_KEY + ":"
	if !strings.has_prefix(trimmed, prefix) {
		return "", false
	}
	return strings.trim_space(trimmed[len(prefix):]), true
}

// `Name = pattern, pattern`. Empty patterns between commas are skipped rather than refused.
parse_topic :: proc(value: string, allocator := context.allocator) -> (topic: Topic, why: string) {
	equals := strings.index_byte(value, '=')
	if equals < 0 {
		return {}, "needs `Name = pattern` - there is no `=`"
	}
	name := strings.trim_space(value[:equals])
	if name == "" {
		return {}, "the topic has no name before the `=`"
	}
	patterns := make([dynamic]string, allocator)
	for part in strings.split(value[equals + 1:], ",", context.temp_allocator) {
		if pattern := strings.trim_space(part); pattern != "" {
			append(&patterns, strings.clone(pattern, allocator))
		}
	}
	if len(patterns) == 0 {
		return {}, fmt.tprintf("%q has no patterns after the `=`", name)
	}
	return Topic{name = strings.clone(name, allocator), patterns = patterns[:]}, ""
}

// `#INCLUDE name`, as both parsers read it: the directive at the start of the line, then the name.
@(private)
include_target :: proc(line: string) -> (name: string, ok: bool) {
	trimmed := strings.trim_space(strings.trim_right(line, "\r"))
	if !strings.has_prefix(trimmed, "#INCLUDE") {
		return "", false
	}
	rest := strings.trim_space(trimmed[len("#INCLUDE"):])
	return rest, rest != ""
}

/*
The generic topics, offered for every file and kept by the quiz page only where they select enough
auctions to quiz on.

Taken from the python quiz's catch-all `default_topics.toml` (bridge-system-apps `apps/quiz/`), which
was written to be system-agnostic. Patterns are the filter box's language: `1*` any suit at that level,
`*` any call, `M`/`m` major/minor, brackets the opponents' call; a pattern matches a PREFIX of the
auction, and opponent calls it does not mention are stepped over.
*/
DEFAULT_TOPICS := [?]Topic {
	{name = "1C opening", patterns = {"1C"}, description = "Every auction starting with a 1C opening."},
	{name = "1D opening", patterns = {"1D"}, description = "Every auction starting with a 1D opening."},
	{name = "Major openings", patterns = {"1M"}, description = "1H or 1S openings."},
	{name = "1NT opening", patterns = {"1N"}, description = "Every auction starting with a 1NT opening."},
	{name = "2C opening", patterns = {"2C"}, description = "Every auction starting with a 2C opening."},
	{name = "2NT opening", patterns = {"2N"}, description = "Every auction starting with a 2NT opening."},
	{name = "Weak twos", patterns = {"2D", "2H", "2S"}, description = "Two-level suit openings other than 2C."},
	{
		name = "Preempts",
		patterns = {"3C", "3D", "3H", "3S", "4C", "4D", "4H", "4S"},
		description = "Three-level and four-level openings.",
	},
	{
		name = "Responses to 1C",
		patterns = {"1C-1*", "1C-2*", "1C-3*"},
		description = "Our 1C opening and partner's response, whatever the opponents do.",
	},
	{
		name = "Major raises",
		patterns = {"1M-2M", "1M-3M", "1M-4M", "1M-2N", "1H-3S", "1H-4m", "1S-4CDH"},
		description = "Partner raises our major opening.",
	},
	{
		name = "Notrump responses",
		patterns = {"1*-1N", "1*-2N", "1*-3N"},
		description = "Partner responds in notrump to a one-level opening.",
	},
	{name = "NT Opening responses", patterns = {"1N-*", "2N-*"}, description = "Responses to 1N or 2N opening"},
	{
		name = "We Double",
		patterns = {"(1*)-X", "(2*)-X", "(3*)-X", "(4*)-X", "(*)-P-(*)-X"},
		description = "Opponents open, we double",
	},
	{
		name = "Opponents Start High",
		patterns = {"(2*)-*", "(3*)-*", "(4*)-*"},
		description = "Opponents open at 2+ level, mostly preempts",
	},
	{
		name = "Opponents interfere",
		patterns = {"1*-(*)", "2*-(*)", "3*-(*)", "4*-(*)", "5*-(*)", "6*-(*)", "7*-(*)"},
		description = "We open, the opponents do something other than pass.",
	},
	{
		name = "Opponents double",
		patterns = {"1*-(X)", "2*-(X)", "3*-(X)", "4*-(X)", "5*-(X)", "6*-(X)", "7*-(X)"},
		description = "We open and the opponents double.",
	},
	{name = "Opponents opened", patterns = {"(*)"}, description = "The opponents opened the bidding."},
	{
		name = "Long auctions",
		patterns = {"*-*-*-*-*-*"},
		description = "Auctions six or more calls deep - the competitive and slam sequences.",
	},
}
