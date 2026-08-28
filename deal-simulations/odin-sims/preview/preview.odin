package preview

import "core:strings"

/*
The BML preview's section window: hand the engine ONE section of the notes, not the whole document.

WHY, measured. In this engine an element with its own box and any content costs ~15.3KB of process memory
(`just mem-probe`), so previewing the assembled `bidding-system.bml` - 1.18MB of html, ~33.5k elements -
commits **328MB** (`just mem-check`).

WHAT DID NOT WORK, and it is the more useful half of the story: hiding the other sections with
`display: none` from a script at the end of the body measured **434MB - WORSE than doing nothing**. The
probe had shown a `display: none` subtree at ~3.9KB an element, but that is only true of a subtree the
engine NEVER LAID OUT. A document is styled and laid out at load, before any script of ours runs, so
hiding afterwards pays for the layout AND for the hidden state, and none of the first payment comes back.
The lesson generalises: in this engine you cannot un-spend layout, you can only not spend it.

So the section window is applied to the TEXT, before the engine sees a byte of it. `slice_sections` is a
string operation on what `bml.render_html` produced: find the top-level headings, keep the run you want,
keep the page's own head and footer nav, drop the rest. No DOM, no script, no engine.

WHY IT LIVES HERE rather than in the renderer: `bridge-markup`'s html is held to byte parity with the
python reference over the whole corpus, and the pages already published on `w:/` came out of it, so the
preview must not change what the renderer emits. Nothing here is visible to `just bml`.

The section a caret sits in is decided here too (`section_of_row`), on the SOURCE text, because that is the
one place both ends agree: the headings in the buffer are in the same order as the headings in the rendered
page, so counting them is the whole mapping. No line numbers in the html, no ids to keep in step.
*/

/*
The heading levels that start a section: `*`, `**` and `***` in BML - `<h1>`, `<h2>`, `<h3>` in the html.

Three levels rather than two, because the corpus does not use them uniformly and two levels leaves some
chapters almost unsliced: `nt-bidding.bml` renders 5 `h1`, ZERO `h2` and 23 `h3`, so cutting at h1/h2 gives
five 24KB sections while cutting at h1/h2/h3 gives twenty-eight of about 4KB. `h4` stays inside its section
- below that a slice would be a single bid table with no context around it.
*/
@(private)
SECTION_TAGS :: []string{"<h1", "<h2", "<h3"}

// The footer `render_html` writes after the last section: a "Top" link and the nav list of every `<h1>`.
// Kept in every slice, because it is how a reader sees what else the document holds.
@(private)
FOOTER_MARKER :: `<a class="top-link"`

/*
Which section a row of the SOURCE falls in, counting from 0.

A BML heading is a line whose first non-space character is `*` followed by whitespace; the renderer emits
`*`/`**`/`***` as `h1`/`h2`/`h3`, which is what `SECTION_TAGS` matches, and `****` does not start a section.
Text before the first heading is section 0, which is also what an empty document answers.
*/
section_of_row :: proc(source: string, row: int) -> int {
	section := 0
	line_index := 0
	seen_heading := false
	rest := source
	for line_index <= row {
		newline := strings.index_byte(rest, '\n')
		line := newline < 0 ? rest : rest[:newline]

		if level := heading_level(line); level >= 1 && level <= 3 {
			// A heading's own row belongs to the section it opens, and the FIRST heading opens section 0:
			// what comes before it (the `#+TITLE:`, a preamble paragraph) belongs to that same section,
			// because every slice keeps everything before the first heading.
			if seen_heading {
				section += 1
			}
			seen_heading = true
		}
		if newline < 0 {
			break
		}
		rest = rest[newline + 1:]
		line_index += 1
	}
	return section
}

// How many `*`s open this line as a heading, or 0 if it is not one. `*text` is not a heading: the marker
// needs whitespace after it, which is also how the parser tells a heading from `*bold*`.
@(private)
heading_level :: proc(line: string) -> int {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	stars := 0
	for i + stars < len(line) && line[i + stars] == '*' {
		stars += 1
	}
	if stars == 0 {
		return 0
	}
	after := i + stars
	if after >= len(line) || (line[after] != ' ' && line[after] != '\t') {
		return 0
	}
	return stars
}

// Where each section starts in the rendered html: the offset of every top-level `<h1`/`<h2`.
//
// A string scan rather than a parse, and it is safe for THIS renderer's output specifically: `render_html`
// emits headings only as children of the body, and its footer nav links are `<a>`s inside `<ul>`s, so no
// `<h1`/`<h2` appears anywhere else. It is not a general-purpose html slicer and does not pretend to be.
@(private)
section_offsets :: proc(html: string, allocator := context.allocator) -> [dynamic]int {
	offsets := make([dynamic]int, 0, 32, allocator)
	body := strings.index(html, "<body")
	from := body < 0 ? 0 : body
	for i := from; i < len(html); i += 1 {
		if html[i] != '<' {
			continue
		}
		for tag in SECTION_TAGS {
			if strings.has_prefix(html[i:], tag) {
				append(&offsets, i)
				break
			}
		}
	}
	return offsets
}

// How many sections the rendered page has. The host says "section 4 of 27" with this, and clamps an index.
section_count :: proc(html: string) -> int {
	offsets := section_offsets(html, context.temp_allocator)
	return len(offsets)
}

/*
The page with only section `index` (plus `window` sections either side) in it.

`index < 0`, or a page with fewer than two sections, hands the html straight back - that is the `full`
button, and a one-section document is already its own slice.

What is kept: everything before the first heading (the head, the stylesheet, the body tag and any preamble),
the chosen run of sections, and the footer nav. What is dropped is the markup of the other sections, so the
engine never lays them out and never pays for them.
*/
slice_sections :: proc(html: string, index: int, window := 0, allocator := context.allocator) -> string {
	if index < 0 {
		return strings.clone(html, allocator)
	}
	offsets := section_offsets(html, context.temp_allocator)
	if len(offsets) < 2 {
		return strings.clone(html, allocator)
	}

	first := clamp(index - window, 0, len(offsets) - 1)
	last := clamp(index + window, first, len(offsets) - 1)
	start := offsets[first]
	end := last + 1 < len(offsets) ? offsets[last + 1] : len(html)

	// The footer, if the page has one, and whatever closes the document after it.
	tail := ""
	if footer := strings.index(html, FOOTER_MARKER); footer >= 0 && footer >= end {
		tail = html[footer:]
	} else if footer < 0 {
		// No footer: keep whatever closes the body, so the result is still a document.
		if close := strings.last_index(html, "</body>"); close >= end {
			tail = html[close:]
		}
	}

	b := strings.builder_make(0, (end - start) + len(tail) + offsets[0] + 64, allocator)
	strings.write_string(&b, html[:offsets[0]])
	strings.write_string(&b, html[start:end])
	strings.write_string(&b, tail)
	return strings.to_string(b)
}

/*
When the whole document is cheap enough to just show.

Measured (`just mem-check`): a rendered page costs roughly 250KB of process memory per KB of html in this
engine, so 17KB of html is a few MB and nobody should be asked to think about it, while 1.18MB is 328MB and
everybody should. Most of this corpus is in the first camp - `2level-preempts.bml` renders to 17KB,
`carding.bml` to 36KB - and slicing those was a nuisance with no saving behind it: the first section of a
chapter is often just its heading, so the preview looked empty for no reason.

64KB is where the line sits: about 16MB, which is the same order as the card page nobody complains about,
and it puts every chapter except `nt-bidding` (122KB), `competitive-bidding`, `uncontested-bidding` (316KB)
and the assembled root (1184KB) in the "just show it" camp.
*/
WHOLE_DOCUMENT_MAX :: 64 * 1024

// Is this page small enough to show whole without thinking about it?
fits_whole :: proc(html: string) -> bool {
	return len(html) <= WHOLE_DOCUMENT_MAX
}

/*
The window of sections to show around `index`: at least `min_bytes` of page, and never an empty one.

WHY THIS EXISTS: a section is a heading plus what follows it, and in this corpus the first section of a
chapter is frequently JUST the heading - `* 2HS Weak Openings` immediately followed by `*** 1st/2nd style` -
so a one-section slice of it renders to a title and nothing else. That is what "the preview looks empty"
was. Growing the window forward until there is something to read costs nothing (the sections after it are
the ones a reader would scroll to anyway) and it cannot run off the end, because the last section is the
last thing it can include.
*/
section_window :: proc(html: string, index: int, min_bytes := 2048) -> (first: int, last: int) {
	offsets := section_offsets(html, context.temp_allocator)
	if len(offsets) == 0 {
		return 0, 0
	}
	first = clamp(index, 0, len(offsets) - 1)
	last = first
	for {
		end := last + 1 < len(offsets) ? offsets[last + 1] : len(html)
		if end - offsets[first] >= min_bytes || last + 1 >= len(offsets) {
			return first, last
		}
		last += 1
	}
}

// The page around `index`, grown to hold something worth reading. `index < 0` is the whole document.
slice_around :: proc(html: string, index: int, min_bytes := 2048, allocator := context.allocator) -> string {
	if index < 0 {
		return strings.clone(html, allocator)
	}
	first, last := section_window(html, index, min_bytes)
	return slice_sections(html, first, last - first, allocator)
}

// The placeholder a folded section's body is replaced by. A class of its own so the preview's stylesheet can
// dim it, and the ellipsis is the whole content: it says "there is something here" and costs one box.
FOLD_PLACEHOLDER :: `<div class="wb-folded">…</div>`

/*
The document FOLDED: every heading in place, one section open, the rest of the bodies replaced by `…`.

This is the shape a person asked for after living with the alternative. Slicing to one section made the
preview cheap and took away the thing a preview is for - you could not see where you were, and a chapter
whose first section is just a heading looked empty. Folding keeps the whole OUTLINE (every heading, in order,
with its own anchor) and spends layout only on the section being edited.

What it costs is the outline: two boxes a section, so the assembled 348-section root is ~700 boxes rather
than 33,500 - and the open section on top of that. The rest is the same trick as `slice_sections`, for the
same measured reason: the cut has to happen in the TEXT, because a document is laid out at load and hiding
things afterwards costs MORE than leaving them alone.

`open_index < 0` folds everything - an outline and nothing else, which is a table of contents.
*/
fold_document :: proc(html: string, open_index: int, min_bytes := 2048, allocator := context.allocator) -> string {
	offsets := section_offsets(html, context.temp_allocator)
	if len(offsets) == 0 {
		return strings.clone(html, allocator)
	}

	first, last := -1, -1
	if open_index >= 0 {
		first, last = section_window(html, open_index, min_bytes)
	}

	b := strings.builder_make(0, len(html) / 4 + 1024, allocator)
	strings.write_string(&b, html[:offsets[0]])
	for start, i in offsets {
		end := i + 1 < len(offsets) ? offsets[i + 1] : section_body_end(html)
		heading_end := heading_element_end(html, start, end)
		strings.write_string(&b, html[start:heading_end])
		if i >= first && i <= last {
			strings.write_string(&b, html[heading_end:end])
		} else if strings.trim_space(html[heading_end:end]) != "" {
			// Only where there is something to stand in for: a heading immediately followed by another one
			// gets no placeholder, because there is nothing folded under it.
			strings.write_string(&b, FOLD_PLACEHOLDER)
		}
	}
	/*
	The page's own footer nav is DROPPED when folded, and that is a fix rather than a saving.

	`render_html` ends every page with a "Top" link and a `<ul>` of its `<h1>`s. In a folded document that is
	a duplicate of what the whole view already is - an outline - and it arrives immediately after the last
	section's ellipsis with nothing to separate it, which reads as a stray link at the bottom of the preview
	(reported, on `2diamond-opening.bml`). Unfolded keeps it, because that is the published page.
	*/
	if close := strings.last_index(html, "</body>"); close >= 0 {
		strings.write_string(&b, html[close:])
	}
	return strings.to_string(b)
}

// Where the sections stop and the page's own footer begins.
@(private)
section_body_end :: proc(html: string) -> int {
	if footer := strings.index(html, FOOTER_MARKER); footer >= 0 {
		return footer
	}
	if close := strings.last_index(html, "</body>"); close >= 0 {
		return close
	}
	return len(html)
}

// The end of the heading ELEMENT that opens a section, so its body can be told apart from it.
@(private)
heading_element_end :: proc(html: string, start: int, limit: int) -> int {
	for tag in ([]string{"</h1>", "</h2>", "</h3>"}) {
		if at := strings.index(html[start:limit], tag); at >= 0 {
			return start + at + len(tag)
		}
	}
	return start
}
