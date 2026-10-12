#+build !js
// The player's REFERENCE side, for `check.mjs`: `native <count> <seed> <out-dir>` writes a card page the way
// the generator does (a random table every board), plus the same page with the card-combination analysis, the
// same again with the double-dummy par caption too (`--par`: DDS, which the player does not have), and
// each page's link fragment READ BACK OUT OF THE PAGE (`share.boards_from_page`), as the workbench's `share`
// does. The wasm player must turn each fragment back into its page, byte for byte.
package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "norn:combo"
import "norn:norn"
import "../deal_solve"
import "../share"

main :: proc() {
	// `native --link <page.html>`: the link fragment for a page already written, as the workbench's `share
	// link` makes it - for a page from anywhere (the analysed advisor's, say), and for checking the page's own
	// Share button against it.
	if len(os.args) == 3 && os.args[1] == "--link" {
		data, err := os.read_entire_file_from_path(os.args[2], context.allocator)
		if err != nil {
			fmt.eprintln("could not read", os.args[2])
			os.exit(1)
		}
		page := string(data)
		title, boards, ok := share.boards_from_page(page)
		if !ok {
			fmt.eprintln("no boards in", os.args[2])
			os.exit(1)
		}
		fmt.println(share.encode({title = title, analyse = strings.contains(page, `<div class="combo"`), boards = boards}))
		return
	}
	if len(os.args) != 4 {
		fmt.eprintln("usage: native <count> <seed> <out-dir> | native --link <page.html>")
		os.exit(2)
	}
	count, _ := strconv.parse_int(os.args[1])
	seed, _ := strconv.parse_u64(os.args[2])
	dir := os.args[3]
	deal_solve.init()

	Kind :: enum {
		Plain,
		Analysed,
		Par,
	}
	for kind in Kind {
		analyse := kind != .Plain
		state := rand.create(seed)
		context.random_generator = rand.default_random_generator(&state)
		b := strings.builder_make()
		norn.render_page_prologue(&b, .Html_Cards, "Shared deals")
		for _ in 0 ..< count {
			deal := norn.deal_hands()
			norn.render_deal_html_cards(&b, deal, randomize_table = true)
			if kind == .Par {
				deal_solve.annotate(&b, deal, .Html_Cards)
			}
			if analyse {
				combo.annotate(&b, deal, .Html_Cards)
			}
			strings.write_byte(&b, '\n')
		}
		norn.render_page_epilogue(&b, .Html_Cards)
		page := strings.to_string(b)

		title, boards, ok := share.boards_from_page(page)
		if !ok {
			fmt.eprintln("the page's boards could not be read back")
			os.exit(1)
		}
		fragment := share.encode({title = title, analyse = analyse, boards = boards})
		names := [Kind]string {
			.Plain    = "plain",
			.Analysed = "analysed",
			.Par      = "par",
		}
		name := names[kind]
		err1 := os.write_entire_file(fmt.tprintf("%s/%s.html", dir, name), b.buf[:])
		err2 := os.write_entire_file(fmt.tprintf("%s/%s.txt", dir, name), transmute([]u8)fragment)
		if err1 != nil || err2 != nil {
			fmt.eprintln("could not write to", dir)
			os.exit(1)
		}
		fmt.printfln("%s: %d boards, page %d bytes, link fragment %d characters", name, len(boards), len(page), len(fragment))
	}
	combo.shutdown()
}
