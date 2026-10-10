/*
The parity gate: every `.bml` file in the corpus, extracted here, against what the python quiz
extracts from it (`testdata/goldens.json`, written by `tools/python_goldens.py`).

A count and a digest per file, so the goldens are small and the test needs no python. When a digest
moves, set `QUIZ_CORPUS_ORACLE` to a directory the oracle wrote with `--dump DIR` and the failure
names the first auction that differs, both ways round.

The goldens follow the NOTES: editing a `.bml` file moves them, legitimately. Re-run the oracle after
an edit (with the bridge-system-apps checkout present) and review the counts it prints.
*/
package quiz_corpus

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import bml "markup:."

@(private = "file")
REPO :: #directory + "/../../.."

@(private = "file")
Golden :: struct {
	count:  int,
	sha256: string,
}

@(test)
test_every_file_matches_the_python_quiz :: proc(t: ^testing.T) {
	goldens_text, read_error := os.read_entire_file(#directory + "/testdata/goldens.json", context.temp_allocator)
	read_ok := read_error == nil
	testing.expect(t, read_ok, "testdata/goldens.json is missing: run tools/python_goldens.py")
	if !read_ok {
		return
	}
	goldens: map[string]Golden
	if json.unmarshal(goldens_text, &goldens, allocator = context.temp_allocator) != nil {
		testing.fail_now(t, "testdata/goldens.json does not parse")
	}

	matched := 0
	for name, golden in goldens {
		source, source_error := os.read_entire_file(fmt.tprintf("%s/%s", REPO, name), context.temp_allocator)
		if source_error != nil {
			testing.expectf(t, false, "%s: in the goldens but not in the repo", name)
			continue
		}
		doc := bml.parse(string(source), {resolve_include = read_include})
		auctions := extract(doc, context.temp_allocator)
		got := digest(auctions)
		if len(auctions) == golden.count && got == golden.sha256 {
			matched += 1
		} else {
			testing.expectf(
				t,
				false,
				"%s: %d auctions (python %d), digest %s",
				name,
				len(auctions),
				golden.count,
				got[:12],
			)
			explain(name, auctions)
		}
		bml.destroy(doc)
	}
	testing.expectf(t, matched == len(goldens), "%d of %d files match the python quiz", matched, len(goldens))
}

@(test)
test_prettify_matches_the_python_regexes :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"1C(1H)", "1C (1H)"},
		{"(1H)2C", "(1H) 2C"},
		{"1C P P 1H", "1C Pass P 1H"}, // re.sub does not overlap: the second P's space was consumed
		{"(P)", "(Pass)"},
		{"(1S)P", "(1S) Pass"},
		{"(1S)X", "(1S) X"},
		{"1C--1D", "1C 1D"},
	}
	for c in cases {
		testing.expect_value(t, prettify_bidrepr(c[0], context.temp_allocator), c[1])
	}
}

@(test)
test_heading_bids :: proc(t: ^testing.T) {
	headers := []Header {
		{kind = .H1, text = "1C Opening"},
		{kind = .H2, text = "1C--1HS"},
		{kind = .H3, text = "Good-Bad"},
	}
	got := bids_from_headers(headers, context.temp_allocator)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], "1C")
		testing.expect_value(t, got[1], "1HS")
	}
	minors := bids_from_headers([]Header{{kind = .H1, text = "(1m)--P--(1N)"}}, context.temp_allocator)
	// `(1m)` keeps its lowercase m - a minor, not a major - and brackets are an opponent's call
	testing.expect(t, len(minors) == 0 || minors[0] != "(1M)", "a lowercase m must not fold to M")
}

@(private = "file")
read_include :: proc(name: string, user: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	data, error := os.read_entire_file(fmt.tprintf("%s/%s", REPO, name), allocator)
	return string(data), error == nil
}

@(private = "file")
digest :: proc(auctions: []Auction) -> string {
	b := strings.builder_make(context.temp_allocator)
	for auction in auctions {
		for call, index in auction.sequence {
			if index > 0 {
				strings.write_byte(&b, 0x1f)
			}
			strings.write_string(&b, call)
		}
		strings.write_byte(&b, 0x1e)
		strings.write_string(&b, auction.description)
		strings.write_byte(&b, 0x1d)
	}
	sum := hash.hash_string(.SHA256, strings.to_string(b), context.temp_allocator)
	return string(hex.encode(sum, context.temp_allocator))
}

// With `QUIZ_CORPUS_ORACLE` set, print the first auction that differs from the python's dump.
@(private = "file")
explain :: proc(name: string, auctions: []Auction) {
	oracle := os.get_env("QUIZ_CORPUS_ORACLE", context.temp_allocator)
	if oracle == "" {
		fmt.eprintfln(
			"  (set QUIZ_CORPUS_ORACLE to a `python_goldens.py --dump` directory to see where %s differs)",
			name,
		)
		return
	}
	stem := strings.trim_suffix(name, ".bml")
	text, text_error := os.read_entire_file(fmt.tprintf("%s/%s.json", oracle, stem), context.temp_allocator)
	if text_error != nil {
		fmt.eprintfln("  no %s.json in %s", stem, oracle)
		return
	}
	python: []Auction
	if json.unmarshal(text, &python, allocator = context.temp_allocator) != nil {
		fmt.eprintfln("  %s.json does not parse", stem)
		return
	}
	for index in 0 ..< max(len(python), len(auctions)) {
		if index >= len(python) || index >= len(auctions) || !same(python[index], auctions[index]) {
			fmt.eprintfln("  first difference at auction %d:", index)
			if index < len(python) {
				fmt.eprintfln("    python: %v  %q", python[index].sequence, python[index].description)
			}
			if index < len(auctions) {
				fmt.eprintfln("    odin:   %v  %q", auctions[index].sequence, auctions[index].description)
			}
			return
		}
	}
}

@(private = "file")
same :: proc(a, b: Auction) -> bool {
	if a.description != b.description || len(a.sequence) != len(b.sequence) {
		return false
	}
	for call, index in a.sequence {
		if call != b.sequence[index] {
			return false
		}
	}
	return true
}

@(test)
test_the_corpus_json_round_trips :: proc(t: ^testing.T) {
	doc := bml.parse("#+TITLE: Tiny\n\n* 1N Opening\n\n1N = 15-17\n  2C = stayman\n    2D = no major\n")
	defer bml.destroy(doc)
	system := system_for_document(doc, "tiny.bml", allocator = context.temp_allocator)
	testing.expect_value(t, system.variant, "tiny")
	testing.expect_value(t, system.title, "Tiny")
	testing.expect_value(t, len(system.auctions), 3)

	text, ok := corpus_json([]Exported_System{system}, context.temp_allocator)
	testing.expect(t, ok)
	back: []Exported_System
	testing.expect(t, json.unmarshal_string(text, &back, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, len(back), 1)
	if len(back) == 1 && len(back[0].auctions) == 3 {
		testing.expect_value(t, back[0].auctions[2].sequence[2], "2D")
		testing.expect_value(t, back[0].auctions[2].description, "no major")
		testing.expect(t, back[0].topics != nil || len(back[0].topics) == 0)
	}
}

@(test)
test_topic_lines_are_read_from_the_source :: proc(t: ^testing.T) {
	source := "#+TITLE: x\n\n#+TOPIC: Stayman = 1N-2C\n  #+TOPIC: Transfers = 1N-2DH, 1N-(X)-2DH ,\n#+TOPIC: = 1C\n#+TOPIC: Nothing =\n#+TOPIC: no equals here\n\n* 1N\n\n1N = 15-17\n"
	topics, problems := read_topics(source, allocator = context.temp_allocator)
	testing.expect_value(t, len(topics), 2)
	if len(topics) == 2 {
		testing.expect_value(t, topics[0].name, "Stayman")
		testing.expect_value(t, len(topics[1].patterns), 2) // the trailing comma adds nothing
		testing.expect_value(t, topics[1].patterns[1], "1N-(X)-2DH")
	}
	testing.expect_value(t, len(problems), 3)
	if len(problems) == 3 {
		testing.expect_value(t, problems[0].line, 5)
		testing.expectf(t, strings.contains(problems[2].why, "no `=`"), "%q", problems[2].why)
	}

	// AND THE PARSER RENDERS NOTHING OF THEM: a block that starts `#+KEY:` is metadata to both parsers.
	doc := bml.parse(source)
	defer bml.destroy(doc)
	for block in doc.blocks {
		testing.expectf(t, !strings.contains(block.text, "TOPIC"), "a topic line leaked into a %v block", block.kind)
	}
}

@(test)
test_topics_are_read_from_included_files_too :: proc(t: ^testing.T) {
	resolve :: proc(name: string, user: rawptr, allocator: mem.Allocator) -> (string, bool) {
		if name == "chapter.bml" {
			return "#+TOPIC: From the chapter = 2C\n", true
		}
		return "", false
	}
	topics, _ := read_topics(
		"#INCLUDE chapter.bml\n#INCLUDE missing.bml\n#+TOPIC: Own = 1C\n",
		resolve,
		allocator = context.temp_allocator,
	)
	testing.expect_value(t, len(topics), 2)
	if len(topics) == 2 {
		testing.expect_value(t, topics[0].name, "Own")
		testing.expect_value(t, topics[1].name, "From the chapter")
	}
}

@(test)
test_document_topics_come_first_and_replace_defaults_by_name :: proc(t: ^testing.T) {
	own := []Topic {
		{name = "Stayman", patterns = {"1N-2C"}},
		{name = "1nt OPENING", patterns = {"1N"}, description = "mine"},
	}
	all := topics_for_quiz(own, context.temp_allocator)
	testing.expect_value(t, len(all), 2 + len(DEFAULT_TOPICS) - 1)
	testing.expect_value(t, all[0].name, "Stayman")
	for topic in all[2:] {
		testing.expectf(
			t,
			!strings.equal_fold(topic.name, "1NT opening"),
			"the default %q should have been replaced",
			topic.name,
		)
	}
}
