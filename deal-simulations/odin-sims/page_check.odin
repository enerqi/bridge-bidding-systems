package main

/*
	page_check — does the norn card page still lay out inside Sciter?

	  just page-check             # renders a deal, loads the page, asserts the numbers; exit 1 on failure
	  just page-check -unported   # the same page with the override block CUT OUT, with the checks inverted

	A `-file` program like `sim.odin`, `analyse_deal.odin` and `workbench.odin`, and the automated half of
	the desktop workbench's stage 2. The workbench hosts the interactive card page in a `<frame>`, and that
	page is a BROWSER page: it lays out in Sciter only because of the `@media sciter { ... }` override block
	in `norn/html_cards_header.html.tmpl` plus the small JS shims in the footer template. Both are silent
	when they break — an unported page does not fail to load, it lays out WRONG (hands 950px tall, a board
	70px wide), which is exactly the kind of regression a card-page edit in norn can cause without anyone
	touching this repository.

	So this renders the page the way the workbench does (`analyse.builder_page_sink` — in memory, no file),
	loads it into a WINDOWLESS engine view with the `sciter` media var set, and asserts measured facts about
	the result: the board's box, the trick slider being a real slider, and — after pressing CCA — the
	overlay panel actually becoming visible, which is the JS `hidden`-attribute shim. No display needed.

	`-unported` is this check checking ITSELF: the same page with the `@media sciter` block CUT OUT has to
	FAIL every layout assertion. A threshold nothing can violate is not a test, and this is the cheapest way
	to keep the numbers honest as the card page grows.

	One measured surprise worth knowing, because it makes the port more robust than the plan assumed: the
	overrides apply in this engine WITHOUT the `sciter` media var being set at all — an unknown bare media
	name matches here rather than being skipped (`-unported` is how that was found: dropping the var changed
	nothing, dropping the block changed everything). The workbench sets the var anyway, so the page's intent
	is explicit and a stricter engine would still match, and a BROWSER still ignores the whole block because
	an unknown media TYPE never matches there — measured on the published page, whose computed styles are
	unchanged by all of this.

	WHY THIS IS A PROGRAM AND NOT A TEST in `test-workbench`: loading this page into the engine from an Odin
	TEST-RUNNER thread crashes inside the engine, every route in (frame or view, memory or file, script cut
	out or not), while the identical calls on a program's MAIN thread — here, and in the workbench itself —
	are fine. The thread is the difference, not the page. `test-workbench` covers the host seam with a small
	document; the layout of the real page is checked here.
*/

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "analyse"
import "norn:combo"
import sciter "sciter:."
import sa "sciter:sciter_app"
import "suit_book"

// A two-hand board: declarer + dummy, defenders unknown. No `--sample`, so no solver and no DDS lifecycle
// — the page still carries the compass, the combo blob and the whole CCA overlay, which is every part of
// the layout the port had to fix.
CHECK_DEAL :: `[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`

// SIX boards, for the carousel, and the count matters twice. A one-board page cannot show the centring bug
// that shipped once (the offsets the move reads must not include the previous move, or each step compounds
// the last and by board 6 the active board is off screen). And three boards would all stay in the layout:
// the page parks the boards outside a small window (`LAYOUT_WINDOW`) to keep resizing cheap, so it takes six
// for parking — and the layout-shift compensation that goes with it — to run at all.
CHECK_DEALS_MULTI :: `[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]` +
	`[Deal "N:KQ97.KJ3.KQ2.QJ4 - A8532.A4.J43.K76 -"]` +
	`[Deal "N:T98.QJT9.AKQ.AKQ - AJ2.K87.J65.J432 -"]` +
	`[Deal "N:A5432.AKQ.A2.A32 - KQ76.J54.KQ3.K54 -"]` +
	`[Deal "N:KQJT.AK32.QJ4.A2 - A987.QJ4.K32.K43 -"]` +
	`[Deal "N:AKQ2.KQ3.AJT.QJ3 - J543.A42.K32.AK2 -"]`

// The view is sized like a modest window rather than a big monitor: the overrides have to work at the size
// someone actually runs the workbench at.
VIEW_WIDTH :: 1280
VIEW_HEIGHT :: 900

// The thresholds. Generous on purpose — this is a "did the stylesheet apply at all" check, not a pixel
// snapshot, and the two failure modes it names are an order of magnitude away from the passing numbers
// (measured on 6.0.4.9 at this view size: a ported board is ~400x560, an unported one 71x835).
MIN_BOARD_WIDTH :: 200
MAX_BOARD_HEIGHT :: 700

// The line the override block opens with, tabs and all: the anchor both the presence check and the
// `-unported` cut use.
OVERRIDES_AT :: "		@media sciter {"

g_failures: int

main :: proc() {
	// `-unported`: cut the override block out of the page and expect it to collapse. The layout checks then
	// assert the OPPOSITE, which is what proves they have teeth.
	styled := true
	for arg in os.args[1:] {
		if arg == "-unported" {
			styled = false
		}
	}

	combo.set_suit_book(suit_book.provider())
	defer combo.shutdown()

	page, page_ok := render_page(CHECK_DEAL)
	if !page_ok {
		os.exit(1)
	}
	defer delete(page)
	fmt.printfln("rendered the card page in memory: %d bytes", len(page))

	if !styled {
		cut, cut_ok := without_overrides(page)
		if !cut_ok {
			fmt.eprintln("could not find the `@media sciter` block to cut; has the template changed?")
			os.exit(1)
		}
		delete(page)
		page = cut
		fmt.printfln("-unported: the override block is CUT OUT (%d bytes); the checks below are inverted", len(page))
	}

	// Cheap checks first, and they do not need the engine: the port's two halves have to BE in the page.
	// The block's own LINE (tabs included), not the words "@media sciter" and not a declaration from inside
	// it: both of those also appear in the template's comments, which is the false positive this check is
	// here to avoid — it cost a confusing failure of the `-unported` control.
	check(strings.contains(page, OVERRIDES_AT) == styled, "the page carries the `@media sciter` overrides")
	check(strings.contains(page, "function setHidden"), "the page carries the desktop JS shims")

	// AN INLINE `<style>` IS CAPPED AT 32 KiB in this engine, and an oversized block is dropped ENTIRE — not
	// truncated at the cap. Bisected twice: 32741 bytes applies, 32769 applies NOTHING, its first rule
	// included. No warning, no error, and the diagnostics go quiet for that sheet because the parser abandons
	// it. It cost a session's worth of confusion when one added COMMENT tipped the card page's ~32.6 KB sheet
	// over the line — and what went was the whole stylesheet, which is why the symptom (hands the full width
	// of the window) looked like the desktop overrides alone had been lost.
	//
	// The cap is PER `<style>` ELEMENT, so norn's `render_page_prologue` both strips comments and splits an
	// oversized sheet across several blocks. This is the tripwire for every block it emits: one of them over
	// the cap is a page that looks wrong for a reason nothing else reports.
	STYLE_CAP :: 32 * 1024
	style_blocks := 0
	biggest_style := 0
	rest := page
	for {
		open := strings.index(rest, "<style>")
		if open < 0 {
			break
		}
		rest = rest[open + len("<style>"):]
		close := strings.index(rest, "</style>")
		if close < 0 {
			break
		}
		style_blocks += 1
		biggest_style = max(biggest_style, close)
		rest = rest[close:]
	}
	check(
		style_blocks > 0 && biggest_style < STYLE_CAP,
		fmt.tprintf(
			"%d <style> block(s), the largest %d bytes, under the engine's %d cap (%d spare)",
			style_blocks,
			biggest_style,
			STYLE_CAP,
			STYLE_CAP - biggest_style,
		),
	)

	if styled {
		// Anchored on the blocks' own lines, indentation included: both queries are NAMED in the template's
		// comments, and a bare substring search finds those instead (it has produced a false failure of this
		// very check).
		sciter_at := strings.index(page, OVERRIDES_AT)
		phone_at := strings.index(page, "		@media (max-width")
		check(
			sciter_at >= 0 && phone_at > sciter_at,
			"the overrides precede the phone @media (this engine drops everything after it)",
		)
	}

	if !sa.load_engine() {
		os.exit(1)
	}
	if err := sa.init(); err != nil {
		fmt.eprintln("could not initialise the engine:", err)
		os.exit(1)
	}
	defer sa.shutdown()

	view, verr := sa.create_windowless({width = VIEW_WIDTH, height = VIEW_HEIGHT})
	if verr != nil {
		fmt.eprintln("could not create a windowless view:", verr)
		os.exit(1)
	}

	// The flag the whole exercise turns on, exactly as `workbench.odin` sets it.
	on := sa.value_from(true)
	defer sa.value_clear(&on)
	vars: sa.Value
	defer sa.value_clear(&vars)
	sa.value_set(&vars, "sciter", &on)
	if err := sa.set_media_vars(view.window, &vars); err != nil {
		fmt.eprintln("could not set the `sciter` media var:", err)
		os.exit(1)
	}

	// The engine's own diagnostics follow. TWO CSS warnings are expected and correct on every run: the
	// browser-only `:is()` seat-focus rule (repeated expanded inside the `@media sciter` block) and the
	// phone `@media (max-width: 640px)` this engine cannot parse. A THIRD line about the webfont
	// `@font-face` is the page's Open Sans <link>, which `@media sciter` overrides to the platform face.
	if err := sa.load_html(view.window, page, "file://page-check/card-page.html"); err != nil {
		fmt.eprintln("could not load the page:", err)
		os.exit(1)
	}
	pump(&view, 0)

	root, rerr := sa.root(view.window)
	if rerr != nil {
		fmt.eprintln("no root element:", rerr)
		os.exit(1)
	}

	// The page's own script builds the carousel out of the rendered boards, so a missing `.slide` means the
	// script did not run — a different failure from a stylesheet that did not apply, and worth separating.
	_, slide_err := sa.select_first(root, ".slide")
	check(slide_err == nil, "the page's script ran (the carousel has slides)")

	// The board. This is the assertion the CSS port exists for.
	if board, err := sa.select_first(root, ".compass"); err == nil {
		box, _ := sa.location(board, .Border, .Root)
		check(
			(int(box.width) >= MIN_BOARD_WIDTH) == styled,
			fmt.tprintf("the board is %dpx wide (want %s %d: `width: fit-content` resolved)", box.width, ">=" if styled else "<", MIN_BOARD_WIDTH),
		)
		check(
			(int(box.height) <= MAX_BOARD_HEIGHT) == styled,
			fmt.tprintf(
				"the board is %dpx tall (want %s %d: line-heights are in em)",
				box.height,
				"<=" if styled else ">",
				MAX_BOARD_HEIGHT,
			),
		)
	} else {
		check(false, fmt.tprintf("the page has a .compass (%v)", err))
	}

	// West and East sit SIDE BY SIDE. The browser page gets that from `display: grid`; the override turns
	// the mid row into a horizontal flow, and without it the two hands stack and the board doubles in
	// height. Comparing their x is what tells the two apart.
	west, west_err := sa.select_first(root, ".seat-w")
	east, east_err := sa.select_first(root, ".seat-e")
	if west_err == nil && east_err == nil {
		wb, _ := sa.location(west, .Border, .Root)
		eb, _ := sa.location(east, .Border, .Root)
		check(
			(eb.x > wb.x + wb.width / 2) == styled,
			fmt.tprintf(
				"West (x=%d w=%d) and East (x=%d) %s the mid row",
				wb.x,
				wb.width,
				eb.x,
				"share" if styled else "must NOT share",
			),
		)
	} else {
		check(false, "the page has a West and an East hand")
	}

	// The trick-target slider. `<input type=range>` is not a Sciter type at all — the page swaps it for the
	// engine's own `<input type=hslider>` at startup (in the unported run the swap still happens; what the
	// `-unported` cut removes is the CSS, so the control is there but unsized).
	if slider, err := sa.select_first(root, "#nc-cca-target"); err == nil {
		ctl, _ := sa.control_type(slider)
		check(ctl == .SLIDER, fmt.tprintf("the trick-target input is a slider (control_type %v)", ctl))
	} else {
		check(false, fmt.tprintf("the page has a trick-target input (%v)", err))
	}

	// Press CCA. This is the JS half of the port: the script shows the overlay by REMOVING the `hidden`
	// attribute, because assigning `element.hidden` is silent and inert here — with the old code the panel
	// stayed invisible and the button read as broken.
	if toggle, err := sa.select_first(root, "#nc-cca-toggle"); err == nil {
		sa.do_click(toggle)
		pump(&view, 24)
		if panel, perr := sa.select_first(root, ".cca-panel"); perr == nil {
			shown, _ := sa.visible(panel)
			check(shown, "pressing CCA shows the overlay (the `hidden` attribute shim works)")
			box, _ := sa.location(panel, .Border, .Root)
			check(box.width > 100 && box.height > 40, fmt.tprintf("and it has a box (%dx%d)", box.width, box.height))
		} else {
			check(false, fmt.tprintf("the page has a CCA panel (%v)", perr))
		}
		// The trick table itself is built client-side when the panel opens, so its rows are the proof that
		// the overlay's own script path ran to the end.
		rows, _ := sa.select_all(root, ".ct tr", context.temp_allocator)
		check(len(rows) > 0, fmt.tprintf("the trick table has %d rows", len(rows)))
		check_the_panel_contains_its_own_table(root)
		if styled {
			// The slider's own appearance is all `@media sciter` work — the native control, its track wrapper
			// and the knob's dressing. In the `-unported` control the CSS is cut, so these have nothing to
			// measure and are skipped rather than written to invert (same rule as the window-bug checks).
			check_the_slider_paints_the_box_it_claims(&view, root)
			// Pinned-right is the coil in that same block, so this is a styled-run check too.
			check_the_trick_target_row(root)
		}
	} else {
		check(false, fmt.tprintf("the page has a CCA button (%v)", err))
	}

	// The rest are the bugs the first cut of the port SHIPPED, each one found by looking at the real window
	// and each one measured back here. They are checked only in the styled run: unlike the four thresholds
	// above they are not written to invert, so `-unported` skips them.
	if styled {
		// Before `check_the_window_bugs`: that one focuses a hand, and a focused hand is sized by a
		// different rule (`4vh`) than the board's ordinary cards.
		check_the_card_size_tracks_the_window(&view, root)
		check_the_window_bugs(&view, root)
		check_the_carousel(&view)
		check_a_single_board_is_centred(&view)
		check_the_page_follows_the_view_size(&view)
		check_the_panel_parks_clear_of_the_board(&view)
	}

	if g_failures > 0 {
		fmt.printfln("\nFAIL: %d check%s failed", g_failures, "" if g_failures == 1 else "s")
		os.exit(1)
	}
	if styled {
		fmt.println("\nPASS: the card page lays out in Sciter")
	} else {
		fmt.println("\nPASS: with the override block cut out the page collapses, so those checks have teeth")
	}
}


// The six real-window regressions, in the order they were found. Each is a one-line consequence of
// something this engine does differently, and each was invisible to every earlier test.
check_the_window_bugs :: proc(view: ^sa.Windowless_View, root: sa.Element) {
	// 1. THE BOARD IS CENTRED — asserted in PIXELS, because the carousel moves the track with a paint-time
	//    `transform` and the layout box does not move with it. This engine ignores `translateX()` and
	//    ignores an assignment to `style.transform`; get either wrong and every board paints flush left
	//    with a window's worth of empty space beside it, which is exactly what shipped once.
	painted_centred(view, root, "one board")

	// 2. THE SEAT PILL HUGS ITS LETTER. `display: inline-block` is reported and then behaves as a block,
	//    so the "W" pill spanned the whole hand.
	seat, seat_err := sa.select_first(root, ".seat-n")
	pill, pill_err := sa.select_first(root, ".seat-n .lbl")
	if seat_err == nil && pill_err == nil {
		sb, _ := sa.location(seat, .Border, .Root)
		pb, _ := sa.location(pill, .Border, .Root)
		check(
			pb.width * 2 < sb.width,
			fmt.tprintf("the seat pill hugs its letter (%dpx inside a %dpx card)", pb.width, sb.width),
		)
	}

	// 3. THE OVERLAY PANEL STAYS INSIDE THE WINDOW. With the opponent-length grid open it outgrew the frame
	//    and the trick-target row was cut off the bottom, because `overflow: auto` does not cap anything
	//    here; `max-height` + `scroll-indicator` does.
	if btn, err := sa.select_first(root, "#nc-cca-opp-btn"); err == nil {
		sa.do_click(btn)
		pump(view, 48)
	}
	panel, panel_err := sa.select_first(root, ".cca-panel")
	if panel_err == nil {
		pb, _ := sa.location(panel, .Border, .Root)
		check(
			int(pb.y + pb.height) <= VIEW_HEIGHT,
			fmt.tprintf("the panel fits the window with the opponent grid open (bottom at %d of %d)", pb.y + pb.height, VIEW_HEIGHT),
		)
		// And the trick-target row is inside it, which is the part that went missing.
		if foot, err := sa.select_first(root, ".cca-foot"); err == nil {
			fb, _ := sa.location(foot, .Border, .Root)
			check(
				fb.y >= pb.y && int(fb.y + fb.height) <= int(pb.y + pb.height) + 2,
				fmt.tprintf("the trick-target row is inside the panel (row %d..%d, panel %d..%d)", fb.y, fb.y + fb.height, pb.y, pb.y + pb.height),
			)
		}
	}

	// 4. THE HELP CARD IS A CARD. The browser's full-screen backdrop is out-of-flow with a percentage
	//    height (1px tall here) and its flex centring left the card measuring one line, so pressing `?`
	//    produced a thin white strip with the text spilling out of it.
	if btn, err := sa.select_first(root, ".cca-head .help"); err == nil {
		sa.do_click(btn)
		pump(view, 64)
		if card, cerr := sa.select_first(root, ".cca-help-card"); cerr == nil {
			cb, _ := sa.location(card, .Border, .Root)
			check(cb.height > 200, fmt.tprintf("the help card has a real box (%dx%d)", cb.width, cb.height))
			check(
				int(cb.y + cb.height) <= VIEW_HEIGHT,
				fmt.tprintf("and it fits the window (bottom at %d of %d)", cb.y + cb.height, VIEW_HEIGHT),
			)
			// Its close button is absolutely positioned, and an inline-level widget out of flow lays out
			// 1x1 here — measured 0x0, i.e. nothing to click.
			if x, xerr := sa.select_first(card, ".x"); xerr == nil {
				xb, _ := sa.location(x, .Border, .Root)
				check(xb.width > 10 && xb.height > 10, fmt.tprintf("the help card's close button is clickable (%dx%d)", xb.width, xb.height))
			}
		}
	}

	// 5. FOCUSING A HAND RESIZES IT AT ONCE. The `only-<seat>` class raises the hand's font-size, and with a
	//    `transition` pending the engine applied it only at the next restyle — on screen the card grew a
	//    beat late, on the next hover, which read as the click lagging.
	if btn, err := sa.select_first(root, "[data-seat=\"n\"]"); err == nil {
		before, _ := sa.select_first(root, ".seat-n")
		bb, _ := sa.location(before, .Border, .Root)
		sa.do_click(btn)
		pump(view, 80)
		after, _ := sa.select_first(root, ".seat-n")
		ab, _ := sa.location(after, .Border, .Root)
		check(
			ab.height > bb.height,
			fmt.tprintf("focusing North enlarges it immediately (%dpx -> %dpx tall)", bb.height, ab.height),
		)
	}
}
// THE CARDS ARE SIZED OFF THE WINDOW, not pinned to one window's worth. The browser sizes the card text with
// `clamp(1rem, min(2.4vh, 4.3vw), 2.2rem)`, and neither function exists in this engine, so the override
// block carries the viewport-height term on its own (`.seat { font-size: 2.4vh }`). That is only worth
// having if `vh` really resolves in a `font-size` here — it does, and it re-evaluates on a resize, but the
// belief that it does NOT survived a whole session (the computed size came back EMPTY, which was the 32 KiB
// stylesheet cap dropping the block, not the unit). If someone reads that old note and "fixes" the size back
// to a constant, the desktop board silently stops matching the browser's at every window but one.
//
// So: measure the seat at the check's view height, shrink the view, and require the card to have shrunk with
// it — in PROPORTION, which a constant cannot fake. Then put the view back, because the carousel check runs
// on it next. A `min()`/`clamp()` spelling fails this too: measured, `min(2.4vh, 4.3vw)` computes a flat
// 13.33px at every window size.
check_the_card_size_tracks_the_window :: proc(view: ^sa.Windowless_View, root: sa.Element) {
	SHORT_HEIGHT :: 560

	tall := seat_font_px(root)
	if tall <= 0 {
		check(false, "the seat's computed font-size is readable")
		return
	}
	check(
		tall > 15 && tall < 40,
		fmt.tprintf("the card text is %.1fpx in a %dpx-tall view (a plausible card size)", tall, VIEW_HEIGHT),
	)

	if err := sa.resize_windowless(view, VIEW_WIDTH, SHORT_HEIGHT); err != nil {
		check(false, fmt.tprintf("the view resizes (%v)", err))
		return
	}
	pump(view, 192)
	short := seat_font_px(root)

	// The ratio the viewport-height term implies, with room for the engine's rounding. A constant size (the
	// old `1.9rem`) lands at 1.0 and fails; the real ratio is 900/560.
	want := f64(VIEW_HEIGHT) / f64(SHORT_HEIGHT)
	got := short > 0 ? tall / short : 0
	check(
		got > want * 0.9 && got < want * 1.1,
		fmt.tprintf(
			"the card text tracks the window: %.1fpx at %d, %.1fpx at %d (ratio %.2f, want ~%.2f)",
			tall,
			VIEW_HEIGHT,
			short,
			SHORT_HEIGHT,
			got,
			want,
		),
	)

	if err := sa.resize_windowless(view, VIEW_WIDTH, VIEW_HEIGHT); err != nil {
		check(false, fmt.tprintf("the view resizes back (%v)", err))
		return
	}
	pump(view, 256)
	back := seat_font_px(root)
	check(
		back > tall * 0.98 && back < tall * 1.02,
		fmt.tprintf("and it comes back on the way up (%.1fpx, was %.1fpx)", back, tall),
	)
}

// The seat's computed `font-size` in pixels, read IN the document — the host's `location` gives boxes and no
// styles. This engine returns a bare number rather than a `10px` string, so a plain float parse does; a
// spelling it rejects yields "" and a `calc()` yields the literal `calc(...)` (which is why the override uses
// a plain unit), and both parse to 0, which the caller reports as a failure.
@(private = "file")
seat_font_px :: proc(root: sa.Element) -> f64 {
	res, err := sa.eval_element(root, `(function () {
		var el = document.querySelector('.slide.active .seat-n') || document.querySelector('.seat-n');
		if (!el) { return ''; }
		return '' + getComputedStyle(el).fontSize;
	})()`)
	if err != nil {
		return 0
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res)
	px, _ := strconv.parse_f64(strings.trim_suffix(strings.trim_space(text), "px"))
	return px
}

// The carousel, on a page with more than one board: every step must leave the ACTIVE board centred. This
// loads a second page into the same view — the checks above are done with the first one by now.
check_the_carousel :: proc(view: ^sa.Windowless_View) {
	page, ok := render_page(CHECK_DEALS_MULTI)
	if !ok {
		check(false, "a multi-board page renders")
		return
	}
	defer delete(page)

	if err := sa.load_html(view.window, page, "file://page-check/carousel.html"); err != nil {
		check(false, fmt.tprintf("the multi-board page loads (%v)", err))
		return
	}
	pump(view, 128)
	root, rerr := sa.root(view.window)
	if rerr != nil {
		check(false, "the multi-board page has a root")
		return
	}

	slides, serr := sa.select_all(root, ".slide", context.temp_allocator)
	check(serr == nil && len(slides) > 1, fmt.tprintf("the carousel has several boards (%d)", len(slides)))
	if len(slides) < 2 {
		return
	}

	// The carousel MOVES BY SCROLLING now, and that is a number the page can be asked about — the only reason
	// this file samples felt pixels is that the previous carousel moved the track with a paint-time `transform`
	// which no geometry API reports. So ask the cheap exact question first; the pixel checks below stay,
	// because they prove what was PAINTED rather than what the page believes.
	off_centre := scroll_off_centre(root)
	check(
		off_centre >= 0 && off_centre <= 2,
		fmt.tprintf("the active board's middle is on the viewport's middle (off by %d px)", off_centre),
	)

	// Board 1, then each press of "next". The tolerance is a tenth of the view; the compounding bug this
	// guards against missed by half a screen and more. Two pumps per step: the move is a transition, so the
	// board is still travelling for the first ~350ms of engine time.
	painted_centred(view, root, "board 1")
	next, next_err := sa.select_first(root, "#nc-next")
	if next_err != nil {
		check(false, "the carousel has a next button")
		return
	}
	for step in 1 ..< len(slides) {
		sa.do_click(next)
		pump(view, 160 + step * 64)
		pump(view, 192 + step * 64)
		painted_centred(view, root, fmt.tprintf("board %d after next", step + 1))
	}

	// FAST SCROLLING: several steps with no frames in between, which is what a spun wheel or a held key
	// delivers. Each step starts a tween, and an earlier tween still writing its own older positions is what
	// left the centre board painted LEFT of centre — the last writer won and it was the stale one. So this
	// clicks back to the first board without pumping, then lets it settle and asks where the board is.
	for _ in 1 ..< len(slides) {
		if prev, err := sa.select_first(root, "#nc-prev"); err == nil {
			sa.do_click(prev)
		}
	}
	pump(view, 400)
	pump(view, 432)
	pump(view, 464)
	painted_centred(view, root, fmt.tprintf("board 1 after %d unpumped steps", len(slides) - 1))

	// A HELD ARROW: steps arriving with a FRAME or two between them, so each one lands on a tween that is
	// genuinely mid-flight — which the page answers by snapping instead of re-targeting, because a
	// re-targeted ease-out never catches up and every frame of it repaints five boards of card text.
	//
	// WHAT THIS CAN CHECK IS THE LANDING, NOT THE PACING. A windowless view cannot measure either: this
	// harness's own `paint_windowless` costs ~130ms a frame and throttles the engine's frame clock, so a tween
	// and a snap step through the burst at almost the same simulated rate — measured, the worst mid-burst lag
	// came out 394px with the catch-up and 387px without it, which is a check with no teeth and was deleted
	// rather than kept as false comfort. Frame rate and smoothness are judged in the real window
	// (`just sims workbench-debug`). What IS worth pinning here is that a burst of overlapping steps still
	// ENDS in the right place, whichever path the moves took.
	if fast, err := sa.select_first(root, "#nc-next"); err == nil {
		for step in 1 ..< len(slides) {
			sa.do_click(fast)
			frame(view, 500 + step * 4)
			frame(view, 502 + step * 4)
		}
	}
	pump(view, 560)
	painted_centred(view, root, fmt.tprintf("and it lands on the last board after %d fast steps", len(slides) - 1))

	// Back to the first board, settled, because the arrow-key checks below start from there.
	if prev, err := sa.select_first(root, "#nc-prev"); err == nil {
		for _ in 1 ..< len(slides) {
			sa.do_click(prev)
			pump(view, 600)
		}
	}
	pump(view, 640)

	// THE ARROW KEYS, which are how anyone reads through a set of deals. Two engine facts had to be met for
	// these to work at all, and both were silent:
	//
	//   * a key only reaches a document once something in it holds the FOCUS. Focusing the `<frame>` is not
	//     that; the workbench focuses the framed `<body>` (see `focus_page`).
	//   * the event carries `code`, NOT `key`. A browser fills in both, this engine fills in `code` only, so
	//     the page's `e.key === 'ArrowRight'` never matched and the arrows read as unimplemented.
	//
	// The codes are the engine's own (`KB_RIGHT`/`KB_LEFT` from the SDK's sciter-x-key-codes.h), not Windows
	// virtual keys — sending VK_RIGHT (39) arrives as the `Quote` key, which is its own small trap.
	KB_RIGHT :: 262
	KB_LEFT :: 263
	sa.windowless_focus(view, true)
	if body, err := sa.select_first(root, "body"); err == nil {
		sa.set_focus(body)
	}
	pump(view, 496)

	// A CLICK FIRST, then the arrow — the order anyone actually uses, and the one that broke. The page reads
	// a settled scroll position back so that a wheel, a swipe or a dragged scrollbar can move the carousel,
	// and that reading is gated on a real pointer/wheel/touch event. A click on the page sets that gate, and
	// while it was never cleared our own animated scroll was read back as the user having scrolled: 140ms into
	// the step the nearest board is still the one being LEFT, so the step was undone and the arrow key did
	// nothing. (The race itself cannot be reproduced here — this harness's own painting is slower than the
	// timer, so the settle always lands after the scroll has finished; what IS pinned is that a click does not
	// stop the arrows.)
	sa.windowless_mouse(view, .MOUSE_DOWN, {VIEW_WIDTH / 2, VIEW_HEIGHT / 2})
	sa.windowless_mouse(view, .MOUSE_UP, {VIEW_WIDTH / 2, VIEW_HEIGHT / 2})
	pump(view, 492)

	before := board_number(root)
	sa.windowless_key(view, .DOWN, KB_RIGHT)
	sa.windowless_key(view, .UP, KB_RIGHT)
	pump(view, 528)
	pump(view, 560)
	after := board_number(root)
	check(after == before + 1, fmt.tprintf("the right arrow steps forward (board %d then %d)", before, after))
	painted_centred(view, root, "the board the right arrow moved to")

	sa.windowless_key(view, .DOWN, KB_LEFT)
	sa.windowless_key(view, .UP, KB_LEFT)
	pump(view, 592)
	pump(view, 624)
	back := board_number(root)
	check(back == before, fmt.tprintf("the left arrow steps back (board %d then %d)", after, back))
	painted_centred(view, root, "the board the left arrow moved back to")
}

// The board number the page is showing, straight from the counter it draws.
board_number :: proc(root: sa.Element) -> int {
	element, err := sa.select_first(root, "#nc-idx")
	if err != nil {
		return -1
	}
	text, terr := sa.text(element, context.temp_allocator)
	if terr != nil {
		return -1
	}
	n, ok := strconv.parse_int(strings.trim_space(text))
	if !ok {
		return -1
	}
	return n
}

// The ACTIVE board's green felt (`--felt`, #3f7d5c). The carousel is moved by a paint-time `transform`,
// which a box cannot see — `location` keeps reporting the LAYOUT position — so the only honest way to ask
// "is the active board centred" is to look at the pixels.
//
// Why the felt and not something more obvious, all measured by dumping the row's colours:
//   * the ACTIVE board's felt is the saturated colour; its NEIGHBOURS wash out to ~#ebf1ee, because an
//     inactive slide is `opacity: 0.4` over white. So the saturated green identifies the active board and
//     nothing else on the row.
//   * the selection ring (`box-shadow` in `--sel`) is not painted by this engine at all — nothing on the
//     row matched it, so an earlier version of this check failed for the wrong reason.
//   * the widest RUN of felt measures nothing useful: the row crosses the hands, so the longest green run
//     is the 28px gap between two cards. FIRST and LAST are what bound the board.
FELT_R :: 0x3f
FELT_G :: 0x7d
FELT_B :: 0x5c
FELT_TOLERANCE :: 8 // the felt's own border and antialiasing sit within this of the flat colour

@(private = "file")
near :: proc(value: u8, target: int) -> bool {
	delta := int(value) - target
	return delta >= -FELT_TOLERANCE && delta <= FELT_TOLERANCE
}

// How far the active board's middle is from the viewport's middle, asked OF THE PAGE (the same quantity
// `centreScrollFor` moves by). -1 if it cannot be measured. This is the check the scroll rewrite made
// possible: a scroll offset is readable, a paint-time transform was not.
// The CCA panel has to CONTAIN what it shows. Two-hand advisor pages carry a wider trick table than a
// generated board does, and the panel was sized to the space the placement gave it rather than to its
// content — 587px around a 607px table — with the overflow NOT clipped: the foot row, the trick-target
// slider and its value were painted past the panel's border, the value ending up outside the white box
// entirely (found in the real window, reproduced here at that window's size). `width: max-content` under
// the existing `max-width` is the fix; this asserts the containment rather than the rule.
check_the_panel_contains_its_own_table :: proc(root: sa.Element) {
	res, err := sa.eval_element(root, `(function () {
		var p = document.querySelector('.cca-panel');
		if (!p) { return 'no panel'; }
		var pr = p.getBoundingClientRect();
		var worst = 0, name = '';
		['.ct', '.cca-foot', '.cca-slider', '#nc-cca-target-val'].forEach(function (sel) {
			var e = document.querySelector(sel);
			if (!e) { return; }
			var r = e.getBoundingClientRect();
			var over = Math.round(Math.max(r.right - pr.right, pr.left - r.left));
			if (over > worst) { worst = over; name = sel; }
		});
		return worst + ' ' + name;
	})()`)
	if err != nil {
		check(false, fmt.tprintf("the panel's contents are measurable (%v)", err))
		return
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res, context.temp_allocator)
	fields := strings.fields(text, context.temp_allocator)
	over, ok := 0, false
	if len(fields) > 0 {
		over, ok = strconv.parse_int(fields[0])
	}
	check(
		ok && over <= 0,
		fmt.tprintf(
			"nothing in the CCA panel is painted outside it (worst overhang %s)",
			strings.trim_space(text),
		),
	)
}

// A CONTROL MUST NOT CLAIM MORE THAN IT DRAWS. `<input type=range>` is not a Sciter type (odin-sciter's
// `docs/BEHAVIORS.md`); `behavior: slider` does attach to it, but the widget then paints at its own
// intrinsic size inside whatever box the CSS gave it — measured by sampling the painted row, a 27px control
// in a 147px box. The other 120px stayed live, so a click on what looked like blank panel moved the trick
// target, which is how it was reported from the real window. The page uses the engine's own
// `<input type=hslider>` instead. Pixels rather than geometry, because the geometry was never the thing
// that was wrong.
check_the_slider_paints_the_box_it_claims :: proc(view: ^sa.Windowless_View, root: sa.Element) {
	res, err := sa.eval_element(root, `(function () {
		var s = document.getElementById('nc-cca-target');
		if (!s) { return '0 0 0'; }
		var r = s.getBoundingClientRect();
		return Math.round(r.left) + ' ' + Math.round(r.right) + ' ' + Math.round((r.top + r.bottom) / 2);
	})()`)
	if err != nil {
		check(false, fmt.tprintf("the slider's box is measurable (%v)", err))
		return
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res, context.temp_allocator)
	f := strings.fields(text, context.temp_allocator)
	if len(f) != 3 {
		check(false, fmt.tprintf("the slider's box reads as three numbers (%q)", text))
		return
	}
	left, _ := strconv.parse_int(f[0])
	right, _ := strconv.parse_int(f[1])
	mid, _ := strconv.parse_int(f[2])
	if right - left <= 0 || mid <= 0 || i32(mid) >= VIEW_HEIGHT {
		check(false, fmt.tprintf("the slider has an on-screen box (%d..%d, row %d)", left, right, mid))
		return
	}

	sa.paint_windowless(view)
	first, last := -1, -1
	for x := left; x <= right; x += 1 {
		if i32(x) < 0 || i32(x) >= VIEW_WIDTH {
			continue
		}
		r, g, b, _ := sa.windowless_pixel(view, i32(x), i32(mid))
		if !(r > 245 && g > 245 && b > 245) { 	// anything that is not the panel's white
			if first < 0 {
				first = x
			}
			last = x
		}
	}
	box := right - left
	painted := last - first
	check(
		painted * 100 >= box * 80,
		fmt.tprintf("the slider draws the box it takes clicks in (painted %dpx of %dpx)", painted, box),
	)
	check_the_slider_knob_is_dressed(root)
	check_the_knob_travels_to_both_ends(view, root)
	check_the_slider_does_not_move_with_the_headline(view, root)
	check_the_row_survives_a_second_digit(view, root)
	check_the_header_buttons_stay_put(view, root)
}

// AND THE HEADER'S BUTTONS MUST NOT MOVE EITHER. The summary beside the title is a sentence that grows and
// shrinks with the target ("sure tricks 7, develop 4 for 11" against "(≥ 12 already)"), and in a wrapping
// row a longer one pushed the N/S, IMPs, ≥ and ▾ buttons onto a second line — the same complaint as the
// slider's, one row up: controls moving under the pointer because a number changed. The summary takes the
// leftover width and does not wrap, so it absorbs the change itself.
check_the_header_buttons_stay_put :: proc(view: ^sa.Windowless_View, root: sa.Element) {
	seen: [2][3]int // the side-toggle's left and top, and the header's height
	for value, i in ([]string{"1", "13"}) {
		set := strings.concatenate(
			{`(function () { if (window.ccaSetTarget) { window.ccaSetTarget(`, value, `); } return ''; })()`},
			context.temp_allocator,
		)
		if res, err := sa.eval_element(root, set); err == nil {
			sa.value_clear(&res)
		}
		pump(view, 60)
		pump(view, 120)

		res, err := sa.eval_element(root, `(function () {
			var head = document.querySelector('.cca-head'), side = document.querySelector('.cca-side');
			if (!head || !side) { return '-1 -1 -1'; }
			var hr = head.getBoundingClientRect(), sr = side.getBoundingClientRect();
			return Math.round(sr.left) + ' ' + Math.round(sr.top) + ' ' + Math.round(hr.height);
		})()`)
		if err != nil {
			check(false, fmt.tprintf("the CCA header is measurable (%v)", err))
			return
		}
		defer sa.value_clear(&res)
		text, _ := sa.value_to_string(&res, context.temp_allocator)
		f := strings.fields(text, context.temp_allocator)
		if len(f) != 3 {
			check(false, fmt.tprintf("the header's boxes read as three numbers (%q)", text))
			return
		}
		for part, j in f {
			seen[i][j], _ = strconv.parse_int(part)
		}
	}
	check(
		seen[0] == seen[1],
		fmt.tprintf(
			"the header's buttons stay put as the summary's length changes (side left/top + header height %v then %v)",
			seen[0],
			seen[1],
		),
	)
}

// A SECOND DIGIT MUST NOT RESHAPE THE ROW. Going 9 -> 10 widens the value by a digit, and the row is
// pinned to the right edge and cannot grow, so the label "tricks ≥" wrapped to two lines instead — the
// control changing height under the pointer, mid-drag. The value has a fixed box now (two digits wide)
// and the label does not wrap; this is that, measured at the two values that differ in width.
check_the_row_survives_a_second_digit :: proc(view: ^sa.Windowless_View, root: sa.Element) {
	shape: [2][3]int // left, width, height
	for value, i in ([]string{"9", "10"}) {
		set := strings.concatenate(
			{`(function () { if (window.ccaSetTarget) { window.ccaSetTarget(`, value, `); } return ''; })()`},
			context.temp_allocator,
		)
		if res, err := sa.eval_element(root, set); err == nil {
			sa.value_clear(&res)
		}
		pump(view, 60)
		pump(view, 120)

		res, err := sa.eval_element(root, `(function () {
			var row = document.querySelector('.cca-slider');
			if (!row) { return '-1 -1 -1'; }
			var r = row.getBoundingClientRect();
			return Math.round(r.left) + ' ' + Math.round(r.width) + ' ' + Math.round(r.height);
		})()`)
		if err != nil {
			check(false, fmt.tprintf("the trick-target row is measurable (%v)", err))
			return
		}
		defer sa.value_clear(&res)
		text, _ := sa.value_to_string(&res, context.temp_allocator)
		f := strings.fields(text, context.temp_allocator)
		if len(f) != 3 {
			check(false, fmt.tprintf("the row's box reads as three numbers (%q)", text))
			return
		}
		for part, j in f {
			shape[i][j], _ = strconv.parse_int(part)
		}
	}
	check(
		shape[0] == shape[1],
		fmt.tprintf(
			"the trick-target row is the same shape at 9 and at 10 (left/width/height %v then %v)",
			shape[0],
			shape[1],
		),
	)
}

// AND THE SLIDER MUST NOT SLIDE. The headline to its left is a sentence whose length changes with the
// target ("make 8: DD 92.2% · SD 91.6%" against "(≥ 12 already)"), so a left-packed row moved the whole
// control sideways every time the number changed — the control you are aiming at walking away from the
// pointer. It is pinned to the right edge of the row instead; this is the check that it stays put.
check_the_slider_does_not_move_with_the_headline :: proc(view: ^sa.Windowless_View, root: sa.Element) {
	seen: [2]int
	for value, i in ([]string{"1", "13"}) {
		set := strings.concatenate(
			{`(function () { if (window.ccaSetTarget) { window.ccaSetTarget(`, value, `); } return ''; })()`},
			context.temp_allocator,
		)
		if res, err := sa.eval_element(root, set); err == nil {
			sa.value_clear(&res)
		}
		pump(view, 60)
		pump(view, 120)
		left, _, _, ok := slider_row(root)
		if !ok {
			check(false, "the slider's box is measurable across a target change")
			return
		}
		seen[i] = left
	}
	drift := seen[0] - seen[1]
	if drift < 0 {
		drift = -drift
	}
	check(
		drift <= 1,
		fmt.tprintf("the slider stays put when the headline's length changes (moved %d px: %d then %d)", drift, seen[0], seen[1]),
	)
}

// The engine builds its slider as the input (whose background IS the track) plus one
// `<button class="slider">`, and THAT BUTTON IGNORES AUTHOR CSS — measured down to
// `.cca-slider input[type="hslider"] > button.slider`, which left it the engine's grey 11px dot, while an
// inline style applied at once. Unstyled the pair reads as a black bar with a pale dot parked on it, so the
// script dresses the knob inline. This is the check that the dressing still lands.
check_the_slider_knob_is_dressed :: proc(root: sa.Element) {
	res, err := sa.eval_element(root, `(function () {
		var s = document.getElementById('nc-cca-target');
		var k = s && s.querySelector('.nc-slider-knob');
		if (!k) { return '0 none'; }
		var cs = getComputedStyle(k);
		// background reads back empty even when set (the engine keeps it under its own name), so the size is
		// the honest witness: the engine's own knob is 11px and the page asks for 1.15em.
		return Math.round(parseFloat(cs.width) || 0) + ' ' + cs.backgroundColor;
	})()`)
	if err != nil {
		check(false, fmt.tprintf("the slider's knob is measurable (%v)", err))
		return
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res, context.temp_allocator)
	f := strings.fields(text, context.temp_allocator)
	width := 0
	if len(f) > 0 {
		width, _ = strconv.parse_int(f[0])
	}
	check(
		width >= 12,
		fmt.tprintf("the slider's knob is sized by the page, not left at the engine's 11px (%s)", strings.trim_space(text)),
	)
}

// THE KNOB HAS TO REACH BOTH ENDS OF ITS TRACK, and be drawn where it takes its clicks. Measured across
// the range, the engine walks the knob's LEFT EDGE from 6px inside the track's left edge to 6px past its
// right, so at the top of the range the whole knob sat past the end of the track — over the value beside
// it. Two things do NOT fix it, both measured: padding on the input reserves no room (identical overhang
// for `padding-right`, symmetric padding, `border-box`), and a wrapper drawing a wider track puts the paint
// somewhere other than the hit area, because clicks are mapped onto the INPUT's box. What works is shifting
// the knob's PAINT by half its width plus that 6 — and the shift must be a `transform`, since `margin-left`
// is what the engine itself moves the knob with (setting it froze the knob at one end).
//
// PIXELS, not rects: a transform is invisible to every geometry API in this engine.
check_the_knob_travels_to_both_ends :: proc(view: ^sa.Windowless_View, root: sa.Element) {
	box_left, box_right, row, ok := slider_row(root)
	if !ok {
		check(false, "the slider's box is measurable")
		return
	}

	for spec in ([]struct {
		value: string,
		end:   string,
	}{{"1", "left"}, {"13", "right"}}) {
		// Through the page's own path (`window.ccaSetTarget`), not by assigning `.value`: the knob is drawn by
		// the page, so "set the target" has to mean re-render, exactly as an edit does.
		set := strings.concatenate(
			{`(function () { if (window.ccaSetTarget) { window.ccaSetTarget(`, spec.value, `); } return ''; })()`},
			context.temp_allocator,
		)
		if res, err := sa.eval_element(root, set); err == nil {
			sa.value_clear(&res)
		}
		// The knob moves on the NEXT layout, not on the assignment.
		pump(view, 60)
		pump(view, 120)
		sa.paint_windowless(view)

		first, last := -1, -1
		for x := box_left - 40; x <= box_right + 40; x += 1 {
			if i32(x) < 0 || i32(x) >= VIEW_WIDTH {
				continue
			}
			r, g, b, _ := sa.windowless_pixel(view, i32(x), i32(row))
			if r < 90 && g > 80 && g < 150 && b > 150 { 	// the knob's blue
				if first < 0 {
					first = x
				}
				last = x
			}
		}
		if first < 0 {
			check(false, fmt.tprintf("the knob is painted at the %s end of the track", spec.end))
			continue
		}
		// The track's box, AFTER the change: the panel re-places itself when the header's summary text
		// changes with the target, so the box read before the click is a dozen pixels out of date — which
		// this check reported as the knob missing the end of the track when it was flush against it.
		now_left, now_right, _, box_ok := slider_row(root)
		if !box_ok {
			check(false, "the slider's box is still measurable")
			continue
		}
		want := now_left if spec.end == "left" else now_right
		// The knob's OWN edge against the track's: flush, and inside. (Its MIDDLE on the end of the track is
		// the other arrangement — half the knob hanging off — and that is what this replaced.)
		//
		// What the page accepted is read back rather than assumed: the target is a board's, and a board with
		// fewer tricks in it clamps below the slider's `max`, which lands the knob short of the end quite
		// correctly. Flushness is then only asserted at the end the slider actually reached.
		landed := slider_value(root)
		edge := first if spec.end == "left" else last
		off := edge - want
		if off < 0 {
			off = -off
		}
		inside := first >= now_left - 2 && last <= now_right + 2
		at_the_end := spec.end == "left" || landed == spec.value
		check(
			inside && (off <= 4 || !at_the_end),
			fmt.tprintf(
				"at the %s end the knob is flush INSIDE the track (value %s, painted %d..%d, track %d..%d, off by %d)",
				spec.end,
				landed,
				first,
				last,
				now_left,
				now_right,
				off,
			),
		)
	}
}

// What the slider is actually showing — the page clamps a target to the board, so this is not always what
// was asked for.
slider_value :: proc(root: sa.Element) -> string {
	res, err := sa.eval_element(root, `(function () {
		var s = document.getElementById('nc-cca-target');
		return s ? '' + s.value : '?';
	})()`)
	if err != nil {
		return "?"
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res, context.temp_allocator)
	return strings.trim_space(text)
}

// The slider's box and the row through its middle — the geometry both pixel checks start from.
slider_row :: proc(root: sa.Element) -> (left: int, right: int, row: int, ok: bool) {
	res, err := sa.eval_element(root, `(function () {
		var s = document.getElementById('nc-cca-target');
		if (!s) { return '0 0 0'; }
		var r = s.getBoundingClientRect();
		return Math.round(r.left) + ' ' + Math.round(r.right) + ' ' + Math.round((r.top + r.bottom) / 2);
	})()`)
	if err != nil {
		return 0, 0, 0, false
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res, context.temp_allocator)
	f := strings.fields(text, context.temp_allocator)
	if len(f) != 3 {
		return 0, 0, 0, false
	}
	left, _ = strconv.parse_int(f[0])
	right, _ = strconv.parse_int(f[1])
	row, _ = strconv.parse_int(f[2])
	return left, right, row, right > left && row > 0 && i32(row) < VIEW_HEIGHT
}

// THE TRICK-TARGET ROW: pinned right, clear of the headline. The two constraints pull against each other,
// which is why both are checked. Pinned right is what stops the control walking sideways as the headline's
// sentence changes length with the target; clear of the headline is what the right edge used to cost, back
// when the panel was as wide as its HEADER row (805px around a 663px table, measured in the real window)
// and the slider was left stranded 100px from anything. The panel takes its width from the TABLE now, so
// the right edge of the row and the right edge of the table are the same place.
check_the_trick_target_row :: proc(root: sa.Element) {
	res, err := sa.eval_element(root, `(function () {
		var h = document.querySelector('.ct-head'), s = document.querySelector('.cca-slider');
		var f = document.querySelector('.cca-foot');
		if (!h || !s || !f) { return '-1 -1'; }
		var hr = h.getBoundingClientRect(), sr = s.getBoundingClientRect(), fr = f.getBoundingClientRect();
		if (!(sr.width > 0)) { return '-1 -1'; }
		// how far the row's right edge is from the slider's, and how much clear air is left of the slider
		return Math.round(fr.right - sr.right) + ' ' + Math.round(sr.left - hr.right);
	})()`)
	if err != nil {
		check(false, fmt.tprintf("the trick-target row is measurable (%v)", err))
		return
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res, context.temp_allocator)
	f := strings.fields(text, context.temp_allocator)
	from_right, clearance := -1, -1
	if len(f) == 2 {
		from_right, _ = strconv.parse_int(f[0])
		clearance, _ = strconv.parse_int(f[1])
	}
	check(
		from_right >= 0 && from_right <= 8,
		fmt.tprintf("the trick-target slider is pinned to the right of its row (%d px from the edge)", from_right),
	)
	check(clearance >= 0, fmt.tprintf("and it does not run into the headline (%d px clear)", clearance))
}


// WHERE THE PANEL PARKS. It tries the four corners and takes the one that covers least of what matters —
// the real (not face-down) hands, and the par/combo caption lines that carry the score. In a window with
// room below the board it must therefore cover NOTHING. It used to, because a bottom anchor was then
// "lifted" clear of the caption on a test that read only "is the panel's bottom below the caption's top",
// which is true of a panel entirely BELOW it as well: measured with the caption at y 926..949, the panel
// was dragged from 1073..1391 (the empty space) up to 599..917, against the board, with 400px going spare.
// The caption is scored like everything else now and the lift is gone.
check_the_panel_parks_clear_of_the_board :: proc(view: ^sa.Windowless_View) {
	page, ok := render_page(CHECK_DEAL)
	if !ok {
		check(false, "a page renders for the panel-placement check")
		return
	}
	defer delete(page)

	// TALL on purpose: the question is what the panel does with room to spare. At the ordinary view height
	// the panel cannot dodge the board at all, and a check that cannot fail proves nothing.
	TALL :: 1400
	if err := sa.resize_windowless(view, VIEW_WIDTH, TALL); err != nil {
		check(false, fmt.tprintf("the view resizes tall (%v)", err))
		return
	}
	if err := sa.load_html(view.window, page, "file://page-check/placement.html"); err != nil {
		check(false, fmt.tprintf("the page loads for the panel-placement check (%v)", err))
		return
	}
	pump(view, 32)
	pump(view, 200)
	root, rerr := sa.root(view.window)
	if rerr != nil {
		check(false, "the placement page has a root")
		return
	}
	if toggle, err := sa.select_first(root, "#nc-cca-toggle"); err == nil {
		sa.do_click(toggle)
		pump(view, 64)
		pump(view, 200)
	}

	res, err := sa.eval_element(root, `(function () {
		var p = document.querySelector('.cca-panel');
		var slide = document.querySelector('.slide');
		if (!p || !slide) { return '-1 no-panel'; }
		var pr = p.getBoundingClientRect(), worst = 0, name = '';
		function bite(r, what) {
			if (!(r.width > 0 && r.height > 0)) { return; }
			var ox = Math.max(0, Math.min(pr.right, r.right) - Math.max(pr.left, r.left));
			var oy = Math.max(0, Math.min(pr.bottom, r.bottom) - Math.max(pr.top, r.top));
			if (ox * oy > worst) { worst = Math.round(ox * oy); name = what; }
		}
		slide.querySelectorAll('.seat').forEach(function (s) {
			if (!s.classList.contains('facedown')) { bite(s.getBoundingClientRect(), 'a hand'); }
		});
		['.par', '.combo'].forEach(function (sel) {
			var c = slide.querySelector(sel);
			if (c) { bite(c.getBoundingClientRect(), sel); }
		});
		return worst + ' ' + (name || 'nothing');
	})()`)
	if err == nil {
		defer sa.value_clear(&res)
		text, _ := sa.value_to_string(&res, context.temp_allocator)
		fields := strings.fields(text, context.temp_allocator)
		area := -1
		if len(fields) > 0 {
			area, _ = strconv.parse_int(fields[0])
		}
		check(
			area == 0,
			fmt.tprintf("with room below the board the panel covers nothing (worst overlap %s)", strings.trim_space(text)),
		)
	} else {
		check(false, fmt.tprintf("the panel's overlap is measurable (%v)", err))
	}

	sa.resize_windowless(view, VIEW_WIDTH, VIEW_HEIGHT)
	pump(view, 200)
}

// THE PAGE HAS TO FOLLOW THE VIEW'S SIZE WITHOUT A `resize` EVENT. Everything responsive on this page hung
// off `window.addEventListener('resize')`, and inside the workbench's Sciter `<frame>` that event never
// arrives: enlarging the workbench window resized the frame and relaid the document out, while the page
// went on centring the board for the old width and left the CCA panel at the old width's size and position
// — until a click on CCA happened to re-run `show`, which is exactly what it looked like from outside ("it
// only lays out when I press the button"). The page now WATCHES the viewport's box instead. This check is
// that watch: resize the view, hand the page some time, and ask whether it caught up.
check_the_page_follows_the_view_size :: proc(view: ^sa.Windowless_View) {
	page, ok := render_page(CHECK_DEAL)
	if !ok {
		check(false, "a page renders for the resize check")
		return
	}
	defer delete(page)

	if err := sa.load_html(view.window, page, "file://page-check/resize.html"); err != nil {
		check(false, fmt.tprintf("the page loads for the resize check (%v)", err))
		return
	}
	pump(view, 32)
	pump(view, 200)
	root, rerr := sa.root(view.window)
	if rerr != nil {
		check(false, "the resize-check page has a root")
		return
	}

	// Open the panel first: its placement is the half of this that a click used to fix by accident.
	if toggle, err := sa.select_first(root, "#nc-cca-toggle"); err == nil {
		sa.do_click(toggle)
		pump(view, 64)
	}

	WIDER :: VIEW_WIDTH + 500
	if err := sa.resize_windowless(view, WIDER, VIEW_HEIGHT); err != nil {
		check(false, fmt.tprintf("the view resizes (%v)", err))
		return
	}
	// The watch runs on its own timer, and the panel's re-clamp is deferred a tick past that.
	for _ in 0 ..< 6 {
		pump(view, 200)
	}

	off := scroll_off_centre(root)
	check(
		off >= 0 && off <= 2,
		fmt.tprintf("the board re-centres when the VIEW resizes, with no resize event (off by %d px)", off),
	)
	check_the_panel_contains_its_own_table(root)
	check_the_panel_is_inside_the_view(root, WIDER)

	if err := sa.resize_windowless(view, VIEW_WIDTH, VIEW_HEIGHT); err != nil {
		return
	}
	pump(view, 200)
}

// And the panel has to stay ON the view. It was placed with a STALE `offsetWidth` — measured on a
// 1075 -> 1575 resize, the old 646px width clamped against the new viewport and the panel came to rest at
// 919..1604, 29px off the right edge, having relaid out 685px wide in the meantime.
check_the_panel_is_inside_the_view :: proc(root: sa.Element, view_width: i32) {
	res, err := sa.eval_element(root, `(function () {
		var p = document.querySelector('.cca-panel');
		if (!p) { return 'no panel'; }
		var r = p.getBoundingClientRect();
		return Math.round(r.left) + ' ' + Math.round(r.right);
	})()`)
	if err != nil {
		check(false, fmt.tprintf("the panel's box is measurable (%v)", err))
		return
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res, context.temp_allocator)
	fields := strings.fields(text, context.temp_allocator)
	if len(fields) != 2 {
		check(false, fmt.tprintf("the panel's box reads as two numbers (%q)", text))
		return
	}
	left, left_ok := strconv.parse_int(fields[0])
	right, right_ok := strconv.parse_int(fields[1])
	check(
		left_ok && right_ok && left >= 0 && right <= int(view_width),
		fmt.tprintf("the panel stays inside the view (%d..%d of %d)", left, right, view_width),
	)
}

// A page with ONE board is centred by the track's padding alone — there is nothing to scroll — and the
// padding is computed by the script from the viewport's width. Hosted in the workbench's `<frame>` that
// script ran BEFORE the frame had a size, so the padding came out 0 and the analysed deal sat flush
// against the left edge until the window was resized (which a desktop window nobody drags never is). The
// page now re-fits on a deferred tick; this is that fix, asserted where a windowless view can see it.
check_a_single_board_is_centred :: proc(view: ^sa.Windowless_View) {
	page, ok := render_page(CHECK_DEAL)
	if !ok {
		check(false, "a single-board page renders")
		return
	}
	defer delete(page)

	if err := sa.load_html(view.window, page, "file://page-check/one-board.html"); err != nil {
		check(false, fmt.tprintf("the single-board page loads (%v)", err))
		return
	}
	// Two pumps: the first is the layout the script saw, the second is the deferred re-fit.
	pump(view, 32)
	pump(view, 200)
	root, rerr := sa.root(view.window)
	if rerr != nil {
		check(false, "the single-board page has a root")
		return
	}

	slides, serr := sa.select_all(root, ".slide", context.temp_allocator)
	check(serr == nil && len(slides) == 1, fmt.tprintf("the page has exactly one board (%d)", len(slides)))

	off := scroll_off_centre(root)
	check(off >= 0 && off <= 2, fmt.tprintf("the single board is centred by the track padding (off by %d px)", off))
}

scroll_off_centre :: proc(root: sa.Element) -> int {
	res, err := sa.eval_element(root, `(function () {
		var vp = document.querySelector('.viewport');
		var a = document.querySelector('.slide.active');
		if (!vp || !a) { return '-1'; }
		var r = a.getBoundingClientRect(), v = vp.getBoundingClientRect();
		return '' + Math.round(Math.abs((r.left + r.right) / 2 - (v.left + v.right) / 2));
	})()`)
	if err != nil {
		return -1
	}
	defer sa.value_clear(&res)
	text, _ := sa.value_to_string(&res)
	n, ok := strconv.parse_int(strings.trim_space(text))
	if !ok {
		return -1
	}
	return n
}

// The first and last saturated-felt pixels on `row`, which bound the active board.
felt_edges :: proc(view: ^sa.Windowless_View, row: i32) -> (left, right: i32, ok: bool) {
	left, right = -1, -1
	for x := i32(0); x < VIEW_WIDTH; x += 1 {
		r, g, b, _ := sa.windowless_pixel(view, x, row)
		if near(r, FELT_R) && near(g, FELT_G) && near(b, FELT_B) {
			if left < 0 {
				left = x
			}
			right = x
		}
	}
	return left, right, left >= 0 && right > left
}

// Is the painted board centred in the view? `what` names the moment for the message.
painted_centred :: proc(view: ^sa.Windowless_View, root: sa.Element, what: string) {
	board, err := sa.select_first(root, ".slide.active .compass")
	if err != nil {
		check(false, fmt.tprintf("%s: the active board is there", what))
		return
	}
	// A horizontal transform does not move the row, only what is painted along it.
	box, _ := sa.location(board, .Border, .Root)
	row := box.y + box.height / 2
	if row >= VIEW_HEIGHT {
		row = VIEW_HEIGHT - 1
	}
	left, right, found := felt_edges(view, row)
	if !found {
		check(false, fmt.tprintf("%s: the active board's felt is painted on row %d", what, row))
		return
	}
	middle := (left + right) / 2
	off := middle - VIEW_WIDTH / 2
	if off < 0 {
		off = -off
	}
	check(
		int(off) <= VIEW_WIDTH / 10,
		fmt.tprintf(
			"%s: the PAINTED board is centred (felt %d..%d, middle %d, off by %d)",
			what,
			left,
			right,
			middle,
			off,
		),
	)
}

// The page with its `@media sciter` block removed — the negative control. The block runs from its own
// `@media sciter` line to the comment that introduces the phone media query, both of which are stable
// landmarks in the template; not finding either means the template moved and this check needs a look.
without_overrides :: proc(page: string) -> (cut: string, ok: bool) {
	start := strings.index(page, OVERRIDES_AT)
	if start < 0 {
		return "", false
	}
	// The block runs to the phone media query's own line. It used to be found by the COMMENT that introduces
	// that query, which stopped existing the day the emitted stylesheet started having its comments stripped
	// (they are 14KB the engine's 32KiB cap cannot spare) — a landmark has to be something the OUTPUT has.
	end := strings.index(page[start:], "		@media (max-width")
	if end < 0 {
		return "", false
	}
	return strings.concatenate({page[:start], page[start + end:]}), true
}

// The card page for `CHECK_DEAL`, through the same call the workbench's analyse path uses: the page as a
// string, nothing written to disk.
render_page :: proc(deal: string) -> (page: string, ok: bool) {
	args, err := analyse.parse_args({deal}, allow_stdin = false)
	defer analyse.args_free(&args)
	if err != "" {
		fmt.eprintln("could not parse the check deal:", err)
		return "", false
	}

	report := strings.builder_make()
	defer strings.builder_destroy(&report)
	page_b := strings.builder_make()

	if result := analyse.run(analyse.builder_page_sink(&report, &page_b), &args); result != .Ok {
		fmt.eprintfln("the analysis failed (%v): %s", result, strings.to_string(report))
		strings.builder_destroy(&page_b)
		return "", false
	}
	return strings.to_string(page_b), true
}

// Layout, style resolution and the behavior attachment that depends on them. A behavior goes live at style
// resolution and a behavior's click is POSTED, so both the first look and the click need a few frames.
// ONE frame. `pump` runs sixteen, which lets any tween finish; a burst of steps has to be delivered with the
// engine barely given time to paint, which is the whole point of the fast-stepping check.
frame :: proc(view: ^sa.Windowless_View, at: int) {
	sa.windowless_heartbeat(view, time.Duration(at) * 16 * time.Millisecond)
	sa.paint_windowless(view)
}

pump :: proc(view: ^sa.Windowless_View, from: int) {
	for i in 0 ..< 16 {
		sa.windowless_heartbeat(view, time.Duration(from + i) * 16 * time.Millisecond)
		sa.paint_windowless(view)
	}
}

check :: proc(ok: bool, what: string) {
	if ok {
		fmt.printfln("  ok    %s", what)
		return
	}
	g_failures += 1
	fmt.printfln("  FAIL  %s", what)
}

_ :: sciter
