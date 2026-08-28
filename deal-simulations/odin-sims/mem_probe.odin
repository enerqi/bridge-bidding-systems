package main

/*
	mem_probe — what does ONE DOM element cost in this engine, and what makes it cost that?

	  just mem-probe                 # every case at 10k elements
	  just mem-probe 40000           # a different size
	  just mem-probe -only class     # just the cases whose name contains "class"

	`mem-check` measured whole documents and left an implausible headline: ~10 KB of process memory per
	element on the notes page and ~20 KB on the card page. That is either the engine's real per-element cost
	or an artefact of what those particular documents carry — 33k elements of prose with a stylesheet, versus
	4k elements with a KB of `data-*` json each and a page of script. A total cannot tell the two apart.

	So this varies ONE THING AT A TIME against the same baseline: bare elements, elements with text, nesting,
	a shared class against a unique class per element, attributes, a big `data-` payload, an inline style, a
	subtree that is `display: none`, and the same document with a script attached. Every case is generated,
	loaded, measured, and then replaced by a blank document so the next case starts from the same place.

	READ THE COMMIT COLUMN, not the working set: the working set moves when the OS trims pages, while private
	commit is what the process actually asked for. Both are printed because they diverge, and the divergence
	is itself worth seeing.

	EVERY CASE RUNS IN ITS OWN PROCESS, and that is not fastidiousness - it is the fix for a wrong answer this
	program produced first time round. Run back to back in one process, a case that follows a bigger one
	measures a delta against memory the process has ALREADY committed, so it reads as almost free: a
	fixed-size block case measured 0.9MB (97 bytes/element) purely because the case before it had left 145MB
	committed, and re-measured 146MB when run first. So the parent here spawns a child per case (`-case`) and
	the child measures nothing but its own case, from a clean process.

	A PROGRAM, not a test: loading documents into the engine from an Odin test-runner thread crashes inside
	the engine (see `page_check.odin`). Kept in the tree rather than thrown away, against the usual rule for
	probes, because "why is the app big" is a question that will be asked again and this is the answer's
	instrument — the numbers below are only trustworthy while they can be re-run.
*/

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "perf"
import sa "sciter:sciter_app"

Case :: struct {
	name:  string,
	// The document, and how many ELEMENTS the body holds (the count the cost is divided by).
	build: proc(n: int, allocator := context.allocator) -> (html: string, elements: int),
}

main :: proc() {
	n := 10_000
	filter := ""
	// `-case NAME` is the CHILD: run exactly this one and print its row. The parent spawns one per case.
	only_case := ""
	// `-view W` narrows the viewport: if the per-element cost is a cached measurement against the available
	// width, it should move with this.
	view_width := 1120
	for i := 0; i < len(os.args[1:]); i += 1 {
		arg := os.args[1 + i]
		switch arg {
		case "-only":
			if 2 + i < len(os.args) {
				i += 1
				filter = os.args[1 + i]
			}
		case "-view":
			if 2 + i < len(os.args) {
				i += 1
				if w, ok := strconv.parse_int(os.args[1 + i]); ok && w > 0 {
					view_width = w
				}
			}
		case "-scroll-api":
			// Not a measurement: what a document can ask about its own scrolling, which is what a
			// virtualising preview has to be built on.
			probe_scroll_api()
			return
		case "-case":
			if 2 + i < len(os.args) {
				i += 1
				only_case = os.args[1 + i]
			}
		case:
			if parsed, ok := strconv.parse_int(arg); ok && parsed > 0 {
				n = parsed
			} else {
				fmt.eprintfln("mem_probe: unknown argument %q", arg)
				os.exit(2)
			}
		}
	}

	cases := []Case {
		{"bare div", build_bare},
		{"div + one char", build_text},
		{"div + 100 chars", build_long_text},
		{"nested 10 deep", build_nested},
		{"class, one rule for all", build_class_shared},
		{"class, one rule EACH", build_class_unique},
		{"5 data attributes", build_attrs},
		{"1 KB data attribute", build_big_attr},
		{"inline style", build_inline_style},
		{"inside display:none", build_hidden},
		{"ul/li list (notes shape)", build_list},
		{"div + text, plus a script", build_with_script},
		// The second round, chasing the first round's headline: a bare element costs under a kilobyte and the
		// same element with ONE character of text costs fifteen. These ask which part of that is the text -
		// and the answer is that it is not the text at all: the same characters in one text node, or in inline
		// spans, or as extra LINES in one block, are all an order of magnitude cheaper.
		{"one text node, same char count", build_one_text_node},
		{"spans inside one div", build_spans},
		{"identical 20-char strings", build_same_strings},
		{"unique 20-char strings", build_unique_strings},
		{"visibility:hidden", build_invisible},
		{"height:0 + overflow:hidden", build_clipped},
		{"white-space: pre", build_pre},
		{"font-size: 4px", build_tiny_font},
		// Round three. Round two found the driver: an element with its OWN BOX and content costs ~15KB, while
		// the same text in inline spans inside one block costs ~2.3KB. These ask what shape that has - does
		// more text step in units (no: ~200 bytes a character, linearly), and do the other display types pay
		// it (inline-block does, and more; flex does).
		{"block, 10 chars", build_chars_10},
		{"block, 40 chars", build_chars_40},
		{"block, 200 chars", build_chars_200},
		{"block, 400 chars", build_chars_400},
		{"display:inline-block", build_inline_block},
		{"display:flex", build_flex},
		{"fixed width+height block", build_fixed_size},
		// Round four, which is where the ORDER BUG was caught. Round three appeared to find a lever - the same
		// 10k divs at 0.9MB with a fixed width, height and `overflow: hidden`, against 143MB auto-sized - and
		// it was an artefact of the case before it leaving 145MB committed. Every one of these rows measures
		// ~15KB/element, fixed size or not: giving a block a size changes NOTHING about what it costs. The
		// only real row here is the EMPTY one, and it agrees with `bare div`.
		{"fixed w+h, no overflow rule", build_fixed_no_overflow},
		{"fixed width only", build_fixed_width},
		{"fixed height only", build_fixed_height},
		{"fixed w+h, nowrap", build_fixed_nowrap},
		{"fixed w+h, EMPTY", build_fixed_empty},
		{"auto size, body fixed width", build_body_fixed},
		{"display:flex again (kept?)", build_flex},
		// Round five, the decisive one: is the ~15KB attached to the BLOCK or to the LINE inside it? These put
		// n lines inside ONE block, by wrapping and by <br>, against n blocks of one line each.
		{"1 block, n wrapped lines", build_wrapped_lines},
		{"1 block, n <br> lines", build_br_lines},
		{"<text> elements", build_text_elements},
		// The editor's own widget, asked the same question: the workbench puts a whole .bml file in a
		// `<plaintext>`, and at 15KB a line that would be its own problem - unless the widget is virtualised.
		{"plaintext, n lines", build_plaintext},
		{"scrolling div, n lines", build_scroller},
	}

	// THE CHILD: one case, one process, one row.
	if only_case != "" {
		for c in cases {
			if c.name != only_case {
				continue
			}
			run_case(c, n, view_width)
			return
		}
		fmt.eprintfln("mem_probe: no case named %q", only_case)
		os.exit(2)
	}

	// THE PARENT: a child process per case, so no case is measured against another's committed memory.
	fmt.printfln("%d elements per case, ONE PROCESS PER CASE, in a 1120x780 windowless view", n)
	fmt.println()
	fmt.printfln("%-30s %8s %9s %10s %9s %9s", "case", "html KB", "commit MB", "bytes/el", "wset MB", "kept MB")
	exe := os.args[0]
	for c in cases {
		if filter != "" && !strings.contains(c.name, filter) {
			continue
		}
		argv := []string{exe, fmt.tprintf("%d", n), "-view", fmt.tprintf("%d", view_width), "-case", c.name}
		state, stdout, stderr, err := os.process_exec({command = argv}, context.temp_allocator)
		if err != nil || !state.success {
			fmt.printfln("%-30s (the child failed: %v %s)", c.name, err, string(stderr))
			continue
		}
		fmt.print(string(stdout))
	}

	fmt.println()
	fmt.println("bytes/el is the COMMIT delta divided by the element count; `kept` is what a blank document")
	fmt.println("did NOT give back. Each row is its own process, so no row is measured against another's peak.")
}

// Measure one case in this process, from a clean start, and print its row.
run_case :: proc(c: Case, n: int, view_width := 1120) {
	if !sa.load_engine() {
		fmt.eprintln("mem_probe: the Sciter engine is not loadable - set SCITER_LIB")
		os.exit(1)
	}
	view, verr := sa.create_windowless({width = i32(view_width), height = 780})
	if verr != nil {
		fmt.eprintln("mem_probe: could not create a windowless view:", verr)
		os.exit(1)
	}

	html, elements := c.build(n)
	defer delete(html)

	// A blank document first, so the engine's one-off allocations land in the baseline rather than in the
	// case's delta.
	blank(&view)
	before_wset, before_commit := perf.memory_mb()

	if sa.load_html(view.window, html, "file://mem-probe/case.html") != nil {
		fmt.printfln("%-30s (the engine refused it)", c.name)
		return
	}
	pump(&view)
	after_wset, after_commit := perf.memory_mb()

	blank(&view)
	_, kept_commit := perf.memory_mb()

	commit_delta := after_commit - before_commit
	fmt.printfln(
		"%-30s %8v %9.1f %10.0f %9.1f %9.1f",
		c.name,
		len(html) / 1024,
		commit_delta,
		commit_delta * 1024 * 1024 / f64(max(elements, 1)),
		after_wset - before_wset,
		kept_commit - before_commit,
	)
}

/*
What API does a scrolling document have in this engine? A parked-section preview needs three things and
none of them is documented: a scroll notification, the scroll offset, and each child's position.
*/
probe_scroll_api :: proc() {
	if !sa.load_engine() {
		fmt.eprintln("mem_probe: the Sciter engine is not loadable - set SCITER_LIB")
		os.exit(1)
	}
	view, verr := sa.create_windowless({width = 600, height = 400})
	if verr != nil {
		fmt.eprintln("mem_probe: could not create a windowless view:", verr)
		os.exit(1)
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<html><head><style>body{overflow:scroll;height:400px}</style></head><body>")
	for i in 0 ..< 200 {
		fmt.sbprintf(&b, "<p id=\"p%d\">paragraph %d, with enough words to take a line or two of the width</p>", i, i)
	}
	strings.write_string(&b, "</body></html>")
	if sa.load_html(view.window, strings.to_string(b), "file://mem-probe/scroll.html") != nil {
		fmt.eprintln("the engine refused the document")
		os.exit(1)
	}
	pump(&view)

	probe := `(function(){
		var out = [];
		var body = document.body;
		out.push("body.scrollTop=" + typeof body.scrollTop);
		out.push("body.scrollTo=" + typeof body.scrollTo);
		out.push("state.box=" + typeof body.state.box);
		try { out.push("scrollInfo=" + JSON.stringify(body.state.box("dimension","client"))); } catch (x) { out.push("client-threw"); }
		var p = document.$("#p100");
		try { out.push("p100 view y=" + JSON.stringify(p.state.box("rect","border","view"))); } catch (x) { out.push("view-threw:" + x); }
		try { out.push("p100 doc y=" + JSON.stringify(p.state.box("rect","border","root"))); } catch (x) { out.push("root-threw:" + x); }
		var fired = 0;
		document.on("scroll", function(){ fired += 1; return false; });
		try { body.scrollTo(0, 2000, false); } catch (x) { out.push("scrollTo-threw:" + x); }
		out.push("after scrollTo: scrollTop=" + body.scrollTop);
		try { out.push("p100 view y after=" + JSON.stringify(p.state.box("rect","border","view"))); } catch (x) {}
		out.push("scroll events=" + fired);
		return out.join(" | ");
	})()`
	result, err := sa.eval(view.window, probe)
	defer sa.value_clear(&result)
	if err != nil {
		fmt.eprintln("the probe did not run:", err)
		os.exit(1)
	}
	text, _ := sa.value_to_string(&result, context.temp_allocator)
	fmt.println(text)
	pump(&view)
	after, aerr := sa.eval(view.window, "String(document.body.scrollTop)")
	defer sa.value_clear(&after)
	if aerr == nil {
		s2, _ := sa.value_to_string(&after, context.temp_allocator)
		fmt.println("after a pump, scrollTop =", s2)
	}
}

// ---- the documents -------------------------------------------------------------------------------
//
// Every builder returns the html AND the element count, because several of them do not have one element per
// line: the nesting case and the list case both put several elements in each repeat.

@(private = "file")
wrap :: proc(body: string, head := "", allocator := context.allocator) -> string {
	return fmt.aprintf("<html><head>%s</head><body>%s</body></html>", head, body, allocator = allocator)
}

build_bare :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 12, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div></div>")
	}
	return wrap(strings.to_string(b), "", allocator), n
}

build_text :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	return wrap(strings.to_string(b), "", allocator), n
}

build_long_text :: proc(n: int, allocator := context.allocator) -> (string, int) {
	text := strings.repeat("word ", 20, context.temp_allocator)
	b := strings.builder_make(0, n * 120, context.temp_allocator)
	for _ in 0 ..< n {
		fmt.sbprintf(&b, "<div>%s</div>", text)
	}
	return wrap(strings.to_string(b), "", allocator), n
}

// Ten levels, so the same element count arrives as a deep tree rather than a flat one.
build_nested :: proc(n: int, allocator := context.allocator) -> (string, int) {
	chains := max(n / 10, 1)
	b := strings.builder_make(0, n * 14, context.temp_allocator)
	for _ in 0 ..< chains {
		for _ in 0 ..< 10 {
			strings.write_string(&b, "<div>")
		}
		strings.write_string(&b, "x")
		for _ in 0 ..< 10 {
			strings.write_string(&b, "</div>")
		}
	}
	return wrap(strings.to_string(b), "", allocator), chains * 10
}

build_class_shared :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 24, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, `<div class="a">x</div>`)
	}
	head := `<style>.a { color: #333; padding: 1px; }</style>`
	return wrap(strings.to_string(b), head, allocator), n
}

// The pathological selector case: one class per element and one rule per class, so the style resolver
// cannot share a computed style between two elements.
build_class_unique :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 28, context.temp_allocator)
	rules := strings.builder_make(0, n * 40, context.temp_allocator)
	strings.write_string(&rules, "<style>")
	for i in 0 ..< n {
		fmt.sbprintf(&b, `<div class="c%d">x</div>`, i)
		fmt.sbprintf(&rules, ".c%d { color: #%03x; padding: 1px; }", i, i & 0xfff)
	}
	strings.write_string(&rules, "</style>")
	return wrap(strings.to_string(b), strings.to_string(rules), allocator), n
}

build_attrs :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 70, context.temp_allocator)
	for i in 0 ..< n {
		fmt.sbprintf(&b, `<div id="e%d" data-a="1" data-b="two" data-c="3.5" data-d="four">x</div>`, i)
	}
	return wrap(strings.to_string(b), "", allocator), n
}

// The card page's shape: a kilobyte of json parked on the element for the script to read later.
build_big_attr :: proc(n: int, allocator := context.allocator) -> (string, int) {
	payload := strings.repeat("0123456789", 102, context.temp_allocator)
	b := strings.builder_make(0, n * 1100, context.temp_allocator)
	for _ in 0 ..< n {
		fmt.sbprintf(&b, `<div data-sim="%s">x</div>`, payload)
	}
	return wrap(strings.to_string(b), "", allocator), n
}

build_inline_style :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 44, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, `<div style="color:#333;padding:1px">x</div>`)
	}
	return wrap(strings.to_string(b), "", allocator), n
}

// Does an element that is never laid out cost less? This is the card page's board parking, asked directly.
build_hidden :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	strings.write_string(&b, `<div style="display:none">`)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	strings.write_string(&b, "</div>")
	return wrap(strings.to_string(b), "", allocator), n + 1
}

// The notes' own shape: nested lists, which is what a bid table renders as.
build_list :: proc(n: int, allocator := context.allocator) -> (string, int) {
	groups := max(n / 5, 1)
	b := strings.builder_make(0, n * 30, context.temp_allocator)
	for _ in 0 ..< groups {
		strings.write_string(&b, "<ul>")
		for _ in 0 ..< 4 {
			strings.write_string(&b, "<li><div>1C</div>strong, artificial</li>")
		}
		strings.write_string(&b, "</ul>")
	}
	return wrap(strings.to_string(b), "", allocator), groups * 9
}

// Script presence, not script work: does having a runtime attached change what an element costs?
build_with_script :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	head := `<script>function probe(){ return document.body.children.length; }</script>`
	return wrap(strings.to_string(b), head, allocator), n
}

// One text node holding the same number of characters as the 10k-div case, so the difference is the number
// of TEXT NODES and line boxes rather than the amount of text.
build_one_text_node :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 2 + 32, context.temp_allocator)
	strings.write_string(&b, "<div>")
	for _ in 0 ..< n {
		strings.write_string(&b, "x ")
	}
	strings.write_string(&b, "</div>")
	return wrap(strings.to_string(b), "", allocator), 1
}

// The same text, in INLINE elements inside one block: n elements, but one block box.
build_spans :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 20 + 32, context.temp_allocator)
	strings.write_string(&b, "<div>")
	for _ in 0 ..< n {
		strings.write_string(&b, "<span>x</span> ")
	}
	strings.write_string(&b, "</div>")
	return wrap(strings.to_string(b), "", allocator), n
}

build_same_strings :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 34, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>abcdefghijklmnopqrst</div>")
	}
	return wrap(strings.to_string(b), "", allocator), n
}

// If the engine keys anything by string content, unique strings pay for it and identical ones do not.
build_unique_strings :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 34, context.temp_allocator)
	for i in 0 ..< n {
		fmt.sbprintf(&b, "<div>abcdefghij%010d</div>", i)
	}
	return wrap(strings.to_string(b), "", allocator), n
}

// `visibility: hidden` keeps the boxes (measured elsewhere in this project); `display: none` does not. If the
// cost is layout, these two should be far apart.
build_invisible :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	strings.write_string(&b, `<div style="visibility:hidden">`)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	strings.write_string(&b, "</div>")
	return wrap(strings.to_string(b), "", allocator), n + 1
}

// Laid out, but clipped away: does anything notice that none of it can be seen?
build_clipped :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	strings.write_string(&b, `<div style="height:0;overflow:hidden">`)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	strings.write_string(&b, "</div>")
	return wrap(strings.to_string(b), "", allocator), n + 1
}

build_pre :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	head := `<style>div { white-space: pre; }</style>`
	return wrap(strings.to_string(b), head, allocator), n
}

build_tiny_font :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	head := `<style>body { font-size: 4px; }</style>`
	return wrap(strings.to_string(b), head, allocator), n
}

@(private = "file")
build_chars :: proc(n: int, chars: int, allocator := context.allocator) -> (string, int) {
	text := strings.repeat("ab ", (chars + 2) / 3, context.temp_allocator)
	b := strings.builder_make(0, n * (chars + 14), context.temp_allocator)
	for _ in 0 ..< n {
		fmt.sbprintf(&b, "<div>%s</div>", text)
	}
	return wrap(strings.to_string(b), "", allocator), n
}

build_chars_10 :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_chars(n, 10, allocator)
}
build_chars_40 :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_chars(n, 40, allocator)
}
build_chars_200 :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_chars(n, 200, allocator)
}
build_chars_400 :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_chars(n, 400, allocator)
}

// Does the cost follow BLOCK-ness or just "has a box"? An inline-block has a box of its own but sits in its
// parent's line.
build_inline_block :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	head := `<style>div { display: inline-block; }</style>`
	return wrap(strings.to_string(b), head, allocator), n
}

build_flex :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	strings.write_string(&b, `<div class="row">`)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	strings.write_string(&b, "</div>")
	head := `<style>.row { display: flex; flex-flow: row wrap; }</style>`
	return wrap(strings.to_string(b), head, allocator), n + 1
}

// A block whose size needs no measuring: if the cost is the measurement structures, this is where it goes.
build_fixed_size :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 13, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<div>x</div>")
	}
	head := `<style>div { width: 40px; height: 12px; overflow: hidden; }</style>`
	return wrap(strings.to_string(b), head, allocator), n
}

@(private = "file")
build_styled :: proc(n: int, rule: string, body_text := "x", allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 16, context.temp_allocator)
	for _ in 0 ..< n {
		fmt.sbprintf(&b, "<div>%s</div>", body_text)
	}
	head := fmt.tprintf("<style>%s</style>", rule)
	return wrap(strings.to_string(b), head, allocator), n
}

build_fixed_no_overflow :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_styled(n, "div { width: 40px; height: 12px; }", "x", allocator)
}
build_fixed_width :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_styled(n, "div { width: 40px; overflow: hidden; }", "x", allocator)
}
build_fixed_height :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_styled(n, "div { height: 12px; overflow: hidden; }", "x", allocator)
}
build_fixed_nowrap :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_styled(n, "div { width: 40px; height: 12px; overflow: hidden; white-space: nowrap; }", "x", allocator)
}
// The control for the fixed-size case: if an EMPTY fixed block costs the same as one with text in it, the
// text is not being laid out at all and the saving is not a saving.
build_fixed_empty :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_styled(n, "div { width: 40px; height: 12px; overflow: hidden; }", "", allocator)
}
// Does the cost depend on the width being resolved against the viewport? A fixed-width body answers it.
build_body_fixed :: proc(n: int, allocator := context.allocator) -> (string, int) {
	return build_styled(n, "body { width: 400px; }", "x", allocator)
}

// n LINES in one block, by making the block too narrow for two words. If the cost follows lines rather than
// blocks, this is as expensive as n blocks; if it follows blocks, it is nearly free.
build_wrapped_lines :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 12, context.temp_allocator)
	strings.write_string(&b, `<div style="width:30px">`)
	for _ in 0 ..< n {
		strings.write_string(&b, "wwww ")
	}
	strings.write_string(&b, "</div>")
	return wrap(strings.to_string(b), "", allocator), n
}

// The same question without relying on the wrap: an explicit line break per line, one block.
build_br_lines :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 10, context.temp_allocator)
	strings.write_string(&b, "<div>")
	for _ in 0 ..< n {
		strings.write_string(&b, "x<br>")
	}
	strings.write_string(&b, "</div>")
	return wrap(strings.to_string(b), "", allocator), n
}

// Sciter's own `<text>` element - what a `<plaintext>` line is made of. Cheaper than a div?
build_text_elements :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 14, context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_string(&b, "<text>x</text>")
	}
	return wrap(strings.to_string(b), "", allocator), n
}

build_plaintext :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 20, context.temp_allocator)
	strings.write_string(&b, `<plaintext style="height:600px">`)
	for i in 0 ..< n {
		fmt.sbprintf(&b, "1C = strong, line %d\n", i)
	}
	strings.write_string(&b, "</plaintext>")
	return wrap(strings.to_string(b), "", allocator), n
}

// The control for the plaintext: the same lines as ordinary blocks inside a scrolling box of the same height.
// If the plaintext is virtualised and this is not, the difference is the widget's doing.
build_scroller :: proc(n: int, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(0, n * 30, context.temp_allocator)
	strings.write_string(&b, `<div style="height:600px;overflow:scroll">`)
	for i in 0 ..< n {
		fmt.sbprintf(&b, "<div>1C = strong, line %d</div>", i)
	}
	strings.write_string(&b, "</div>")
	return wrap(strings.to_string(b), "", allocator), n
}

// ---- the engine ----------------------------------------------------------------------------------

@(private = "file")
blank :: proc(view: ^sa.Windowless_View) {
	_ = sa.load_html(view.window, "<html><body>blank</body></html>", "file://mem-probe/blank.html")
	pump(view)
}

@(private = "file")
pump :: proc(view: ^sa.Windowless_View) {
	for i in 0 ..< 8 {
		sa.windowless_heartbeat(view, time.Duration(i) * 16 * time.Millisecond)
		sa.paint_windowless(view)
	}
}
