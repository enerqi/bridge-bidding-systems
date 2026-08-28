package preview

import "core:fmt"
import "core:strings"
import "core:testing"

/*
The section window, tested without an engine.

Both halves are string work on purpose - the caret's section is counted in the SOURCE, the slice is cut from
the RENDERED html - so all of it is testable here rather than through a document in a view. What has to hold
is that the two counts agree: the nth heading in the buffer is the nth section of the page, or the preview
shows the wrong part of the document.
*/

@(private = "file")
SOURCE :: `#+TITLE: Notes

* One

prose under one

** One A

1C = strong

*** One A i

1D = negative

* Two

prose under two
`

// The page those headings render to, in the renderer's own shape (head, body, sections, footer nav).
@(private = "file")
PAGE :: `<html><head><title>Notes</title></head><body class="content"><h1 id="One">One</h1><p>prose under one</p><h2 id="One_A">One A</h2><div class="bidtable">1C</div><h3 id="One_A_i">One A i</h3><div class="bidtable">1D</div><h1 id="Two">Two</h1><p>prose under two</p><a class="top-link" href="#">Top</a><div class="nav-links"><ul><li><a href="#One">One</a></li></ul></div></body></html>`

@(test)
test_a_row_maps_to_the_section_it_is_in :: proc(t: ^testing.T) {
	// Row 0 is `#+TITLE`, before any heading: section 0, the same as the first heading's own section.
	testing.expect_value(t, section_of_row(SOURCE, 0), 0)
	testing.expect_value(t, section_of_row(SOURCE, 2), 0) // `* One`
	testing.expect_value(t, section_of_row(SOURCE, 4), 0) // its prose
	testing.expect_value(t, section_of_row(SOURCE, 6), 1) // `** One A`
	testing.expect_value(t, section_of_row(SOURCE, 8), 1)
	testing.expect_value(t, section_of_row(SOURCE, 10), 2) // `*** One A i`
	testing.expect_value(t, section_of_row(SOURCE, 14), 3) // `* Two`
	testing.expect_value(t, section_of_row(SOURCE, 16), 3)
	// Past the end answers the last section rather than running off.
	testing.expect_value(t, section_of_row(SOURCE, 9999), 3)
}

@(test)
test_the_source_and_the_page_agree_on_how_many_sections :: proc(t: ^testing.T) {
	// THE invariant: the count from the buffer and the count from the html have to be the same, or an index
	// taken from the caret means something else to the slicer.
	testing.expect_value(t, section_count(PAGE), 4)
	testing.expect_value(t, section_of_row(SOURCE, 9999) + 1, section_count(PAGE))
}

@(test)
test_a_deeper_heading_does_not_start_a_section :: proc(t: ^testing.T) {
	// `****` (h4) stays inside its section: a slice of one bid table has no context around it.
	source := "* One\n\n**** Deep\n\n1C = strong\n"
	testing.expect_value(t, section_of_row(source, 2), 0)
	testing.expect_value(t, section_of_row(source, 4), 0)
}

@(test)
test_a_bold_line_is_not_a_heading :: proc(t: ^testing.T) {
	// `*bold*` opens with a star and is not a heading; the marker needs whitespace after it.
	source := "* One\n\n*emphasised* prose\n\n* Two\n"
	testing.expect_value(t, section_of_row(source, 2), 0)
	testing.expect_value(t, section_of_row(source, 4), 1)
}

@(test)
test_a_slice_keeps_the_head_one_section_and_the_footer :: proc(t: ^testing.T) {
	one := slice_sections(PAGE, 1, 0, context.temp_allocator)

	// The head and the body tag: without them the result is not a document and the stylesheet is gone.
	testing.expect(t, strings.contains(one, "<title>Notes</title>"), "the head must survive")
	testing.expect(t, strings.contains(one, `<body class="content">`), "the body tag must survive")
	// The section asked for, and NOT its neighbours.
	testing.expect(t, strings.contains(one, `id="One_A"`), "the chosen section must be there")
	testing.expect(t, !strings.contains(one, `id="One"`) || strings.contains(one, `id="One_A"`), "")
	testing.expect(t, !strings.contains(one, "prose under one"), "the previous section must be gone")
	testing.expect(t, !strings.contains(one, "prose under two"), "the following section must be gone")
	testing.expect(t, !strings.contains(one, `id="One_A_i"`), "the next section must be gone")
	// The footer nav: it is how a reader sees what else the document holds.
	testing.expect(t, strings.contains(one, "nav-links"), "the footer nav must survive")
	testing.expect(t, strings.contains(one, "</body></html>"), "the document must still close")

	// And the point of the exercise: it is much smaller.
	testing.expect(t, len(one) < len(PAGE), "a slice must be smaller than the page")
}

@(test)
test_a_window_widens_the_slice :: proc(t: ^testing.T) {
	narrow := slice_sections(PAGE, 1, 0, context.temp_allocator)
	wide := slice_sections(PAGE, 1, 1, context.temp_allocator)
	testing.expect(t, len(wide) > len(narrow), "a window of one either side must include more")
	testing.expect(t, strings.contains(wide, "prose under one"), "the section before should be included")
	testing.expect(t, strings.contains(wide, `id="One_A_i"`), "the section after should be included")
}

@(test)
test_a_negative_index_is_the_whole_document :: proc(t: ^testing.T) {
	// This is the `full` button, and it must be the page itself rather than a reconstruction of it.
	testing.expect_value(t, slice_sections(PAGE, -1, 0, context.temp_allocator), PAGE)
}

@(test)
test_an_index_past_the_end_is_clamped :: proc(t: ^testing.T) {
	// The caret can be past the last heading of a document whose page has fewer sections than the buffer
	// suggests (an `#INCLUDE` that could not be read, say). Clamping shows the last section instead of
	// producing an empty page.
	last := slice_sections(PAGE, 99, 0, context.temp_allocator)
	testing.expect(t, strings.contains(last, "prose under two"), "the last section is what a clamp gives")
	testing.expect(t, len(last) < len(PAGE), "and it is still a slice")
}

@(test)
test_a_page_with_no_headings_is_handed_back :: proc(t: ^testing.T) {
	page := `<html><head></head><body><p>just prose</p></body></html>`
	testing.expect_value(t, slice_sections(page, 0, 0, context.temp_allocator), page)
	testing.expect_value(t, section_count(page), 0)
}

// ---- the adaptive default and the grown window ----------------------------------------------------

@(test)
test_a_small_page_is_shown_whole :: proc(t: ^testing.T) {
	// The rule that fixed the complaint: a chapter that renders to a few KB costs a few MB whole, so nobody
	// should be asked to think about sections for it. The line is `WHOLE_DOCUMENT_MAX`.
	testing.expect(t, fits_whole(PAGE), "a tiny page should be shown whole")
	big := strings.repeat("<p>prose</p>", (WHOLE_DOCUMENT_MAX / 12) + 64, context.temp_allocator)
	testing.expect(t, !fits_whole(big), "a page past the threshold should not be")
}

@(test)
test_the_window_grows_until_there_is_something_to_read :: proc(t: ^testing.T) {
	// THE BUG THIS FIXES: in this corpus a chapter often opens `* Heading` immediately followed by
	// `*** Sub heading`, so a one-section slice of it is a title and nothing else - which is what "the
	// preview looks empty" was. The window grows FORWARD instead.
	first, last := section_window(PAGE, 0, 2048)
	testing.expect_value(t, first, 0)
	testing.expect(t, last > first, "a section with nothing in it should pull in the next one")

	// It cannot run off the end: the last section is the last thing it can include.
	last_first, last_last := section_window(PAGE, 3, 2048)
	testing.expect_value(t, last_first, 3)
	testing.expect_value(t, last_last, 3)

	// And a section that already holds enough is left alone.
	fat := strings.concatenate(
		{
			`<html><body><h1 id="A">A</h1><p>`,
			strings.repeat("x", 4096, context.temp_allocator),
			`</p><h1 id="B">B</h1><p>b</p></body></html>`,
		},
		context.temp_allocator,
	)
	fat_first, fat_last := section_window(fat, 0, 2048)
	testing.expect_value(t, fat_first, 0)
	testing.expect_value(t, fat_last, 0)
}

@(test)
test_slice_around_is_the_whole_document_for_a_negative_index :: proc(t: ^testing.T) {
	testing.expect_value(t, slice_around(PAGE, -1, 2048, context.temp_allocator), PAGE)
}

// ---- folding ---------------------------------------------------------------------------------------

@(test)
test_a_folded_document_keeps_every_heading :: proc(t: ^testing.T) {
	// The point of folding rather than slicing: the OUTLINE survives, so a preview still tells you where you
	// are in the document. Every heading, and the anchors that make the nav work.
	folded := fold_document(PAGE, 1, 2048, context.temp_allocator)
	for anchor in ([]string{`id="One"`, `id="One_A"`, `id="One_A_i"`, `id="Two"`}) {
		testing.expectf(t, strings.contains(folded, anchor), "the outline lost %s", anchor)
	}
	// The footer nav is NOT kept - see `test_a_folded_page_drops_the_footer_nav`; the headings above are the
	// outline it would have duplicated.
	testing.expect(t, strings.contains(folded, "</body></html>"), "the document must still close")
}

@(test)
test_a_folded_document_shows_the_open_section_and_ellipses_for_the_rest :: proc(t: ^testing.T) {
	// Section 0 is `One` + "prose under one"; folding with section 3 open should keep `Two`'s body and stand
	// the others down to a placeholder.
	folded := fold_document(PAGE, 3, 0, context.temp_allocator)
	testing.expect(t, strings.contains(folded, "prose under two"), "the open section's body must be there")
	testing.expect(t, !strings.contains(folded, "prose under one"), "a folded section's body must not be")
	testing.expect(t, strings.contains(folded, FOLD_PLACEHOLDER), "a folded section needs its placeholder")

	// The saving is measured on a page with real bodies in it: on `PAGE`, whose sections are a line each, a
	// 32-byte placeholder is bigger than the 26 bytes it stands in for - which is honest, and is why the
	// application only folds documents past `WHOLE_DOCUMENT_MAX`.
	fat := strings.builder_make(context.temp_allocator)
	strings.write_string(&fat, "<html><body>")
	for i in 0 ..< 20 {
		fmt.sbprintf(&fat, `<h1 id="s%d">S%d</h1><p>`, i, i)
		strings.write_string(&fat, strings.repeat("x", 2000, context.temp_allocator))
		strings.write_string(&fat, "</p>")
	}
	strings.write_string(&fat, `<a class="top-link" href="#">Top</a></body></html>`)
	page := strings.to_string(fat)
	one_open := fold_document(page, 0, 0, context.temp_allocator)
	testing.expect(t, len(one_open) < len(page) / 4, "folding a real page should cut it to a fraction")
}

@(test)
test_folding_everything_is_an_outline :: proc(t: ^testing.T) {
	// `open_index < 0` is the table of contents: headings, placeholders, no bodies at all.
	outline := fold_document(PAGE, -1, 0, context.temp_allocator)
	testing.expect(t, !strings.contains(outline, "prose under one"), "no body should survive")
	testing.expect(t, !strings.contains(outline, "prose under two"), "no body should survive")
	testing.expect(t, strings.contains(outline, `id="Two"`), "but every heading should")
}

@(test)
test_a_heading_with_nothing_under_it_gets_no_placeholder :: proc(t: ^testing.T) {
	// `* Weak Openings` immediately followed by `*** 1st/2nd style` is the corpus's own shape. An ellipsis
	// under the first would be standing in for nothing.
	page := `<html><body><h1 id="A">A</h1><h3 id="B">B</h3><p>body</p></body></html>`
	outline := fold_document(page, -1, 0, context.temp_allocator)
	testing.expect_value(t, strings.count(outline, FOLD_PLACEHOLDER), 1)
}

@(test)
test_a_folded_page_drops_the_footer_nav :: proc(t: ^testing.T) {
	// The reported oddity: a folded preview ended with a stray bullet link. That is the page's own footer nav
	// - a duplicate of the outline the folded view already is - arriving straight after an ellipsis.
	folded := fold_document(PAGE, 1, 0, context.temp_allocator)
	testing.expect(t, !strings.contains(folded, "nav-links"), "the footer nav duplicates a folded outline")
	testing.expect(t, !strings.contains(folded, "top-link"), "and so does its Top link")
	testing.expect(t, strings.contains(folded, "</body></html>"), "the document must still close")

	// Unfolded is the published page, nav and all.
	testing.expect(t, strings.contains(slice_sections(PAGE, -1, 0, context.temp_allocator), "nav-links"), "")
}
