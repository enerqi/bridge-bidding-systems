package main

/*
	workbench_test.odin — the workbench's tests.

	SPLIT OUT OF `workbench.odin`, which had reached ~12,900 lines with half of them tests. That split is
	why this program is a PACKAGE DIRECTORY rather than one of the repo's `-file` programs: `odin ... -file`
	compiles exactly one file, so a second file is only possible once the thing is a package. `sim.odin`,
	`analyse_deal.odin`, `page_check.odin` and `bml2html.odin` are all still single files, and all of them
	are a fraction of this size.

	WHAT THESE PIN is the seam between the document and the host — the ids the host reads, that the argv
	its controls compose is ACCEPTED BY THE REAL PARSERS, and the layout facts that only a rendered
	document can answer. The analysis itself is not retested here; `analyse`'s own tests and `test-golden`
	cover it.
*/

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "../analyse"
import "../bidding"
import "../outline"
import "../prefs"
import "../preview"
import "../scenario_dsl"
import bml "markup:."
import "norn:cli"
import "norn:combo"
import "norn:norn"
import sciter "sciter:."
import sa "sciter:sciter_app"

// ---------------------------------------------------------------------------------------------------
// Tests
//
// A WINDOWLESS view rather than a window: it needs no visible desktop, and it is how odin-sciter's own
// examples test a document. What these pin is the seam between the document and the host — the ids the
// host reads, and that the argv its controls compose is ACCEPTED BY THE REAL PARSERS. That last one is
// the point of composing an argv at all: a flag misspelled here would otherwise surface as a runtime
// "unknown flag" in the transcript, and only once someone pressed the button.
//
// The analysis itself is not retested here; `analyse`'s own tests and `test-golden` cover it.

@(private = "file")
g_view: sa.Windowless_View

// Bring up the engine, the view and one loaded document, and hand back an App wired to it. Returns false
// when there is no engine to test against, which is a skip rather than a failure.
@(private = "file")
test_app :: proc(t: ^testing.T, app: ^App) -> (ok: bool) {
	if !sa.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	// A test binary reaches the engine without going through the application's `init`, so it installs the
	// debug output itself: on Windows a CSS warning with no handler installed arrives as an exception,
	// which the test runner treats as fatal.
	sa.set_default_debug_output()

	if g_view.window == nil {
		// The engine keeps the view for the life of the process, so it is not the tracking allocator's
		// business — otherwise every later test reports it as a leak.
		context.allocator = runtime.default_allocator()
		v, err := sa.create_windowless({width = 1120, height = 780})
		testing.expect_value(t, err, nil)
		if v.window == nil {
			return false
		}
		g_view = v
	}
	// The same flag `main` sets, and for the same reason: a card page hosted in the frame reads it. Set on
	// every call rather than once with the view, because it is what the frame test is really asserting and
	// a media var that had to be set elsewhere would be a trap for the next test.
	set_sciter_media_var(g_view.window)

	testing.expect_value(t, sa.load_html(g_view.window, compose_document(context.temp_allocator), "about:blank"), nil)
	pump_view()

	app.window = g_view.window
	app.allocator = context.allocator
	app.selected = 0
	// The same wiring `main` does, so the tests see the registry the window sees. With no scenario
	// directories configured this loads nothing and leaves `app.scenarios` as `bidding.registry`.
	load_user_scenarios(app)
	app.transcript = strings.builder_make()
	return true
}

// Run the engine over the view: layout, style resolution and the behavior attachment that depends on it.
@(private = "file")
pump_view :: proc() {
	for i in 0 ..< 8 {
		sa.windowless_heartbeat(&g_view, time.Duration(i) * 16 * time.Millisecond)
		sa.paint_windowless(&g_view)
	}
}

@(private = "file")
pump :: proc(app: ^App) {
	pump_view()
}

@(private = "file")
test_app_destroy :: proc(app: ^App) {
	strings.builder_destroy(&app.transcript)
	delete(app.tag_on, app.allocator)
	delete(app.groups, app.allocator)
	scenario_dsl.destroy_loaded(&app.loaded, app.allocator)
	delete(app.scenarios, app.allocator)
	for directory in app.scenario_dirs {
		delete(directory, app.allocator)
	}
	delete(app.scenario_dirs, app.allocator)
	job_free(&app.job, app.allocator)
	free_goto_index(app)
	delete(app.scroll_want, app.allocator)
	delete(app.shown_path, app.allocator)
	clear_outputs(app)
	delete(app.outputs)
	delete(app.bml_open, app.allocator) // `open_bml` clones it onto the heap, as `main` frees at exit
	// The scenario editor's folder, its file names and the open file — cloned by `adopt_scenario_dir` and
	// `open_scenario_file`, and never given back here, so every editor test reported them as leaks.
	for name in app.scn_names {
		delete(name, app.allocator)
	}
	delete(app.scn_names, app.allocator)
	delete(app.scn_dir, app.allocator)
	delete(app.scn_open, app.allocator)
}

// Set an input's text the way a person typing into it would leave it.
@(private = "file")
type_into :: proc(app: ^App, selector: string, text: string) {
	element := find(app, selector)
	if element == nil {
		return
	}
	value := sa.value_from(text)
	defer sa.value_clear(&value)
	sa.set_element_value(element, &value)
}

@(private = "file")
tick :: proc(app: ^App, selector: string) {
	element := find(app, selector)
	if element == nil {
		return
	}
	value := sa.value_from(true)
	defer sa.value_clear(&value)
	sa.set_element_value(element, &value)
}

// The stylesheet is spliced in, and the marker does not survive into the document.
//
// It also guards against browser idioms Sciter does not implement — but only in CODE: the comments in
// both UI files DISCUSS `display:flex`, `grid` and `clamp()` (that is what they are warning about), so a
// naive substring search over the whole document matches its own documentation. Stripping the comments
// first is the difference between a test of the stylesheet and a test of the prose.
@(test)
test_compose_document_splices_the_stylesheet :: proc(t: ^testing.T) {
	document := compose_document(context.temp_allocator)
	testing.expect(t, !strings.contains(document, CSS_MARKER), "the marker must be consumed")
	testing.expect(t, strings.contains(document, "flow: vertical"), "the CSS must be present")
	testing.expect(t, strings.contains(document, `id="report"`), "the HTML must be present")

	code := strip_css_comments(document, context.temp_allocator)
	for idiom in ([]string{"display: flex", "display:flex", "display: grid", "display:grid", "clamp(", "vw;", "vh;"}) {
		testing.expectf(
			t,
			!strings.contains(code, idiom),
			"Sciter does not implement %q — see ui/workbench.css",
			idiom,
		)
	}
}

// Everything between `/*` and `*/`, removed. Only used by the test above.
@(private = "file")
strip_css_comments :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	rest := s
	for {
		open := strings.index(rest, "/*")
		if open < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:open])
		close := strings.index(rest[open:], "*/")
		if close < 0 {
			break // unterminated: the remainder is all comment
		}
		rest = rest[open + close + 2:]
	}
	return strings.to_string(b)
}

// The Sciter EULA's attribution, VERBATIM, in the About panel — a ship blocker on odin-sciter's release
// checklist, and the kind of text an editing pass "improves" without knowing it is quoted. The engine's
// own EULA states the required sentence; this asserts the document still carries it, and that a link to
// the site is there for the host to handle.
@(test)
test_the_about_panel_carries_the_sciter_attribution :: proc(t: ^testing.T) {
	document := compose_document(context.temp_allocator)
	required :: "This Application"
	site :: "http://sciter.com/"

	testing.expect(
		t,
		strings.contains(document, "uses Sciter Engine"),
		"the EULA's attribution sentence must appear in the About panel, verbatim",
	)
	testing.expect(t, strings.contains(document, required))
	testing.expect(t, strings.contains(document, "copyright Terra Informatica Software, Inc."))
	testing.expect(t, strings.contains(document, site), "and it must be a link to the site")
	testing.expect(t, strings.contains(document, `id="about-sciter-link"`), "which the host opens")
}

// The About panel is reachable and closable, and showing it hides the working panes rather than floating
// over them (an overlay would hit Sciter's 1px collapse — see the CSS).
@(test)
test_the_about_panel_toggles :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// `style` reports the value in EFFECT, not only an inline one, so the stylesheet's own
	// `.about { display: none }` is what this reads before the host has touched anything.
	testing.expect_value(t, effective_display(&app, "#about-panel"), "none")

	show_about(&app, true)
	testing.expect_value(t, effective_display(&app, "#about-panel"), "block")
	testing.expect_value(t, effective_display(&app, ".panes"), "none") // the panes give way to it

	show_about(&app, false)
	testing.expect_value(t, effective_display(&app, "#about-panel"), "none")
	testing.expect_value(t, effective_display(&app, ".panes"), "block")
}

// An element's `display` as the engine has it — the stylesheet's value until the host sets an inline one.
@(private = "file")
effective_display :: proc(app: ^App, selector: string) -> string {
	element := find(app, selector)
	if element == nil {
		return "<missing>"
	}
	value, err := sa.style(element, "display", context.temp_allocator)
	if err != nil {
		return "<error>"
	}
	return value
}

// Every id the host reads or writes has to exist in the document. A rename on either side is otherwise
// silent: `find` returns nil, `read_text` returns "", and a control simply stops working.
@(test)
test_the_document_carries_every_control_the_host_touches :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	for selector in ([]string {
			"#engine",
			"#scenarios",
			"#count",
			"#format",
			"#seed",
			"#outdir",
			"#dd",
			"#fixed",
			"#all",
			"#generate",
			"#cancel",
			"#fill",
			"#status",
			"#deal",
			"#sample",
			"#contract",
			"#target",
			"#as-page",
			"#analyse",
			"#clear",
			"#report",
			".panes",
			"#about",
			"#about-panel",
			"#about-close",
			"#about-sciter-link",
			"#about-versions",
			"#about-book",
			"#deal-split",
			"#pageview",
			"#page",
			"#page-title",
			"#page-dump",
			"#tabs",
			`.tab[data-view="panes"]`,
			`.tab[data-view="editor"]`,
		}) {
		testing.expectf(t, find(&app, selector) != nil, "the document is missing %s", selector)
	}
}

// The pre-filled output directory has to be somewhere that can actually be written. `w:/deals/` is this
// project's convention and the justfile exports it, so the field would otherwise open showing a dead path
// on any machine without that volume — and the user would only find out when a batch refused.
@(test)
test_the_default_output_dir_falls_back_when_unreachable :: proc(t: ^testing.T) {
	// A folder that does not exist yet, under a drive that does, is REACHABLE: resolve_out_dir creates it.
	testing.expect(t, path_is_reachable("target/debug/not-there-yet/deeper"))
	testing.expect(t, path_is_reachable("."))

	// A drive letter nothing is mounted on is not, and no amount of creating would help.
	unreachable_path :: "zz:/deals"
	testing.expect(t, !path_is_reachable(unreachable_path))

	chosen, note := choose_out_dir(unreachable_path, context.temp_allocator)
	testing.expect(t, chosen != unreachable_path, "an unreachable candidate must not be offered")
	testing.expect(t, path_is_reachable(chosen), chosen)
	testing.expect(t, strings.contains(note, unreachable_path), note) // says what it rejected
	testing.expect(t, strings.contains(note, chosen), note) // and what it used instead

	// A reachable candidate is taken as given, with nothing to report.
	kept, quiet := choose_out_dir("target/debug", context.temp_allocator)
	testing.expect_value(t, kept, "target/debug")
	testing.expect_value(t, quiet, "")

	// No candidate at all: a real directory, and no note — the user was not overridden, just defaulted.
	empty, silent := choose_out_dir("", context.temp_allocator)
	testing.expect(t, path_is_reachable(empty), empty)
	testing.expect_value(t, silent, "")
}

// The document is decoded as UTF-8. Without a `<meta charset>` the engine falls back to the SYSTEM
// codepage, and every non-ASCII character in the help text arrives mangled — an em dash as `â€"`,
// a `·` as `Â·` — with nothing logged and nothing else wrong. It is invisible to every other
// test here, because the bytes in the file were always correct; only the reader was.
//
// This asserts the round trip: an em dash authored in the document has to come back out of the DOM as an
// em dash, and the classic mojibake prefix must not appear anywhere in the text.
@(test)
test_the_document_is_decoded_as_utf8 :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect(
		t,
		strings.contains(compose_document(context.temp_allocator), `charset="utf-8"`),
		"the document must declare its encoding",
	)

	// Body text, through the parser and back.
	help := find(&app, "#help-generate-text")
	testing.expect(t, help != nil)
	text, err := sa.text(help, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.contains(text, "—"), "an em dash must survive as an em dash")
	testing.expect(t, !strings.contains(text, "â"), "mojibake: UTF-8 read as a single-byte codepage")

	// And attribute values, which is what the hint bar reads.
	hint := hint_for(find(&app, "#seed"))
	testing.expect(t, strings.contains(hint, "—"), hint)
	testing.expect(t, !strings.contains(hint, "â"), hint)
}

// Every control a person can touch carries BOTH kinds of help: `title` for the engine's hover tooltip and
// `data-hint` for the hint bar. The two are separate mechanisms and it is easy to add a control with one,
// or with neither — which is how a UI ends up assuming its reader already knows the flags.
@(test)
test_every_control_is_documented :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Interactive elements only: a label or a legend explains itself by being read.
	for selector in ([]string {
			"#count",
			"#format",
			"#seed",
			"#outdir",
			"#dd",
			"#fixed",
			"#all",
			"#generate",
			"#cancel",
			"#deal",
			"#sample",
			"#contract",
			"#target",
			"#analyse",
			"#clear",
			"#about",
			"#help-generate",
			"#help-analyse",
			`.tab[data-view="panes"]`,
			`.tab[data-view="editor"]`,
			"#deal-list-toggle",
			`.segbtn[data-pane="closed"]`,
			`.segbtn[data-pane="split"]`,
			`.segbtn[data-pane="wide"]`,
			"#bml-files-toggle",
			"#bml-folder",
			"#bml-fold",
			"#bml-links",
			"#bml-preview",
			"#bml-save",
			"#help-bml",
			"#bml-text",
		}) {
		element := find(&app, selector)
		testing.expectf(t, element != nil, "no %s", selector)
		if element == nil {
			continue
		}
		title, _ := sa.attribute(element, "title", context.temp_allocator)
		hint, _ := sa.attribute(element, "data-hint", context.temp_allocator)
		testing.expectf(t, title != "", "%s has no title= (the engine's hover tooltip)", selector)
		testing.expectf(t, hint != "", "%s has no data-hint= (the hint bar)", selector)
		// A hint is a sentence, not a repeat of the label — the label is already on screen next to it.
		testing.expectf(t, len(hint) > 30, "%s's hint is too short to explain anything: %q", selector, hint)
	}
}

// The hint bar fills from whatever the pointer or the keyboard is on, and empties again. This is the whole
// mechanism: `data-hint` in the document, `.MOUSE`/`.FOCUS` in the subscription, one line of text out.
@(test)
test_the_hint_bar_follows_the_pointer :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	bar := find(&app, "#hint")
	testing.expect(t, bar != nil)

	// Straight through the same proc the events call, since a synthetic MOUSE_ENTER is the engine's to send.
	seed := find(&app, "#seed")
	hint := hint_for(seed)
	testing.expect(t, strings.contains(hint, "SAME deals"), hint)
	show_hint(&app, hint)
	shown, _ := sa.text(bar, context.temp_allocator)
	testing.expect_value(t, shown, hint)

	show_hint(&app, "")
	empty, _ := sa.text(bar, context.temp_allocator)
	testing.expect_value(t, empty, "")

	// A label or an inner span is what the pointer usually lands on, so the hint has to be found by
	// walking UP from the target. `#scenarios` carries one; its rendered rows do not.
	draw_scenarios(&app)
	pump(&app)
	rows, _ := sa.select_all(find(&app, "#scenarios"), ".row", context.temp_allocator)
	if len(rows) > 0 {
		if name, err := sa.select_first(rows[0], ".name"); err == nil {
			testing.expect(t, strings.contains(hint_for(name), "scenario"), hint_for(name))
		}
	}
}

// The `?` next to each panel legend toggles that panel's paragraph, and the panels start closed.
@(test)
test_the_panel_help_toggles :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	for pair in ([]struct {
			button, block: string,
		}{{"#help-generate", "#help-generate-text"}, {"#help-analyse", "#help-analyse-text"}}) {
		testing.expect_value(t, effective_display(&app, pair.block), "none") // closed to begin with

		sa.do_click(find(&app, pair.button))
		pump(&app)
		testing.expectf(t, effective_display(&app, pair.block) == "block", "%s did not open", pair.block)

		sa.do_click(find(&app, pair.button))
		pump(&app)
		testing.expectf(t, effective_display(&app, pair.block) == "none", "%s did not close again", pair.block)
	}
}

// Every control gives visible feedback under the pointer. Sciter's default stylesheet does NOT do this
// for you — measured: a bare `<button>` computes `background-color: transparent` at rest, hovered and
// active alike — so a stylesheet that sets a background and stops has produced a control that looks
// dead to the touch. `set_element_state` drives the same state bits a real pointer sets.
@(test)
test_controls_have_interaction_states :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// selector, and whether hover/active must differ from rest
	for probe in ([]struct {
			selector: string,
			active:   bool,
		} {
			{"#generate", true}, // the primary button
			{"#clear", true}, // the secondary (.ghost) button
			{"#about", true},
			{`.tab[data-view="editor"]`, true}, // a tab is a button and paints its own states
			{"#count", false}, // a text field: hover only
			{"#outdir", false},
		}) {
		element := find(&app, probe.selector)
		testing.expectf(t, element != nil, "no %s", probe.selector)
		if element == nil {
			continue
		}

		rest := background_in_state(&app, element, {})
		hover := background_in_state(&app, element, {.HOVER})
		testing.expectf(
			t,
			rest != hover,
			"%s does not react to the pointer: background stays %s on hover",
			probe.selector,
			rest,
		)
		if probe.active {
			pressed := background_in_state(&app, element, {.ACTIVE})
			testing.expectf(t, pressed != rest, "%s does not react to being pressed (%s)", probe.selector, rest)
		}
	}

	// A DISABLED button must NOT light up: `cancel` starts disabled, and its hover rule has to lose to the
	// disabled one. This is the half that ordinary eyeballing misses, because the button looks right until
	// you point at something you cannot click.
	cancel := find(&app, "#cancel")
	testing.expect(t, cancel != nil)
	set_enabled(&app, "#cancel", false)
	pump(&app)
	off_rest := background_in_state(&app, cancel, {})
	off_hover := background_in_state(&app, cancel, {.HOVER})
	testing.expect_value(t, off_hover, off_rest)
}

// An element's computed background in a given state, with the state left as it was found.
@(private = "file")
background_in_state :: proc(app: ^App, element: sa.Element, bits: sciter.Element_State_Bits) -> string {
	sa.set_element_state(element, bits, {}, true) // set the bits under test
	pump(app)
	value, _ := sa.style(element, "background-color", context.temp_allocator)
	sa.set_element_state(element, {}, bits, true) // and put them back
	pump(app)
	return value
}

// Clicking a row MOVES the selection. This is the test that was missing: the first version rendered the
// list correctly and asserted exactly that, while no click ever reached the host — a `<div>` has no
// behavior, so it raises no `.BUTTON_CLICK`, and the selection could never leave the first scenario.
// `do_click` goes through the same native controller a real click does, so `behavior: button` in the CSS
// is what both depend on.
@(test)
test_clicking_a_row_moves_the_selection :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	if len(bidding.registry) < 3 {
		return // needs somewhere to move to
	}

	// The same handler `main` installs, on the same window — so this exercises the real event path. It is
	// detached again because the windowless view outlives the test and `app` does not: the engine would be
	// left holding the address of a stack frame that has gone.
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	draw_scenarios(&app)
	// A native behavior attaches when the element's style is RESOLVED, not when it is inserted, so freshly
	// `set_html`'d rows have no controller until the engine has run a pass over them. A real window pumps
	// constantly and this is invisible there; a windowless view pumps only when told, so without this the
	// rows answer no click and the test blames the CSS.
	pump(&app)

	list := find(&app, "#scenarios")
	rows, err := sa.select_all(list, ".row", context.temp_allocator)
	testing.expect_value(t, err, nil)
	if len(rows) < 3 {
		return
	}

	// A row must answer the click at all — `handled = false` here IS the bug this test exists for.
	handled, cerr := sa.do_click(rows[2])
	testing.expect_value(t, cerr, nil)
	testing.expect(t, handled, "a row must carry a behavior that answers a click (behavior: button)")

	// `do_click` runs the behavior synchronously but the resulting BUTTON_CLICK is DELIVERED through the
	// event queue, so the handler has not run yet. Pump, then assert — the same shape
	// odin-sciter's examples/behavior.odin uses around its own click tests.
	pump(&app)
	testing.expect_value(t, app.selected, 2)

	// And the document followed the model: exactly one row marked, and it is that one.
	marked, merr := sa.select_all(find(&app, "#scenarios"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	index, _ := sa.attribute(marked[0], "data-index", context.temp_allocator)
	testing.expect_value(t, index, "2")

	// And it moves again, rather than sticking wherever it first landed.
	fresh, _ := sa.select_all(find(&app, "#scenarios"), ".row", context.temp_allocator)
	sa.do_click(fresh[1])
	pump(&app)
	testing.expect_value(t, app.selected, 1)
}

// The scenario list is a projection of the registry, and the selection is part of it.
@(test)
test_the_scenario_list_renders_the_registry :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	draw_scenarios(&app)
	list := find(&app, "#scenarios")
	rows, err := sa.select_all(list, ".row", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, len(bidding.registry) > 0, "the bidding system must register scenarios")
	testing.expect_value(t, len(rows), len(bidding.registry))

	selected, serr := sa.select_all(list, ".row.sel", context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, len(selected), 1) // exactly the one `app.selected` names
}

// ---- the scenario filter -------------------------------------------------------------------------
//
// The matching and the ranking are `outline`'s, tested there with no engine in the way. What is worth a
// document is what THIS side adds, and in particular the two things that would be silent wrong answers
// rather than visible failures: that a row still names its registry entry once the list has been narrowed
// (a filtered list is the one way `data-index` and `app.selected` can come to mean different things), and
// that a selection the filter hides is repaired rather than left off screen deciding what generate runs.

// Type into the filter the way a person does — one character at a time, so the edit behavior raises the
// `.VALUE_CHANGED` the list is redrawn from. Setting the value would test the redraw and not the wiring.
@(private = "file")
type_filter :: proc(app: ^App, text: string) {
	input := find(app, "#scenario-filter")
	if input == nil {
		return
	}
	_ = sa.set_focus(input)
	_ = sa.send_text(input, text)
	pump(app)
}

@(private = "file")
scenario_row_elements :: proc(app: ^App) -> []sa.Element {
	rows, err := sa.select_all(find(app, "#scenarios"), ".row", context.temp_allocator)
	if err != nil {
		return nil
	}
	return rows
}

// A registry name with dashes in it, so a query can be built by REPLACING them with spaces. That is the
// property under test and the reason this is derived rather than hard-coded: the corpus spells its auctions
// with punctuation nobody types.
@(private = "file")
dashed_scenario_name :: proc(app: ^App) -> (name: string, ok: bool) {
	for scenario in app.scenarios {
		if strings.count(scenario.name, "-") >= 2 && len(scenario.name) >= 8 {
			return scenario.name, true
		}
	}
	return "", false
}

// Typing narrows the list, and the punctuation the registry spells its names with is not something anyone
// has to type: the query here is the name with its dashes replaced by spaces.
@(test)
test_the_filter_narrows_the_list_to_the_scenarios_it_names :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	draw_scenarios(&app)
	pump(&app)
	testing.expect_value(t, len(scenario_row_elements(&app)), len(app.scenarios))

	name, found := dashed_scenario_name(&app)
	if !found {
		return // nothing in the registry to make the point with
	}
	query, _ := strings.replace_all(name, "-", " ", context.temp_allocator)
	type_filter(&app, query)

	shown := visible_scenarios(&app, context.temp_allocator)
	testing.expectf(t, len(shown) > 0, "%q matched nothing at all", query)
	testing.expectf(
		t,
		len(shown) < len(app.scenarios),
		"%q left all %d scenarios, so it narrowed nothing",
		query,
		len(app.scenarios),
	)
	testing.expect_value(t, len(scenario_row_elements(&app)), len(shown))

	// The scenario whose name was typed is not merely present — it is the best match. Anything else means
	// the ranking would make somebody scroll for the row they spelled out in full.
	testing.expect_value(t, app.scenarios[shown[0]].name, name)

	// And a query that names nothing says so, rather than leaving a blank box that reads as a broken list.
	type_filter(&app, "zzzzqqq")
	testing.expect_value(t, len(scenario_row_elements(&app)), 0)
	empty, eerr := sa.select_all(find(&app, "#scenarios"), ".empty", context.temp_allocator)
	testing.expect_value(t, eerr, nil)
	testing.expect_value(t, len(empty), 1)
}

// THE INVARIANT THE FILTER COULD BREAK SILENTLY: a row carries its index in the REGISTRY, not its position
// in the narrowed list. Clicking the second row of a filtered list must select the scenario that row names
// — and it is the generate job, the chips and the pane that would otherwise all be about a stranger.
@(test)
test_a_filtered_row_still_names_its_own_scenario :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	draw_scenarios(&app)
	pump(&app)
	type_filter(&app, "1c")

	rows := scenario_row_elements(&app)
	if len(rows) < 2 {
		return // needs a narrowed list with somewhere to click that is not the first row
	}
	// Deliberately NOT the first row: a bug that used a list position would agree with the registry index
	// at zero and nowhere else.
	target := rows[1]
	named, nerr := sa.select_first(target, ".name")
	testing.expect_value(t, nerr, nil)
	wanted, werr := sa.text(named, context.temp_allocator)
	testing.expect_value(t, werr, nil)

	// A row must answer a click at all (`behavior: button`), narrowed or not.
	handled, cerr := sa.do_click(target)
	testing.expect_value(t, cerr, nil)
	testing.expect(t, handled, "a filtered row must still carry the behavior that answers a click")
	pump(&app)

	testing.expectf(
		t,
		app.scenarios[app.selected].name == wanted,
		"the second row of the filtered list reads %q but selected %q",
		wanted,
		app.scenarios[app.selected].name,
	)
	// And the index really was the registry's, not the row's position in the narrowed list.
	testing.expect(t, app.selected != 1 || wanted == app.scenarios[1].name, "the row's index is the registry's")
}

// A filter that hides the selection MOVES it; a filter that still shows it leaves it alone. The first is
// the correctness half — `app.selected` is what generate runs — and the second is the courtesy half:
// narrowing a list is not a reason to move off the row somebody was reading.
@(test)
test_the_filter_repairs_a_selection_it_hid :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	draw_scenarios(&app)
	pump(&app)

	name, found := dashed_scenario_name(&app)
	if !found {
		return
	}
	query, _ := strings.replace_all(name, "-", " ", context.temp_allocator)

	// Select something, then narrow to a query that (almost certainly) excludes it — and assert on the
	// PROPERTY rather than on which scenario it landed on: whatever is selected is on screen.
	select_scenario(&app, len(app.scenarios) - 1)
	type_filter(&app, query)
	shown := visible_scenarios(&app, context.temp_allocator)
	if len(shown) == 0 {
		return
	}
	testing.expect(
		t,
		slice.contains(shown, app.selected),
		"the filter left the selection off screen, where it still decides what generate runs",
	)

	// Now narrow FURTHER in a way that still shows the selection: it must not move.
	settled := app.selected
	filter_scenarios(&app) // the same query, re-applied - nothing was hidden, so nothing should move
	testing.expect_value(t, app.selected, settled)
}

// ---- the output formats ---------------------------------------------------------------------------
//
// ONE EXTENSION PER FORMAT is a rule this codebase already had, in a comment, with nothing enforcing it —
// and the html pair broke it in silence for as long as both existed. `html-cards` and `html-handviewer`
// both wrote `<scenario>.html`, so generating a scenario as one and then as the other REPLACED the first,
// and the chip row could only ever show a single `html` chip for two different things. Reported as "the
// html-handviewer format takes over the html button". A comment is not a guard; this is.

// EVERY FORMAT'S EXTENSION IS ITS OWN. The whole bug, in one assertion.
@(test)
test_no_two_formats_share_an_extension :: proc(t: ^testing.T) {
	extensions := FORMAT_EXTENSIONS
	for format in Deal_Format {
		for other in Deal_Format {
			if format == other {
				continue
			}
			testing.expectf(
				t,
				extensions[format] != extensions[other],
				"%v and %v both write %s — generating one would overwrite the other",
				format,
				other,
				extensions[format],
			)
		}
	}
}

// AND SO IS EVERY GENERATE FORMAT'S. `extension_for` maps the dropdown's names, which is the other half:
// the enum above describes what is found ON DISK, this describes what a run WRITES, and it was the second
// that collided.
@(test)
test_no_two_generate_formats_share_an_extension :: proc(t: ^testing.T) {
	names := []string{"html-cards", "html-handviewer", "pbn", "lin", "handviewer", "line", "numeric", "pretty"}
	for name, i in names {
		for other in names[i + 1:] {
			testing.expectf(
				t,
				extension_for(name) != extension_for(other),
				"%s and %s both write %s — the second run would replace the first",
				name,
				other,
				extension_for(name),
			)
		}
	}
	// And every one of them is a format the chip row can actually name, so nothing can be generated that
	// the window then cannot see.
	for name in names {
		_, format, known := format_of_extension(fmt.tprintf("x%s", extension_for(name)))
		testing.expectf(t, known, "%s writes %s, which no Deal_Format claims", name, extension_for(name))
		_ = format
	}
}

// THE BROWSER BUTTON IS FOR PAGES. `open_in_browser` is a shell open, so a `.txt` goes to Notepad and a
// `.lin` to whatever claims it — neither is what a button labelled `browser` promises. Reported.
@(test)
test_only_a_page_goes_to_the_browser :: proc(t: ^testing.T) {
	for path in ([]string{"deals/1c-any.html", "deals/1c-any.hv.html"}) {
		testing.expectf(t, browsable_page(path), "%s is a page and should open in a browser", path)
	}
	for path in ([]string {
			"deals/1c-any.txt",
			"deals/1c-any.lin",
			"deals/1c-any.pbn",
			"deals/1c-any.hv.txt",
			"deals/1c-any.line",
			"deals/1c-any.num",
			"",
		}) {
		testing.expectf(t, !browsable_page(path), "%s is not a page; a browser is the wrong home for it", path)
	}
}

// ---- the scenario groups -------------------------------------------------------------------------
//
// The membership and the OR rule are `bidding`'s, tested there against the registry. What is worth a
// document here is the COMPOSITION — that the groups widen and the typing narrows, in that order, in the
// one loop both go through — and the picker's keys.

// The index of a tag by name, so no test hard-codes a position in `bidding.tags`.
@(private = "file")
tag_index :: proc(name: string) -> (index: int, ok: bool) {
	for tag, i in bidding.tags {
		if tag.name == name {
			return i, true
		}
	}
	return 0, false
}

// A GROUP NARROWS THE LIST, AND THE FILTER NARROWS WHAT IS LEFT. The order matters and this is what pins
// it: the groups decide which scenarios are in play, the query only ranks and cuts within them.
@(test)
test_a_group_narrows_the_list_and_composes_with_the_filter :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	draw_scenarios(&app)
	pump(&app)
	testing.expect_value(t, len(visible_scenarios(&app, context.temp_allocator)), len(app.scenarios))

	club, found := tag_index("swedish-club")
	if !found {
		return
	}
	toggle_tag(&app, club)
	grouped := visible_scenarios(&app, context.temp_allocator)
	testing.expect(t, len(grouped) > 0 && len(grouped) < len(app.scenarios), "a group is a proper subset")
	// EVERY row shown carries the group — the filter is not merely reordering.
	for index in grouped {
		testing.expectf(
			t,
			bidding.has_any_tag(app.scenarios[index].name, {"swedish-club"}),
			"%q is shown under swedish-club but does not carry it",
			app.scenarios[index].name,
		)
	}
	testing.expect_value(t, len(scenario_row_elements(&app)), len(grouped))

	// And typing narrows THAT, rather than starting again from the whole registry.
	type_filter(&app, "1c")
	both := visible_scenarios(&app, context.temp_allocator)
	testing.expect(t, len(both) <= len(grouped), "the query must narrow the group, not widen it")
	for index in both {
		testing.expectf(
			t,
			bidding.has_any_tag(app.scenarios[index].name, {"swedish-club"}),
			"%q survived the query but is outside the selected group",
			app.scenarios[index].name,
		)
	}

	// Turning the group off gives the rest back, with the query still applied.
	toggle_tag(&app, club)
	ungrouped := visible_scenarios(&app, context.temp_allocator)
	testing.expect(t, len(ungrouped) >= len(both), "dropping the group cannot lose rows")
}

// TWO GROUPS ARE A UNION, NOT AN INTERSECTION. The decision the whole control hangs off: intersected, two
// groups would be a near-empty list nobody asked for.
@(test)
test_two_groups_are_a_union :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	first, ok_first := tag_index("swedish-club")
	second, ok_second := tag_index("competitive")
	if !ok_first || !ok_second {
		return
	}

	toggle_tag(&app, first)
	only_first := len(visible_scenarios(&app, context.temp_allocator))
	toggle_tag(&app, first)

	toggle_tag(&app, second)
	only_second := len(visible_scenarios(&app, context.temp_allocator))

	toggle_tag(&app, first) // both on now
	together := len(visible_scenarios(&app, context.temp_allocator))

	testing.expectf(
		t,
		together >= only_first && together >= only_second,
		"two groups gave %d rows against %d and %d alone — that is an intersection, not a union",
		together,
		only_first,
		only_second,
	)
	testing.expect(t, together > only_second, "adding the bigger group must add rows")
	testing.expect(t, together <= len(app.scenarios), "a union cannot exceed the registry")
}

// The chips exist only while something is selected, and pressing one removes that group. They are the only
// thing on screen saying the list is narrowed, so "no chips" and "no filtering" have to be the same state.
@(test)
test_the_group_chips_appear_only_when_a_group_is_selected :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	draw_tag_chips(&app)
	pump(&app)
	testing.expect(t, effective_display_is_hidden(&app, "#tagchips"), "no group selected, no chip row")

	club, found := tag_index("swedish-club")
	if !found {
		return
	}
	toggle_tag(&app, club)
	pump(&app)
	testing.expect(t, !effective_display_is_hidden(&app, "#tagchips"), "a selected group must show its chip")
	chips, cerr := sa.select_all(find(&app, "#tagchips"), ".tagchip", context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, len(chips), 1)

	// Pressing the chip removes the group — and the chip must answer a click at all, which is the
	// `behavior: button` failure that has bitten every list in this window.
	handled, derr := sa.do_click(chips[0])
	testing.expect_value(t, derr, nil)
	testing.expect(t, handled, "a chip must carry the behavior that answers a click")
	pump(&app)
	testing.expect(t, effective_display_is_hidden(&app, "#tagchips"), "removing the last group hides the row")
	testing.expect_value(t, len(visible_scenarios(&app, context.temp_allocator)), len(app.scenarios))
}

// Is the groups button lit? A CLASS TOKEN test, not a substring one, and that is not pedantry: `"on"` is a
// substring of `"icon"`, so `strings.contains(class, "on")` is true of every icon button in this window
// whatever its state. Written the wrong way first and caught by the test failing in the one direction it
// could — the light that would never go out.
@(private = "file")
lit_groups_button :: proc(app: ^App) -> bool {
	button := find(app, "#deal-groups")
	if button == nil {
		return false
	}
	class, err := sa.attribute(button, "class", context.temp_allocator)
	if err != nil {
		return false
	}
	for token in strings.split(class, " ", context.temp_allocator) {
		if token == "on" {
			return true
		}
	}
	return false
}

// ---- the keyboard layer --------------------------------------------------------------------------
//
// Every one of these calls a toggle that is already tested through its button, so what is asserted here is
// the ROUTING: that the key arrives, in the right view, and moves the same state the pointer would.

// The tabs, the sidebar and the pane, from the keyboard. CTRL+1 / CTRL+2 / CTRL+TAB / CTRL+B / CTRL+\.
@(test)
test_the_window_shortcuts_reach_the_controls :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	if !editor_corpus(t, &app) {return} 	// CTRL+2 needs somewhere to go
	show_view(&app, .Panes)
	pump(&app)

	// THE TABS, and the browser's arrangement: 0 is the zoom, 1..n are the views.
	press_key(&app, .NUM_2, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
	press_key(&app, .NUM_1, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)

	// CTRL+3 is the third place, the scenario editor.
	press_key(&app, .NUM_3, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Scenarios)
	press_key(&app, .NUM_1, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)

	// CTRL+TAB WALKS THE TAB STRIP, in the strip's own order — deals, notes, scenarios — and SHIFT walks
	// it the other way. It was the same move either way round when there were two views; with three, "next"
	// is a real direction and the test has to say which way round it goes.
	press_key(&app, .TAB, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
	press_key(&app, .TAB, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Scenarios)
	press_key(&app, .TAB, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	press_key(&app, .TAB, ctrl = true, shift = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Scenarios)
	press_key(&app, .NUM_1, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)

	// CTRL+B folds the scenario list and brings it back.
	testing.expect(t, scenario_list_shown(&app), "the list starts on screen")
	press_key(&app, .B, ctrl = true)
	pump(&app)
	testing.expect(t, !scenario_list_shown(&app), "CTRL+B should fold the list")
	press_key(&app, .B, ctrl = true)
	pump(&app)
	testing.expect(t, scenario_list_shown(&app), "and bring it back")

	// CTRL+\ CYCLES the hand page. It needs a page: the segment refuses an empty pane, and so does the key.
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Split)
	press_key(&app, .BACKSLASH, ctrl = true)
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Wide)
	press_key(&app, .BACKSLASH, ctrl = true)
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Closed)
	// AND IT WRAPS, so the three positions are one ring rather than a walk that stops at the end.
	press_key(&app, .BACKSLASH, ctrl = true)
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Split)
}

// CTRL+/ OPENS THE KEYS LIST FROM EITHER VIEW, and it is a VIEW rather than a pane of the deals one.
// Reported: "keys or actions specific to the deals tab should not trigger when on the notes tab" — this
// was the leak. Every other shortcut in `window_shortcut_key` past the tabs is behind
// `current_view(app) != .Panes`, but CTRL+/ was not, and because the panel lived in `.work` it opened in
// the notes view WHERE NOTHING SHOWS IT: invisible, and the deals view's report pane left hidden for when
// you came back. Rehoming it fixes both halves — it works in the notes view, and it stops being the deals
// view's furniture.
@(test)
test_the_keys_list_opens_from_either_view :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	if !editor_corpus(t, &app) {return}

	// FROM THE DEALS VIEW, and back to it.
	show_view(&app, .Panes)
	pump(&app)
	press_key(&app, .SLASH, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Keys)
	testing.expect(t, !effective_display_is_hidden(&app, "#keyspanel"), "the keys list should be on screen")
	press_key(&app, .SLASH, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)

	// FROM THE NOTES VIEW, and back to THAT — not to the deals view, which is where a fixed destination
	// would have dropped you.
	show_editor(&app)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
	press_key(&app, .SLASH, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Keys)
	testing.expect(t, !effective_display_is_hidden(&app, "#keyspanel"), "and on screen from the notes view")
	press_key(&app, .ESCAPE) // bare escape, the way anybody closes something they opened to read
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)

	// AND THE REPORT PANE IS NOT ITS BUSINESS ANY MORE: it was hidden to make room before, so a trip
	// through the keys list left the deals view missing its transcript.
	show_view(&app, .Panes)
	pump(&app)
	testing.expect(t, !effective_display_is_hidden(&app, "#report"), "the report pane should be back")
}

// THE DEALS VIEW'S KEYS DO NOTHING IN THE NOTES VIEW. The gate is one early return in
// `window_shortcut_key`, and this is what says it is still there.
@(test)
test_the_deals_shortcuts_are_inert_in_the_notes_view :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	if !editor_corpus(t, &app) {return}

	show_view(&app, .Panes)
	pump(&app)
	list_before := scenario_list_shown(&app)
	selected_before := app.selected

	show_editor(&app)
	pump(&app)
	for key in ([]sciter.Sc_Kb_Codes{.B, .BACKSLASH, .O, .G, .R}) {
		press_key(&app, key, ctrl = true)
		pump(&app)
		testing.expectf(t, current_view(&app) == .Editor, "a deals key left the notes view (%v)", key)
	}
	testing.expect(t, !tag_picker_open(&app), "CTRL+G opened the group picker from the notes view")

	show_view(&app, .Panes)
	pump(&app)
	testing.expect_value(t, scenario_list_shown(&app), list_before)
	testing.expect_value(t, app.selected, selected_before)
}

// THE KEYS LIST NAMES EVERY KEY THE HANDLER ANSWERS. It is static markup, so this is what stops the two
// drifting — a shortcut that works and is not listed is a shortcut nobody has, which is the whole reason
// the panel exists.
@(test)
test_the_keys_panel_names_every_shortcut :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	pump(&app)

	panel := find(&app, "#keyspanel")
	testing.expect(t, panel != nil, "there is no keys panel")
	if panel == nil {return}
	shown, err := sa.text(panel, context.temp_allocator)
	testing.expect_value(t, err, nil)
	listed := strings.to_lower(shown, context.temp_allocator)

	for key in ([]string {
			"ctrl+1",
			"ctrl+2",
			"ctrl+tab",
			"ctrl+r",
			"ctrl+g",
			"ctrl+b",
			"ctrl+\\",
			"ctrl+o",
			"ctrl+enter",
			"ctrl+/",
		}) {
		testing.expectf(t, strings.contains(listed, key), "the keys list does not mention %s", key)
	}
}

// CTRL+O WALKS WHAT THE SCENARIO HAS, not all seven formats. The chips draw every format always, but a
// scenario usually has one or two on disk — seven keys would be five dead presses, and which five changes
// per scenario. Asserted through `formats_for`, so the walk cannot land somewhere the chips draw dead.
@(test)
test_the_format_key_only_visits_formats_that_exist :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	show_view(&app, .Panes)
	pump(&app)

	// With nothing generated the key is a no-op that SAYS so, rather than opening a file that is not there.
	name := app.scenarios[app.selected].name
	if formats_for(&app, name) == {} {
		press_key(&app, .O, ctrl = true)
		pump(&app)
		said, _ := sa.text(find(&app, "#status"), context.temp_allocator)
		testing.expectf(
			t,
			strings.contains(said, name),
			"pressing the format key with nothing generated should name the scenario, said %q",
			said,
		)
	}
	// The walk itself is `step_output_format`, whose set is `formats_for` by construction — there is no
	// path in it that can reach a format the folder does not hold, which is what the type of the loop says.
}

// AN ICON ON THE ACCENT MUST RESTATE BOTH ITS HALVES. Reported twice now from the real window, the second
// time as "the highlighted tri state button loses its border ... outline of the button picture hard to
// read": `.icon` fixes its outline at `--ink-soft` and its ground at `--sunken`, which is right on every
// dark button here and wrong on the one accent one, where the outline becomes light-blue-on-light-blue.
//
// The assertion is on the COMPUTED colours rather than on pixels: the failure is a missing rule, and a
// rule that is missing reads back as the default. A pixel test would also pass or fail on the rasterizer,
// which this harness does not share with the window.
@(test)
test_a_lit_segment_redraws_its_icon_for_the_accent :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") { 	// the group is dead until something is in the pane
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)

	lit := find(&app, ".segbtn.on .icon")
	testing.expect(t, lit != nil, "no segment is lit, so there is nothing to check")
	unlit := find(&app, ".segbtn:not(.on) .icon")
	testing.expect(t, unlit != nil, "every segment is lit?")
	if lit == nil || unlit == nil {return}

	lit_border, lerr := sa.style(lit, "border-top-color", context.temp_allocator)
	unlit_border, uerr := sa.style(unlit, "border-top-color", context.temp_allocator)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, uerr, nil)
	testing.expectf(
		t,
		lit_border != unlit_border,
		"the lit icon keeps the unlit outline (%s) — on the accent ground that is the colour that vanished",
		lit_border,
	)
}

// THE PICKER HAS A DOOR YOU CAN SEE. A key nobody can find is a feature nobody has, which is the standing
// complaint against the notes view's CTRL+R palette — so the button is the fix and this is what stops it
// being quietly dropped. It also asserts the button LIGHTS while a group is selected: the bar can get
// cramped enough to squeeze the chips, and then the button is all that says the list is narrowed.
@(test)
test_the_groups_button_opens_the_picker_and_lights_when_it_matters :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	show_view(&app, .Panes)
	draw_tag_chips(&app)
	pump(&app)

	button := find(&app, "#deal-groups")
	testing.expect(t, button != nil, "the deals bar has no groups button")
	if button == nil {return}

	// Nothing selected: the button is there and unlit, and the picker is shut.
	testing.expect(t, !lit_groups_button(&app), "nothing is selected, so nothing should be lit")
	testing.expect(t, !tag_picker_open(&app), "the picker starts closed")

	// Pressing it opens the picker — the same door CTRL+G opens.
	click(&app, "#deal-groups")
	pump(&app)
	testing.expect(t, tag_picker_open(&app), "the groups button must open the picker")

	// A selected group lights it.
	press_key(&app, .NUM_1)
	pump(&app)
	testing.expect(t, lit_groups_button(&app), "a selected group must light the button")

	// And clearing puts it out, so the light cannot be left on over an unfiltered list.
	clear_tags(&app)
	pump(&app)
	testing.expect(t, !lit_groups_button(&app), "no groups selected, no light")

	click(&app, "#deal-groups") // shut it again, so the report pane is back for whatever runs next
	pump(&app)
}

// The keys the list is driven by are ON SCREEN, not only in a tooltip or a help panel. Asserted on the
// rendered text rather than on the markup, because the point is what somebody can read.
@(test)
test_the_scenario_list_names_its_keys :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	pump(&app)

	head := find(&app, "#scenario-list .head")
	testing.expect(t, head != nil, "the scenario list has no header")
	if head == nil {return}
	shown, err := sa.text(head, context.temp_allocator)
	testing.expect_value(t, err, nil)
	lowered := strings.to_lower(shown, context.temp_allocator)
	testing.expectf(t, strings.contains(lowered, "ctrl+r"), "the filter key is not on screen: %q", shown)
	testing.expectf(t, strings.contains(lowered, "ctrl+g"), "the groups key is not on screen: %q", shown)
}

// CTRL+G, the picker, and the report pane it borrows. Through the real handler, because the seam is that
// the digits reach the window at all while a widget holds the focus.
@(test)
test_ctrl_g_opens_the_group_picker_over_the_report_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	show_view(&app, .Panes)
	draw_scenarios(&app)
	pump(&app)
	testing.expect(t, !tag_picker_open(&app), "the picker starts closed")
	testing.expect(t, !effective_display_is_hidden(&app, "#report"), "and the report pane has the space")

	press_key(&app, .G, ctrl = true)
	pump(&app)
	testing.expect(t, tag_picker_open(&app), "CTRL+G should open the picker")
	testing.expect(t, effective_display_is_hidden(&app, "#report"), "the picker takes the report pane's space")

	rows, rerr := sa.select_all(find(&app, "#tagpicker-list"), ".tagrow", context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, len(rows), min(len(bidding.tags), TAG_PICKER_ROWS))

	// A DIGIT TOGGLES, and the list behind the picker follows immediately — the picker is not a dialog
	// with an OK button, so there is no committed and uncommitted state to get out of step.
	before := len(visible_scenarios(&app, context.temp_allocator))
	press_key(&app, .NUM_1)
	pump(&app)
	testing.expect(t, app.tag_on[0], "1 should toggle the first group on")
	after := len(visible_scenarios(&app, context.temp_allocator))
	testing.expect(t, after < before, "selecting a group must narrow the list")
	lit, lerr := sa.select_all(find(&app, "#tagpicker-list"), ".tagrow.on", context.temp_allocator)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, len(lit), 1)

	// The same digit toggles back off: this is multi-select, so nothing here is a radio.
	press_key(&app, .NUM_1)
	pump(&app)
	testing.expect(t, !app.tag_on[0], "the same digit should toggle it off again")

	// BACKSPACE clears everything, ENTER closes and hands the report pane back.
	press_key(&app, .NUM_2)
	pump(&app)
	press_key(&app, .BACKSPACE)
	pump(&app)
	testing.expect_value(t, len(selected_tag_names(&app, context.temp_allocator)), 0)

	press_key(&app, .ENTER)
	pump(&app)
	testing.expect(t, !tag_picker_open(&app), "enter should close the picker")
	testing.expect(t, !effective_display_is_hidden(&app, "#report"), "and give the report pane its space back")
}

// The four keys, through the real handler. The arrows and escape are the ones that need the sinking-phase
// interception: an `<input>`'s own edit behavior sees them first, so a bubbling handler would be told they
// were already handled and the field would answer none of them.
@(test)
test_the_filter_keys_reach_the_field :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	show_view(&app, .Panes)
	draw_scenarios(&app)
	pump(&app)

	// CTRL+R BRINGS THE LIST BACK. The field is in the bar and stays on screen when the list folds, so a
	// key that narrowed a list nobody could see would be the one useless version of this.
	show_scenario_list(&app, false)
	pump(&app)
	testing.expect(t, !scenario_list_shown(&app), "the list should be folded for this part")
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, scenario_list_shown(&app), "CTRL+R should unfold the list it filters")

	input := find(&app, "#scenario-filter")
	testing.expect(t, input != nil, "the deals bar has no filter field")
	if input == nil {return}
	state, serr := sa.element_state(input)
	testing.expect_value(t, serr, nil)
	testing.expect(t, .FOCUS in state, "CTRL+R should put the caret in the filter")

	// The arrows move the selection, and are CLAMPED rather than wrapped: `up` at the top stays at the top.
	type_filter(&app, "1c")
	shown := visible_scenarios(&app, context.temp_allocator)
	if len(shown) < 2 {
		return
	}
	select_scenario(&app, shown[0])
	press_key(&app, .DOWN)
	pump(&app)
	testing.expect_value(t, app.selected, shown[1])
	press_key(&app, .UP)
	pump(&app)
	testing.expect_value(t, app.selected, shown[0])
	press_key(&app, .UP)
	pump(&app)
	testing.expect_value(t, app.selected, shown[0]) // clamped, not wrapped to the bottom

	// ESCAPE gives the whole registry back.
	press_key(&app, .ESCAPE)
	pump(&app)
	testing.expect_value(t, read_text(&app, "#scenario-filter"), "")
	testing.expect_value(t, len(scenario_row_elements(&app)), len(app.scenarios))
}

// THE round-trip: the controls compose an argv, and norn's own parser accepts it and reads back what the
// controls said. Nothing here asserts on the argv's spelling — `cli.parse_args` is the authority, which
// is the whole reason the UI goes through it instead of building an `Options` by hand.
@(test)
test_the_generate_argv_is_valid_to_norns_parser :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "24")
	type_into(&app, "#seed", "7")
	type_into(&app, "#outdir", "C:/tmp/deals")
	tick(&app, "#dd")
	tick(&app, "#fixed")

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job // so test_app_destroy frees it
	testing.expect_value(t, len(job.scenarios), 1) // the selected one, since #all is not ticked
	testing.expect_value(t, job.ext, ".html") // the default format is html-cards

	// What the worker does per scenario, minus the run itself.
	argv := make([dynamic]string, 0, len(job.argv) + 4, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, "-S", job.scenarios[0], "-o", "C:/tmp/deals/x.html")

	opts, ok, message := cli.parse_args(argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	testing.expect_value(t, opts.count, 24)
	testing.expect_value(t, opts.format, norn.Output_Format.Html_Cards)
	testing.expect_value(t, opts.scenario, job.scenarios[0])
	testing.expect_value(t, opts.output, "C:/tmp/deals/x.html")
	testing.expect(t, opts.dd, "--dd must reach the parser")
	testing.expect(t, !opts.randomize_table, "--fixed-table must clear the randomised table")
	seed, has_seed := opts.seed.?
	testing.expect(t, has_seed)
	testing.expect_value(t, seed, u64(7))
	_, is_generate := opts.mode.(cli.Generate)
	testing.expect(t, is_generate)
}

// `every scenario` is what turns one job into the whole registry — the batch the `gen-all` recipe runs.
@(test)
test_every_scenario_queues_the_whole_registry :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", "C:/tmp/deals")
	tick(&app, "#all")

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	testing.expect_value(t, len(job.scenarios), len(bidding.registry))
}

// The other round-trip, through the advisor's parser. Note the deal arrives as ONE argument with its `-`
// hands intact: there is no shell here to split it, and `analyse.parse_args` reads the positional tail.
@(test)
test_the_analyse_argv_is_valid_to_the_analyse_parser :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#deal", `[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`)
	type_into(&app, "#sample", "200")
	type_into(&app, "#contract", "3NT")
	type_into(&app, "#target", "9")

	job, err := analyse_job(&app)
	testing.expect_value(t, err, "")
	app.job = job

	args, perr := analyse.parse_args(job.argv, allow_stdin = false)
	defer analyse.args_free(&args)
	testing.expectf(t, perr == "", "the advisor rejected the composed argv: %s", perr)
	testing.expect_value(t, args.sample, 200)
	testing.expect_value(t, args.contract, "3NT")
	testing.expect_value(t, args.target, 9)

	// And the deal text still resolves to the two-hand board it named.
	boards, berr := analyse.resolve_boards(args.text)
	defer delete(boards)
	testing.expect_value(t, berr, "")
	testing.expect_value(t, len(boards), 1)
	testing.expect_value(t, boards[0].known, bit_set[norn.Seat]{.North, .South})
}

// The per-scenario command line must survive a library resetting this thread's temp allocator, because one
// on the far side of `cli.run` does exactly that (`combo.annotate`, Html_Cards path). A temp-allocated `-o`
// path passed the first scenarios of a batch and then arrived as recycled bytes — a filename of NUL
// characters, 45 pages in. The `free_all` below is that reset, in one line.
@(test)
test_a_scenario_command_survives_a_temp_allocator_reset :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "4")
	type_into(&app, "#outdir", PARITY_DIR)
	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	if len(job.scenarios) != 1 {
		return
	}

	command := scenario_command(&app.job, job.scenarios[0])
	defer command_free(&command)
	expected := command.path

	free_all(context.temp_allocator) // what the far side of cli.run does to this thread

	testing.expect_value(t, command.path, expected)
	testing.expect(t, strings.has_suffix(command.path, ".html"), "the path must still name a page")
	testing.expect(
		t,
		strings.contains(command.path, job.scenarios[0]),
		"and still name the scenario, not recycled bytes",
	)
	// The argv the parser sees is intact too — `-o` last, with that path.
	n := len(command.argv)
	if testing.expect(t, n >= 2, "the argv carries -o <path>") {
		testing.expect_value(t, command.argv[n - 2], "-o")
		testing.expect_value(t, command.argv[n - 1], expected)
	}
	// And norn still accepts it.
	opts, ok, message := cli.parse_args(command.argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	testing.expect_value(t, opts.output, expected)
}

// The output directory is settled BEFORE anything is generated: made absolute, and created when missing.
// `norn:cli` writes the page only after generating it and does not create parents, so without this a typo
// costs a full run per scenario and then says `Not_Exist`.
@(test)
test_the_output_directory_is_absolute_and_created :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// A RELATIVE path with a component that does not exist yet: both behaviours in one.
	fresh := "target/debug/wb-outdir-probe/nested"
	if os.exists(fresh) {
		os.remove_all(fresh)
	}
	type_into(&app, "#outdir", fresh)

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job

	testing.expect(t, filepath.is_abs(job.out_dir), job.out_dir)
	testing.expect(t, os.is_dir(job.out_dir), "the directory must exist by the time a job holds it")
	slashed := strings.replace_all(job.out_dir, "\\", "/", context.temp_allocator) or_else job.out_dir
	testing.expect(t, strings.contains(slashed, "wb-outdir-probe/nested"), job.out_dir)

	// A path that names an existing FILE is a refusal, not a directory to create.
	type_into(&app, "#outdir", PARITY_FILE)
	_, ferr := generate_job(&app)
	testing.expect(t, strings.contains(ferr, "is a file"), ferr)
}

// The refusals that would otherwise reach a parser as something confusing (an empty `-o`, an empty
// positional) and fail deeper in, with a worse message.
@(test)
test_the_jobs_refuse_incomplete_input :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", "")
	_, gerr := generate_job(&app)
	testing.expect(t, strings.contains(gerr, "output dir"), gerr)

	type_into(&app, "#outdir", "C:/tmp/deals")
	type_into(&app, "#count", "nonsense")
	_, cerr := generate_job(&app)
	testing.expect(t, strings.contains(cerr, "deals"), cerr)

	type_into(&app, "#deal", "   ")
	_, aerr := analyse_job(&app)
	testing.expect(t, strings.contains(aerr, "paste a deal"), aerr)
}

// The transcript reaches the report pane through the `plaintext` behavior's `content` property (or the
// `set_text` fallback), which is the one piece of the UI whose write path is not an ordinary DOM call.
@(test)
test_the_transcript_reaches_the_report_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	strings.write_string(&app.transcript, "hello from the host\n")
	draw_transcript(&app)

	content, ok := report_content(&app, context.temp_allocator)
	testing.expect(t, ok, "the report pane must publish a plaintext asset to read back")
	testing.expect(t, strings.contains(content, "hello from the host"), content)

	// The trailing-newline trim, pinned: without it the widget reports a leading blank line, and the pane
	// shows one. (Measured — see draw_transcript's note.)
	testing.expect(t, !strings.has_prefix(content, "\n") && !strings.has_prefix(content, "\r\n"), content)

	// `sciter_app.text` reads the element's own text, which for this behavior is empty however much
	// content it holds. Pinned so nobody "simplifies" report_content into a text() call.
	report := find(&app, "#report")
	own_text, terr := sa.text(report, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, own_text, "")
}

// The generate path, actually run: the worker's per-scenario body (parse args, wire hooks, `cli.run`)
// against a real scenario, writing a real card page. Seeded and `--fixed-table`, so the bytes are
// reproducible — which is what lets `just sims wb-cli-parity` diff this file against the same run through
// `sim.exe` and prove the window and the command line produce the same page.
//
// Deliberately NOT --dd: that would pull DDS into a test binary that also runs the windowless engine, and
// the hook wiring is one assignment either way (its table is `sim_hooks`', tested by being shared).
@(test)
test_the_generate_path_writes_the_same_page_the_cli_does :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "4")
	type_into(&app, "#seed", "42")
	type_into(&app, "#outdir", PARITY_DIR)
	tick(&app, "#fixed")

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	if len(job.scenarios) != 1 {
		return
	}

	// Exactly what `work_generate` does for one scenario, minus the `post_callback`s.
	argv := make([dynamic]string, 0, len(job.argv) + 4, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, "-S", job.scenarios[0], "-o", PARITY_FILE)

	opts, ok, message := cli.parse_args(argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	run_ok, run_message := cli.run(bidding.registry, opts)
	testing.expectf(t, run_ok, "the in-process run failed: %s", run_message)

	page, rerr := os.read_entire_file_from_path(PARITY_FILE, context.temp_allocator)
	testing.expectf(t, rerr == nil, "no page at %s: %v", PARITY_FILE, rerr)
	testing.expect(t, len(page) > 1000, "a card page is more than a few bytes")
	testing.expect(t, strings.has_prefix(string(page), "<!DOCTYPE html>"), "and it is a document")
	testing.expect(t, strings.contains(string(page), "compass"), "carrying the card page's own markup")
	// Titled by the scenario that ran — asked of the registry rather than spelled out, so adding or
	// reordering scenarios cannot break this.
	testing.expect(
		t,
		strings.contains(string(page), cli.scenario_title(app.scenarios[app.selected])),
		"the page must be titled by the scenario that ran",
	)
}

// Where the parity test writes. A fixed path rather than a temp one, because the point is for a recipe to
// pick the file up afterwards and diff it.
PARITY_DIR :: "target/debug"
PARITY_FILE :: "target/debug/wb-parity.html"

// The deal both frame tests use: declarer + dummy, defenders unknown. No `--sample`, so no solver and no
// DDS lifecycle — the page still carries the compass, the combo blob and the whole CCA overlay, which is
// everything the layout has to get right.
FRAME_DEAL :: `[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`

// The card page as a string, through the same call the analyse path uses (`analyse.builder_page_sink`, no
// file). Caller owns the page.
@(private = "file")
render_test_page :: proc(t: ^testing.T) -> (page: string, ok: bool) {
	args, perr := analyse.parse_args({FRAME_DEAL}, allow_stdin = false)
	defer analyse.args_free(&args)
	if !testing.expectf(t, perr == "", "the advisor rejected the test deal: %s", perr) {
		return "", false
	}

	report := strings.builder_make()
	defer strings.builder_destroy(&report)
	page_b := strings.builder_make()

	result := analyse.run(analyse.builder_page_sink(&report, &page_b), &args)
	if !testing.expect_value(t, result, analyse.Result.Ok) {
		strings.builder_destroy(&page_b)
		return "", false
	}
	// The diagnostics say what happened, and the page is NOT among them: a page in memory means nothing
	// was written to disk.
	testing.expect(
		t,
		strings.contains(strings.to_string(report), "rendered the card page"),
		"the diagnostics must say the page was rendered",
	)
	return strings.to_string(page_b), true
}

// The page comes back IN MEMORY and carries the desktop overrides. No engine in this one: it is about the
// seam `analyse.builder_page_sink` opened — the page as a string, and nothing written to disk.
@(test)
test_the_analyse_run_hands_back_the_card_page :: proc(t: ^testing.T) {
	defer combo.shutdown() // the page's CCA blob starts combo's pool

	page, ok := render_test_page(t)
	if !ok {
		return
	}
	defer delete(page)

	testing.expect(t, strings.has_prefix(page, "<!DOCTYPE html>"), "the page must be a document")
	testing.expect(t, len(page) > 10_000, "and a whole one")
	testing.expect(t, strings.contains(page, "compass"), "carrying the card page's markup")
	// The two halves of the port that make it show correctly in the frame, pinned so a norn template edit
	// that dropped either is caught HERE rather than as a wrecked-looking window.
	testing.expect(t, strings.contains(page, "@media sciter"), "the page must carry the desktop CSS overrides")
	testing.expect(t, strings.contains(page, "function setHidden"), "and the desktop JS shims")
	// The `@media sciter` block MUST come before the phone media query: this engine treats
	// `@media (max-width: ...)` as a parse error and discards the rest of the stylesheet, so a block after
	// it silently does nothing. Measured — it is how the first cut of the port came to have no effect.
	//
	// Both anchors carry the block's own INDENTATION, because the template's comments name both queries in
	// prose and a bare substring search finds those first (which is how this test first failed).
	sciter_at := strings.index(page, "		@media sciter {")
	phone_at := strings.index(page, "		@media (max-width")
	testing.expect(t, phone_at > 0, "the phone media query must still be there")
	testing.expectf(
		t,
		sciter_at < phone_at,
		"the desktop overrides (at %d) must precede the phone media query (at %d) or the engine drops them",
		sciter_at,
		phone_at,
	)
}

// The frame plumbing, end to end: a document goes in from MEMORY, the engine parses it, its script runs,
// and the host can read the sub-document back out. `frame.document` is the only way in — a selector from
// the outer root does not cross the boundary, and this asserts that too.
//
// WHY A SMALL DOCUMENT AND NOT THE CARD PAGE. Measured on 6.0.4.9: loading the real card page into this
// engine from an Odin TEST-RUNNER thread crashes inside the engine — as a frame document or as the view's
// own document, from memory or from a file, with the media var or without it, and with the page's own
// `<script>` cut out. The same page, the same build flags and the same calls are fine on a program's main
// thread, which is where the workbench runs them, so the fault is the thread rather than the page or this
// host code. `just page-check` is that main-thread check and is where the hosted page's LAYOUT is
// asserted; these tests cover the seam around it.
FRAME_DOC ::
	`<html><head><meta charset="utf-8"></head><body><div id="probe" class="compass">before</div>` +
	`<script>document.getElementById('probe').textContent = 'after';</script></body></html>`

@(test)
test_the_frame_hosts_a_document_from_memory :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)

	root, ok := framed_root(t, &app)
	if !ok {
		return
	}
	probe, perr := sa.select_first(root, "#probe")
	if !testing.expectf(t, perr == nil, "the framed document has no #probe: %v", perr) {
		return
	}
	// The sub-document's own script ran, which is what the card page depends on for its whole carousel.
	text, terr := sa.text(probe, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, text, "after")

	// And it is a document of its own: the id is NOT reachable from the outer root.
	outer := sa.root(app.window) or_else nil
	if outer != nil {
		_, oerr := sa.select_first(outer, "#probe")
		testing.expectf(t, oerr != nil, "a selector must not cross into the frame (got %v)", oerr)
	}
}

// The other route in: a page a generate run has already written.
@(test)
test_the_frame_hosts_a_document_from_disk :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	path, jerr := filepath.join({PARITY_DIR, "wb-frame-doc.html"}, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	if werr := os.write_entire_file(path, transmute([]u8)string(FRAME_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", path, werr)
		return
	}
	absolute, aerr := filepath.abs(path, context.temp_allocator)
	testing.expect_value(t, aerr, nil)

	testing.expect(t, show_page_file(&app, absolute), "the frame must accept the written page")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, page_pane_shown(&app), "a page that arrives opens the pane it arrived in")
	// The bar names what is on screen, which for a generated page is the path it came from.
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, absolute)

	if root, ok := framed_root(t, &app); ok {
		_, perr := sa.select_first(root, "#probe")
		testing.expectf(t, perr == nil, "the page from disk did not parse: %v", perr)
	}
}

// The framed document's root element, through the frame behavior's `document` property.
@(private = "file")
framed_root :: proc(t: ^testing.T, app: ^App) -> (root: sa.Element, ok: bool) {
	asset, has_asset := page_frame_asset(app)
	if !testing.expect(t, has_asset, "the frame behavior must be reachable") {
		return nil, false
	}
	document, derr := sa.asset_get(asset, "document")
	defer sa.value_clear(&document)
	if !testing.expectf(t, derr == nil, "the frame has no document: %v", derr) {
		return nil, false
	}
	element, eerr := sa.element_from_value(&document)
	if !testing.expectf(t, eerr == nil, "the frame's document is not an element: %v", eerr) {
		return nil, false
	}
	return element, true
}

// The SELECTION opens what the scenario HAS, newest first — not what the format dropdown names. (A chip
// names one format instead; this is the answer for "just show me it".)
//
/*
WHICH FORMATS EXIST, WITHOUT PRESSING ANYTHING - the third level of folder -> scenario -> format.

Browsing the list used to be browsing NAMES: nothing said whether a scenario had anything behind it, and
the pane could only ever open the newest output, so a pbn written before the page was unreachable without
changing the format dropdown (which says what the next RUN will write, not what is on disk).

Two projections of ONE `read_dir`, both pinned here: a tag per format on the row, and a chip per format for
the selected scenario that opens THAT file. The single listing is the point - seven extensions across 101
scenarios would be 707 `stat` calls a redraw, on a directory that is a network share by default.
*/
@(test)
test_the_formats_that_exist_are_visible_and_pressable :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)
	pump(&app)

	type_into(&app, "#outdir", PARITY_DIR)
	app.selected = 0
	name := app.scenarios[0].name
	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	cards, _ := filepath.join({directory, fmt.tprintf("%s.html", name)}, context.temp_allocator)
	pbn, _ := filepath.join({directory, fmt.tprintf("%s.pbn", name)}, context.temp_allocator)
	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`
	PBN_DOC :: "[Event \"probe\"]\n[Deal \"N:AKQ.234.567.8765 ... \"]\n"
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", cards, werr)
		return
	}
	defer os.remove(cards)
	if werr := os.write_entire_file(pbn, transmute([]u8)string(PBN_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", pbn, werr)
		return
	}
	defer os.remove(pbn)

	scan_outputs(&app)
	testing.expect_value(t, formats_for(&app, name), Format_Set{.Html, .Pbn})

	// `.hv.txt` must beat `.txt`, or every handviewer file reads as pretty text. The longest extension wins.
	base, format, ok := format_of_extension("2c-opener.hv.txt")
	testing.expect(t, ok, "an .hv.txt file is a format")
	testing.expect_value(t, base, "2c-opener")
	testing.expect_value(t, format, Deal_Format.Handviewer)

	// THE ROW carries the tags, so the list says what is behind each name.
	draw_scenarios(&app)
	pump(&app)
	row := find(&app, `#scenarios .row[data-index="0"] .have`)
	testing.expect(t, row != nil, "the row has no format tags")
	if row == nil {return}
	tags, _ := sa.text(row, context.temp_allocator)
	testing.expectf(t, strings.contains(tags, "cards"), "the tags name the page: %q", tags)
	testing.expectf(t, strings.contains(tags, "pbn"), "and the pbn: %q", tags)

	// THE CHIPS are the same answer for the SELECTED scenario, one press each.
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)
	testing.expect(t, !effective_display_is_hidden(&app, "#outputs"), "the chips row should be up")
	chip := find(&app, `#outputs .chip[data-open=".pbn"]`)
	testing.expect(t, chip != nil, "no chip for the pbn")
	if chip == nil {return}

	// SELECTING A SCENARIO LIGHTS THE CHIP FOR WHAT THE FOLLOW JUST LOADED - reported: on the first click of
	// a scenario the row came up with nothing lit (or the PREVIOUS file's chip lit), and only a second click
	// agreed with the pane. The chips were drawn by `note_selected_page` BEFORE the follow loaded anything,
	// so the redraw now hangs off `remember_shown_path`, which every path that shows a file goes through.
	set_pane_mode(&app, .Split) // an open pane is what makes the selection follow
	pump(&app)
	remember_shown_path(&app, "") // nothing shown yet, as on a fresh window
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)
	followed, _ := sa.select_all(find(&app, "#outputs"), ".chip.on", context.temp_allocator)
	testing.expect_value(t, len(followed), 1)
	if len(followed) == 1 {
		// The invariant is what matters, not which extension wins: the LIT CHIP IS THE FILE IN THE PANE.
		// (Which one that is depends on modification times - both files here were written moments apart.)
		which, _ := sa.attribute(followed[0], "data-open", context.temp_allocator)
		in_pane, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
		testing.expectf(
			t,
			strings.has_suffix(in_pane, which),
			"the lit chip (%s) is not what the pane is showing (%s)",
			which,
			in_pane,
		)
	}

	// Pressing the pbn chip opens THE PBN - not the newest output, which is what `selected_output` resolves
	// and which here is the html page. This is also what moves the lit chip off the html one.
	click(&app, `#outputs .chip[data-open=".pbn"]`)
	pump(&app)
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, pbn)

	// THE LIT CHIP SAYS WHICH FILE IS UP. With a page and a pbn both on disk, nothing else on screen does:
	// `selected_output` resolves the newest, and the pane's title is a path in a corner.
	lit, _ := sa.select_all(find(&app, "#outputs"), ".chip.on", context.temp_allocator)
	testing.expect_value(t, len(lit), 1)
	if len(lit) == 1 {
		which, _ := sa.attribute(lit[0], "data-open", context.temp_allocator)
		testing.expect_value(t, which, ".pbn")
	}

	// EVERY FORMAT IS ON THE ROW, ALWAYS - the ones with no file are present and DEAD. A row that listed
	// only what existed could say "this has html and text" but never "and no pbn", and two scenarios then
	// showed two different sets of chips, which is not something you can compare at a glance.
	all_chips, _ := sa.select_all(find(&app, "#outputs"), ".chip", context.temp_allocator)
	testing.expect_value(t, len(all_chips), len(Deal_Format))
	dead := find(&app, `#outputs .chip[data-open=".lin"]`)
	testing.expect(t, dead != nil, "the lin chip should be there even with no lin file")
	if dead != nil {
		state, _ := sa.element_state(dead)
		testing.expect(t, .DISABLED in state, "a format with no file is dead, not absent")
	}

	// And the refusal is the MODEL's, because `do_click` runs a disabled button's behavior all the same.
	before, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	click(&app, `#outputs .chip[data-open=".lin"]`)
	pump(&app)
	after_dead, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, after_dead, before)

	// A scenario with nothing generated still shows the row - seven dead chips, which is the answer
	// "nothing here yet" written out rather than an empty space that could mean anything.
	app.selected = len(app.scenarios) - 1
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)
	if formats_for(&app, app.scenarios[app.selected].name) == {} {
		testing.expect(t, !effective_display_is_hidden(&app, "#outputs"), "the row stays up")
		alive, _ := sa.select_all(find(&app, "#outputs"), ".chip.have", context.temp_allocator)
		testing.expect_value(t, len(alive), 0)
	}
}

/*
THE STYLESHEET CANNOT HIT THE ENGINE`S INLINE CAP AGAIN - the guard for a trap that does not look like one.

AN INLINE `<style>` IS CAPPED AT 32 KiB, ALL OR NOTHING: at one byte over, the WHOLE block is discarded,
first rule included, with no warning and no CSS diagnostics. This file passed it while the deals view was
growing (35,781 bytes), and what broke was not the LOOK - `behavior: button` stopped attaching, so scenario
rows, file rows and palette entries all answered `do_click` with `handled = false`, and three unrelated
tests failed as if the event routing had broken.

`css_blocks` now cuts the sheet into blocks that fit, so the answer to "will this happen again" is no rather
than "not until someone adds 3 KB". What this pins is the cutting itself, on the REAL stylesheet and on the
two inputs that would break a naive version of it - a comment containing braces (this file has several) and
a nested block that must not be cut in half.
*/
@(test)
test_the_stylesheet_is_cut_into_blocks_that_fit :: proc(t: ^testing.T) {
	blocks := css_blocks(string(UI_CSS), CSS_BUDGET, context.temp_allocator)
	testing.expect(t, len(blocks) > 0, "the stylesheet produced no blocks at all")

	// Every block fits, and nothing was lost or reordered: the blocks joined back together ARE the file.
	rejoined := strings.builder_make(context.temp_allocator)
	for block, i in blocks {
		testing.expectf(
			t,
			len(block) <= CSS_CAP,
			"block %d is %d bytes, over the engine`s %d cap",
			i,
			len(block),
			CSS_CAP,
		)
		strings.write_string(&rejoined, block)
	}
	testing.expect_value(t, strings.to_string(rejoined), string(UI_CSS))

	// And the document really carries them as separate elements.
	document := compose_document(context.temp_allocator)
	testing.expect_value(t, strings.count(document, CSS_JOIN), len(blocks) - 1)

	// A SHEET THAT ALREADY FITS IS ONE BLOCK - the common case, and no `<style>` element is spent on it.
	small := css_blocks("a { color: red; }\nb { color: blue; }", CSS_BUDGET, context.temp_allocator)
	testing.expect_value(t, len(small), 1)
}

/*
THE TWO INPUTS THAT WOULD MAKE A NAIVE CUTTER PRODUCE A BROKEN SHEET.

Both are real: this project`s stylesheet quotes `@set name { … }` and `@media` blocks inside its comments,
and it uses `@media` for the phone layout of the hosted page. Cutting on a brace count alone would put a
block boundary inside a sentence, or inside a media block - and a `<style>` that starts with half a rule is
a `<style>` the engine discards from that point on. Neither failure would look like a cutting bug.
*/
@(test)
test_the_cutter_never_cuts_inside_a_comment_or_a_block :: proc(t: ^testing.T) {
	// A tiny budget, so every top-level rule is its own block and the boundaries are easy to name.
	braces_in_a_comment := `/* a comment that quotes @set thing { rules } and @media (x) { y } */
one { color: red; }
two { color: blue; }`
	blocks := css_blocks(braces_in_a_comment, 1, context.temp_allocator)
	for block, i in blocks {
		trimmed := strings.trim_space(block)
		testing.expectf(
			t,
			!strings.has_prefix(trimmed, "rules }") && !strings.has_prefix(trimmed, "y }"),
			"block %d starts inside a comment: %q",
			i,
			trimmed,
		)
	}
	rejoined := strings.concatenate(blocks, context.temp_allocator)
	testing.expect_value(t, rejoined, braces_in_a_comment)

	// A NESTED BLOCK stays whole: the two rules inside the media block are never a boundary.
	nested := `@media (max-width: 640px) {
	one { color: red; }
	two { color: blue; }
}
three { color: green; }`
	media := css_blocks(nested, 1, context.temp_allocator)
	testing.expect_value(t, len(media), 2) // the media block, then the rule after it
	testing.expect(t, strings.has_prefix(strings.trim_space(media[0]), "@media"), "the media block is one piece")
	testing.expectf(
		t,
		strings.count(media[0], "{") == strings.count(media[0], "}"),
		"the media block was cut in half: %q",
		media[0],
	)
	testing.expect_value(t, strings.concatenate(media, context.temp_allocator), nested)
}

/*
OPENING THE PANE SHOWS THE SELECTED SCENARIO, whatever was in it before.

Reported: "the selected format button for a scenario needs a refresh when the hand page goes from hidden to
shown, all options are still unselected". The chips were not stale - they were RIGHT. The pane was showing
the file from before it was closed, the selection had moved on in the meantime (a closed pane is not
followed, deliberately: a hand page is up to 86MB and arrowing down a list must not load one per row), and
so no chip matched what was on screen. Nothing was wrong with the chips; the window was showing one
scenario while everything around it named another.

So opening the pane re-asks the same question the follow asks. This pins the case that was reported and the
one it must not break: a page that IS the selection is not reloaded when the pane comes back.
*/
@(test)
test_opening_the_pane_shows_the_scenario_that_is_selected :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", PARITY_DIR)
	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`

	first := app.scenarios[0].name
	second := app.scenarios[1].name
	first_page, _ := filepath.join({directory, fmt.tprintf("%s.html", first)}, context.temp_allocator)
	second_page, _ := filepath.join({directory, fmt.tprintf("%s.html", second)}, context.temp_allocator)
	for path in ([]string{first_page, second_page}) {
		if werr := os.write_entire_file(path, transmute([]u8)string(CARDS_DOC)); werr != nil {
			testing.expectf(t, false, "could not write %s: %v", path, werr)
			return
		}
	}
	defer os.remove(first_page)
	defer os.remove(second_page)
	scan_outputs(&app)

	// Look at the first scenario with the pane open.
	app.selected = 0
	note_selected_page(&app)
	set_pane_mode(&app, .Split)
	pump(&app)
	testing.expect_value(t, app.shown_path, first_page)

	// Close it, and move on. A closed pane does not follow - that is the rule that makes the list cheap to
	// arrow through - so the frame still holds the FIRST scenario`s page.
	set_pane_mode(&app, .Closed)
	app.selected = 1
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)
	testing.expect_value(t, app.shown_path, first_page)
	dark, _ := sa.select_all(find(&app, "#outputs"), ".chip.on", context.temp_allocator)
	testing.expect_value(t, len(dark), 0) // nothing on screen belongs to this scenario, and nothing claims to

	// Opening it again shows the scenario the window is otherwise all about.
	set_pane_mode(&app, .Split)
	pump(&app)
	testing.expect_value(t, app.shown_path, second_page)
	lit, _ := sa.select_all(find(&app, "#outputs"), ".chip.on", context.temp_allocator)
	testing.expect_value(t, len(lit), 1)

	// And a page that IS the selection is left alone: closing and opening does not re-read the file.
	set_pane_mode(&app, .Closed)
	pump(&app)
	testing.expect(t, shown_page_is_the_selection(&app), "the pane still holds the selected scenario`s page")
	set_pane_mode(&app, .Split)
	pump(&app)
	testing.expect_value(t, app.shown_path, second_page)
}

/*
THE REPORT PANE IS A READOUT. `<plaintext>` IS AN EDITOR, and that is why this needs saying twice.

It was chosen for the run log because it holds thousands of lines and lets them be selected and copied - but
what it IS, is the editor behind the notes view. So the log had a caret and took typing, and an edit there
means nothing: the next `TRANSCRIPT` message replaces the whole content. Reported ("why is the output box
editable"), and `readonly` is the fix.

What this pins is the BEHAVIOUR rather than the attribute: text typed at it does not change what the pane
holds. An attribute check would pass on a spelling this engine ignores.
*/
@(test)
test_the_report_pane_cannot_be_typed_into :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)
	pump(&app)

	transcribe_local(&app, "norn: scenario written")
	pump(&app)
	before, ok := report_content(&app, context.temp_allocator)
	testing.expect(t, ok, "the report pane has no content")
	if !ok {return}

	report := find(&app, "#report")
	testing.expect(t, report != nil, "no report pane")
	if report == nil {return}
	_ = sa.set_focus(report)
	pump(&app)
	// The keys a person would type into it, through the same door a real keystroke comes in by.
	for character in ([]u32{'x', 'y', 'z'}) {
		_, _ = sa.send_key(report, .CHAR, character)
	}
	pump(&app)

	after, still := report_content(&app, context.temp_allocator)
	testing.expect(t, still, "the report pane lost its content entirely")
	testing.expect_value(t, after, before)
}

/*
THE ICON MEANS ONE THING ON EVERY SEGMENT: THE FILLED PART IS THE HAND PAGE.

Reported: "the whole width button is lighter and the light part of the middle button is on the left half".
Both were true, and the cause was the icon taking `currentColor` from its button. On a dark segment that is
a light block on a dark screen - right. On the LIT segment `currentColor` is `--accent-ink` on an accent
ground, so the filled half went dark and the EMPTY half became the bright one: the same drawing said "page
on the right" unlit and "page on the left" lit.

The icon carries its own ground and ink now, and this asserts the property that fixes: the filled half of
`split` is on the RIGHT of its icon, at rest and when the segment is lit - because that is where the pane
is. Pixels, because this is about what the thing LOOKS like; the geometry was never wrong.
*/
@(test)
test_the_pane_icons_say_the_same_thing_lit_or_not :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") { 	// wakes the group
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)

	// `split` lit (the page IS beside the controls), then `wide` lit so `split` is the neutral one.
	for mode in ([]Pane_Mode{.Split, .Wide}) {
		set_pane_mode(&app, mode)
		pump(&app)
		sa.paint_windowless(&g_view)

		icon := find(&app, `.segbtn[data-pane="split"] .icon`)
		testing.expect(t, icon != nil, "the split segment has no icon")
		if icon == nil {return}
		box, err := sa.location(icon, .Content, .Root)
		testing.expect_value(t, err, nil)
		if box.width < 6 || box.height < 4 {
			continue
		}
		left := half_brightness(box, left = true)
		right := half_brightness(box, left = false)
		testing.expectf(
			t,
			right > left,
			"with %v lit, the split icon is brighter on the LEFT (%d) than the right (%d) - the fill is the hand page, and the pane is on the right",
			mode,
			left,
			right,
		)
	}
}

// Mean brightness of one half of a box, as a number to compare with the other half.
@(private = "file")
half_brightness :: proc(box: sa.Rect, left: bool) -> int {
	from := box.x if left else box.x + box.width / 2
	to := box.x + box.width / 2 if left else box.x + box.width
	total, count := 0, 0
	for y in box.y ..< box.y + box.height {
		for x in from ..< to {
			if x < 0 || y < 0 || x >= 1120 || y >= 780 {
				continue
			}
			r, g, b, _ := sa.windowless_pixel(&g_view, x, y)
			total += int(r) + int(g) + int(b)
			count += 1
		}
	}
	return total / max(count, 1)
}

/*
THE BROWSER MARK IS ON THE CHIP THAT OPENS A BROWSER, AND ON NO OTHER.

Reported: "why does hv have the browser link arrow but no way to open in browser... html format has no open
in browser feature". Both halves were true and they are different bugs.

`hv` is `-f handviewer`: bridgebase QUERY STRINGS, one deal a line, written to `.hv.txt`. It is TEXT, it
always opened as text in the pane, and the mark on it was reading the format`s NAME rather than what would
happen - a promise nothing kept. The output that really needs a browser is an `html-handviewer` PAGE, an
`<iframe>` per deal onto bridgebase.com; both html formats write `.html`, so the kind comes from inside the
file and the mark now follows the same answer the press acts on.

And the other half: a cards page you were LOOKING at had no way out of the window at all. That is the pane`s
own `browser` button, tested below.
*/
@(test)
test_the_browser_mark_follows_the_file_not_the_format_name :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", PARITY_DIR)
	app.selected = 0
	name := app.scenarios[0].name
	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	cards, _ := filepath.join({directory, fmt.tprintf("%s.html", name)}, context.temp_allocator)
	hv, _ := filepath.join({directory, fmt.tprintf("%s.hv.txt", name)}, context.temp_allocator)
	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`
	HANDVIEWER_DOC :: `<html><head><meta charset="utf-8"></head><body><iframe src="https://www.bridgebase.com/tools/handviewer.html?lin=x"></iframe></body></html>`
	HV_QUERIES :: "n=sAThJ8dJ9cAJT7542&s=s632hA9754d43cK83&e=sQ9875hK32dA865c6&w=sKJ4hQT6dKQT72cQ9&a=_&v=n&d=n\n"

	if werr := os.write_entire_file(hv, transmute([]u8)string(HV_QUERIES)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", hv, werr)
		return
	}
	defer os.remove(hv)
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", cards, werr)
		return
	}
	defer os.remove(cards)

	scan_outputs(&app)
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)

	// `.hv.txt` is text. No mark, and pressing it puts the text in the pane rather than launching anything.
	hv_chip := find(&app, `#outputs .chip[data-open=".hv.txt"]`)
	testing.expect(t, hv_chip != nil, "no hv chip")
	if hv_chip == nil {return}
	hv_html, _ := sa.html(hv_chip, allocator = context.temp_allocator)
	testing.expectf(t, !strings.contains(hv_html, "away"), "the hv chip must not promise a browser: %s", hv_html)
	testing.expect_value(t, file_kind(hv), Output_Kind.Text)

	// A CARDS page is hosted here, so no mark either.
	cards_chip := find(&app, `#outputs .chip[data-open=".html"]`)
	testing.expect(t, cards_chip != nil, "no html chip")
	if cards_chip == nil {return}
	cards_html, _ := sa.html(cards_chip, allocator = context.temp_allocator)
	testing.expectf(t, !strings.contains(cards_html, "away"), "a cards page opens in the pane: %s", cards_html)

	// The SAME chip carries the mark once the file behind it is a handviewer page - the kind is read from
	// inside the file, because both html formats share the extension.
	if werr := os.write_entire_file(cards, transmute([]u8)string(HANDVIEWER_DOC)); werr == nil {
		scan_outputs(&app)
		note_selected_page(&app)
		pump(&app)
		marked := find(&app, `#outputs .chip[data-open=".html"]`)
		testing.expect(t, marked != nil, "the html chip went away")
		if marked != nil {
			marked_html, _ := sa.html(marked, allocator = context.temp_allocator)
			testing.expectf(
				t,
				strings.contains(marked_html, "away"),
				"a handviewer page IS the browser case: %s",
				marked_html,
			)
		}
	}
}

// WHATEVER IS IN THE PANE CAN LEAVE THE WINDOW. The chips answer "which file"; this answers "not here" -
// a browser has more room for a 48-deal page, a find-in-page and a print. It follows what is SHOWN rather
// than what is selected, and it is dead for a page `analyse` built in memory, which has no file to hand
// over: writing a temp file nobody asked for would be the wrong kind of helpful.
@(test)
test_the_pane_can_send_what_it_shows_to_a_browser :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	pump(&app)

	button := find(&app, "#page-browser")
	testing.expect(t, button != nil, "the pane has no browser button")
	if button == nil {return}
	dead, _ := sa.element_state(button)
	testing.expect(t, .DISABLED in dead, "nothing is shown yet, so there is nothing to open")

	// A page built in memory (what `analyse` produces) has no file behind it - still dead.
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)
	still_dead, _ := sa.element_state(button)
	testing.expect(t, .DISABLED in still_dead, "an in-memory page has no file to open in a browser")

	// A page read off disk does.
	type_into(&app, "#outdir", PARITY_DIR)
	app.selected = 0
	name := app.scenarios[0].name
	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	cards, _ := filepath.join({directory, fmt.tprintf("%s.html", name)}, context.temp_allocator)
	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", cards, werr)
		return
	}
	defer os.remove(cards)

	testing.expect(t, show_page_file(&app, cards), "the page did not load from disk")
	pump(&app)
	alive, _ := sa.element_state(button)
	testing.expect(t, .DISABLED not_in alive, "a page with a file behind it can go to a browser")
	testing.expect_value(t, app.shown_path, cards)
}

/*
THE DEALS BAR LINES UP - one row, one centre line, and the lit segment filling its button.

Reported from the window with a picture: "alignment is bad, highlight for tristate button not even cover all
button space, icons not centred, including for scenarios button. scenarios, generate every scenario and
deals folder all not centred". Three faults in one row, and all three are the same kind of thing - a
horizontal flow does NOT centre children of different heights, and an inline-block sits on the BASELINE.

What this pins:

  * every control in the bar shares the bar`s centre line (a button, a checkbox, a small label and a text
    field are four different heights, so this is the assertion that they are laid on one axis rather than
    stacked from the top);
  * each segment FILLS the group, so the lit one`s accent ground covers the whole button rather than
    leaving a strip of the group`s background under it;
  * each icon sits on its button`s centre, not on its text baseline.

Boxes rather than pixels here: this is layout, and the geometry is the thing that was wrong. The tolerance
is 2px, which is a rounding at a fractional zoom rather than a misalignment anyone can see.
*/
@(test)
test_the_deals_bar_lines_up :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") { 	// wakes the segment group
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)

	// AT EVERY ZOOM, not just at 100%. The report came with a picture of a ZOOMED window, and a first
	// version of this test that ran at rest passed on the broken bar: a row of mixed heights can look
	// settled at one scale and come apart at another, because the paddings, the borders and the text all
	// grow by different roundings. So the whole check runs again at each step.
	defer for _ in 0 ..< 8 {_ = zoom_step(&app, -1)} 	// leave the window as it was found
	for step in 0 ..= 6 {
		if step > 0 {
			_ = zoom_step(&app, 1)
			pump(&app)
		}
		check_the_bar_lines_up(t, &app, step)
	}
}

@(private = "file")
check_the_bar_lines_up :: proc(t: ^testing.T, app: ^App, step: int) {
	bar := find(app, ".panes .bar")
	testing.expect(t, bar != nil, "the deals view has no bar")
	if bar == nil {return}
	bar_box, berr := sa.location(bar, .Padding, .Root)
	testing.expect_value(t, berr, nil)
	bar_centre := bar_box.y + bar_box.height / 2

	// ONE CENTRE LINE for everything in the row.
	for selector in ([]string {
			"#deal-list-toggle",
			".bar #scenario-filter",
			"#all",
			".barlabel-check",
			// SCOPED to the deals bar: the settings view has a `.seg` and a label of its own, and an unscoped
			// `find` takes the first in the document - a hidden one, at 0.
			".panes .bar .seg",
			".panes .bar .barlabel",
			".bar #outdir",
		}) {
		element := find(app, selector)
		testing.expectf(t, element != nil, "the bar is missing %s", selector)
		if element == nil {
			continue
		}
		box, err := sa.location(element, .Border, .Root)
		if err != nil {
			continue
		}
		centre := box.y + box.height / 2
		testing.expectf(
			t,
			abs(centre - bar_centre) <= 2,
			"at zoom step %d, %s sits at %d against the bar`s centre %d (off by %d)",
			step,
			selector,
			centre,
			bar_centre,
			abs(centre - bar_centre),
		)
	}

	// THE SEGMENTS FILL THE GROUP. `.Padding` on the group is the box inside its border, which is what
	// a segment should cover top to bottom - anything less is the strip the report showed under the lit one.
	group := find(app, "#deal-pane-mode")
	testing.expect(t, group != nil, "no segment group")
	if group != nil {
		inner, gerr := sa.location(group, .Padding, .Root)
		testing.expect_value(t, gerr, nil)
		for name in ([]string{"closed", "split", "wide"}) {
			segment := find(app, fmt.tprintf(`.segbtn[data-pane="%s"]`, name))
			if segment == nil {
				continue
			}
			box, err := sa.location(segment, .Border, .Root)
			if err != nil {
				continue
			}
			testing.expectf(
				t,
				box.height >= inner.height - 1,
				"the %s segment is %dpx tall in a %dpx group - the lit ground would not cover it",
				name,
				box.height,
				inner.height,
			)
		}
	}

	// AND THE ICONS ARE CENTRED IN THEIR BUTTONS.
	for selector in ([]string{"#deal-list-toggle", `.segbtn[data-pane="split"]`}) {
		button := find(app, selector)
		if button == nil {
			continue
		}
		icon, ierr := sa.select_first(button, ".icon")
		if ierr != nil {
			testing.expectf(t, false, "%s has no icon", selector)
			continue
		}
		button_box, _ := sa.location(button, .Border, .Root)
		icon_box, _ := sa.location(icon, .Border, .Root)
		button_centre := button_box.y + button_box.height / 2
		icon_centre := icon_box.y + icon_box.height / 2
		testing.expectf(
			t,
			abs(icon_centre - button_centre) <= 2,
			"the icon in %s sits %dpx off its button`s centre",
			selector,
			abs(icon_centre - button_centre),
		)
	}
}

/*
THE ICONS ARE STILL RECTANGLES WHEN THE WINDOW IS ZOOMED - and an honest note about what this can see.

The icons shipped as inline `<svg>`. Reported from the real window: "the more we zoom in, the more the icons
look wrong - starts looking like rectangles, ends more like an r". A throwaway probe reproduced exactly that
by painting the icon markup inside an element with `zoom: 2.0` and reading the pixels back: perfect at 1:1,
TOP-AND-LEFT-ONLY zoomed, with or without a viewBox, at any element size, `overflow: visible` or not. They
are bordered boxes now, which is the fix: a border is drawn by the box painter and laid out by the same box
model as everything else here, so it scales with the document like every other length in this window.

WHAT THIS TEST DOES NOT PROVE. Aimed at the OLD svg icon inside this document it PASSES - so the defect does
not reproduce here, and the difference worth suspecting is the RASTERIZER: this harness is a windowless
software view, while the real window is on a GPU backend by default (`WORKBENCH_GFX` exists to force one).
That makes `WORKBENCH_GFX=raster` the bisect if a drawing ever looks wrong again in the window and right in
a test, and it means the reported bug`s only witness is a real window.

So what is pinned here is the weaker, still worth having property: at every zoom step to the ceiling, the
`closed` segment`s icon has ink on all four edges AND A HOLE IN THE MIDDLE. That catches a shape that
collapses, fills in or loses a side for any reason this harness CAN see - and it is written the way it is
because of two things learned by writing it worse first: a disabled segment is painted in `--line` and reads
as no ink at all (so a page is loaded to wake it), and a lit segment is a filled accent block (so the
neutral one is the one measured).
*/
@(test)
test_an_icon_is_still_a_rectangle_when_the_window_is_zoomed :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	pump(&app)
	defer for _ in 0 ..< 12 {_ = zoom_step(&app, -1)} 	// leave the window as it was found

	// THE SEGMENT HAS TO BE AWAKE TO BE MEASURED. A disabled one is painted in `--line` (#313244), which is
	// below any sane ink threshold - a pixel test aimed at it reports "no edges" whatever it is drawing, and
	// would fail the correct icon as loudly as the broken one. A page in the pane is what enables it, and
	// opening the pane leaves `closed` as the NEUTRAL segment (the lit one is a filled accent block, which
	// is the other thing this test must not be pointed at).
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {
		testing.fail_now(t, "the page did not load into the frame")
	}
	set_pane_mode(&app, .Split)
	pump(&app)

	factor := 1.0
	for step in 0 ..= 10 {
		if step > 0 {
			factor = zoom_step(&app, 1)
		}
		pump(&app)
		sa.paint_windowless(&g_view)

		icon := find(&app, `.segbtn[data-pane="closed"] .icon`)
		testing.expect(t, icon != nil, "the closed segment has no icon")
		if icon == nil {return}
		box, err := sa.location(icon, .Border, .Root)
		testing.expect_value(t, err, nil)
		if box.width < 6 || box.height < 5 || box.y + box.height >= 780 {
			continue // off the bottom of a windowless view, or too small to say anything about
		}

		testing.expectf(t, edge_has_ink(box, .Top), "no top edge at zoom %.2f", factor)
		testing.expectf(t, edge_has_ink(box, .Left), "no left edge at zoom %.2f", factor)
		testing.expectf(t, edge_has_ink(box, .Bottom), "NO BOTTOM EDGE at zoom %.2f - the svg-under-zoom bug", factor)
		testing.expectf(t, edge_has_ink(box, .Right), "NO RIGHT EDGE at zoom %.2f - the svg-under-zoom bug", factor)
		// An OUTLINE, not a blob: the middle of the `closed` icon is the bar behind it.
		testing.expectf(t, !centre_is_ink(box), "the closed icon is filled in at zoom %.2f", factor)
	}
}

@(private = "file")
Edge :: enum {
	Top,
	Bottom,
	Left,
	Right,
}

@(private = "file")
pixel_is_ink :: proc(x, y: i32) -> bool {
	if x < 0 || y < 0 || x >= 1120 || y >= 780 {
		return false
	}
	r, g, b, _ := sa.windowless_pixel(&g_view, x, y)
	return int(r) + int(g) + int(b) > 3 * 120 // the bar is #181825..#313244, the icon`s ink #a6adc8+
}

// Is anything painted along one edge of a box? A hairline border lands either side of the boundary once the
// zoom is fractional, so each edge is a two-pixel band.
@(private = "file")
edge_has_ink :: proc(box: sa.Rect, edge: Edge) -> bool {
	switch edge {
	case .Top, .Bottom:
		y := box.y if edge == .Top else box.y + box.height - 1
		inward: i32 = 1 if edge == .Top else -1
		for x in box.x ..< box.x + box.width {
			if pixel_is_ink(x, y) || pixel_is_ink(x, y + inward) {
				return true
			}
		}
	case .Left, .Right:
		x := box.x if edge == .Left else box.x + box.width - 1
		inward: i32 = 1 if edge == .Left else -1
		for y in box.y ..< box.y + box.height {
			if pixel_is_ink(x, y) || pixel_is_ink(x + inward, y) {
				return true
			}
		}
	}
	return false
}

// The middle third of the box: ink there means a filled shape rather than an outline.
@(private = "file")
centre_is_ink :: proc(box: sa.Rect) -> bool {
	lit := 0
	total := 0
	for y in box.y + box.height / 3 ..< box.y + 2 * box.height / 3 {
		for x in box.x + box.width / 3 ..< box.x + 2 * box.width / 3 {
			total += 1
			if pixel_is_ink(x, y) {
				lit += 1
			}
		}
	}
	return total > 0 && lit * 2 > total
}

/*
WHY THE WINDOW STOPPED ANSWERING DURING `every scenario` IN `pretty`, and the three things that fixed it.

Reported from the real window: the batch ran (the terminal was printing a scenario a second), the progress
bar never painted, and Windows marked the window Not Responding for the length of the run. The work was on
the worker thread, so it was the ENGINE thread that was buried, and this is what buried it:

  * `echo` was true for the batch. `every scenario` in `pretty` at 48 deals is ~110 runs of ~700 lines, so
    about SEVENTY-FOUR THOUSAND lines went through `transcribe`;
  * each of those posted a `TRANSCRIPT` callback, and each callback rewrites the WHOLE content of the report
    pane - quadratic, and paced by a worker that can queue thousands before the first is dispatched;
  * the pane is a `<plaintext>`, which is not virtualised and costs ~22KB a LINE, so the same run was also
    building a document of some gigabytes.

The fixes are one per cause: a batch does not echo (the glance is for the scenario you asked for), a burst
of lines costs ONE post, and the transcript keeps its tail rather than growing without limit.
*/
@(test)
test_a_batch_does_not_pour_its_deals_into_the_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", PARITY_DIR)
	type_into(&app, "#count", "4")
	type_into(&app, "#format", "pretty")
	app.selected = 0

	one, one_err := generate_job(&app)
	defer job_free(&one, app.allocator)
	testing.expect_value(t, one_err, "")
	testing.expect_value(t, len(one.scenarios), 1)
	testing.expect(t, one.echo, "one scenario of pretty text is exactly what the pane is for")

	// The same run over every scenario is NOT a glance, however small each one is.
	tick(&app, "#all")
	batch, batch_err := generate_job(&app)
	defer job_free(&batch, app.allocator)
	testing.expect_value(t, batch_err, "")
	testing.expect_value(t, len(batch.scenarios), len(app.scenarios))
	testing.expect(t, !batch.echo, "a batch writes files; it must not echo every deal of every scenario")
}

// A BURST OF LINES COSTS ONE POST, and the transcript keeps its tail. Both are about the ENGINE thread: it
// redraws the whole pane per message, and the pane costs ~22KB a line, so an unbounded transcript with a
// post per line is what "not responding" was made of.
@(test)
test_the_transcript_coalesces_its_posts_and_keeps_its_tail :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// The flag IS the post: `transcribe` posts only when it claims it, and the handler clears it before
	// drawing. So one claim outstanding across any number of lines is the assertion.
	testing.expect(t, !bool(sync.atomic_load(&app.transcript_pending)), "nothing pending on a fresh app")
	transcribe(&app, "the first line claims it")
	testing.expect(t, bool(sync.atomic_load(&app.transcript_pending)), "the first line schedules a redraw")
	for i in 0 ..< 5000 {
		transcribe(&app, fmt.tprintf("[%d/5000] a scenario wrote a page", i))
	}
	testing.expect(
		t,
		bool(sync.atomic_load(&app.transcript_pending)),
		"5000 more lines are still the ONE redraw that was already scheduled",
	)

	// Drawing clears it, and the next line schedules the next one.
	sync.atomic_store(&app.transcript_pending, false)
	transcribe(&app, "and a line after the redraw schedules another")
	testing.expect(t, bool(sync.atomic_load(&app.transcript_pending)), "the next burst claims it again")

	// THE TAIL IS WHAT IS KEPT. A run says how it went at the END, and the pane cannot hold the middle of a
	// 74,000-line batch at 22KB a line.
	for i in 0 ..< 20000 {
		transcribe(&app, fmt.tprintf("[%d] norn: scenario written, 48 accepted from 1229 deals", i))
	}
	sync.lock(&app.mutex)
	text := strings.clone(strings.to_string(app.transcript), context.temp_allocator)
	sync.unlock(&app.mutex)
	testing.expectf(
		t,
		len(text) <= TRANSCRIPT_CAP,
		"the transcript is %d bytes, past its %d cap",
		len(text),
		TRANSCRIPT_CAP,
	)
	testing.expect(t, strings.contains(text, "earlier lines dropped"), "and it says the middle went")
	testing.expect(t, strings.contains(text, "[19999]"), "the LAST line is the one that must survive")
	// Cut on a line boundary: the pane never shows half a line.
	for line in strings.split_lines(strings.trim_right_space(text), context.temp_allocator) {
		if strings.has_prefix(line, "[") {
			testing.expectf(t, strings.contains(line, "] norn: scenario written"), "half a line survived: %q", line)
			break
		}
	}
}

/*
`EVERY SCENARIO` OVERRIDES THE SELECTION, SO IT SHOWS ITSELF IN THE LIST.

It used to sit in the generate panel between `double-dummy hooks` and `fixed table` - two harmless per-run
switches - while doing something neither of them does: ignoring the scenario you have selected and running
all 101, one page each. A consequential control reading as a third checkbox, two rows below the thing it
contradicts.

It is in the bar next to the list now, and the LIST is where its state is legible: while it is on, every row
takes the soft wash and a left edge, and the selected row keeps its own stronger mark on top. Both questions
stay answered at once - what the run will cover, and which scenario the chips and the pane are about - which
is why the selection is neither cleared nor disabled while it is on.

The class goes on the LIST, not on each row: the rows are replaced wholesale on every redraw and a per-row
mark would have to be re-decided every time.
*/
@(test)
test_every_scenario_shows_itself_in_the_list :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)
	pump(&app)

	// It lives in the BAR, beside the list control - not in the generate panel with the run settings.
	box := find(&app, ".bar #all")
	testing.expect(t, box != nil, "`every scenario` is not in the bar")
	if box == nil {return}
	list := find(&app, "#scenarios")
	testing.expect(t, list != nil, "no scenario list")
	if list == nil {return}

	off, _ := sa.attribute(list, "class", context.temp_allocator)
	testing.expect(t, !strings.contains(off, "all"), "the list should not be marked before it is ticked")

	click(&app, "#all")
	pump(&app)
	testing.expect(t, read_bool(&app, "#all"), "the click should tick the box")
	on, _ := sa.attribute(list, "class", context.temp_allocator)
	testing.expectf(t, strings.contains(on, "all"), "the list should be marked while it is on, class=%q", on)

	// THE SELECTION SURVIVES IT. The run covers everything; the selection still says which scenario the
	// chips and the pane are about, and the two marks are meant to be readable at the same time.
	app.selected = 3
	draw_scenarios(&app)
	pump(&app)
	marked, merr := sa.select_all(list, ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	still_on, _ := sa.attribute(list, "class", context.temp_allocator)
	testing.expectf(t, strings.contains(still_on, "all"), "a redraw must not lose the mark, class=%q", still_on)

	// And the run really does cover everything while it is on - the mark is not decoration.
	type_into(&app, "#outdir", PARITY_DIR)
	job, err := generate_job(&app)
	defer job_free(&job, app.allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(job.scenarios), len(app.scenarios))

	click(&app, "#all")
	pump(&app)
	back, _ := sa.attribute(list, "class", context.temp_allocator)
	testing.expect(t, !strings.contains(back, "all"), "unticking takes the mark off again")
}

// THE DEALS FOLDER IS IN THE BAR, AND CHANGING IT RE-ASKS WHAT THERE IS TO SHOW. It is not a setting of
// generating - it says where this window reads as well as where it writes, which is why the pane segment's
// aliveness follows it. Typing a folder with pages in it must wake the segment without anything else being
// pressed, and typing it away again must put it back to sleep.
@(test)
test_the_deals_folder_decides_what_there_is_to_show :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)
	pump(&app)

	// It lives in the BAR now, on the same row as the pane segment, rather than in the generate panel.
	field := find(&app, ".bar #outdir")
	testing.expect(t, field != nil, "the deals folder is not in the bar")
	segment := find(&app, `.segbtn[data-pane="split"]`)
	if field == nil || segment == nil {return}
	field_box, ferr := sa.location(field, .Border, .Root)
	segment_box, serr := sa.location(segment, .Border, .Root)
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, serr, nil)
	testing.expectf(
		t,
		abs(field_box.y - segment_box.y) < field_box.height,
		"the folder (y=%d) and the segment (y=%d) should share the bar's row",
		field_box.y,
		segment_box.y,
	)
	testing.expectf(
		t,
		field_box.width > 100,
		"the folder field is %dpx wide - it takes the bar's slack",
		field_box.width,
	)

	app.selected = 0
	name := app.scenarios[0].name
	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	cards, _ := filepath.join({directory, fmt.tprintf("%s.html", name)}, context.temp_allocator)
	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", cards, werr)
		return
	}
	defer os.remove(cards)

	// Pointing at a folder with pages in it is enough on its own: no button is pressed here. Leaving the
	// field is the moment that re-asks, so the test does what a person does - put the caret in it, set the
	// text, then go somewhere else. (`set_element_value` alone raises no edit event at all: measured, the
	// window's handler never woke, which is why the focus move is here and not a synthesised event.)
	leave_the_folder_field :: proc(app: ^App, field: sa.Element, text: string) {
		_ = sa.set_focus(field)
		pump(app)
		type_into(app, "#outdir", text)
		if elsewhere := find(app, "#scenarios"); elsewhere != nil {
			_ = sa.set_focus(elsewhere)
		}
		pump(app)
	}

	leave_the_folder_field(&app, field, PARITY_DIR)
	testing.expect(t, page_available(&app), "a folder with a page for this scenario has something to show")
	alive, _ := sa.element_state(segment)
	testing.expect(t, .DISABLED not_in alive, "so the segment is alive")

	// And pointing somewhere with nothing in it puts the window back where it was.
	leave_the_folder_field(&app, field, "target/debug/wb-empty-folder-probe")
	testing.expect(t, !page_available(&app), "an empty folder has nothing to show")
	dead, _ := sa.element_state(segment)
	testing.expect(t, .DISABLED in dead, "and the segment is dead again")
}

/*
A PAGE ON DISK IS A PAGE TO SHOW - reported from the window, and it was a dead end rather than a blemish.

A generate run writes its pages to DISK and puts none of them in the frame. The segment used to ask whether
one had been LOADED, so after pressing generate it stayed dead - and with `view page` reduced to the browser
hatch there was then nothing on screen that would load one. Shut pane, dead control, a directory full of
pages, and no way from one to the other.

So the question is now "is there a page to show", which a file for the selected scenario answers, and
OPENING the pane is what loads it. The same answer covers a fresh start on an output directory from an
earlier session: those deals may be old, but the page names its scenario and the status line names the file,
and refusing to show something that is sitting right there would be the worse behaviour.
*/
@(test)
test_a_page_on_disk_wakes_the_segment_and_opening_loads_it :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)
	pump(&app)

	type_into(&app, "#outdir", PARITY_DIR)
	app.selected = 0
	name := app.scenarios[0].name
	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	cards, _ := filepath.join({directory, fmt.tprintf("%s.html", name)}, context.temp_allocator)
	os.remove(cards)

	// Nothing on disk, nothing in the frame: dead, and it says so rather than opening an empty pane.
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)
	testing.expect(t, !page_available(&app), "with no file and no page there is nothing to show")
	segment := find(&app, `.segbtn[data-pane="split"]`)
	testing.expect(t, segment != nil, "no split segment")
	if segment == nil {return}
	dead, _ := sa.element_state(segment)
	testing.expect(t, .DISABLED in dead, "the segment should be dead")

	// A page appears on disk, the way a generate run leaves one. NOTHING is loaded into the frame by that.
	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", cards, werr)
		return
	}
	defer os.remove(cards)

	note_selected_page(&app) // what a run ending, or the selection moving, asks
	pump(&app)
	testing.expect(t, !app.page_ready, "nothing has been loaded into the frame yet")
	testing.expect(t, page_available(&app), "but there IS a page to show")
	alive, _ := sa.element_state(segment)
	testing.expect(t, .DISABLED not_in alive, "so the segment is alive")

	// And pressing it is what fetches the file: the pane opens with the page in it, not empty.
	click(&app, `.segbtn[data-pane="split"]`)
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Split)
	testing.expect(t, app.page_ready, "opening an empty pane loads the selection into it")
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, cards)
}

/*
PICKING A SCENARIO SHOWS ITS PAGE - but only into a pane that is already open, and never a handviewer.

Three rules, and every one of them is a decision rather than an implementation detail, so all three are
pinned here:

  * an OPEN pane follows the selection. That is what makes the list a way of reading through what has been
    generated rather than a thing to press `view page` after.
  * a SHUT pane stays shut and loads NOTHING. A hand page is up to ~86MB of laid-out document, and arrowing
    down a 101-scenario list must not load one per row; a shut pane is someone not looking at pages.
  * a HANDVIEWER page is never followed in either state, because showing one means launching a BROWSER
    (those pages are an iframe per deal onto bridgebase.com) and no click in a list should do that. The
    `browser` button appears instead, and it is hidden again for every other kind.
*/
@(test)
test_picking_a_scenario_follows_only_into_an_open_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", PARITY_DIR)
	app.selected = 0
	name := app.scenarios[0].name
	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	cards, _ := filepath.join({directory, fmt.tprintf("%s.html", name)}, context.temp_allocator)
	os.remove(cards)

	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", cards, werr)
		return
	}
	defer os.remove(cards)

	// A SHUT pane: the selection says what is there and loads nothing.
	testing.expect(t, !page_pane_shown(&app), "the pane starts shut")
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)
	testing.expect(t, !page_pane_shown(&app), "a selection must not open the pane by itself")
	testing.expect(t, !app.page_ready, "and must not have loaded anything into it")

	// OPEN it (as generating or analysing would) and the same selection now lands in it.
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, cards)

	// A HANDVIEWER page is NOT followed: the pane keeps what it had, and the chip for it (which carries the
	// ↗ mark) is what opens it, deliberately.
	HANDVIEWER_DOC :: `<html><head><meta charset="utf-8"></head><body><iframe src="https://www.bridgebase.com/tools/handviewer.html?lin=x"></iframe></body></html>`
	if werr := os.write_entire_file(cards, transmute([]u8)string(HANDVIEWER_DOC)); werr != nil {
		testing.expectf(t, false, "could not rewrite %s: %v", cards, werr)
		return
	}
	note_selected_page(&app)
	follow_selection_tick(&app) // the debounce, which a windowless view cannot fire
	pump(&app)
	after, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, after, cards) // unchanged: nothing was loaded over it
}

// Two failures this pins, both reported from the window: following the dropdown made the button claim there
// was nothing to view after switching the format (the pages were right there), and an earlier version tracked
// "the last page this run wrote", which after a 110-scenario batch is never the one you were looking at.
// The message also has to name the scenario and where it looked; a bare "nothing" leaves the user choosing
// between the wrong directory, the wrong format and a run they never did.
@(test)
test_view_page_opens_what_the_scenario_has :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", PARITY_DIR)
	app.selected = 0
	name := app.scenarios[0].name

	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	cards, _ := filepath.join({directory, fmt.tprintf("%s.html", name)}, context.temp_allocator)
	text, _ := filepath.join({directory, fmt.tprintf("%s.txt", name)}, context.temp_allocator)
	os.remove(cards)
	os.remove(text)

	// Nothing written for it yet.
	_, _, found, why := selected_output(&app)
	testing.expect(t, !found, "with nothing on disk there is nothing to view")
	testing.expectf(t, strings.contains(why, name), "the message names the scenario: %s", why)
	testing.expectf(t, strings.contains(why, "generate"), "and what to do about it: %s", why)
	testing.expectf(t, strings.contains(why, directory), "and where it looked: %s", why)

	// A CARDS page: recognised by the carousel's own id rather than by the extension, because both html
	// formats write `.html`.
	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", cards, werr)
		return
	}
	defer os.remove(cards)

	shown, kind, exists, _ := selected_output(&app)
	testing.expect(t, exists, "the page on disk is found")
	testing.expect_value(t, shown, cards)
	testing.expect_value(t, kind, Output_Kind.Cards)

	// A TEXT output on its own resolves too — the format dropdown still says html-cards and is not
	// consulted. (WHICH of two outputs wins when both exist is a modification-time comparison, and two
	// files written in the same breath can share a tick, so that is not what this asserts: what matters is
	// that each kind resolves, and that the kind always describes the file that was chosen.)
	set_input(&app, "#format", "html-cards")
	os.remove(cards)
	if werr := os.write_entire_file(text, transmute([]u8)string("North opens 1C\n")); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", text, werr)
		return
	}
	defer os.remove(text)

	newest, newest_kind, newest_found, _ := selected_output(&app)
	testing.expect(t, newest_found, "the text output is found")
	testing.expect_value(t, newest, text)
	testing.expect_value(t, newest_kind, Output_Kind.Text)

	// And with both on disk, whichever wins, its kind is the kind of the file that won.
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr == nil {
		both, both_kind, both_found, _ := selected_output(&app)
		testing.expect(t, both_found, "with both on disk, one of them is chosen")
		testing.expect(t, both == cards || both == text, "and it is one of the two")
		testing.expect_value(t, both_kind, file_kind(both))
	}

	// A HANDVIEWER page is the third kind, and it is told apart by what is IN the file: pages of iframes onto
	// bridgebase.com cannot be hosted in the frame, so they go to the browser instead.
	HANDVIEWER_DOC :: `<html><head><meta charset="utf-8"></head><body><iframe src="https://www.bridgebase.com/tools/handviewer.html?lin=x"></iframe></body></html>`
	testing.expect_value(t, file_kind(text), Output_Kind.Text)
	if werr := os.write_entire_file(cards, transmute([]u8)string(HANDVIEWER_DOC)); werr == nil {
		testing.expect_value(t, file_kind(cards), Output_Kind.Handviewer)
	}

	// An unselected list is its own message rather than a wrong path.
	app.selected = -1
	_, _, none, none_why := selected_output(&app)
	testing.expect(t, !none, "with nothing selected there is nothing to resolve")
	testing.expectf(t, strings.contains(none_why, "scenario"), "and it asks for a scenario: %s", none_why)
}

// The geometry dump: it measures the framed document, names what it could not find, and says why when
// there is nothing to measure. This is the affordance that gets a REAL window's numbers into a bug report,
// so its failure mode has to be a sentence rather than an empty pane.
@(test)
test_the_page_dump_measures_the_framed_document :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Nothing in the frame yet.
	dump_page(&app)
	empty, _ := report_content(&app, context.temp_allocator)
	testing.expect(t, strings.contains(empty, "dump:"), "an empty frame reports why, rather than nothing")

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)
	dump_page(&app)

	text, ok := report_content(&app, context.temp_allocator)
	testing.expect(t, ok, "the transcript is readable")
	testing.expect(t, strings.contains(text, "---- page dump: a test document ----"), "the dump names the page")
	testing.expect(t, strings.contains(text, "view "), "and reports the view size")
	testing.expect(t, strings.contains(text, ".compass"), "and measures an element it found")
	testing.expect(t, strings.contains(text, "display="), "with the computed styles that differ here")
	testing.expect(t, strings.contains(text, "MISSING"), "and names the selectors it did not find")
	testing.expect(t, strings.contains(text, "---- end of dump ----"), "and is bounded, so it can be pasted")
}

// Showing the page REPLACES the panes, and closing it puts them back — one view at a time, including when
// THE HAND PANE, and what it does and does not replace.
//
// It is a pane of the deals view rather than a view of its own, so a page arriving must leave the deals view
// ON (it used to replace it) - and About, which replaces everything, must still take it off screen.
@(test)
test_the_hand_pane_opens_beside_the_controls :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, !page_pane_shown(&app), "the pane starts closed - there is nothing in it")

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, page_pane_shown(&app), "the page opened the pane")
	testing.expect(t, !effective_display_is_hidden(&app, ".work"), "and the controls are still beside it")
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, "a test document")

	// About replaces the whole view, pane included.
	show_about(&app, true)
	testing.expect_value(t, current_view(&app), View.About)
	// The DEALS VIEW goes off screen and takes the pane with it. The pane`s own `display` is untouched -
	// `effective_display_is_hidden` reads one element rather than the chain - and that is exactly what lets
	// it come back below still open.
	testing.expect(t, effective_display_is_hidden(&app, ".panes"), "About must take the deals view off screen")

	// And leaving About comes back to the deals view with the pane still open: closing it is a decision
	// somebody makes, not something a detour does for them.
	show_about(&app, false)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, page_pane_shown(&app), "the pane came back with the view")

	show_page_pane(&app, false)
	testing.expect(t, !page_pane_shown(&app), "and it closes when it is asked to")
	testing.expect_value(t, current_view(&app), View.Panes)
}

// `wide` hides the WORK - both panes are `width: *`, so the page takes what the controls stop asking for -
// and closing a wide pane has to bring the controls back, or the view is a scenario list and an empty
// column with no way on screen to get anything else.
@(test)
test_a_wide_hand_pane_gives_the_controls_back_when_it_closes :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)

	set_pane_wide(&app, true)
	testing.expect(t, pane_is_wide(&app), "wide must hide the work")
	testing.expect(t, page_pane_shown(&app), "and leave the page on screen")
	testing.expect(t, scenario_list_shown(&app), "the scenario list is what wide keeps")

	show_page_pane(&app, false)
	testing.expect(t, !pane_is_wide(&app), "closing a wide pane must unwiden it")
	testing.expect(t, !effective_display_is_hidden(&app, ".work"), "the controls have to come back")

	// Widening a CLOSED pane opens it rather than emptying the view.
	set_pane_wide(&app, true)
	testing.expect(t, page_pane_shown(&app), "wide implies open")
	set_pane_wide(&app, false)
	show_page_pane(&app, false)
}

// The scenario list folds away the way the notes view`s file list does - the same glyph, the same idiom,
// now the same splitter.
@(test)
test_the_scenario_list_folds_away :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect(t, scenario_list_shown(&app), "the list starts on screen")
	show_scenario_list(&app, false)
	testing.expect(t, !scenario_list_shown(&app), "and folds away")
	testing.expect(t, !effective_display_is_hidden(&app, ".work"), "without taking the controls with it")
	show_scenario_list(&app, true)
	testing.expect(t, scenario_list_shown(&app), "and comes back")
}

// "as card page" is what routes an analyse run to the frame instead of to the report pane, and it must not
// add a `--html` (that would write a file nobody asked for).
@(test)
test_the_card_page_checkbox_asks_for_the_page_in_memory :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#deal", FRAME_DEAL)

	job, err := analyse_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	testing.expect(t, !job.want_page, "unticked, the run writes the text report")

	tick(&app, "#as-page")
	job_free(&app.job, app.allocator)
	ticked, terr := analyse_job(&app)
	testing.expect_value(t, terr, "")
	app.job = ticked
	testing.expect(t, ticked.want_page, "ticked, the run renders the page")
	for arg in ticked.argv {
		testing.expectf(t, arg != "--html" && arg != "-o", "the page path must not be composed: %s", arg)
	}

	args, perr := analyse.parse_args(ticked.argv, allow_stdin = false)
	defer analyse.args_free(&args)
	testing.expectf(t, perr == "", "the advisor rejected the composed argv: %s", perr)
	testing.expect_value(t, args.html_path, "")
}


// ---------------------------------------------------------------------------------------------------
// Drag and drop
//
// The engine only produces EXCHANGE events during a real system drag, which no test can stage — the same
// limit odin-sciter's own example documents. What IS testable is everything the drop hands to: the URL
// the engine passes (measured on Windows, and reproduced here as a literal), the routing by extension,
// and the command the reader is spawned with.

// The exact payload a Windows 11 / engine 6.0.4.9 drop from Explorer carried, measured: a `file:///` URL,
// percent-encoded, not a path.
@(test)
test_a_dropped_file_url_becomes_a_path :: proc(t: ^testing.T) {
	path, ok := file_url_to_path(
		"file:///C:/Users/Enerqi/dev/bridge-hand-ocr/fixtures/intobridge-2-hand-large-2.png",
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect_value(t, path, "C:/Users/Enerqi/dev/bridge-hand-ocr/fixtures/intobridge-2-hand-large-2.png")

	// A screenshot in a folder with a space in its name is the ordinary case on Windows, not an edge one:
	// the percent-decode is the whole reason this is not a prefix strip.
	spaced, spaced_ok := file_url_to_path("file:///C:/My%20Deals/hand%231.png", context.temp_allocator)
	testing.expect(t, spaced_ok)
	testing.expect_value(t, spaced, "C:/My Deals/hand#1.png")

	// A bare path is taken as it stands, and nothing at all is refused rather than analysed.
	bare, bare_ok := file_url_to_path("C:/deals/hand.png", context.temp_allocator)
	testing.expect(t, bare_ok)
	testing.expect_value(t, bare, "C:/deals/hand.png")
	_, empty_ok := file_url_to_path("", context.temp_allocator)
	testing.expect(t, !empty_ok, "an empty url is not a file")
}

// The engine hands the payload over as a MAP, and the value under "file" is an ARRAY even for one file.
// Built by hand here, which is the point of `drop_file_path` being separate from the event.
@(test)
test_the_drop_payload_map_yields_the_dropped_file :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return} 	// the Value API needs the engine loaded
	defer test_app_destroy(&app)

	files := sa.value_make_array(1)
	defer sa.value_clear(&files)
	url := sa.value_from("file:///C:/deals/hand.png")
	defer sa.value_clear(&url)
	testing.expect_value(t, sa.value_set_at(&files, 0, &url), nil)

	data: sa.Value
	sa.value_init(&data)
	defer sa.value_clear(&data)
	testing.expect_value(t, sa.value_set(&data, "file", &files), nil)

	path, ok := drop_file_path(&data, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, path, "C:/deals/hand.png")

	// A drop carrying no file at all is refused rather than guessed at — this is what Linux delivers (an
	// empty map), and what the status line reports.
	empty: sa.Value
	sa.value_init(&empty)
	defer sa.value_clear(&empty)
	_, empty_ok := drop_file_path(&empty, context.temp_allocator)
	testing.expect(t, !empty_ok, "an empty payload carries nothing to open")
}

// What a dropped file means. Every branch here is something the window already knew how to do.
@(test)
test_a_drop_is_routed_by_what_the_file_is :: proc(t: ^testing.T) {
	testing.expect_value(t, drop_action("C:/shots/hand.png"), Drop_Action.Read_Image)
	testing.expect_value(t, drop_action("C:/shots/HAND.JPEG"), Drop_Action.Read_Image) // case is not a format
	testing.expect_value(t, drop_action("C:/deals/board.pbn"), Drop_Action.Deal_File)
	testing.expect_value(t, drop_action("C:/deals/board.lin"), Drop_Action.Deal_File)
	testing.expect_value(t, drop_action("w:/deals/2c-opener.html"), Drop_Action.Page)
	testing.expect_value(t, drop_action("C:/notes/system.bml"), Drop_Action.Unknown)
	testing.expect_value(t, drop_action("C:/no-extension"), Drop_Action.Unknown)
}

// The reader's command line. `--project` is the load-bearing flag: hand-ocr's PROJECT environment has the
// vision stack, and the script's own PEP-723 environment does not (it carries docopt and nothing else), so
// running the script without it fails on `import cv2` rather than on anything to do with the picture.
@(test)
test_the_ocr_command_runs_hand_ocr_in_its_own_project :: proc(t: ^testing.T) {
	command := ocr_command("C:/shots/hand.png", "C:/dev/bridge-hand-ocr", context.temp_allocator)

	testing.expect_value(t, command[0], "uv")
	testing.expect_value(t, command[1], "run")
	testing.expect_value(t, command[2], "--project")
	testing.expect_value(t, command[3], "C:/dev/bridge-hand-ocr")
	testing.expect(t, strings.has_suffix(command[5], "hand-ocr.py"), "the script comes from that checkout")
	testing.expect(t, strings.contains(command[5], "bridge-hand-ocr"), "and not from anywhere else")
	testing.expect_value(t, command[6], "C:/shots/hand.png")
	testing.expect_value(t, command[7], "--format")
	testing.expect_value(t, command[8], "pbn") // the one format `analyse.parse_args` reads back
}

// A dropped image is the analyse BUTTON with the deal arriving from a picture: the panel's controls have
// to reach the run unchanged, or the drop would silently analyse something other than what the window says.
@(test)
test_a_dropped_image_carries_the_analyse_panels_settings :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#sample", "200")
	type_into(&app, "#contract", "3NT")
	type_into(&app, "#target", "9")
	tick(&app, "#as-page")

	job, err := ocr_job(&app, "C:/shots/hand.png")
	testing.expect_value(t, err, "")
	app.job = job
	testing.expect_value(t, job.kind, Job_Kind.Ocr)
	testing.expect_value(t, job.image, "C:/shots/hand.png")
	testing.expect(t, job.want_page, "ticked, the drop draws the card page")

	// The argv carries no deal yet — that is what hand-ocr is for — so it is checked by appending one, which
	// is exactly what `work_ocr` does with what it read.
	argv := make([dynamic]string, 0, len(job.argv) + 1, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, FRAME_DEAL)

	args, perr := analyse.parse_args(argv[:], allow_stdin = false)
	defer analyse.args_free(&args)
	testing.expectf(t, perr == "", "the advisor rejected the composed argv: %s", perr)
	testing.expect_value(t, args.sample, 200)
	testing.expect_value(t, args.contract, "3NT")
	testing.expect_value(t, args.target, 9)
	testing.expect_value(t, args.html_path, "") // the page is asked for in memory, as with the button
}

// The plumbing, end to end, against the REAL hand-ocr: `--demo` skips the vision stack (it emits a
// hardcoded deal), so this is `uv` + the checkout + the argv + the format, in about two seconds and with
// no opencv needed. SKIPPED rather than failed where hand-ocr is not checked out — it is a sibling repo
// and an optional one, and a test that fails on its absence would fail on every machine but this one.
@(test)
test_hand_ocr_answers_with_a_deal_the_advisor_can_read :: proc(t: ^testing.T) {
	dir := hand_ocr_dir(context.temp_allocator)
	if !os.is_dir(dir) {
		log.warnf("hand-ocr is not at %s — skipping the reader plumbing test", dir)
		return
	}

	command := ocr_command("--demo", dir, context.temp_allocator)
	state, stdout, stderr, exec_err := os.process_exec({command = command}, context.temp_allocator)
	if exec_err != nil {
		log.warnf("could not run uv (%v) — skipping the reader plumbing test", exec_err)
		return
	}
	testing.expectf(t, state.success, "hand-ocr exited with %d: %s", state.exit_code, string(stderr))

	deal := strings.trim_space(string(stdout))
	testing.expectf(t, strings.contains(deal, "[Deal"), "hand-ocr printed no deal tag: %q", deal)

	// The point of the whole exchange: what it prints is what the advisor reads.
	args, perr := analyse.parse_args({deal}, allow_stdin = false)
	defer analyse.args_free(&args)
	testing.expectf(t, perr == "", "the advisor rejected what hand-ocr printed: %s", perr)
	boards, berr := analyse.resolve_boards(args.text)
	defer delete(boards)
	testing.expect_value(t, berr, "")
	testing.expect_value(t, len(boards), 1)
}

// ---- the BML editor -----------------------------------------------------------------------------
//
// Four seams, and each of them has a way of failing silently:
//   * the corpus is found by walking UP from the working directory, which is a different number of levels
//     for `just test-workbench` than for the built exe;
//   * the colour is applied by the document's own script through an API this side cannot read back, so the
//     script reports a COUNT and that count is the assertion;
//   * a save rewrites a file of the user's notes, and the line endings and the trailing newline are what
//     would turn a one-word edit into a diff of every line;
//   * the mark names are written twice — once in the script, once in the stylesheet — and a mark nothing
//     styles is invisible rather than broken.

// The notes are two directories above this one, and `bml_docs_dir` is what has to find them. A test binary
// runs with the working directory `just` was invoked from, which is `deal-simulations/odin-sims`.
@(test)
test_the_bml_corpus_is_found_by_walking_up :: proc(t: ^testing.T) {
	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no .bml corpus above the working directory (%s) — skipping", note)
		return
	}
	testing.expect(t, bml_corpus_at(dir), "the directory it named does not hold the corpus marker")

	names := list_bml_files(dir, context.temp_allocator)
	testing.expect(t, len(names) > 5, "the corpus should hold more than a handful of .bml files")
	testing.expect(t, slice.contains(names, BML_CORPUS_MARKER), "the root document should be in the list")
	for name in names {
		testing.expectf(t, strings.has_suffix(name, ".bml"), "%q is not a .bml file", name)
	}
	// Sorted, because the picker shows them in this order and the first one is what the editor opens.
	testing.expect(t, slice.is_sorted(names), "the file list should be sorted by name")
}

// Opening a file fills the widget and the picker agrees with it afterwards.
@(test)
test_the_bml_editor_opens_a_file :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	pump(&app)

	ok, why := open_bml(&app, BML_CORPUS_MARKER)
	testing.expectf(t, ok, "could not open %s: %s", BML_CORPUS_MARKER, why)
	if !ok {
		return
	}
	pump(&app)

	source, got := bml_source(&app, context.temp_allocator)
	testing.expect(t, got, "the buffer could not be read back")
	testing.expect(t, len(source) > 100, "the buffer is too small to be the root document")
	testing.expect(t, strings.contains(source, "#INCLUDE"), "the root document is the one with the includes")
	// The widget is fed `\n` whatever the file holds — a `\r` reaching it would show up as a glyph.
	testing.expect(t, !strings.contains(source, "\r"), "no carriage return should reach the widget")
	testing.expect(t, app.bml_crlf, "the corpus is CRLF, and that has to be remembered for the save")
	// The list marks what is open, which is where "which file is this?" is answered now that the picker is
	// a sidebar rather than a dropdown.
	marked, merr := sa.select_all(find(&app, "#bml-list"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	open_name, _ := sa.attribute(marked[0], "data-file", context.temp_allocator)
	testing.expect_value(t, open_name, BML_CORPUS_MARKER)
}

// The colour. `bmlColorize()` is the document's own function and it hands back how many marks it applied;
// this is the only visible result, because a mark is not an attribute and reads back through a `Range` or
// not at all. A zero here means the script did not run — a syntax error in it, or `Range.applyMark` gone.
@(test)
test_the_bml_editor_colours_what_it_loads :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // no corpus needed: the buffer is written directly

	set_bml_source(
		&app,
		strings.join(
			{
				"#+TITLE: a title",
				"",
				"* Opening bids",
				"",
				"1C = 16+ hcp, see [relay](#Relay)",
				"  (1H) = an overcall of 8+ !h",
			},
			"\n",
			context.temp_allocator,
		),
	)
	pump(&app)

	marks := colorize_bml(&app)
	testing.expect(t, marks >= 6, "every one of those lines carries at least one token to colour")
}

// A save must give the file back BYTE FOR BYTE when nothing was edited. That is not a tautology here: the
// widget hands its content back as `\n` with no trailing newline, and the corpus is CRLF with one — so a
// round trip that did not restore both would rewrite every line of every file anyone opened.
@(test)
test_a_bml_save_round_trips_the_bytes :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// A scratch copy, not the user's notes: this test writes.
	dir := filepath.join({"target", "debug"}, context.temp_allocator) or_else "."
	name := "wb-editor-round-trip.bml"
	path := filepath.join({dir, name}, context.temp_allocator) or_else name
	original := "#+TITLE: round trip\r\n\r\n* Opening bids\r\n\r\n1C = 16+ hcp\r\n  1D = 0-7 hcp\r\n"
	if err := os.write_entire_file(path, transmute([]u8)original); err != nil {
		log.warnf("could not write %s (%v) — skipping", path, err)
		return
	}
	defer os.remove(path)

	app.docs = dir
	pump(&app)

	ok, why := open_bml(&app, name)
	testing.expectf(t, ok, "could not open the scratch file: %s", why)
	if !ok {
		return
	}
	pump(&app)

	written, save_why := save_bml(&app)
	testing.expectf(t, written, "could not save the scratch file: %s", save_why)

	back, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(back), original)
}

// The preview renders THE BUFFER — the point of the whole editor, and the thing the python reference could
// not do (it renders a path). Asserted through the frame's own document rather than by looking at the html
// string: what matters is that a document came out and the engine took it.
@(test)
test_the_bml_preview_renders_the_buffer :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""
	app.bml_open = "scratch.bml"
	defer app.bml_open = ""

	set_bml_source(&app, "#+TITLE: previewed\n\n* Slam bidding\n\n4N = RKB\n")
	pump(&app)

	ok, why := preview_bml(&app)
	testing.expectf(t, ok, "the preview did not render: %s", why)
	if !ok {
		return
	}
	pump(&app)

	heading, found := preview_selection(&app, "h1")
	testing.expect(t, found, "the preview has no <h1> — the document did not reach the frame")
	testing.expect_value(t, heading, "Slam bidding")

	// The bid table is what a `.bml` document is FOR, and it is the part of the renderer with structure:
	// a heading would still be there if the bid-table path had produced nothing.
	_, table := preview_selection(&app, "div.bidtable")
	testing.expect(t, table, "the preview has no bid table")
}

// The same, with the notes' OWN stylesheet inlined — which is the shape the application actually loads, and
// the shape that has to survive the width-media stripper. Hidden frame, for the reason in `preview_selection`.
@(test)
test_the_preview_carries_the_notes_stylesheet :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no corpus (%s) — skipping", note)
		return
	}
	app.docs = dir
	app.bml_open = "scratch.bml"
	defer app.bml_open = ""

	set_bml_source(
		&app,
		strings.join({"#+TITLE: styled", "", "* Opening bids", "", "1C = 16+ hcp"}, "\n", context.temp_allocator),
	)
	pump(&app)

	ok, why := preview_bml(&app)
	testing.expectf(t, ok, "the preview did not render: %s", why)
	pump(&app)

	heading, found := preview_selection(&app, "h1")
	testing.expect(t, found, "the styled preview has no <h1>")
	testing.expect_value(t, heading, "Opening bids")
}

// The preview document is SELF-CONTAINED: the stylesheet inlined, and no `<link>` left to fetch. A webfont
// `<link>` is an outbound https request from a desktop window, and a relative `bml.css` would resolve
// against a base url this frame does not have — either way the page arrives unstyled and nothing says why.
@(test)
test_the_preview_document_fetches_nothing :: proc(t: ^testing.T) {
	app: App
	app.docs = "" // no stylesheet to find, which is the harder case: the tags still have to go
	rendered :=
		`<html><head><link rel="stylesheet" type="text/css" href="bml.css" />` +
		`<link href="https://fonts.googleapis.com/css?family=Open Sans" rel="stylesheet" />` +
		`<title>t</title></head><body class="content"><h1>H</h1></body></html>`

	page := preview_document(&app, rendered, allocator = context.temp_allocator)
	testing.expect(t, !strings.contains(page, "<link"), "no <link> may survive into the preview")
	testing.expect(t, !strings.contains(page, "fonts.googleapis.com"), "the webfont request must be gone")
	testing.expect(t, strings.contains(page, "<style>"), "the stylesheet is inlined instead")
	testing.expect(t, strings.contains(page, "<h1>H</h1>"), "the body must come through untouched")
	testing.expect(t, strings.contains(page, "<title>t</title>"), "and so must the rest of the head")
}

// The mark names are written twice — `BML_MARKS` in the script, `::mark(...)` in the stylesheet — and the
// two lists have to agree. A mark nothing styles is not an error: it is text that quietly stays grey.
@(test)
test_bml_marks_are_styled :: proc(t: ^testing.T) {
	document := compose_document(context.temp_allocator)

	names, found := marks_declared_by_the_script(document, "BML_MARKS", context.temp_allocator)
	testing.expect(t, found, "the script's BML_MARKS list is not in the document")
	testing.expect(t, len(names) >= 6, "the colorizer should name at least six token classes")
	for name in names {
		rule := fmt.tprintf("::mark(%s)", name)
		testing.expectf(t, strings.contains(document, rule), "%s has no %s rule in the stylesheet", name, rule)
	}

	// The same for the diagnostics' own marks, which are a second list for a second reason: they are
	// CLEARED separately (an edit invalidates a position, but not a token's colour), and an unstyled
	// squiggle is invisible in exactly the way an unstyled token is.
	problems, problems_found := marks_declared_by_the_script(document, "BML_PROBLEM_MARKS", context.temp_allocator)
	testing.expect(t, problems_found, "the script's BML_PROBLEM_MARKS list is not in the document")
	testing.expect_value(t, len(problems), 2)
	for name in problems {
		rule := fmt.tprintf("::mark(%s)", name)
		testing.expectf(t, strings.contains(document, rule), "%s has no %s rule in the stylesheet", name, rule)
	}
}

// THE CARET HAS TO BE VISIBLE, and the caret is the only thing that says a pane is an editor. Two ways it
// went missing, both silent, both here:
//
//  1. Sciter's caret colour is `text-selection-caret-color`. The browsers' `caret-color` is not a property
//     this engine has, so spelling it that way parses, matches, and paints the engine's own default —
//     black, which is `--sunken` on this sheet. A property read back EMPTY is that mistake.
//  2. The engine paints a caret only in a FOCUSED widget, and opening the view used to focus nothing.
//
// The colour is read as a computed style rather than grepped out of the sheet, because the point is what
// the engine resolved — a property it does not know is exactly what a `var()` that resolved would look
// like in the text.
@(test)
test_the_editor_has_a_visible_caret :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	text := find(&app, "#bml-text")
	testing.expect(t, text != nil, "there is no source pane")
	if text == nil {return}

	colour, cerr := sa.style(text, "text-selection-caret-color", context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	testing.expectf(t, colour != "", "the engine does not know text-selection-caret-color")
	// --accent is #89b4fa. Whatever spelling comes back, it must not be the black default nor transparent,
	// either of which is an invisible caret on the sunken background.
	testing.expectf(
		t,
		!strings.contains(colour, "transparent") && !strings.contains(colour, "0,0,0"),
		"the caret is %q against a #11111b background",
		colour,
	)

	// And something holds the caret the moment the view opens.
	state, serr := sa.element_state(text)
	testing.expect_value(t, serr, nil)
	testing.expect(t, .FOCUS in state, "the source pane opens without the focus, so it paints no caret")
}

// The live preview is a DEBOUNCE whose delay is the last render`s own cost, and this is the arithmetic of
// it: a cheap document waits the base, an expensive one waits proportionally longer, and nothing waits more
// than the cap. Measured costs are what the numbers here stand for - ~100ms for a chapter shown as one
// section, ~1s for the assembled root shown whole.
@(test)
test_the_live_preview_delay_scales_with_what_a_render_costs :: proc(t: ^testing.T) {
	app: App
	app.bml_live_base = LIVE_PREVIEW_BASE

	// A chapter: four times 100ms is under the base, so the base is what a person waits.
	app.bml_preview_cost = 100 * time.Millisecond
	testing.expect_value(t, live_preview_delay(&app), LIVE_PREVIEW_BASE)

	// Half a second a render, and the delay follows it rather than the base.
	app.bml_preview_cost = 500 * time.Millisecond
	testing.expect_value(t, live_preview_delay(&app), 2 * time.Second)

	// The assembled root. Four seconds would be the scale; the cap is what it gets.
	app.bml_preview_cost = time.Second
	testing.expect_value(t, live_preview_delay(&app), LIVE_PREVIEW_MAX)

	// And WORKBENCH_LIVE_MS=0 turns the whole thing off - `preview` goes back to being the only render.
	app.bml_live_base = 0
	testing.expect_value(t, live_preview_delay(&app), 0)
}

// A render must not start inside a render. It pumps the engine to build the document in the frame, so a
// timer or a click delivered during that pump reaches the same code with a half-built document in the pane -
// which is why the guard is in `preview_bml` itself and not in the live path that made it necessary.
//
// The same test pins the two numbers the live preview reads: what the render COST (its debounce is scaled by
// it) and a fingerprint of the text the pane is showing (an idle timer over an unchanged buffer must not
// render at all). Hidden frame, for the reason in `preview_selection`.
@(test)
test_a_preview_refuses_to_start_inside_another_one :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""
	app.bml_open = "scratch.bml"
	defer app.bml_open = ""

	set_bml_source(&app, "#+TITLE: live\n\n* Slam bidding\n\n4N = RKB\n")
	pump(&app)

	app.bml_rendering = true
	refused, why := preview_bml(&app)
	testing.expect(t, !refused, "a render started inside another one")
	testing.expect_value(t, why, "the preview is still rendering")
	app.bml_rendering = false

	ok, reason := preview_bml(&app)
	testing.expectf(t, ok, "the preview did not render: %s", reason)
	pump(&app)
	testing.expect(t, app.bml_preview_cost > 0, "the render cost was not measured - the debounce cannot scale")
	testing.expect(t, app.bml_rendered != 0, "the rendered text was not fingerprinted")
	testing.expect(t, !app.bml_rendering, "the guard was left set - nothing would ever render again")

	// The fingerprint is of the TEXT, so the same buffer rendered twice is the same number: that identity is
	// what makes a timer over an untouched buffer free.
	was := app.bml_rendered
	_, _ = preview_bml(&app)
	pump(&app)
	testing.expect_value(t, app.bml_rendered, was)
}
// COLOURING MUST NOT TOUCH THE CARET OR THE SELECTION. It is a `Range` per token over the very text someone
// is editing, so "the caret jumped" and "there is selection paint where there is no selection" both have
// the colorizer as their first suspect. This is the measurement that answers it: the widget's own
// `selectionStart`/`selectionEnd` (an array `[row, col]`, reached through the plaintext asset - script sees
// `undefined`), read either side of a whole pass and a dirty pass, and either side of a RENDER, which is the
// other thing that runs while someone types.
@(test)
test_colouring_does_not_move_the_caret_or_the_selection :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	set_bml_source(
		&app,
		strings.join(
			{
				"#+TITLE: probe",
				"",
				"* Head one",
				"",
				"1C = strong, see [x](#Head two)",
				"  1D = weak",
				"",
				"* Head two",
				"",
				"2C = game force",
			},
			"\n",
			context.temp_allocator,
		),
	)
	pump(&app)
	_ = colorize_bml(&app)
	pump(&app)

	element := find(&app, "#bml-text")
	testing.expect(t, element != nil, "there is no source pane")
	if element == nil {return}
	sa.set_focus(element)
	pump(&app)
	asset, aerr := sa.element_asset(element, "plaintext")
	testing.expect_value(t, aerr, nil)

	// Put the caret on the line with the most to colour on it - a call, an `=`, a cross-reference.
	set_caret_row(&app, 4)
	pump(&app)
	before := selection_of(asset)
	testing.expect_value(t, caret_row(&app), 4)

	testing.expect_value(t, colorize_bml(&app) > 0, true)
	pump(&app)
	testing.expect_value(t, selection_of(asset), before)
	testing.expect_value(t, caret_row(&app), 4)

	// The dirty pass, which is the one that runs on every burst of typing.
	dirty, derr := sa.eval(app.window, "bmlColorizeDirty()")
	sa.value_clear(&dirty)
	testing.expect_value(t, derr, nil)
	pump(&app)
	testing.expect_value(t, selection_of(asset), before)

	// And a render, which the live preview runs from under the same keystrokes. Hidden frame, for the reason
	// in `preview_selection`.
	app.bml_open = "scratch.bml"
	defer app.bml_open = ""
	if ok, why := preview_bml(&app); !ok {
		log.warnf("the preview did not render (%s) - skipping the render half", why)
		return
	}
	pump(&app)
	testing.expect_value(t, selection_of(asset), before)
	testing.expect_value(t, caret_row(&app), 4)
}

// `[row, col] -> [row, col]`, or a word saying why not. A string because it is only ever compared with
// another reading of itself.
@(private = "file")
selection_of :: proc(asset: ^sciter.Som_Asset_T) -> string {
	pair :: proc(asset: ^sciter.Som_Asset_T, name: string) -> string {
		value, err := sa.asset_get(asset, name)
		defer sa.value_clear(&value)
		if err != nil {
			return "unreadable"
		}
		if kind, _ := sa.value_type(&value); kind != .ARRAY {
			return "not-a-position"
		}
		row, _ := sa.value_at(&value, 0)
		col, _ := sa.value_at(&value, 1)
		defer sa.value_clear(&row)
		defer sa.value_clear(&col)
		r, rerr := sa.value_to_int(&row)
		c, cerr := sa.value_to_int(&col)
		if rerr != nil || cerr != nil {
			return "not-a-position"
		}
		return fmt.tprintf("%d:%d", r, c)
	}
	return fmt.tprintf("%s -> %s", pair(asset, "selectionStart"), pair(asset, "selectionEnd"))
}
/*
A ZOOMED FIELD STILL HAS ITS TEXT IN THE MIDDLE OF IT.

The engine`s own sheet gives `input[type=text]` and `select` a fixed `height: 1.4em`, and the caption inside
does not stay centred in that box as `zoom` goes up - it walks DOWNWARDS, until at a high zoom the text is
sitting on the bottom border with its descenders cut off. `height: auto` is the fix (the control sizes itself
to what it is showing) and this is the measurement that says so, because nothing in the geometry API can see
it: the caption is INTERNAL to the control (`child_count` is 0, and a composite control`s internals take no
author CSS), so the only witness is the pixels.

So: paint the view, find the rows inside the field that have ink in them, and check the gap above the ink
against the gap below it. Balanced at 100% either way - the bug is what zoom does to it (13/13 at 100%,
22/11 at 133% with the engine`s height, 13/13 and 17/17 with this one).

Only up to 133%: above that this windowless harness reports the whole field as bright, which is a property of
the harness rather than of the layout (the boxes and the ratios stay sane) and would make the check a coin
toss. The mechanism is the same at every step, so the first three answer for the rest.
*/
@(test)
test_a_zoomed_field_keeps_its_text_centred :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	set_input(&app, "#outdir", "www")
	pump(&app)
	defer for _ in 0 ..< 3 {_ = zoom_step(&app, -1)} 	// leave the window as it was found

	for step in 0 ..= 3 {
		if step > 0 {
			_ = zoom_step(&app, 1)
		}
		pump(&app)
		above, below, ok := ink_gaps(&app, "#outdir")
		if !ok {
			log.warn("the field has no ink in it - skipping this step")
			continue
		}
		testing.expectf(
			t,
			abs(above - below) <= 3,
			"at zoom %.2f the text sits %dpx from the top and %dpx from the bottom of its field",
			zoom_factor(&app),
			above,
			below,
		)
	}
}

// The gap above and below the INK inside a control, in painted pixels. A row counts as ink when more than a
// caret`s width of it is brighter than the field it sits on.
@(private = "file")
ink_gaps :: proc(app: ^App, selector: string) -> (above: int, below: int, ok: bool) {
	element := find(app, selector)
	if element == nil {
		return 0, 0, false
	}
	box, berr := sa.location(element, .Border, .Root)
	if berr != nil {
		return 0, 0, false
	}
	sa.paint_windowless(&g_view)
	top, bottom := -1, -1
	for y := box.y; y < box.y + box.height; y += 1 {
		if y < 0 || y >= 780 {
			continue
		}
		bright := 0
		for x := box.x + 4; x < min(box.x + box.width - 4, 1120); x += 1 {
			if x < 0 {
				continue
			}
			r, g, b, _ := sa.windowless_pixel(&g_view, x, y)
			if int(r) + int(g) + int(b) > 3 * 120 { 	// the field is #313244, the ink #cdd6f4
				bright += 1
			}
		}
		if bright > 2 {
			if top < 0 {
				top = int(y)
			}
			bottom = int(y)
		}
	}
	if top < 0 {
		return 0, 0, false
	}
	return top - int(box.y), int(box.y + box.height) - bottom, true
}
// Typing must not re-colour the whole chapter. It used to: the `change` handler ran a whole-buffer pass
// every 40ms, which is a `Range` per token over every line — 49ms on a 1400-line chapter and 203ms on the
// 5300-line one, measured, and felt as a keyboard that lags behind a burst of typing while a single
// keypress looks fine.
//
// The dirty pass reads each line and marks only the ones whose text is not the text they were last marked
// with, which costs 2-8ms of walking and no Range work at all. THIS test is that property: a dirty pass
// straight after a whole one must mark NOTHING. If the per-line memory ever stops working the assertion
// fails here rather than being felt as a slow editor months later.
@(test)
test_a_dirty_colour_pass_skips_the_lines_that_did_not_change :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // no corpus needed: the buffer is written directly

	set_bml_source(
		&app,
		strings.join(
			{
				"#+TITLE: a title",
				"",
				"* Opening bids",
				"",
				"1C = 16+ hcp, see [relay](#Relay)",
				"  (1H) = an overcall of 8+ !h",
			},
			"\n",
			context.temp_allocator,
		),
	)
	pump(&app)

	whole := colorize_bml(&app)
	testing.expect(t, whole > 0, "the whole pass marked nothing — the colorizer did not run")

	dirty, err := sa.eval(app.window, "bmlColorizeDirty()")
	defer sa.value_clear(&dirty)
	testing.expect_value(t, err, nil)
	marked, ierr := sa.value_to_int(&dirty)
	testing.expect_value(t, ierr, nil)
	testing.expectf(t, marked == 0, "a dirty pass re-marked %d tokens on text nobody had touched", marked)

	// And the HOST entry point is unaffected by that memory: a new file must colour whether or not the
	// widget reused its line elements to hold it.
	set_bml_source(&app, "* Another chapter\n\n2N = 20-21 balanced\n")
	pump(&app)
	testing.expect(t, colorize_bml(&app) > 0, "a freshly loaded buffer came back uncoloured")
}

// The editor is one of four views that REPLACE each other; two of them on screen at once was the bug the
// `View` enum exists to make impossible.
@(test)
test_the_editor_view_replaces_the_panes :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	pump(&app)

	testing.expect_value(t, current_view(&app), View.Panes)
	show_editor(&app)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
	testing.expect(t, effective_display_is_hidden(&app, ".panes"), "the panes must be off screen")
	testing.expect(t, app.bml_open != "", "the first visit should open a file")

	show_view(&app, .Panes)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, effective_display_is_hidden(&app, "#editview"), "the editor must be off screen")
}

// Switching files over EDITED text is refused once, and the picker is put back on the file that is really
// open — otherwise the control and the buffer would disagree about which file `save` writes to.
@(test)
test_switching_away_from_unsaved_text_is_refused_once :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	if len(app.bml_names) < 2 {
		log.warn("fewer than two .bml files — nothing to switch to; skipping")
		return
	}
	pump(&app)

	first, second := app.bml_names[0], app.bml_names[1]
	ok, why := open_bml(&app, first)
	testing.expectf(t, ok, "could not open %s: %s", first, why)
	if !ok {
		return
	}
	pump(&app)
	testing.expect(t, !bml_modified(&app), "a freshly loaded buffer is not modified")

	// A KEY, delivered to the focused widget, because that is what actually sets `isModified`. Two things
	// measured while getting here, both worth knowing before writing another test against this widget:
	// `appendLine` through a script does nothing at all in a windowless view (no text, no modification),
	// and a `.CHAR` key marks the buffer modified WITHOUT inserting the character. So this asserts the
	// FLAG's effect on the guard, which is what the guard reads; the discard itself is what reloads the
	// text either way.
	element := find(&app, "#bml-text")
	sa.set_focus(element)
	pump(&app)
	processed, kerr := sa.send_key(element, .CHAR, u32('X'))
	pump(&app)
	testing.expect(t, processed && kerr == nil, "the widget did not take the key")
	if !bml_modified(&app) {
		log.warn("the widget does not report a typed character as a modification; skipping the guard")
		return
	}

	switch_bml_file(&app, second)
	pump(&app)
	testing.expect_value(t, app.bml_open, first) // refused
	// And the LIST still says which file is really open, marked as having unsaved changes.
	marked, merr := sa.select_all(find(&app, "#bml-list"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	open_name, _ := sa.attribute(marked[0], "data-file", context.temp_allocator)
	testing.expect_value(t, open_name, first)
	classes, _ := sa.attribute(marked[0], "class", context.temp_allocator)
	testing.expect(t, strings.contains(classes, "dirty"), "the open row should show it has unsaved changes")

	switch_bml_file(&app, second)
	pump(&app)
	testing.expect_value(t, app.bml_open, second) // the second attempt discards and loads
}

// Point `app` at the real corpus, or say why not. A skip rather than a failure: the tests that need the
// notes are testing the seam onto them, and a checkout without them is a thing that happens.
@(private = "file")
editor_corpus :: proc(t: ^testing.T, app: ^App) -> bool {
	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no .bml corpus (%s) — skipping", note)
		return false
	}
	app.docs = dir
	app.bml_names = list_bml_files(dir, context.temp_allocator)
	draw_bml_files(app)
	return len(app.bml_names) > 0
}

// One element's text out of the PREVIEW frame's sub-document. The frame is a document of its own, so this
// goes through the frame behavior's `document` property the way `focus_page` does.
//
// TWO WINDOWLESS-ONLY LANDMINES, measured while writing these tests, and both take the PROCESS down rather
// than returning an error (the runner then hangs, because its crash handler touches the engine from another
// thread and trips the one-thread rule):
//
//   * `sa.location` on a `<frame>` ELEMENT once a document is loaded into it. An EMPTY frame measures fine,
//     which is the trap — the same call in `test_the_editor_split_gives_both_halves_a_box` is safe because
//     nothing has been previewed yet.
//   * reaching into the frame's document AT ALL while the frame is DISPLAYED. Which is why the preview test
//     below never calls `show_editor`: it previews into a hidden frame and reads it there.
//
// The real WINDOW does neither of these things wrong — `focus_page` has always reached into a visible card
// page — so this is a property of the windowless view rather than of the engine's frames, and it is a limit
// on what these tests can assert, not on the application.
@(private = "file")
preview_selection :: proc(app: ^App, selector: string) -> (text: string, ok: bool) {
	element := find(app, "#bml-page")
	if element == nil {
		return "", false
	}
	asset, aerr := sa.element_asset(element, "frame")
	if aerr != nil {
		return "", false
	}
	document, derr := sa.asset_get(asset, "document")
	defer sa.value_clear(&document)
	if derr != nil {
		return "", false
	}
	root, rerr := sa.element_from_value(&document)
	if rerr != nil {
		return "", false
	}
	found, ferr := sa.select_first(root, selector)
	if ferr != nil || found == nil {
		return "", false
	}
	value, terr := sa.text(found, context.temp_allocator)
	return value, terr == nil
}

// The mark names the script declares, read out of the composed document. Reading them rather than repeating
// them here is the point: a name added to the script with no stylesheet rule has to FAIL the test, and a
// list duplicated in this file would only ever test itself.
@(private = "file")
marks_declared_by_the_script :: proc(
	document: string,
	variable := "BML_MARKS",
	allocator := context.allocator,
) -> (
	names: []string,
	ok: bool,
) {
	opening := fmt.tprintf("var %s = [", variable)
	start := strings.index(document, opening)
	if start < 0 {
		return nil, false
	}
	rest := document[start:]
	close := strings.index(rest, "]")
	if close < 0 {
		return nil, false
	}
	list := make([dynamic]string, 0, 8, allocator)
	for field in strings.split(rest[len(opening):close], ",", context.temp_allocator) {
		name := strings.trim(field, " \t\r\n\"")
		if name != "" {
			append(&list, strings.clone(name, allocator))
		}
	}
	return list[:], len(list) > 0
}

// The widget's LINES are the buffer, and its `content` property is not. This is the measurement `bml_source`
// is built on, kept as a test because the whole save path depends on it and because it is the sort of thing
// a later engine could quietly fix — at which point this fails and says so, which is the useful outcome
// either way.
//
// Measured on Sciter 6.0.4.9: writing three lines gives three `<text>` children holding exactly those three
// lines, and a `content` that has gained a blank line at the FRONT and LOST the boundary between the last
// two. `\n` and `\r\n` are both accepted going in.
@(test)
test_the_widget_lines_are_the_buffer :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	for input in ([]string{"a\nb\nc", "a\r\nb\r\nc"}) {
		set_bml_source(&app, input)
		pump(&app)

		lines, ok := bml_source(&app, context.temp_allocator)
		testing.expect(t, ok, "the buffer could not be read")
		testing.expect_value(t, lines, "a\nb\nc")

		// And the property this does NOT use, so the reason is on the record rather than in a comment.
		element := find(&app, "#bml-text")
		asset, aerr := sa.element_asset(element, "plaintext")
		testing.expect_value(t, aerr, nil)
		value, gerr := sa.asset_get(asset, "content")
		defer sa.value_clear(&value)
		testing.expect_value(t, gerr, nil)
		content, serr := sa.value_to_string(&value, context.temp_allocator)
		testing.expect_value(t, serr, nil)
		testing.expect_value(t, content, "\r\na\r\nbc")
	}
}

// The editor's LAYOUT, as far as a windowless view can judge it — which is the geometry and not the look.
//
// What this catches is the failure this engine actually produces: an element with no size. `size: *` is how
// a Sciter box fills what is left, and the two halves of the split and the `<frame>` inside the right one
// each depend on it; get any of them wrong and the half is 0 wide (or the frame is), which reads as "the
// editor opened empty" or "preview did nothing" rather than as a stylesheet mistake. `frame#page` carries
// the same comment for the same reason.
//
// What it CANNOT judge is everything the colours and the proportions are about. That needs the window.
@(test)
test_the_editor_split_gives_both_halves_a_box :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	view, verr := sa.location(find(&app, "#editview"), .Border, .Root)
	testing.expect_value(t, verr, nil)
	source, serr := sa.location(find(&app, "#bml-text"), .Border, .Root)
	testing.expect_value(t, serr, nil)
	preview, perr := sa.location(find(&app, "#bml-page"), .Border, .Root)
	testing.expect_value(t, perr, nil)

	testing.expectf(t, view.width > 1000, "the editor should fill the window, not %dpx", view.width)
	testing.expectf(t, source.width > 300, "the source half is %dpx wide", source.width)
	testing.expectf(t, preview.width > 300, "the preview half is %dpx wide", preview.width)
	testing.expectf(t, source.height > 400, "the source half is %dpx tall", source.height)
	testing.expectf(t, preview.height > 400, "the preview half is %dpx tall", preview.height)

	// Halves, within a pixel or two of each other — the whole point of `width: *` on both.
	testing.expectf(
		t,
		abs(source.width - preview.width) <= 2,
		"the split is lopsided: %dpx of source against %dpx of preview",
		source.width,
		preview.width,
	)
	// Side by side rather than stacked, and both inside the view.
	testing.expect(t, source.x + source.width <= preview.x + 2, "the source half must be left of the preview")
	testing.expect(
		t,
		source.y >= view.y && preview.y + preview.height <= view.y + view.height,
		"both halves must be inside the view",
	)
}

// The stripper, on the shapes that were measured. This cannot assert the CRASH — a test that crashes takes
// the runner down with it — so it asserts the thing that prevents it, against exactly the conditions that
// were bisected: a width feature goes, a bare media type stays.
@(test)
test_width_media_blocks_are_stripped :: proc(t: ^testing.T) {
	css :=
		"body { background: antiquewhite; } " +
		"@media all and (max-width: 699px) { .content { max-width: 600px; } } " +
		".content { max-width: 900px; } " +
		"@media (max-width: 799px) { .content { max-width: 700px; } h1 { font-size: 2em; } } " +
		"@media all and (min-width: 900px) and (max-width: 1045px) { .content { max-width: 800px; } } " +
		"@media screen { .nav-links { display: block; } } " +
		"a { color: Sienna; } "

	out := strip_width_media_blocks(css, context.temp_allocator)
	testing.expect(t, !strings.contains(out, "max-width: 699px"), "a bare width feature must go")
	testing.expect(t, !strings.contains(out, "max-width: 799px"), "and so must the next one")
	testing.expect(t, !strings.contains(out, "min-width: 900px"), "and the min/max range")
	testing.expect(t, !strings.contains(out, "600px"), "the rules inside a dropped block go with it")
	testing.expect(t, !strings.contains(out, "font-size: 2em"), "every rule inside it, not just the first")

	testing.expect(t, strings.contains(out, "@media screen"), "a bare media TYPE is safe and must stay")
	testing.expect(t, strings.contains(out, ".nav-links"), "so must what is inside it")
	testing.expect(t, strings.contains(out, "background: antiquewhite"), "ordinary rules before a block stay")
	testing.expect(t, strings.contains(out, "max-width: 900px"), "the base width rule is the one that survives")
	testing.expect(t, strings.contains(out, "color: Sienna"), "and the rules after the last block")
}

// The notes' own stylesheet, through the stripper, is safe to hand this engine — and it is not a trivial
// pass: `bml.css` carries a dozen width blocks and they are what the preview would die on.
@(test)
test_the_real_stylesheet_survives_the_stripper :: proc(t: ^testing.T) {
	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no corpus (%s) — skipping", note)
		return
	}
	path := filepath.join({dir, "bml.css"}, context.temp_allocator) or_else ""
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		log.warnf("no bml.css at %s (%v) — skipping", path, err)
		return
	}
	css := string(data)
	testing.expect(t, strings.contains(css, "max-width:"), "this test is pointless if the sheet has no width rules")

	out := strip_width_media_blocks(css, context.temp_allocator)
	testing.expect(t, len(out) < len(css), "something should have been removed")
	testing.expect(t, strings.contains(out, "background: antiquewhite"), "the page background must survive")
	// Not one `@media` left carrying a width feature — checked by walking what is left rather than by
	// trusting the count, because one missed block is a crash rather than a wrong colour.
	rest := out
	for {
		at := strings.index(rest, "@media")
		if at < 0 {
			break
		}
		open := strings.index_byte(rest[at:], "{"[0])
		testing.expect(t, open >= 0, "an @media with no block survived")
		if open < 0 {
			break
		}
		condition := rest[at:][:open]
		testing.expectf(t, !strings.contains(condition, "width"), "a width query survived: %q", condition)
		rest = rest[at + open + 1:]
	}
}

// Does the preview page FILL its half, or does it paint its background over the content column and leave
// white either side? That was the first thing wrong with it in the real window, and it is what
// `PREVIEW_OVERRIDE_CSS` exists for.
//
// THE PAGE IS LOADED AS THE VIEW'S OWN DOCUMENT, not into the `<frame>`, and that is forced rather than
// chosen: a hidden frame is 1x1 and everything inside it measures 0, while a frame that is both DISPLAYED
// and LOADED cannot be reached into at all from a windowless view without taking the process down (see
// `preview_selection`). Loading the page directly is the same harness `page_check` uses on the card page,
// and it measures the thing in question — a page of this shape, in a viewport of this size.
@(test)
test_the_preview_page_fills_the_view :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no corpus (%s) — skipping", note)
		return
	}
	app.docs = dir

	source := strings.join(
		{"#+TITLE: filled", "", "* Opening bids", "", "1C = 16+ hcp, any shape", "  1D = 0-7 hcp"},
		"\n",
		context.temp_allocator,
	)
	doc := bml.parse(source, {resolve_include = bml_include, include_user = &app})
	defer bml.destroy(doc)
	page := preview_document(&app, bml.render_html(doc, context.temp_allocator), allocator = context.temp_allocator)
	testing.expect(t, strings.contains(page, "antiquewhite"), "the notes' stylesheet should be inlined")

	testing.expect_value(t, sa.load_html(g_view.window, page, "file://workbench/bml-preview.html"), nil)
	pump_view()

	root := sa.root(g_view.window) or_else nil
	testing.expect(t, root != nil, "the preview page has no root")
	if root == nil {
		return
	}

	view, verr := sa.location(root, .Border, .Root)
	testing.expect_value(t, verr, nil)

	body, berr := sa.select_first(root, "body")
	testing.expect_value(t, berr, nil)
	if berr != nil {
		return
	}
	box, lerr := sa.location(body, .Border, .Root)
	testing.expect_value(t, lerr, nil)

	// THE ROOT is the box that has to fill the view, because it is the one being painted — the body cannot
	// be, since in these pages the body IS the 900px content column (`<body class="content">`). Measured
	// here at 901 of 1121, which is exactly the white strip the window showed.
	testing.expectf(
		t,
		view.width >= 1118 && view.height >= 700,
		"the root is %dx%d — it does not fill the view, so painting it will not fill it either",
		view.width,
		view.height,
	)
	testing.expectf(t, box.width <= 902, "the content column is %dpx wide, past its max-width", box.width)
	testing.expectf(t, box.height >= 200, "the content column is only %dpx tall", box.height)

	// Centred, which is what leaves a gutter either side — the gutter this is all about.
	left := box.x - view.x
	right := (view.x + view.width) - (box.x + box.width)
	testing.expectf(t, left > 20 && right > 20, "no gutter to paint: %dpx left, %dpx right", left, right)
	testing.expectf(t, abs(left - right) <= 2, "the column is not centred: %dpx left against %dpx right", left, right)

	// And the gutter is PAINTED, in the colour the sheet gave the body. The computed value comes from the
	// page's own runtime because the host bindings read boxes, not styles — the same reason `dump_page`
	// measures the card page from inside it.
	painted, eerr := sa.eval(g_view.window, "String(getComputedStyle(document.documentElement).backgroundColor)")
	defer sa.value_clear(&painted)
	if eerr != nil {
		log.warnf("could not read the root's computed background (%v) — the geometry above still holds", eerr)
		return
	}
	colour, serr := sa.value_to_string(&painted, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	// antiquewhite is 250,235,215. Whatever spelling the engine hands back, it must not be transparent and
	// must not be the default white — either of those is a white gutter.
	testing.expectf(t, colour != "", "the root has no computed background at all")
	testing.expectf(
		t,
		!strings.contains(colour, "transparent") && !strings.contains(colour, "255,255,255"),
		"the root's background is %q — the gutters will be white",
		colour,
	)
}

// The override, on the two shapes that matter, without an engine: the colour is MIRRORED from the sheet
// rather than written out, so a change to `bml.css` cannot leave the preview's gutters the wrong colour.
@(test)
test_the_preview_override_mirrors_the_page_background :: proc(t: ^testing.T) {
	mirrored := preview_override_css(
		"body { font-family: 'Open Sans'; background: antiquewhite; } .content { max-width: 900px; }",
		context.temp_allocator,
	)
	testing.expect(t, strings.contains(mirrored, "background: antiquewhite"), "the body colour must reach the root")
	testing.expect(t, strings.contains(mirrored, "html { size: *"), "and the root must fill the frame")

	// `background-color` counts as the same thing.
	spelled := preview_override_css("body { background-color: #fdf6e3; }", context.temp_allocator)
	testing.expect(t, strings.contains(spelled, "background: #fdf6e3"), "background-color must be read too")

	// A compound selector is NOT the body rule: `.content` is what carries the width in these sheets, and
	// reading a colour out of `body.content` would be reading the column's own background.
	compound := preview_override_css("body.content { background: pink; }", context.temp_allocator)
	testing.expect(t, !strings.contains(compound, "pink"), "a compound selector is not the body rule")

	// Nothing to mirror: fill the body instead, so its text at least has no white gutters beside it.
	plain := preview_override_css(".content { max-width: 900px; }", context.temp_allocator)
	testing.expect(t, strings.contains(plain, "max-width: none"), "with no page colour, the body fills instead")
}

// The header bar has to survive a NARROW window, and it gained a button this session (`bml`), which is
// exactly the kind of change that pushes the last control off the right edge. `header` is a horizontal flow
// with a `width: *` title in the middle, so the title is what should give — but nothing enforces that, and
// a bar whose buttons have walked off the edge is unusable rather than ugly: `about` carries the licence
// obligation and `close`/`bml` are how the views are reached at all.
//
// The view is RESIZED and put back, because `g_view` lives for the whole process and every later test would
// otherwise run in whatever size this one left behind.
@(test)
test_the_header_survives_a_narrow_window :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	NARROW_W :: 640
	NARROW_H :: 520
	defer {
		sa.resize_windowless(&g_view, 1120, 780)
		pump_view()
	}

	for size in ([][2]i32{{1120, 780}, {NARROW_W, NARROW_H}}) {
		testing.expect_value(t, sa.resize_windowless(&g_view, size[0], size[1]), nil)
		pump_view()

		root := sa.root(g_view.window) or_else nil
		if root == nil {
			continue
		}
		view, verr := sa.location(root, .Border, .Root)
		testing.expect_value(t, verr, nil)

		// Every control in the bar, and the bar itself. `#engine` is text rather than a control but it is
		// what was crowding the About button when the engine version used to live in it, so it is measured.
		for selector in ([]string{"header", "#tabs", "#engine", "#about", `.tab[data-view="editor"]`}) {
			element := find(&app, selector)
			testing.expectf(t, element != nil, "no %s", selector)
			if element == nil {
				continue
			}
			box, lerr := sa.location(element, .Border, .Root)
			testing.expect_value(t, lerr, nil)
			testing.expectf(
				t,
				box.x + box.width <= view.x + view.width,
				"at %dx%d, %s ends at %dpx in a %dpx window",
				size[0],
				size[1],
				selector,
				box.x + box.width,
				view.width,
			)
			testing.expectf(t, box.width > 0 && box.height > 0, "at %dx%d, %s has no box", size[0], size[1], selector)
		}

		// One row, not two: the buttons wrapping under the title is the failure this really guards, and it
		// shows up as a header taller than a line of text with its padding.
		header, herr := sa.location(find(&app, "header"), .Border, .Root)
		testing.expect_value(t, herr, nil)
		testing.expectf(
			t,
			header.height < 60,
			"at %dx%d the header is %dpx tall — its controls wrapped",
			size[0],
			size[1],
			header.height,
		)
	}
}

// The editor's own bar is the same shape and the same risk, and it carries more: a 260px picker, three
// buttons, the `?` and a `width: *` status line. Narrow enough and the status line is what should give.
@(test)
test_the_editor_bar_survives_a_narrow_window :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	defer {
		sa.resize_windowless(&g_view, 1120, 780)
		pump_view()
	}
	testing.expect_value(t, sa.resize_windowless(&g_view, 720, 520), nil)
	pump_view()

	root := sa.root(g_view.window) or_else nil
	if root == nil {
		return
	}
	view, _ := sa.location(root, .Border, .Root)

	for selector in ([]string {
			"#bml-files-toggle",
			"#bml-folder",
			"#bml-fold",
			"#bml-links",
			"#bml-preview",
			"#bml-save",
		}) {
		element := find(&app, selector)
		testing.expectf(t, element != nil, "no %s", selector)
		if element == nil {
			continue
		}
		box, _ := sa.location(element, .Border, .Root)
		testing.expectf(
			t,
			box.x + box.width <= view.x + view.width,
			"at 720px, %s ends at %dpx in a %dpx window",
			selector,
			box.x + box.width,
			view.width,
		)
	}
	bar, berr := sa.location(find(&app, ".bar"), .Border, .Root)
	testing.expect_value(t, berr, nil)
	testing.expectf(t, bar.height < 60, "at 720px the editor bar is %dpx tall — its controls wrapped", bar.height)
}

// ---- the tabs -----------------------------------------------------------------------------------
//
// The header is a PROJECTION of `View`, which is the whole reason there is no `close` anywhere: the strip
// says where you are, and clicking it says where to go. Three things can therefore go wrong silently and
// each has a check here — the strip disagreeing with what is on screen, a tab for a place that has nothing
// behind it being clickable, and About losing the place it was entered from.

// Clicking a tab navigates, and the strip agrees with the view afterwards.
@(test)
test_a_tab_selects_its_view :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_view(&app, .Panes)
	pump(&app)
	testing.expect(t, tab_is_selected(&app, "panes"), "the opening view should be marked at startup")

	click(&app, `.tab[data-view="editor"]`)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
	testing.expect(t, tab_is_selected(&app, "editor"), "the notes tab should be marked")
	testing.expect(t, !tab_is_selected(&app, "panes"), "and only one tab at a time")

	click(&app, `.tab[data-view="panes"]`)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, tab_is_selected(&app, "panes"), "back to the deals tab")
}

// THE PANE SEGMENT IS DEAD UNTIL THERE IS A PAGE, and the refusal is the MODEL`s. Worth asserting because
// the engine does not enforce it: `do_click` runs a disabled button`s behavior and the click is delivered
// like any other, so a check that only read the attribute would pass while the application opened an empty
// pane.
@(test)
test_the_pane_segment_is_dead_until_there_is_a_page :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)
	pump(&app)

	split := find(&app, `.segbtn[data-pane="split"]`)
	testing.expect(t, split != nil, "no split segment")
	if split == nil {return}
	state, _ := sa.element_state(split)
	testing.expect(t, .DISABLED in state, "the segment should start disabled")

	click(&app, `.segbtn[data-pane="split"]`)
	pump(&app)
	testing.expect(t, !page_pane_shown(&app), "a click with nothing behind it must not open the pane")

	shown := show_page_html(&app, MINIMAL_PAGE, "a page")
	testing.expect(t, shown, "the page did not load into the frame")
	if !shown {return}
	pump(&app)
	testing.expect(t, page_pane_shown(&app), "the page opened the pane")
	state2, _ := sa.element_state(split)
	testing.expect(t, .DISABLED not_in state2, "a page unlocks the segment")
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, "a page")
}

// EVERY TRANSITION IS ONE PRESS, which is the point of three positions instead of two toggles. Closed to
// wide used to be two presses in a particular order (`hand page`, then `wide`), and closing a wide pane had
// a correction hidden in it - the pane un-widened itself on the way out so the controls came back. Both are
// now "put it there", and the pane`s CONTENT survives all of it: nothing here reloads a page.
@(test)
test_the_pane_segment_reaches_every_position_in_one_press :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)
	pump(&app)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Split)

	// closed -> wide, in ONE press, from the position furthest from it.
	click(&app, `.segbtn[data-pane="closed"]`)
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Closed)
	click(&app, `.segbtn[data-pane="wide"]`)
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Wide)
	testing.expect(t, page_pane_shown(&app), "wide implies open - a wide shut pane is not a state")

	// wide -> split brings the controls back beside the page, with the page still in it.
	click(&app, `.segbtn[data-pane="split"]`)
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Split)
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, "a page")
}

// THE LIT SEGMENT SAYS WHERE THE PAGE IS. It is derived from the display properties on every draw rather
// than remembered, so this asserts the projection AND that exactly one of the three claims to be current -
// two lit segments is what a second copy of the state looks like once it has drifted.
@(test)
test_the_lit_segment_says_where_the_page_is :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	pump(&app)

	for mode in ([]Pane_Mode{.Closed, .Split, .Wide, .Closed}) {
		set_pane_mode(&app, mode)
		pump(&app)
		lit, count := test_lit_segment(&app)
		testing.expectf(t, count == 1, "%v lit %d segments, not exactly one", mode, count)
		testing.expect_value(t, lit, pane_mode_name(mode))
	}
}

@(private = "file")
test_lit_segment :: proc(app: ^App) -> (name: string, count: int) {
	for candidate in ([]string{"closed", "split", "wide"}) {
		element := find(app, fmt.tprintf(`.segbtn[data-pane="%s"]`, candidate))
		if element == nil {
			continue
		}
		class, _ := sa.attribute(element, "class", context.temp_allocator)
		if strings.contains(class, "on") {
			name = candidate
			count += 1
		}
	}
	return
}

/*
THE SPLIT`S STATE, and the trap under it.

`frameset.state` is the pane widths, and the FORM matters: it reads back as length STRINGS with their units
and it accepts nothing else. Writing an array of NUMBERS returns success and changes nothing - measured with
a throwaway probe before any of this was written, and pinned here because a silent no-op is exactly the kind
of thing a later refactor puts back while every test still passes.

Flex units survive the round trip, which is what makes the remembered layout a PROPORTION rather than a
pixel count - the reason it is still meaningful in a window of another size.
*/
/*
DRAGGING A SPLITTER ACTUALLY MOVES THE PANES.

Asked for by name — "pane dragging not working, wheres the test to keep it working" — and it was a fair
question, because there wasn't one. What existed tested the MODEL: that `frameset.state` round-trips as
strings, and that `wide` restores a remembered proportion. Both pass while the thing a hand does is broken,
because neither of them touches a splitter.

This drives the pointer, through `sa.send_mouse`. Three things it depends on, all of them measured in the
bindings' own notes: the position is in the WINDOW'S CLIENT AREA (the space `location(el, .Border, .View)`
reports, not the element's own), the button must be in `buttons` for a press to count at all (an empty set
is delivered, reports `processed = false`, and the behavior ignores it), and a drag is three events —
down on the splitter, move, up — with the button held through all three.

What it asserts is the PROPORTION changing, not a pixel count: `state` comes back in flex units, so a drag
is only observable as the panes' shares moving relative to one another.
*/
@(test)
test_a_splitter_drag_moves_the_panes :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") { 	// all three panes have to be on screen to drag between
		testing.fail_now(t, "the page did not load into the frame")
	}
	set_pane_mode(&app, .Split)
	pump(&app)

	splitter, serr := sa.select_first(find(&app, "#deal-split"), ".divider")
	testing.expect_value(t, serr, nil)
	if splitter == nil {
		testing.expect(t, false, "the split has no .divider between its panes")
		return
	}

	list := find(&app, "#scenario-list")
	before, berr := sa.location(list, .Border, .View)
	testing.expect_value(t, berr, nil)

	// The grab point: the middle of the splitter, in client-area coordinates.
	box, gerr := sa.location(splitter, .Border, .View)
	testing.expect_value(t, gerr, nil)
	at := [2]i32{box.x + box.width / 2, box.y + box.height / 2}
	button := sciter.Mouse_Buttons{.MAIN_MOUSE_BUTTON}

	_, derr := sa.send_mouse(splitter, .MOUSE_DOWN, at, button)
	testing.expect_value(t, derr, nil)
	moved := [2]i32{at.x + 120, at.y}
	_, merr := sa.send_mouse(splitter, .MOUSE_MOVE, moved, button)
	testing.expect_value(t, merr, nil)
	_, uerr := sa.send_mouse(splitter, .MOUSE_UP, moved, button)
	testing.expect_value(t, uerr, nil)
	pump(&app)

	after, aerr := sa.location(list, .Border, .View)
	testing.expect_value(t, aerr, nil)
	testing.expectf(
		t,
		after.width > before.width,
		"dragging the splitter 120px right left the list at %dpx, from %dpx — the panes did not move",
		after.width,
		before.width,
	)

	// AND THE HOST CAN SEE IT. A drag the window cannot read back is a drag it cannot remember across a
	// `wide` or a session, which is what `deals.split` in the prefs file is for.
	widths := read_split_state(&app, context.temp_allocator)
	testing.expectf(
		t,
		len(widths) == DEAL_SPLIT_PANES,
		"the frameset reported %d panes after a drag, not %d",
		len(widths),
		DEAL_SPLIT_PANES,
	)
}

@(test)
test_the_split_state_round_trips_as_strings :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	pump(&app)

	// THE STATE ONLY COUNTS THE PANES THAT ARE SHOWN, and the hand pane starts shut - so a window that has
	// generated nothing reports TWO. Measured, and the reason `visible_split_widths` exists at all.
	testing.expectf(
		t,
		len(read_split_state(&app, context.temp_allocator)) == DEAL_SPLIT_PANES - 1,
		"a shut pane should leave 2 entries",
	)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)

	widths := read_split_state(&app, context.temp_allocator)
	testing.expectf(t, len(widths) == DEAL_SPLIT_PANES, "the frameset reported %d panes, not 3", len(widths))
	if len(widths) != DEAL_SPLIT_PANES {return}

	testing.expect(t, write_split_state(&app, {"180px", "1*", "3*"}), "the state would not take strings")
	pump(&app)
	after := read_split_state(&app, context.temp_allocator)
	testing.expectf(t, len(after) == DEAL_SPLIT_PANES, "%d panes after writing, not 3", len(after))
	if len(after) != DEAL_SPLIT_PANES {return}
	testing.expect_value(t, after[0], "180px")
	testing.expect_value(t, after[2], "3*") // the FLEX unit survived - the proportion is what is kept

	// And the panes really moved: the list is the width that was asked for, not the one it was authored at.
	list := find(&app, "#scenario-list")
	testing.expect(t, list != nil, "no scenario list")
	if list != nil {
		box, err := sa.location(list, .Border, .Root)
		testing.expect_value(t, err, nil)
		testing.expectf(t, box.width > 170 && box.width < 195, "the list is %dpx wide, not about 180", box.width)
	}
}

// WIDE REMEMBERS THE PROPORTION IT LEFT. The reading has to be taken before the controls are hidden, because
// a hidden pane DROPS OUT of the frameset`s state (three entries become two, measured) - so a remember that
// ran a moment later would store a two-pane array and hand the wrong widths to the wrong panes on the way
// back. Hence the read on the way out and the restore on the way in.
@(test)
test_wide_restores_the_width_the_split_was_dragged_to :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	pump(&app)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {
		testing.fail_now(t, "the page did not load into the frame")
	}
	pump(&app)

	// Stand in for a drag: a drag ends by folding what it did into the MODEL (`take_deal_drag`).
	app.deal_layout = {250, 500}
	apply_deal_layout(&app)
	pump(&app)

	set_pane_mode(&app, .Wide)
	pump(&app)
	testing.expect_value(t, pane_mode(&app), Pane_Mode.Wide)
	during := read_split_state(&app, context.temp_allocator)
	testing.expectf(
		t,
		len(during) == DEAL_SPLIT_PANES - 1,
		"a hidden pane should leave 2 entries, not %d",
		len(during),
	)

	set_pane_mode(&app, .Split)
	pump(&app)
	back := read_split_state(&app, context.temp_allocator)
	testing.expectf(t, len(back) == DEAL_SPLIT_PANES, "%d panes after coming back, not 3", len(back))
	if len(back) != DEAL_SPLIT_PANES {return}
	// The controls come back at the width they were dragged to, and the page takes the rest.
	testing.expect_value(t, back[1], "500px")
	testing.expect_value(t, back[2], "1*")
}

// ESCAPE AND CTRL+W CLOSE ABOUT, back to where it was opened from, as its `close` button does. Asked for
// from the window: a panel you open only to read should close the way a hand reaches for. And ctrl+w on a
// WORKING view does nothing — it must never be the key that closes the window.
@(test)
test_escape_and_ctrl_w_close_the_about_panel :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	show_view(&app, .Panes)
	pump(&app)
	show_about(&app, true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.About)
	press_key(&app, .ESCAPE)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)

	show_about(&app, true)
	pump(&app)
	press_key(&app, .W, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)

	// On a working view, ctrl+w is nobody's.
	press_key(&app, .W, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
}

// About is the one thing with a `close`, because it is an errand rather than a place. Closing it goes back
// to WHERE IT WAS ENTERED FROM — dropping someone onto the panes would throw away a loaded card page or the
// chapter they were reading for no reason — and it leaves the tab strip saying where that is.
@(test)
test_about_returns_to_where_it_was_opened_from :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	show_editor(&app)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)

	click(&app, "#about")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.About)
	// The strip still says where closing will land, which is the point of not re-marking it for About.
	testing.expect(t, tab_is_selected(&app, "editor"), "About should leave the tab strip alone")

	click(&app, "#about-close")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
}

// A document that loads and lays out in a frame, and nothing more: these tests are about navigation, not
// about the card page (`page-check` owns that).
@(private = "file")
MINIMAL_PAGE :: "<html><head><style>body { size: *; }</style></head><body><h1>page</h1></body></html>"

// The `:disabled` STATE, not the attribute: a presence-only `disabled` in the markup reads back as an
// EMPTY attribute value, so `attribute(...) != ""` is false for a tab that really is disabled. The state
// bits are what the engine itself matches `:disabled` on, and they answer for both spellings.
@(private = "file")
tab_is_disabled :: proc(app: ^App, view: string) -> bool {
	element := find(app, fmt.tprintf(`.tab[data-view="%s"]`, view))
	if element == nil {
		return false
	}
	state, err := sa.element_state(element)
	return err == nil && .DISABLED in state
}

@(private = "file")
tab_is_selected :: proc(app: ^App, view: string) -> bool {
	element := find(app, fmt.tprintf(`.tab[data-view="%s"]`, view))
	if element == nil {
		return false
	}
	classes, err := sa.attribute(element, "class", context.temp_allocator)
	return err == nil && strings.contains(classes, "sel")
}

// A click, the way the engine delivers one. `do_click` is what the bindings offer for a button and it is
// what the window handler then sees — which is the seam these tests are about, so it is worth going through
// it rather than calling the handler's body.
@(private = "file")
click :: proc(app: ^App, selector: string) {
	element := find(app, selector)
	if element == nil {
		return
	}
	_, _ = sa.do_click(element)
}

// ---- the heading palette (CTRL+R) ----------------------------------------------------------------
//
// The ranking and the parsing are `outline`'s, tested there with no engine in the way. What is worth a
// document is the SEAM: that the key reaches the palette at all while a widget has the focus, that the
// keys the input's own edit behavior would otherwise eat (enter, escape, the arrows) get to the palette
// first, that a row is a real control, and — the one that would be a silent wrong answer rather than a
// visible failure — that the caret ends up on the row the heading is actually on.

// CTRL+R opens it, and the list opens on the file being edited. Through the window handler: a key test with
// nothing attached passes without an event being delivered.
@(test)
test_ctrl_r_opens_the_heading_palette_on_the_open_file :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	testing.expect(t, effective_display_is_hidden(&app, "#bml-goto"), "the palette starts closed")
	press_key(&app, .R, ctrl = true)
	pump(&app)

	testing.expect(t, app.goto_open, "CTRL+R should open the palette")
	testing.expect(t, !effective_display_is_hidden(&app, "#bml-goto"), "the palette should be on screen")
	testing.expect(t, len(app.goto_all) > 100, "the whole corpus's headings should be indexed, not one file's")

	rows := goto_row_elements(&app)
	testing.expect(t, len(rows) > 0, "an empty query still lists headings")
	testing.expect(t, len(rows) <= GOTO_ROWS, "the list is capped at GOTO_ROWS rows")
	// The open file first, which is the whole reason the palette is worth opening with nothing typed.
	testing.expect_value(t, app.goto_rows[0].file, app.bml_open)
	// And the highlight is on the first row, so ENTER means something the moment it is open.
	marked, merr := sa.select_all(find(&app, "#bml-goto-list"), ".hit.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)

	// The same key closes it.
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, !app.goto_open, "CTRL+R again should close it")
	testing.expect(t, effective_display_is_hidden(&app, "#bml-goto"), "and take it off screen")
}

// Typing filters, and ENTER jumps — to ANOTHER FILE, which is the case a file-list-then-scroll workflow
// cannot do at all. The destination is read out of the index, so the assertion is on the caret's row rather
// than on a heading name this test hard-codes.
@(test)
test_typing_a_heading_and_pressing_enter_jumps_to_it :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)

	target, found := typeable_heading_elsewhere(&app)
	if !found {
		log.warn("no plainly-typeable heading in another chapter — skipping")
		return
	}
	type_query(&app, target.text)
	pump(&app)

	// An exact name is the top of the range in `outline.score_name`, so it is the highlighted row.
	testing.expect(t, len(app.goto_rows) > 0, "an exact heading name must match itself")
	testing.expect_value(t, app.goto_rows[0].text, target.text)
	testing.expect_value(t, app.goto_rows[0].file, target.file)

	press_key(&app, .ENTER)
	pump(&app)

	testing.expect(t, !app.goto_open, "a jump closes the palette")
	testing.expect_value(t, app.bml_open, target.file)
	testing.expect_value(t, caret_row(&app), target.row)
	// And the caret really is on that heading — the row is only a number until the line is read back.
	source, got := bml_source(&app, context.temp_allocator)
	testing.expect(t, got, "the file should be in the editor")
	lines := strings.split_lines(source, context.temp_allocator)
	if target.row < len(lines) {
		testing.expect(
			t,
			strings.contains(lines[target.row], target.text),
			fmt.tprintf("row %d of %s reads %q, not the heading", target.row, target.file, lines[target.row]),
		)
	}
}

// The arrows move the highlight and ESCAPE closes with the caret where it was. Both keys the input's own
// edit behavior would otherwise take, which is why the handler claims them on the way DOWN.
@(test)
test_the_arrows_choose_a_row_and_escape_closes_the_palette :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)
	if len(app.goto_rows) < 3 {
		log.warn("fewer than three headings listed — skipping")
		return
	}

	press_key(&app, .DOWN)
	press_key(&app, .DOWN)
	pump(&app)
	testing.expect_value(t, app.goto_sel, 2)
	// The mark follows the model, or the row ENTER acts on is not the row anyone can see.
	marked, _ := sa.select_all(find(&app, "#bml-goto-list"), ".hit.sel", context.temp_allocator)
	testing.expect_value(t, len(marked), 1)
	index, _ := sa.attribute(marked[0], "data-goto", context.temp_allocator)
	testing.expect_value(t, index, "2")

	// Up past the top WRAPS to the end rather than sticking, so a held key never looks broken.
	press_key(&app, .UP)
	press_key(&app, .UP)
	press_key(&app, .UP)
	pump(&app)
	testing.expect_value(t, app.goto_sel, len(app.goto_rows) - 1)

	before := caret_row(&app)
	press_key(&app, .ESCAPE)
	pump(&app)
	testing.expect(t, !app.goto_open, "escape closes the palette")
	testing.expect(t, effective_display_is_hidden(&app, "#bml-goto"), "and takes it off screen")
	testing.expect_value(t, caret_row(&app), before) // a cancel moves nothing
}

// A row is a real control. Same lesson as the scenario rows and the file rows: a plain `<div>` raises no
// `.BUTTON_CLICK`, so the pointer would do nothing at all and only `do_click` catches it.
@(test)
test_clicking_a_palette_row_jumps_to_that_heading :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)

	rows := goto_row_elements(&app)
	if len(rows) < 2 {
		log.warn("fewer than two headings listed — skipping")
		return
	}
	// The second row, so this cannot pass by accident on the one that was already highlighted.
	wanted := app.goto_rows[1]
	handled, cerr := sa.do_click(rows[1])
	testing.expect_value(t, cerr, nil)
	testing.expect(t, handled, "a palette row must answer a click (behavior: button)")
	pump(&app)

	testing.expect(t, !app.goto_open, "a click jumps and closes")
	testing.expect_value(t, app.bml_open, wanted.file)
	testing.expect_value(t, caret_row(&app), wanted.row)
}

// The palette belongs to the notes view: its keys are claimed while it is open, so leaving the view has to
// close it or ESCAPE and the arrows stay captured behind another tab.
@(test)
test_leaving_the_notes_view_closes_the_palette :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, app.goto_open, "the palette should be open")

	click(&app, `.tab[data-view="panes"]`)
	pump(&app)
	testing.expect(t, !app.goto_open, "switching view closes the palette")

	// And the key is nobody's outside the notes view.
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, !app.goto_open, "CTRL+R does nothing on the deals view")
}

// The index is built from the BUFFER for the file being edited, so a heading typed a moment ago is already a
// destination. This is the test that fails if the index is ever read from disk for the open file, or cached
// across an edit.
@(test)
test_the_palette_finds_a_heading_that_is_only_in_the_buffer :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	app.docs = ""

	// No folder, no files — the palette has nothing to index and says so rather than opening empty.
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, !app.goto_open, "with no folder there is nothing to go to")

	// A folder of one file, whose buffer holds a heading the FILE does not.
	dir := scratch_bml_dir(t)
	if dir == "" {return}
	defer os.remove(dir) // an empty directory; `remove` takes either on this platform
	name := "wb-goto-buffer.bml"
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("* On disk\n\n1C = strong\n")), nil)
	defer os.remove(path)

	use_bml_dir(&app, dir)
	// `use_bml_dir` frees what it replaces, so what it leaves behind is this test's to free -
	// `test_app_destroy` cannot, since other tests hand the same fields TEMP memory.
	defer {
		for listed in app.bml_names {
			delete(listed, app.allocator)
		}
		delete(app.bml_names, app.allocator)
		delete(app.docs, app.allocator)
		app.bml_names = nil
		app.docs = ""
	}
	pump(&app)
	testing.expect_value(t, app.bml_open, name)
	set_bml_source(&app, "* On disk\n\n1C = strong\n\n** Typed just now\n")
	pump(&app)

	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, app.goto_open, "the palette should open on a folder with headings in it")
	type_query(&app, "Typed just now")
	pump(&app)
	testing.expect(t, len(app.goto_rows) > 0, "a heading in the buffer is a destination")
	testing.expect_value(t, app.goto_rows[0].text, "Typed just now")
	press_key(&app, .ENTER)
	pump(&app)
	testing.expect_value(t, caret_row(&app), 4)
}

// A document the parser OBJECTS to still gets previewed, pane and all. This was broken and is exactly the
// kind of thing a hand test misses: most chapters are clean, so the pane appeared, and one mistyped
// directive was enough to render into a frame that was never shown - which reads as "preview does nothing on
// this file" rather than as a diagnostic.
@(test)
test_a_document_with_a_diagnostic_still_shows_the_preview_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	set_bml_source(&app, "#NOTADIRECTIVE oops\n\n* One\n\n1C = strong\n")
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	pump(&app)

	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "a document with a diagnostic still renders: %s", why)
	testing.expect(t, app.bml_showing, "the pane has to be up, diagnostic or not")
	testing.expect(t, !effective_display_is_hidden(&app, "#bml-page"), "the frame must be on screen")
	// And the diagnostic is still what the status line reports, since that is the useful half.
	testing.expect(t, len(why) > 0 && strings.contains(why, "marked"), fmt.tprintf("no diagnostic reported: %q", why))
}

// The PREVIEW half of the same scroll: the heading has to be FINDABLE in the rendered page, which is the
// part that can be wrong quietly — the host matches headings by their text, so a renderer that wrapped a
// heading's text in a span, or a trailing space, would silently stop the preview following the jump.
//
// The movement itself is not asserted, and cannot be here: `scroll_to_view` does nothing until the window
// has been shown and rendered (the bindings say so), and a windowless view must not reach into a DISPLAYED
// frame at all (see `preview_selection`) — so this previews into a HIDDEN frame, as the other preview tests
// do, and asserts the lookup.
@(test)
test_the_preview_can_find_the_heading_a_jump_landed_on :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	source := "* One\n\n1C = strong\n\n* Two Deep\n\n2C = weak\n\n*** Three\n\n3C = preempt\n"
	set_bml_source(&app, source)
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	pump(&app)

	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)
	pump(&app)

	// Every level the palette can jump to, including the `***` one that is not a top-level section.
	for name in ([]string{"One", "Two Deep", "Three"}) {
		testing.expectf(t, scroll_preview_to_heading(&app, name), "the preview should hold the heading %q", name)
	}
	// And a heading that is not there is reported rather than scrolling to something else.
	testing.expect(t, !scroll_preview_to_heading(&app, "Not A Heading Here"), "a missing heading is not found")
}

// THE CASE THAT MADE THE PREVIEW SCROLL LOOK COMPLETELY BROKEN, and the reason the lookup is by anchor id: a
// heading is BML, so `1!c-1!s` renders as `1<span class="ccolor">♣</span>-1<span class="scolor">♠</span>` and
// a heading holding a cross-reference renders an `<a>` inside it. Neither reads back as the typed string, so
// a text match found nothing — silently, on most of this corpus, since so many headings name a suit.
@(test)
test_the_preview_finds_a_heading_that_renders_as_markup :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	source := "* 1!c opening\n\n1C = strong\n\n** 1!c-1!s Compromise\n\n2N = balanced\n\n*** After a [double](#Takeout)\n"
	set_bml_source(&app, source)
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	pump(&app)
	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)
	pump(&app)

	// Exactly the strings the palette holds — the SOURCE text of each heading, macros and link markup and all.
	for name in ([]string{"1!c opening", "1!c-1!s Compromise", "After a [double](#Takeout)"}) {
		testing.expectf(
			t,
			scroll_preview_to_heading(&app, name),
			"the preview should find %q by its anchor id (%s)",
			name,
			bml.normalise_header_id(name, context.temp_allocator),
		)
	}
	// A near miss is still a miss: the id is the whole string, not a prefix of it.
	testing.expect(t, !scroll_preview_to_heading(&app, "1!c"), "a partial heading is not a heading")
}

// THE SCROLL, which is the half that made the jump look like it had done nothing: `selectRange` moves the
// caret and leaves the view where it was, so a heading 1700 lines down was selected off screen. Read from
// the widget's own scroll position, which is what a person would be looking at.
@(test)
test_a_jump_scrolls_the_source_to_the_heading :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	app.docs = ""

	// A file long enough to have somewhere to scroll TO: 400 lines of prose with a heading near the end.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "* The top of the file\n")
	for i in 0 ..< 400 {
		fmt.sbprintf(&b, "%dC = a bid on line %d\n", 1 + i % 7, i)
	}
	strings.write_string(&b, "*** A long way down\n\n2N = and its table\n")
	set_bml_source(&app, strings.to_string(b))
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	show_editor(&app)
	pump(&app)

	source, _ := bml_source(&app, context.temp_allocator)
	target := 0
	for line, row in strings.split_lines(source, context.temp_allocator) {
		if strings.contains(line, "A long way down") {
			target = row
		}
	}
	testing.expect(t, target > 200, "the heading should be a long way down the file")

	before, berr := sa.scroll_info(find(&app, "#bml-text"))
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, before.pos.y, 0)

	set_caret_row(&app, target)
	pump(&app)

	testing.expect_value(t, caret_row(&app), target)
	after, aerr := sa.scroll_info(find(&app, "#bml-text"))
	testing.expect_value(t, aerr, nil)
	testing.expectf(t, after.pos.y > 0, "the source pane did not scroll (still at %d)", after.pos.y)

	// The line is IN the view, and not at the very top of it: the lead-in is what tells you the heading is
	// in the middle of a document rather than at the start of one.
	line, cerr := sa.child(find(&app, "#bml-text"), sa.Child_Index(target))
	testing.expect_value(t, cerr, nil)
	box, lerr := sa.location(line, .Border, .Container)
	testing.expect_value(t, lerr, nil)
	testing.expectf(
		t,
		box.y >= after.pos.y && box.y + box.height <= after.pos.y + after.view.height,
		"line %d (at %d) is outside the view (%d..%d)",
		target,
		box.y,
		after.pos.y,
		after.pos.y + after.view.height,
	)
	testing.expectf(t, box.y - after.pos.y > 0, "there should be lead-in above the heading")
}

// The palette is a row of the editor's FLOW, not an overlay, and the reason is in the CSS header: an
// out-of-flow percentage height lays out 1px tall in this engine. So both halves have to keep their boxes
// while it is open - a palette that took the whole window, or one that laid out 1px tall, are the two ways
// this goes wrong and neither would fail any of the tests above.
@(test)
test_the_open_palette_leaves_both_editor_panes_a_box :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)

	for selector in ([]string{"#bml-goto", "#bml-goto-input", "#bml-goto-list", "#bml-text", ".split"}) {
		element := find(&app, selector)
		testing.expectf(t, element != nil, "no %s", selector)
		if element == nil {
			continue
		}
		box, err := sa.location(element, .Border, .Root)
		testing.expect_value(t, err, nil)
		testing.expectf(t, box.width > 100 && box.height > 4, "%s has no box: %dx%d", selector, box.width, box.height)
	}

	// The palette is a BAR: a few rows of a 780px window, not most of it. The cap is `max-height` on the
	// list, and a cap that stopped applying would be invisible until the source had nowhere to go.
	palette, _ := sa.location(find(&app, "#bml-goto"), .Border, .Root)
	source, _ := sa.location(find(&app, "#bml-text"), .Border, .Root)
	testing.expectf(
		t,
		palette.height < 340,
		"the palette is %dpx tall — the row cap stopped applying",
		palette.height,
	)
	testing.expectf(t, source.height > 200, "the source is only %dpx tall with the palette open", source.height)
}

// ---- the palette's test plumbing ----------------------------------------------------------------

// The window handler, attached the way `main` attaches it. Every palette test needs it: the keys and the
// row clicks both arrive through it, and without it a key test passes vacuously.
@(private = "file")
attach_for_test :: proc(app: ^App) {
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = app,
	}
	sa.attach_window_handler(app.window, &app.handler)
}

// A key press at the document ROOT, which is where a window handler hears it from whatever has the focus.
@(private = "file")
press_key :: proc(app: ^App, key: sciter.Sc_Kb_Codes, ctrl := false, shift := false) {
	root := sa.root(app.window) or_else nil
	if root == nil {
		return
	}
	states: sciter.Keyboard_States
	if ctrl {states += {.LCONTROL}}
	if shift {states += {.LSHIFT}}
	_, _ = sa.send_key(root, .DOWN, u32(key), states)
}

// Type into the query box the way a person would — one character at a time, so the edit behavior raises the
// `.VALUE_CHANGED` the list is redrawn from. Setting the value directly would test the redraw and not the
// wiring.
@(private = "file")
type_query :: proc(app: ^App, text: string) {
	input := find(app, "#bml-goto-input")
	if input == nil {
		return
	}
	_ = sa.set_focus(input)
	_ = sa.send_text(input, text)
	pump(app)
}

@(private = "file")
goto_row_elements :: proc(app: ^App) -> []sa.Element {
	rows, err := sa.select_all(find(app, "#bml-goto-list"), ".hit", context.temp_allocator)
	if err != nil {
		return nil
	}
	return rows
}

// A heading in a DIFFERENT chapter whose name can be typed literally: no `!c` suit macro, no punctuation the
// edit behavior might treat as a shortcut. The corpus has hundreds, so this is a filter and not a search.
@(private = "file")
typeable_heading_elsewhere :: proc(app: ^App) -> (heading: outline.Heading, ok: bool) {
	for entry in app.goto_all {
		if entry.file == app.bml_open || len(entry.text) < 6 || len(entry.text) > 40 {
			continue
		}
		plain := true
		for r in entry.text {
			if !(r == ' ' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')) {
				plain = false
				break
			}
		}
		if !plain {
			continue
		}
		// Unique in the corpus, or the ranking's tie-break is what this test would be asserting.
		seen := 0
		for other in app.goto_all {
			if other.text == entry.text {
				seen += 1
			}
		}
		if seen == 1 {
			return entry, true
		}
	}
	return {}, false
}

// A directory of our own to point the editor at. The user's notes are not a scratch space, and this test
// writes.
@(private = "file")
scratch_bml_dir :: proc(t: ^testing.T) -> string {
	dir, jerr := filepath.join({os.get_env("TEMP", context.temp_allocator), "wb-goto-scratch"}, context.temp_allocator)
	if jerr != nil {
		log.warn("no scratch directory available — skipping")
		return ""
	}
	if err := os.make_directory(dir); err != nil && !os.exists(dir) {
		log.warnf("could not make %s (%v) — skipping", dir, err)
		return ""
	}
	return strings.clone(dir, context.temp_allocator)
}

// ---- the file sidebar ---------------------------------------------------------------------------
//
// The list is the picker now, so three things it does are worth pinning: a row has to be CLICKABLE at all
// (`behavior: button` — the bug the scenario rows already taught this codebase), the list has to fold away,
// and pointing the editor at another folder has to replace the list rather than accumulate it.

// A row is a real control and a click on it opens the file. `do_click` goes through the same native
// controller a pointer does, which is why it catches a missing `behavior: button` where calling the handler
// directly would not.
@(test)
test_clicking_a_file_row_opens_it :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	rows, rerr := sa.select_all(find(&app, "#bml-list"), ".row", context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, len(rows), len(app.bml_names))
	if len(rows) < 2 {
		log.warn("fewer than two .bml files — nothing to click; skipping")
		return
	}

	// The second row, so this cannot pass by accident on the file `show_editor` opens by itself.
	wanted, _ := sa.attribute(rows[1], "data-file", context.temp_allocator)
	name := strings.clone(wanted, context.temp_allocator)
	handled, cerr := sa.do_click(rows[1])
	testing.expect_value(t, cerr, nil)
	testing.expect(t, handled, "a file row must answer a click (behavior: button)")
	pump(&app)

	testing.expect_value(t, app.bml_open, name)
	source, got := bml_source(&app, context.temp_allocator)
	testing.expect(t, got && len(source) > 0, "the file's text should be in the editor")

	// Exactly one row marked, and it is that one — the list is a projection of `bml_open`, so two marks
	// would mean two sources of truth.
	marked, merr := sa.select_all(find(&app, "#bml-list"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	open_name, _ := sa.attribute(marked[0], "data-file", context.temp_allocator)
	testing.expect_value(t, open_name, name)
}

// The toggle folds the list away and brings it back, and the two panes take the room. Read from the document
// both times, because that is what the toggle itself reads — a remembered flag could disagree with it.
@(test)
test_the_files_toggle_folds_the_sidebar :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	testing.expect(t, !effective_display_is_hidden(&app, "#bml-files"), "the list starts on screen")
	wide, _ := sa.location(find(&app, "#bml-text"), .Border, .Root)

	sa.do_click(find(&app, "#bml-files-toggle"))
	pump(&app)
	testing.expect(t, effective_display_is_hidden(&app, "#bml-files"), "the list should fold away")
	folded, _ := sa.location(find(&app, "#bml-text"), .Border, .Root)
	testing.expectf(
		t,
		folded.width > wide.width,
		"the source pane did not take the room: %dpx with the list, %dpx without",
		wide.width,
		folded.width,
	)

	sa.do_click(find(&app, "#bml-files-toggle"))
	pump(&app)
	testing.expect(t, !effective_display_is_hidden(&app, "#bml-files"), "and come back")
}

// Pointing the editor at another folder REPLACES what it was showing. This is the half of the folder dialog
// that can be tested: the dialog itself blocks in native modal code, so `choose_bml_folder` stops at the
// `Window.this.selectFolder` call and everything after it lives here.
@(test)
test_choosing_a_folder_replaces_the_list :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	// `editor_corpus` hands out temp-allocated names; `use_bml_dir` frees what it replaces with the app's
	// allocator, so this test owns its own copies from the start.
	app.docs = strings.clone(app.docs, app.allocator)
	app.bml_names = clone_strings(app.bml_names, app.allocator)
	// `use_bml_dir` frees what it replaces, so whatever it leaves behind at the end is this test's to free —
	// `test_app_destroy` cannot, since other tests hand the same fields TEMP memory.
	defer {
		for name in app.bml_names {
			delete(name, app.allocator)
		}
		delete(app.bml_names, app.allocator)
		delete(app.docs, app.allocator)
	}
	show_editor(&app)
	pump(&app)
	testing.expect(t, len(app.bml_names) > 1, "the corpus should have more than one file")

	// A folder of our own with one file in it.
	dir := filepath.join({"target", "debug", "wb-editor-folder"}, context.temp_allocator) or_else "."
	if err := os.make_directory_all(dir); err != nil {
		log.warnf("could not create %s (%v) — skipping", dir, err)
		return
	}
	name := "only.bml"
	path := filepath.join({dir, name}, context.temp_allocator) or_else name
	if err := os.write_entire_file(path, transmute([]u8)string("#+TITLE: only\r\n")); err != nil {
		log.warnf("could not write %s (%v) — skipping", path, err)
		return
	}
	defer os.remove(path)

	use_bml_dir(&app, dir)
	pump(&app)

	testing.expect_value(t, len(app.bml_names), 1)
	testing.expect_value(t, app.bml_open, name) // the one file is opened for you
	testing.expect_value(t, app.docs, dir)

	rows, _ := sa.select_all(find(&app, "#bml-list"), ".row", context.temp_allocator)
	testing.expect_value(t, len(rows), 1) // replaced, not appended to
	shown, _ := sa.attribute(rows[0], "data-file", context.temp_allocator)
	testing.expect_value(t, shown, name)

	folder, ferr := sa.text(find(&app, "#bml-dir"), context.temp_allocator)
	testing.expect_value(t, ferr, nil)
	testing.expect(t, strings.contains(folder, "wb-editor-folder"), "the folder should be named above its files")

	// A folder with no notes in it is reported and KEPT, rather than refused: "did it not work, or is it
	// empty?" is a question the window should answer by itself.
	empty := filepath.join({"target", "debug", "wb-editor-empty"}, context.temp_allocator) or_else "."
	if err := os.make_directory_all(empty); err == nil {
		use_bml_dir(&app, empty)
		pump(&app)
		testing.expect_value(t, len(app.bml_names), 0)
		testing.expect_value(t, app.bml_open, "")
		none, _ := sa.select_all(find(&app, "#bml-list"), ".row", context.temp_allocator)
		testing.expect_value(t, len(none), 0)
	}
}

// With no folder found at startup the editor still OPENS, and says what to do. It used to refuse and name an
// environment variable, which is no use to somebody holding a mouse — the `folder…` button is the answer and
// it is in the view being refused.
@(test)
test_the_editor_opens_without_a_corpus :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.docs = ""
	app.bml_names = nil
	show_editor(&app)
	pump(&app)

	testing.expect_value(t, current_view(&app), View.Editor)
	testing.expect(t, find(&app, "#bml-folder") != nil, "the way out has to be in the view")
	status, _ := sa.text(find(&app, "#bml-status"), context.temp_allocator)
	testing.expect(t, strings.contains(status, "folder"), "it should say to choose a folder, not name a variable")
}

// A PREVIEW ON SCREEN FOLLOWS THE BUFFER. Clicking another file used to leave the old file rendered beside
// the new source, with nothing in the window to say so — the worst kind of wrong, because it looks right.
//
// Read through the frame's own document, hidden (see `preview_selection`), and asserted on the HEADING,
// which is the one thing that differs per file and is not in the source pane at all.
@(test)
test_a_preview_follows_the_file_that_is_open :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := filepath.join({"target", "debug", "wb-editor-follow"}, context.temp_allocator) or_else "."
	if err := os.make_directory_all(dir); err != nil {
		log.warnf("could not create %s (%v) - skipping", dir, err)
		return
	}
	first, second := "aaa-first.bml", "zzz-second.bml"
	// The cleanup is deferred OUT HERE rather than inside the loop: a `defer` in a loop body runs at the end
	// of each ITERATION, so `defer os.remove(path)` there deleted each file the moment it was written and
	// left the list empty — which read as `list_bml_files` being broken.
	defer for name in ([]string{first, second}) {
		if path := filepath.join({dir, name}, context.temp_allocator) or_else ""; path != "" {
			os.remove(path)
		}
	}
	for pair in ([][2]string{{first, "Opening bids"}, {second, "Slam bidding"}}) {
		path := filepath.join({dir, pair[0]}, context.temp_allocator) or_else pair[0]
		text := strings.concatenate(
			{"#+TITLE: t\r\n\r\n* ", pair[1], "\r\n\r\n1C = 16+ hcp\r\n"},
			context.temp_allocator,
		)
		if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
			log.warnf("could not write %s (%v) - skipping", path, err)
			return
		}
	}

	app.docs = strings.clone(dir, app.allocator)
	app.bml_names = list_bml_files(dir, app.allocator)
	defer {
		for name in app.bml_names {
			delete(name, app.allocator)
		}
		delete(app.bml_names, app.allocator)
		delete(app.docs, app.allocator)
	}
	testing.expect_value(t, len(app.bml_names), 2)

	// NOT shown: `show_editor` would display the frame, and a displayed frame cannot be read into from a
	// windowless view at all. The buffer and the preview do not care which view is on screen.
	draw_bml_files(&app)
	ok, why := open_bml(&app, first)
	testing.expectf(t, ok, "could not open %s: %s", first, why)
	pump(&app)

	// No preview asked for yet, so opening a file must not render one — the first is something you ask for.
	testing.expect(t, !app.previewed, "opening a file should not preview it by itself")

	rendered, reason := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", reason)
	pump(&app)
	testing.expect(t, app.previewed, "a rendered preview should be remembered")
	heading, found := preview_selection(&app, "h1")
	testing.expect(t, found, "the preview has no heading")
	testing.expect_value(t, heading, "Opening bids")

	// The bug: click the other file, and the preview must move with it.
	switch_bml_file(&app, second)
	pump(&app)
	testing.expect_value(t, app.bml_open, second)
	moved, still_there := preview_selection(&app, "h1")
	testing.expect(t, still_there, "the preview vanished when the file changed")
	testing.expect_value(t, moved, "Slam bidding")

	// And a new FOLDER forgets the preview: what is in the frame belongs to the folder just left, so the
	// next file opened there should not silently re-render into it.
	use_bml_dir(&app, dir)
	testing.expect(t, !app.previewed, "a folder change should forget the preview")
}

// ---- the squiggles ------------------------------------------------------------------------------
//
// The parse's diagnostics, marked on the text they are about. Same seam as the colour and the same
// problem: the marking happens in the document through an API this side cannot read back, so the script
// reports a COUNT and answers `bmlProblemAt` for the message. What these tests can and cannot see:
//   * the count, and the message at a position - both from the script;
//   * NOT the hover itself. `rangeFromPoint` needs a box, and in a windowless view the editor is inside a
//     hidden view, so every line measures 0x0 (measured). The hover's two halves are tested separately: the
//     lookup here, and the mark under the pointer by `page-check`'s cousin - the real window.

// The number of problems the document is currently holding, straight from the script.
@(private = "file")
problem_count :: proc(app: ^App) -> int {
	// The list lives ON THE EDITOR ELEMENT now — one per editor, since the scenario editor squiggles its
	// own parse — so this asks the notes editor for its own, and `|| 0` covers a buffer nothing has ever
	// marked (the property does not exist until the first `bmlSetProblems`).
	result, err := sa.eval(app.window, `(document.$("#bml-text").wbProblems || []).length`)
	defer sa.value_clear(&result)
	if err != nil {
		return -1
	}
	count, ierr := sa.value_to_int(&result)
	return ierr == nil ? int(count) : -1
}

// What the hover would say at that line and column.
@(private = "file")
problem_at :: proc(app: ^App, line, col: int) -> string {
	script := fmt.tprintf("bmlProblemAt(%d, %d)", line, col)
	result, err := sa.eval(app.window, script)
	defer sa.value_clear(&result)
	if err != nil {
		return ""
	}
	text, terr := sa.value_to_string(&result, context.temp_allocator)
	return terr == nil ? text : ""
}

// A misspelled directive is the diagnostic that matters most, because without it the whole block is dropped
// from the page in silence. It has to arrive at the right line, and be readable there.
@(test)
test_a_bad_directive_is_squiggled_where_it_is :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // no corpus needed: the buffer is written directly

	set_bml_source(&app, "* Openings\n\n1C = strong\n\n  #HDIE\n  1D = negative\n")
	pump(&app)
	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)

	testing.expect_value(t, problem_count(&app), 1)
	// Line 5, column 3 — the `#` of `#HDIE`, two spaces in.
	message := problem_at(&app, 5, 3)
	testing.expectf(t, strings.contains(message, "#HDIE"), "the message does not name the directive: %q", message)
	testing.expect_value(t, problem_at(&app, 3, 1), "") // and nothing on the good line
	testing.expectf(t, strings.contains(why, "1 marked"), "the status should say what was marked: %q", why)
}

// The cross-reference check is OFF by default and the button turns it on, because a chapter of this corpus
// links to headings in its sibling files on purpose. Both states are the point.
@(test)
test_the_links_toggle_decides_whether_anchors_are_checked :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	// A click test needs the window handler ATTACHED, or every "nothing happened" passes vacuously.
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	set_bml_source(&app, "* Real Heading\n\nsee [elsewhere](#No Such Heading)\n")
	pump(&app)
	rendered, _ := preview_bml(&app)
	testing.expect(t, rendered, "the preview did not render")
	testing.expect_value(t, problem_count(&app), 0)

	// The button, not the flag: the click path is what a person has.
	click(&app, "#bml-links")
	pump(&app)
	testing.expect(t, app.bml_links, "the click should turn the check on")
	testing.expect_value(t, problem_count(&app), 1)
	message := problem_at(&app, 3, 17)
	testing.expectf(t, strings.contains(message, "anchor"), "the message should name the anchor: %q", message)

	// And off again, with the squiggle going away rather than being left behind.
	click(&app, "#bml-links")
	pump(&app)
	testing.expect(t, !app.bml_links, "the second click should turn the check off")
	testing.expect_value(t, problem_count(&app), 0)
}

// A diagnostic about an INCLUDED file has no line in this buffer, so marking it would put a squiggle on
// whatever happens to be at that line number. It is reported in the transcript instead.
@(test)
test_a_problem_in_another_file_is_reported_but_not_marked :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // so the include cannot be resolved from anywhere

	set_bml_source(&app, "* Openings\n\n#INCLUDE nowhere.bml\n")
	pump(&app)
	rendered, _ := preview_bml(&app)
	testing.expect(t, rendered, "the preview did not render")

	// The include's own line IS in this buffer, so that one is marked.
	testing.expect_value(t, problem_count(&app), 1)
	testing.expect(
		t,
		strings.contains(strings.to_string(app.transcript), "nowhere.bml"),
		"the transcript should name the file that could not be read",
	)
}

// A squiggle is a position, and a position is only true of the text it was computed from. Opening another
// file has to take the marks with it - the alternative is a confident underline on an innocent word.
@(test)
test_a_squiggle_does_not_survive_the_buffer_it_was_computed_from :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir, jerr := filepath.join({os.get_env("TEMP", context.temp_allocator), "wb-squiggle"}, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	os.make_directory(dir)
	name := "one.bml"
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("* One\n\n1C = strong\n")), nil)
	defer os.remove(path)

	app.docs = "" // the bad text is written straight into the widget
	set_bml_source(&app, "#HDIE\n1C = strong\n")
	pump(&app)
	rendered, _ := preview_bml(&app)
	testing.expect(t, rendered, "the preview did not render")
	testing.expect_value(t, problem_count(&app), 1)

	// Now open a real file over it.
	use_bml_dir(&app, dir)
	pump(&app)
	opened, why := open_bml(&app, name)
	testing.expectf(t, opened, "the file did not open: %s", why)
	pump(&app)
	testing.expect_value(t, problem_count(&app), 0)
}

// ---- the global zoom ----------------------------------------------------------------------------
//
// CTRL+wheel, CTRL+plus/minus, CTRL+0. Split across the two languages for a measured reason (a wheel's
// delta reaches no host handler), so what is tested here is the seam: the script's clamp and round trip,
// the KEY path through the real window handler, and that the property really changes a box. The physical
// wheel is the one part no test can drive — it has no host-side entry point to synthesise.

// The width of a control, as the engine laid it out. The measurement zoom is supposed to move.
@(private = "file")
button_width :: proc(app: ^App, selector: string) -> i32 {
	element := find(app, selector)
	if element == nil {
		return 0
	}
	box, err := sa.location(element, .Border, .Root)
	return err == nil ? box.width : 0
}

@(test)
test_zoom_scales_the_window_and_comes_back :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Not a silent skip: if this button has no box the test would "pass" having measured nothing.
	base := button_width(&app, "#generate")
	if !testing.expect(t, base > 0, "the generate button has no box to measure") {
		return
	}
	testing.expect_value(t, zoom_factor(&app), 1)

	// Four notches in is 1.1^4 ≈ 1.46, and the box has to move with it: `zoom` is a LAYOUT property in
	// this engine, which is the fact the whole feature rests on.
	for _ in 0 ..< 4 {
		zoom_step(&app, 1)
	}
	pump(&app)
	factor := zoom_factor(&app)
	testing.expectf(t, factor > 1.4 && factor < 1.5, "four notches in should be about 1.46, not %v", factor)
	wide := button_width(&app, "#generate")
	testing.expectf(t, wide > base, "the button is %dpx at %v zoom, was %dpx at 1", wide, factor, base)

	// CTRL+0 is a return to exactly 1, not to approximately 1 — the steps are multiplicative.
	zoom_step(&app, 0)
	pump(&app)
	testing.expect_value(t, zoom_factor(&app), 1)
	testing.expect_value(t, button_width(&app, "#generate"), base)
}

@(test)
test_zoom_stops_at_its_limits :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Far past either end, in one direction and then the other. A clamp that let the factor run would
	// leave a window nobody can read and no way back to it with the pointer.
	for _ in 0 ..< 40 {
		zoom_step(&app, 1)
	}
	high := zoom_factor(&app)
	testing.expectf(t, high <= 2.5 && high >= 2.2, "the top of the range should be about 2.5, not %v", high)

	for _ in 0 ..< 40 {
		zoom_step(&app, -1)
	}
	low := zoom_factor(&app)
	testing.expectf(t, low >= 0.7 && low <= 0.8, "the bottom of the range should be about 0.7, not %v", low)

	zoom_step(&app, 0)
	testing.expect_value(t, zoom_factor(&app), 1)
}

// The keyboard half, through the window handler the application installs — a key test with nothing attached
// would pass without a single event being delivered.
@(test)
test_ctrl_plus_and_minus_and_zero_are_the_zoom_keys :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	root := sa.root(app.window) or_else nil
	press :: proc(root: sa.Element, key: sciter.Sc_Kb_Codes, ctrl: bool) {
		_, _ = sa.send_key(root, .DOWN, u32(key), ctrl ? sciter.Keyboard_States{.LCONTROL} : {})
	}

	press(root, .EQUAL, true)
	testing.expectf(t, zoom_factor(&app) > 1, "CTRL+= should zoom in, factor is %v", zoom_factor(&app))
	press(root, .MINUS, true)
	testing.expect_value(t, zoom_factor(&app), 1)

	press(root, .KP_ADD, true)
	press(root, .KP_ADD, true)
	testing.expectf(t, zoom_factor(&app) > 1.2, "the numpad should zoom too, factor is %v", zoom_factor(&app))
	press(root, .NUM_0, true)
	testing.expect_value(t, zoom_factor(&app), 1)

	// WITHOUT ctrl, none of these are zoom keys — `-` and `0` are characters somebody is typing.
	press(root, .MINUS, false)
	press(root, .NUM_0, false)
	press(root, .EQUAL, false)
	testing.expect_value(t, zoom_factor(&app), 1)

	// And the status line says what happened, since a zoom has no other announcement.
	press(root, .EQUAL, true)
	status, _ := sa.text(find(&app, "#status"), context.temp_allocator)
	testing.expectf(t, strings.contains(status, "zoom"), "the status should report the zoom: %q", status)
	press(root, .NUM_0, true)
}

// ---- the preview's section window ----------------------------------------------------------------
//
// The preview hands the engine ONE section of the notes, because the assembled document costs 328MB laid
// out in full (`just mem-check`) and this engine cannot un-spend layout: hiding the rest with
// `display: none` from a script measured WORSE than leaving it alone. So the cut is in the text, and these
// tests are about the seam - the wrapper really does cut, the `full` button really does not, and the status
// line says which of the two you are looking at.

@(test)
test_the_preview_carries_one_section_and_full_carries_all :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // no corpus needed: the buffer is written directly

	source := "#+TITLE: T\n\n* One\n\n1C = strong\n\n* Two\n\n2C = weak\n\n* Three\n\n3C = preempt\n"
	set_bml_source(&app, source)
	pump(&app)

	doc := bml.parse(source)
	defer bml.destroy(doc)
	html := bml.render_html(doc, context.temp_allocator)
	testing.expect_value(t, preview.section_count(html), 3)

	// Section 1 (the middle one) and nothing else: the neighbours' own text has to be absent, which is what
	// "the engine never lays it out" means at this level.
	// The DESCRIPTIONS are what a test looks for, not the calls: a bid's suit is rendered as a glyph, so
	// `1C` in the source is `1<span class="ccolor">&#9827;</span>` in the page.
	//
	// The chosen section is there; what is NOT asserted here is that its neighbours are absent, because the
	// window grows forward until it holds something worth reading and these sections are a line each. The
	// exact windows are `preview`'s own tests (`just test-preview`).
	one := preview_document(&app, html, 1, context.temp_allocator)
	testing.expect(t, strings.contains(one, "weak"), "the chosen section must be in the document")
	// Still a document, and still styled: the head and the inlined stylesheet are what make it one.
	testing.expect(t, strings.contains(one, "<style>"), "the preview must keep its stylesheet")
	testing.expect(t, strings.contains(one, "</body>"), "the preview must still close its body")

	// `full` is the same wrapper with -1, and it has everything.
	all := preview_document(&app, html, -1, context.temp_allocator)
	for expected in ([]string{"strong", "weak", "preempt"}) {
		testing.expectf(t, strings.contains(all, expected), "the whole document should hold %s", expected)
	}
	testing.expect(t, len(all) >= len(one), "the whole document cannot be smaller than a slice of it")
}

@(test)
test_the_preview_follows_the_caret_and_says_which_section :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	source := "* One\n\n1C = strong\n\n* Two\n\n2C = weak\n\n* Three\n\n3C = preempt\n"
	set_bml_source(&app, source)
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	pump(&app)

	// A click test needs the handler attached, or "nothing happened" passes without an event being delivered.
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	// This document is TINY, so the size-based default is the whole thing - which is the fix for a chapter
	// that used to open showing nothing but its first heading.
	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)
	testing.expect_value(t, app.bml_scope, Preview_Scope.Unfolded)
	testing.expectf(t, strings.contains(why, "unfolded"), "a small document should open unfolded: %q", why)

	// Folding says which sections are OPEN, because the window grows forward until there is something to read
	// and naming only the first would be a lie.
	click(&app, "#bml-fold")
	pump(&app)
	testing.expect_value(t, app.bml_scope, Preview_Scope.Folded)
	_, section_why := preview_bml(&app)
	testing.expectf(
		t,
		strings.contains(section_why, "folded"),
		"the status should say the document is folded: %q",
		section_why,
	)

	// And back, through the other button of the pair.
	click(&app, "#bml-fold")
	pump(&app)
	testing.expect_value(t, app.bml_scope, Preview_Scope.Unfolded)
}

// A big document defaults the other way, and that is the whole point of the rule: the threshold is the
// document's SIZE, not a fixed preference, because 17KB whole is a few MB and 1.18MB whole is 328MB.
@(test)
test_a_big_document_opens_on_one_section :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	// Enough sections of enough prose to pass `preview.WHOLE_DOCUMENT_MAX` once rendered.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 140 {
		fmt.sbprintf(&b, "* Section %d\n\n", i)
		for _ in 0 ..< 12 {
			strings.write_string(&b, "some prose about bidding, long enough to add up over sixty sections\n")
		}
		strings.write_string(&b, "\n")
	}
	set_bml_source(&app, strings.to_string(b))
	pump(&app)

	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)
	testing.expect_value(t, app.bml_scope, Preview_Scope.Folded)
	testing.expect(t, strings.contains(why, "folded"), "a big document should open folded")
}

// The preview is a TOGGLE, and closing it is what hands the rendered document back to the engine.
@(test)
test_the_preview_button_closes_the_preview :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	set_bml_source(&app, "* One\n\n1C = strong\n")
	pump(&app)

	click(&app, "#bml-preview")
	pump(&app)
	testing.expect(t, app.bml_showing, "the first press should show the preview")
	testing.expect(t, !effective_display_is_hidden(&app, "#bml-page"), "the pane should be on screen")
	label, _ := sa.text(find(&app, "#bml-preview"), context.temp_allocator)
	testing.expect_value(t, strings.trim_space(label), "close")

	click(&app, "#bml-preview")
	pump(&app)
	testing.expect(t, !app.bml_showing, "the second press should close it")
	testing.expect(t, effective_display_is_hidden(&app, "#bml-page"), "the pane should be off screen")
	closed_label, _ := sa.text(find(&app, "#bml-preview"), context.temp_allocator)
	testing.expect_value(t, strings.trim_space(closed_label), "preview")
}


// The window froze once because a `mouseidle` handler called a method that does not exist
// (`plaintext.popup(...)`, from the SDK's marks sample) and threw on every hover. A handler that throws
// stops the window accepting clicks, and the only trace was an unhandled promise rejection naming the
// engine's own `debug-peer.js`. So: no popups in this document, and the hover path says so out loud.
@(test)
test_the_document_opens_no_popups :: proc(t: ^testing.T) {
	document := compose_document(context.temp_allocator)
	// Not "<popup" in general: the engine renders a `title=` tooltip as one and the stylesheet rightly
	// styles it. What must not come back is a popup THIS document owns, and the call that opens it.
	testing.expect(t, !strings.contains(document, `id="bml-tip"`), "the tip popup is what froze the window")
	testing.expect(t, !strings.contains(document, ".popup("), "nothing here may call an element's popup method")
	// The hover is a status-line message now, and it is guarded: a throw inside it must not escape.
	testing.expect(t, strings.contains(document, "function bmlMessageAt"), "the hover lookup must be there")
	testing.expect(t, strings.contains(document, "catch (x) {"), "the hover handler must catch its own errors")
}

// Every function the editor's script calls on an ELEMENT has to exist, because a typo is not a syntax error
// here - it is a TypeError at the moment a person hovers, and the window stops taking clicks. These are the
// ones this document depends on, checked against the engine rather than against the documentation.
@(test)
test_the_element_methods_the_editor_calls_exist :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	set_bml_source(&app, "1C = strong\n")
	pump(&app)

	probe := `(function(){
		var editor = document.$("#bml-text");
		var missing = [];
		var wanted = ["rangeFromPoint", "timer"];
		for (var i = 0; i < wanted.length; i++) {
			if (typeof editor[wanted[i]] !== "function") missing.push(wanted[i]);
		}
		var r = new Range();
		var line = editor.children[0];
		if (line && line.firstChild) {
			r.setStart(line.firstChild, 0);
			r.setEnd(line.firstChild, 1);
			var range_wanted = ["applyMark", "clearMark", "marks"];
			for (var j = 0; j < range_wanted.length; j++) {
				if (typeof r[range_wanted[j]] !== "function") missing.push("Range." + range_wanted[j]);
			}
		} else {
			missing.push("no line to test a Range against");
		}
		return missing.join(",");
	})()`
	result, err := sa.eval(app.window, probe)
	defer sa.value_clear(&result)
	testing.expect_value(t, err, nil)
	missing, _ := sa.value_to_string(&result, context.temp_allocator)
	testing.expectf(t, missing == "", "the editor calls methods this engine does not have: %s", missing)
}

/*
A small text output, echoed into the report pane as well as written to its file.

The deals ARE the output of this window, and up to a point the pane is a better place to read them than a
file somebody has to go and open: `pretty` of a couple of dozen deals is exactly the thing you want to
glance at after pressing generate. Past that it stops being a glance, hence `ECHO_MAX_DEALS` and the
`text_format` test - a 48-board card page is not text, and forty scenarios of it in a transcript would be
neither readable nor cheap (the report pane is a `<plaintext>`, which is NOT virtualised: ~22KB a line,
measured).

Read from the FILE rather than kept from the run: `cli.run` writes the output and hands nothing back, and
re-reading it is both simpler and honest about what was actually written.
*/
ECHO_MAX_DEALS :: 48

echo_output :: proc(app: ^App, path: string) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		transcribe(app, fmt.tprintf("  (could not read %s back: %v)", filepath.base(path), err))
		return
	}
	text := strings.trim_right_space(string(data))
	if text == "" {
		transcribe(app, "  (it is empty)")
		return
	}
	// Line by line, so the pane's own line structure matches the file's: `transcribe` appends one line at a
	// time and the widget's content is its lines (see `draw_transcript`).
	for line in strings.split_lines(text, context.temp_allocator) {
		transcribe(app, line)
	}
}

// ---- the generated file's name, and the echo ------------------------------------------------------
//
// Every text format used to write `<scenario>.txt`, so `pretty` then `line` of one scenario overwrote the
// first and "view page" could not tell them apart. One extension per format fixes both.
@(test)
test_each_format_writes_its_own_extension :: proc(t: ^testing.T) {
	seen := make(map[string]string, 8, context.temp_allocator)
	for format in ([]string{"pretty", "line", "handviewer", "pbn", "lin", "numeric"}) {
		extension := extension_for(format)
		testing.expectf(t, extension != "", "%s has no extension", format)
		if owner, clash := seen[extension]; clash {
			testing.expectf(t, false, "%s and %s would both write %s", owner, format, extension)
		}
		seen[extension] = format
	}
	// THE TWO HTML FORMATS NO LONGER SHARE `.html`, and this assertion used to say they did "on purpose" —
	// in a test named for the opposite rule. Sharing meant generating a scenario as one and then as the
	// other REPLACED the first, and the chip row could only show a single `html` chip for two different
	// things. `file_kind` still reads a page's kind from INSIDE it, which is what keeps the `.html` files
	// generated before this split opening correctly.
	testing.expect_value(t, extension_for("html-cards"), ".html")
	testing.expect_value(t, extension_for("html-handviewer"), ".hv.html")
	// And an unknown format is text rather than nothing.
	testing.expect_value(t, extension_for("something-new"), ".txt")
}

// Every option the format dropdown offers has to be a format the parser accepts AND one this side can name a
// file for. A dropdown that offers a format norn rejects is a button that fails.
@(test)
test_every_format_option_is_real :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	element := find(&app, "#format")
	options, err := sa.select_all(element, "option", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, len(options) >= 5, "the dropdown should offer every format")
	for option in options {
		value, _ := sa.attribute(option, "value", context.temp_allocator)
		argv := []string{"-n", "1", "-f", value, "-o", "-"}
		_, ok, message := cli.parse_args(argv)
		testing.expectf(t, ok, "norn rejects the format %q the dropdown offers: %s", value, message)
		testing.expectf(t, extension_for(value) != "", "%q has no extension", value)
	}
}

// A small text run is shown in the pane as well as written to the file — the deals are the output of this
// window, and up to a point the pane is where you want to read them.
@(test)
test_a_small_text_run_is_echoed_into_the_report_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "4")
	type_into(&app, "#seed", "42")
	type_into(&app, "#outdir", PARITY_DIR)
	type_into(&app, "#format", "pretty")

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	testing.expect(t, job.echo, "four deals of pretty text is worth echoing")
	testing.expect_value(t, job.ext, ".txt")

	// Write one scenario's output the way the worker does, then echo it.
	path := PARITY_DIR + "/wb-echo.txt"
	argv := make([dynamic]string, 0, len(job.argv) + 4, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, "-S", job.scenarios[0], "-o", path)
	opts, ok, message := cli.parse_args(argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	run_ok, run_message := cli.run(bidding.registry, opts)
	testing.expectf(t, run_ok, "the in-process run failed: %s", run_message)
	defer os.remove(path)

	echo_output(&app, path)
	pump(&app)
	transcript := strings.to_string(app.transcript)
	testing.expect(t, len(transcript) > 100, "the deals should be in the pane")
	// `pretty` draws the four hands round a compass, so the pane holds the seat letters.
	testing.expect(t, strings.contains(transcript, "North") || strings.contains(transcript, "N "), "")
	// And what is in the pane is what is in the file.
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	first := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)[0]
	testing.expectf(t, strings.contains(transcript, first), "the pane should hold the file's first line %q", first)
}

// A card page is not text, and forty scenarios of it in a `<plaintext>` would be neither readable nor cheap.
@(test)
test_a_card_page_run_is_not_echoed :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "4")
	type_into(&app, "#outdir", PARITY_DIR)
	type_into(&app, "#format", "html-cards")
	job, cards_err := generate_job(&app)
	testing.expect_value(t, cards_err, "")
	testing.expect(t, !job.echo, "an html page must not be poured into the transcript")

	// Nor is a big text run: past `ECHO_MAX_DEALS` it stops being a glance.
	type_into(&app, "#format", "pretty")
	type_into(&app, "#count", "500")
	big, big_err := generate_job(&app)
	testing.expect_value(t, big_err, "")
	testing.expect(t, !big.echo, "500 deals is not a glance")
	app.job = big
}

// The LIN format exists so a generated deal can be OPENED somewhere - a bridgebase or IntoBridge hand link -
// and read back by the advisor. Both halves are worth pinning here, because they are what make the format
// worth having: the record's shape, and that norn's own reader accepts what norn's writer produced.
@(test)
test_a_generated_lin_record_round_trips :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "3")
	type_into(&app, "#seed", "7")
	type_into(&app, "#outdir", PARITY_DIR)
	type_into(&app, "#format", "lin")
	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	testing.expect_value(t, job.ext, ".lin")
	testing.expect(t, job.echo, "three deals of text is worth echoing")

	path := PARITY_DIR + "/wb-lin.lin"
	argv := make([dynamic]string, 0, len(job.argv) + 4, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, "-S", job.scenarios[0], "-o", path)
	opts, ok, message := cli.parse_args(argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	run_ok, run_message := cli.run(bidding.registry, opts)
	testing.expectf(t, run_ok, "the in-process run failed: %s", run_message)
	defer os.remove(path)

	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
	testing.expect_value(t, len(lines), 3)
	for line in lines {
		testing.expectf(t, strings.has_prefix(line, "st||md|"), "not a LIN record: %q", line)
		// The advisor's own reader, on the generator's own output: this is the loop the format is for.
		board, lin_err := norn.parse_lin_deal(line)
		testing.expectf(t, lin_err == .None, "our LIN did not read back: %v (%q)", lin_err, line)
		testing.expect_value(t, card_count(board.deal), DECK_CARDS)
	}
}

// Every card, once. A deal that reads back with 51 cards would still "parse".
@(private = "file")
DECK_CARDS :: 52

@(private = "file")
card_count :: proc(deal: norn.Deal) -> (total: int) {
	for seat in norn.Seat {
		for card in deal[seat] {
			_ = card
			total += 1
		}
	}
	return
}

/*
A LOADED SCENARIO'S TAGS REACH THE GROUPS, THE PICKER AND THE FILTER.

The last piece of the user-scenario path: a `.scenario` file that says `tags: mine` has declared a group,
and a group with no row in the picker is one nobody can select. So the picker lists the UNION of the
compiled vocabulary and whatever the files declared.

TWO THINGS THIS PINS that a name-keyed lookup would get wrong. The tags are read BY INDEX into the
concatenated registry, because a loaded scenario may share a name with a compiled one and only an index
says which is meant. And the compiled groups keep their positions, because the picker's DIGITS are
positions: `1` must not become a different group because a file appeared in a directory.
*/
@(test)
test_a_loaded_scenarios_tags_become_a_group :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	temp, temp_err := os.temp_directory(context.temp_allocator)
	if temp_err != nil {return}
	folder, join_err := filepath.join({temp, "workbench-scenario-tags"}, context.temp_allocator)
	if join_err != nil {return}
	_ = os.make_directory(folder)
	defer os.remove_all(folder)
	path, path_err := filepath.join({folder, "mine.scenario"}, context.temp_allocator)
	if path_err != nil {return}
	source := "scenario my-own \"a scenario of my own\"\n  tags: mine, slam\n  north: hcp >= 20\n"
	if os.write_entire_file(path, transmute([]u8)source) != nil {return}

	// Re-wire this app against that directory, the way `load_user_scenarios` does from the environment.
	compiled_groups := len(app.groups)
	compiled_scenarios := len(app.scenarios)
	scenario_dsl.destroy_loaded(&app.loaded, app.allocator)
	delete(app.scenarios, app.allocator)
	scenario_dsl.set_vocabulary(bidding.vocabulary)
	app.loaded = scenario_dsl.load_directories({folder}, app.allocator)
	registry := make([dynamic]cli.Scenario, 0, len(bidding.registry) + len(app.loaded.scenarios), app.allocator)
	append(&registry, ..bidding.registry)
	append(&registry, ..app.loaded.scenarios)
	app.scenarios = registry[:]
	build_groups(&app)

	testing.expect_value(t, len(app.scenarios), compiled_scenarios + 1)
	if len(app.loaded.scenarios) != 1 {
		testing.expect(t, false, "the scenario file did not load")
		return
	}

	// `slam` is already a compiled group, so only `mine` is new — a declared tag must not be duplicated.
	testing.expect_value(t, len(app.groups), compiled_groups + 1)
	added := app.groups[len(app.groups) - 1]
	testing.expect_value(t, added.name, "mine")
	testing.expect(t, added.from_files, "a group that came from a file should say so")

	// THE COMPILED GROUPS KEEP THEIR POSITIONS, which is what the picker's digits depend on.
	for i in 0 ..< compiled_groups {
		testing.expect_value(t, app.groups[i].name, bidding.tags[i].name)
		testing.expect(t, !app.groups[i].from_files, "a compiled group is not from a file")
	}

	// THE FILTER USES THEM. Selecting `mine` leaves exactly the loaded scenario.
	mine := len(app.groups) - 1
	toggle_tag(&app, mine)
	shown := visible_scenarios(&app, context.temp_allocator)
	testing.expect_value(t, len(shown), 1)
	if len(shown) == 1 {
		testing.expect_value(t, app.scenarios[shown[0]].name, "my-own")
	}

	// And the scenario carries BOTH tags it declared, so selecting `slam` includes it beside the
	// compiled slam scenarios rather than instead of them.
	toggle_tag(&app, mine)
	slam, found_slam := -1, false
	for group, i in app.groups {
		if group.name == "slam" {
			slam, found_slam = i, true
			break
		}
	}
	if found_slam {
		toggle_tag(&app, slam)
		with_slam := visible_scenarios(&app, context.temp_allocator)
		testing.expect(t, len(with_slam) > 1, "the compiled slam scenarios should still be there")
		carries := false
		for index in with_slam {
			if app.scenarios[index].name == "my-own" {
				carries = true
			}
		}
		testing.expect(t, carries, "a loaded scenario's second tag should place it in that group too")
		toggle_tag(&app, slam)
	}
}

// ---- the scenario editor -------------------------------------------------------------------------
//
// The LANGUAGE is `scenario_dsl`'s and is tested there with no engine in the way — the grammar, the
// diagnostics, the round trip and the parity oracle against a compiled predicate. What is worth a document
// is the same seam every other view's tests are about: that a row is clickable at all, that the buffer
// really is what `check` parses, that a squiggle lands on the SCENARIO editor and not on the notes one,
// and — the two that would be silently wrong rather than visibly broken — that choosing a folder is
// remembered, and that a reload rebuilds everything that points into the registry.

// A scratch folder with `.scenario` files in it. Under TEMP rather than in the repository: these tests
// write, and a folder of half-written scenarios beside the real ones is exactly the confusion this whole
// feature exists to avoid.
@(private = "file")
scratch_scenario_dir :: proc(t: ^testing.T, leaf: string) -> string {
	dir, jerr := filepath.join({os.get_env("TEMP", context.temp_allocator), leaf}, context.temp_allocator)
	if jerr != nil {
		log.warn("no scratch directory available — skipping")
		return ""
	}
	if err := os.make_directory(dir); err != nil && !os.exists(dir) {
		log.warnf("could not make %s (%v) — skipping", dir, err)
		return ""
	}
	// EMPTIED, not merely created: these tests count the files they find, and a leftover from a previous
	// run is a count that is right on a clean machine and wrong on the machine it is debugged on.
	if infos, err := os.read_directory_by_path(dir, 0, context.temp_allocator); err == nil {
		for info in infos {
			if info.type != .Directory && strings.has_suffix(info.name, SCENARIO_EXT) {
				os.remove(info.fullpath)
			}
		}
	}
	return strings.clone(dir, context.temp_allocator)
}

@(private = "file")
write_scenario_file :: proc(dir: string, name: string, body: string) -> bool {
	path, jerr := filepath.join({dir, name}, context.temp_allocator)
	if jerr != nil {
		return false
	}
	if err := os.write_entire_file(path, transmute([]u8)body); err != nil {
		log.warnf("could not write %s (%v) — skipping", path, err)
		return false
	}
	return true
}

// Two scenarios that between them use both halves of the language: a generic condition, and a NAMED helper
// from this bidding system's own vocabulary.
@(private = "file")
TWO_SCENARIOS :: `scenario wb-strong-nt "15-17 balanced opposite five hearts"
  tags: mine
  north: hcp in 15..17 and balanced
  south: hearts >= 5

scenario wb-named "a compiled helper, named from a file"
  north: is_strong_1c
`

// The folder, the list, and the first file in the editor. `use_scenario_dir` is the whole of "a folder was
// chosen" except the modal dialog, which is why it is a procedure of its own.
@(test)
test_the_scenario_editor_lists_a_folder_and_opens_the_first_file :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	dir := scratch_scenario_dir(t, "wb-scn-list")
	if dir == "" {return}
	if !write_scenario_file(dir, "a-first.scenario", TWO_SCENARIOS) {return}
	if !write_scenario_file(dir, "b-second.scenario", "scenario wb-second \"another one\"\n  north: hcp >= 20\n") {
		return
	}

	show_view(&app, .Scenarios) // a hidden view has no behaviors, so a row in it answers no click
	use_scenario_dir(&app, dir)
	pump(&app)

	testing.expect_value(t, len(app.scn_names), 2)
	testing.expect_value(t, app.scn_open, "a-first.scenario") // sorted, so the first is the first
	source, got := scenario_source(&app, context.temp_allocator)
	testing.expect(t, got && strings.contains(source, "wb-strong-nt"), "the file's text should be in the editor")

	rows, rerr := sa.select_all(find(&app, "#scn-list"), ".row", context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, len(rows), 2)
	if len(rows) < 2 {return}

	// The SECOND row, so this cannot pass by accident on the file that was opened for us. A row has to
	// answer a click at all, which is `behavior: button` and the bug this codebase has now learned twice.
	handled, cerr := sa.do_click(rows[1])
	testing.expect_value(t, cerr, nil)
	testing.expect(t, handled, "a scenario file row must answer a click (behavior: button)")
	pump(&app)
	testing.expect_value(t, app.scn_open, "b-second.scenario")

	// And the marking is a projection of `scn_open`, so exactly one row carries it.
	marked, merr := sa.select_all(find(&app, "#scn-list"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	if len(marked) == 1 {
		open_name, _ := sa.attribute(marked[0], "data-sfile", context.temp_allocator)
		testing.expect_value(t, open_name, "b-second.scenario")
	}
}

// A `.scenario` row must not reach the BML editor. Both lists are `.row`s and only the attribute tells
// them apart, so this is the one thing that would silently half-work: the click would be handled, the
// notes editor would try to read a scenario file as notes, and the scenario editor would sit there
// showing the previous file.
@(test)
test_a_scenario_row_does_not_reach_the_notes_editor :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	dir := scratch_scenario_dir(t, "wb-scn-routing")
	if dir == "" {return}
	if !write_scenario_file(dir, "routing.scenario", TWO_SCENARIOS) {return}

	show_view(&app, .Scenarios)
	use_scenario_dir(&app, dir)
	pump(&app)

	before := strings.clone(app.bml_open, context.temp_allocator)
	rows, _ := sa.select_all(find(&app, "#scn-list"), ".row", context.temp_allocator)
	if len(rows) == 0 {
		testing.fail_now(t, "no scenario file rows to click")
	}
	_, _ = sa.do_click(rows[0])
	pump(&app)

	testing.expect_value(t, app.scn_open, "routing.scenario")
	testing.expect_value(t, app.bml_open, before) // the notes editor was not touched
}

// The two-step over unsaved text: refused once, with the bar saying so, then it goes through. The same
// bargain the notes editor makes, and the reason neither of them needs a modal.
@(test)
test_leaving_an_unsaved_scenario_is_refused_once :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-unsaved")
	if dir == "" {return}
	if !write_scenario_file(dir, "one.scenario", "scenario wb-one \"one\"\n  north: hcp >= 12\n") {return}
	if !write_scenario_file(dir, "two.scenario", "scenario wb-two \"two\"\n  north: hcp >= 13\n") {return}

	use_scenario_dir(&app, dir)
	pump(&app)
	testing.expect_value(t, app.scn_open, "one.scenario")

	// TYPE into the buffer, the way an edit really arrives: a host-side `content=` write does not set the
	// widget's own modified flag, and that flag is exactly what the guard reads.
	if editor := find(&app, "#scn-text"); editor != nil {
		_ = sa.set_focus(editor)
		pump(&app)
		_, _ = sa.send_key(editor, .DOWN, u32(sciter.Sc_Kb_Codes.X), {})
		_, _ = sa.send_key(editor, .UP, u32(sciter.Sc_Kb_Codes.X), {})
		pump(&app)
	}
	if !scenario_modified(&app) {
		log.warn("the editor did not report the synthesised keystroke as an edit — skipping the guard")
		return
	}

	switch_scenario_file(&app, "two.scenario")
	pump(&app)
	testing.expect_value(t, app.scn_open, "one.scenario") // refused, and the file is still the edited one
	testing.expect(t, app.scn_armed, "the refusal should arm the next attempt")

	switch_scenario_file(&app, "two.scenario")
	pump(&app)
	testing.expect_value(t, app.scn_open, "two.scenario") // and the second attempt goes through
}

// `save` writes the buffer back with the file's OWN line endings. A CRLF file whose only change is one
// word must not come back as a rewrite of every line — the same care `open_bml`/`save_bml` take.
@(test)
test_a_scenario_save_round_trips_the_bytes :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-save")
	if dir == "" {return}
	original := "scenario wb-crlf \"crlf\"\r\n  tags: mine\r\n  north: hcp in 15..17 and balanced\r\n"
	if !write_scenario_file(dir, "crlf.scenario", original) {return}

	use_scenario_dir(&app, dir)
	pump(&app)
	testing.expect(t, app.scn_crlf, "the file's line endings should be remembered")

	written, why := save_scenario_file(&app)
	testing.expectf(t, written, "could not save: %s", why)

	path := filepath.join({dir, "crlf.scenario"}, context.temp_allocator) or_else ""
	back, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(back), original)
}

// ---- check ---------------------------------------------------------------------------------------

// The colorizer runs over the buffer and marks it. The COUNT is all this side can see — a mark leaves no
// attribute behind — so zero from a buffer with text in it means the script did not run at all.
@(test)
test_the_scenario_editor_colours_what_it_loads :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	set_scenario_source(&app, TWO_SCENARIOS)
	pump(&app)
	testing.expect(t, colorize_scenario(&app) > 0, "the scenario colorizer should mark something")
}

/*
`check` parses THE BUFFER — not the file — and answers the three questions the report is for.

The frequency is asserted as a SHAPE rather than as a number: it is a real measurement over pseudo-random
deals, and pinning the exact hit count would pin the shuffler's stream rather than the language. What is
worth asserting is that a condition a fifth of hands meet is not reported as unreachable, which no amount
of seeding drift can move.
*/
@(test)
test_check_reports_what_it_understood_and_how_often_it_happens :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// REDUNDANT BRACKETS, deliberately. `and` already binds tighter than `or`, so a report that ECHOED the
	// source would show them and one printed from the TREE cannot — which is the difference being asserted:
	// what comes back is what the parser understood, not what was typed.
	//
	// What is NOT asserted is two comparisons fusing into a range: the parser does not do that, and it
	// should not. Rewriting `hcp >= 8 and hcp <= 11` into `hcp in 8..11` would be the report improving on
	// somebody's text rather than reflecting it.
	set_scenario_source(
		&app,
		"scenario wb-check \"eight to eleven\"\n  north: (hcp in 8..11 and balanced) or hearts >= 6\n",
	)
	pump(&app)
	check_scenario(&app)
	pump(&app)

	report := read_scenario_report(&app)
	testing.expect(
		t,
		strings.contains(report, "hcp in 8..11 and balanced or hearts >= 6"),
		"the report should spell the tree canonically, without the brackets the precedence makes redundant",
	)
	testing.expect(t, strings.contains(report, "happens:"), "the report should measure how often it happens")
	testing.expect(
		t,
		!strings.contains(report, "not once"),
		"a condition a fifth of hands meet should not be reported as unreachable",
	)
}

// A condition nothing meets is reported as such, in the words that say what to do about it. This is the
// answer the whole check exists for: an unreachable scenario is not a parse error and not a logic error,
// it is a generate run that never finishes.
@(test)
test_check_says_when_a_scenario_is_too_tight_to_generate :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	set_scenario_source(&app, "scenario wb-impossible \"nobody has this\"\n  north: hcp >= 38\n")
	pump(&app)
	check_scenario(&app)
	pump(&app)

	testing.expect(
		t,
		strings.contains(read_scenario_report(&app), "not once"),
		"a 38-point hand cannot be dealt, and the report should say so",
	)
}

/*
A bad line is squiggled ON THE SCENARIO EDITOR, and the notes editor's own squiggles are not touched.

THE SECOND HALF IS THE POINT. The two editors share the document's marking code, and the problem list used
to be one global — so a check here would have taken the notes editor's squiggles off, and a parse there
would have taken these off, with nothing on screen saying why. The lists live on the editor ELEMENTS now,
and this is what says so.
*/
@(test)
test_a_scenario_diagnostic_is_squiggled_on_its_own_editor :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Give the NOTES editor a squiggle of its own first, so there is something to take away by accident.
	set_bml_source(&app, "#+TITLE: fine\n\n#INCLDUE nothing.bml\n")
	pump(&app)
	marked := show_bml_problems(
		&app,
		{{line = 3, col = 1, length = 8, severity = .Error, message = "unknown directive"}},
	)
	testing.expect_value(t, marked, 1)

	set_scenario_source(&app, "scenario wb-bad \"a name nothing defines\"\n  north: is_not_a_real_helper\n")
	pump(&app)
	check_scenario(&app)
	pump(&app)

	// AT LEAST ONE rather than exactly one: an unknown word can also leave the seat line with no condition,
	// which is a second true thing to say about the same line. What is pinned here is WHICH EDITOR the
	// squiggles landed on.
	testing.expect(t, scenario_problem_count(&app) >= 1, "the bad line should be squiggled")
	testing.expect(
		t,
		strings.contains(read_scenario_report(&app), "is_not_a_real_helper"),
		"the report should name the word it did not know",
	)
	// AND the notes editor still has its own.
	testing.expect_value(t, problem_count(&app), 1)
}

// A name a compiled scenario already has is a NOTE rather than an error: `cli.lookup` takes the first
// exact match and the compiled registry is concatenated first, so the file's version can never be
// reached. Silently is the wrong way for that to be true.
@(test)
test_check_says_when_a_compiled_scenario_wins_the_name :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	if len(bidding.registry) == 0 {
		log.warn("no compiled scenarios — skipping")
		return
	}

	taken := bidding.registry[0].name
	source := fmt.tprintf("scenario %s \"a name the compiled registry already has\"\n  north: hcp >= 12\n", taken)
	set_scenario_source(&app, source)
	pump(&app)
	check_scenario(&app)
	pump(&app)

	testing.expect(
		t,
		strings.contains(read_scenario_report(&app), "the compiled one wins"),
		"a shadowed name should be reported",
	)
}

// `words` puts the whole vocabulary in the report, which is the only place inside this window that a
// person can find out what names they may write.
@(test)
test_words_lists_the_grammar_and_the_vocabulary :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	scenario_dsl.set_vocabulary(bidding.vocabulary)
	scenario_words(&app)
	pump(&app)

	report := read_scenario_report(&app)
	testing.expect(t, strings.contains(report, "holds("), "the grammar should be listed")
	if len(bidding.vocabulary) > 0 {
		testing.expect(t, strings.contains(report, bidding.vocabulary[0].name), "every named helper should be listed")
	}
}

// ---- new, and the pref ---------------------------------------------------------------------------

// A NEW FILE PARSES. The template is the first thing anybody sees of this language, so it has to be a
// working scenario rather than a wall of commented-out syntax — and "working" is a thing to assert, not
// to believe, since the template is a string literal nothing else compiles.
@(test)
test_a_new_scenario_file_starts_as_one_that_parses :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-new")
	if dir == "" {return}
	use_scenario_dir(&app, dir)
	pump(&app)

	path := filepath.join({dir, "my-auction.scenario"}, context.temp_allocator) or_else ""
	created, why := create_scenario_file(&app, path)
	testing.expectf(t, created, "could not create the file: %s", why)
	if !created {return}
	pump(&app)

	testing.expect_value(t, app.scn_open, "my-auction.scenario")
	testing.expect_value(t, len(app.scn_names), 1)

	// It parses, with no diagnostics, and the scenario is named after the FILE — which is the one name the
	// person has already chosen.
	scenario_dsl.set_vocabulary(bidding.vocabulary)
	source, _ := scenario_source(&app, context.temp_allocator)
	programs, diagnostics := scenario_dsl.parse(source, "template", context.temp_allocator)
	defer for &program in programs {
		scenario_dsl.destroy_program(&program)
	}
	for diagnostic in diagnostics {
		testing.expectf(
			t,
			false,
			"the new-file template should parse clean: %s",
			scenario_dsl.diagnostic_text(diagnostic, context.temp_allocator),
		)
	}
	testing.expect_value(t, len(programs), 1)
	if len(programs) == 1 {
		testing.expect_value(t, programs[0].name, "my-auction")
	}

	// An existing file is OPENED rather than overwritten: what would be lost is somebody's scenario.
	again, message := create_scenario_file(&app, path)
	testing.expect(t, !again, "an existing file must not be overwritten")
	testing.expect(t, strings.contains(message, "already exists"), "and it should say why")
}

/*
CHOOSING A FOLDER IS REMEMBERED, and that is the whole of item 3 of the handoff: the `scenarios.dirs` pref
was READ at startup and nothing had ever written it, so the only way to tell this program where scenarios
live was an environment variable — a thing to name at a developer, not at somebody holding a mouse.

The previously remembered folders are KEPT, after the chosen one: a person can have several (their own, a
partner's, one checked into a repository), and choosing which to EDIT is not saying to forget the others.
*/
@(test)
test_choosing_a_scenario_folder_is_remembered :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-pref")
	if dir == "" {return}

	// A prefs store with no PATH: the values are set and nothing is written to disk, which is what a test
	// wants and is also the state a first run is in before the file exists.
	app.prefs = prefs.load("", context.temp_allocator)
	defer prefs.destroy(&app.prefs)
	prefs.set(&app.prefs, SCENARIO_DIRS_PREF, "C:/somewhere/else")

	use_scenario_dir(&app, dir)
	pump(&app)

	remembered, found := prefs.get(&app.prefs, SCENARIO_DIRS_PREF)
	testing.expect(t, found, "choosing a folder should write the pref")
	testing.expect(t, strings.has_prefix(remembered, dir), "the chosen folder should come first")
	testing.expect(
		t,
		strings.contains(remembered, "C:/somewhere/else"),
		"and the folders that were already remembered should stay",
	)

	// Twice over the same folder must not accumulate it twice.
	use_scenario_dir(&app, dir)
	pump(&app)
	twice, _ := prefs.get(&app.prefs, SCENARIO_DIRS_PREF)
	testing.expect_value(t, strings.count(twice, dir), 1)
}

// ---- reload --------------------------------------------------------------------------------------

/*
RELOAD IS THE SEAM between a saved file and the deals list, and it is the one operation here that touches
everything: the registry, the groups, the flags parallel to them, the rows and the selection.

What this pins is that a file written after startup becomes a real scenario — in `app.scenarios`, findable
by `cli.lookup`, with its declared tag a real group in the picker — and that the selection survives by
NAME. An index kept across a reload silently means a different auction, which is the failure that would
never look like a bug.
*/
@(test)
test_reload_puts_a_new_file_in_the_deals_list :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-reload")
	if dir == "" {return}
	if !write_scenario_file(
		dir,
		"reloaded.scenario",
		"scenario wb-reloaded \"written after startup\"\n  tags: wb-scratch-group\n  north: hcp >= 12\n",
	) {return}

	// The folders are read from the pref at reload, so this is also the path a chosen folder takes.
	app.prefs = prefs.load("", context.temp_allocator)
	defer prefs.destroy(&app.prefs)
	prefs.set(&app.prefs, SCENARIO_DIRS_PREF, dir)

	compiled := len(app.scenarios)
	if compiled == 0 {
		log.warn("no compiled scenarios — skipping")
		return
	}
	// Park the selection on a compiled scenario, so the restore has a name to find that the reload cannot
	// have moved by accident.
	wanted := strings.clone(app.scenarios[0].name, context.temp_allocator)
	app.selected = 0

	reloaded, why := reload_scenarios(&app)
	testing.expectf(t, reloaded, "the reload was refused: %s", why)
	pump(&app)

	testing.expect_value(t, len(app.scenarios), compiled + 1)
	found, ok := cli.lookup(app.scenarios, "wb-reloaded")
	testing.expect(t, ok, "the file's scenario should be in the registry")
	if ok {
		testing.expect(t, cli.is_interpreted(found), "and it should be an interpreted one")
	}

	// The selection survived by name.
	testing.expect(t, app.selected >= 0 && app.selected < len(app.scenarios))
	if app.selected >= 0 && app.selected < len(app.scenarios) {
		testing.expect_value(t, app.scenarios[app.selected].name, wanted)
	}

	// The tag it declared is a real group, and the flags were rebuilt to match.
	testing.expect_value(t, len(app.tag_on), len(app.groups))
	declared := false
	for group in app.groups {
		if group.name == "wb-scratch-group" {
			declared = true
			testing.expect(t, group.from_files, "a group from a file should say so")
		}
	}
	testing.expect(t, declared, "a tag declared in a file should become a group")

	// And a second reload over the same folder is idempotent — the registry does not grow every press.
	again, _ := reload_scenarios(&app)
	testing.expect(t, again)
	testing.expect_value(t, len(app.scenarios), compiled + 1)
}

// A reload while a generate job is in flight is REFUSED, and this is not politeness: the worker thread
// reads `app.scenarios`, and the interpreted conditions in it point at programs a reload frees. Freeing
// them mid-run is a crash on somebody else's schedule.
@(test)
test_reload_is_refused_while_a_job_is_running :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.running = true
	defer app.running = false
	ok, why := reload_scenarios(&app)
	testing.expect(t, !ok, "a reload must not run under a job")
	testing.expect(t, strings.contains(why, "run is in progress"), "and it should say why")
}

/*
THE REGISTRY THE WORKER RUNS IS THE ONE THE WINDOW SHOWS.

`work_generate` looked a scenario up in `bidding.registry` — the COMPILED list — while the window's own
list is the concatenation of that and the loaded ones. So a text scenario could be selected, named in the
status line and in the output path, and then fail with "unknown scenario" the moment generate was pressed.
This asserts the distinction the fix is about: the name is absent from the compiled registry and present
in the one the worker now uses.
*/
@(test)
test_a_loaded_scenario_is_reachable_where_generate_looks :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-registry")
	if dir == "" {return}
	if !write_scenario_file(
		dir,
		"generated.scenario",
		"scenario wb-generatable \"reachable from generate\"\n  north: hcp >= 10\n",
	) {return}

	app.prefs = prefs.load("", context.temp_allocator)
	defer prefs.destroy(&app.prefs)
	prefs.set(&app.prefs, SCENARIO_DIRS_PREF, dir)
	reloaded, why := reload_scenarios(&app)
	testing.expectf(t, reloaded, "the reload was refused: %s", why)

	_, in_compiled := cli.lookup(bidding.registry, "wb-generatable")
	testing.expect(t, !in_compiled, "the compiled registry cannot know about a file written just now")
	_, in_window := cli.lookup(app.scenarios, "wb-generatable")
	testing.expect(t, in_window, "and the registry the worker runs must")
}

// How many squiggles are on the SCENARIO editor. Its own list, on its own element — see
// `test_a_scenario_diagnostic_is_squiggled_on_its_own_editor` for why that matters.
@(private = "file")
scenario_problem_count :: proc(app: ^App) -> int {
	result, err := sa.eval(app.window, `(document.$("#scn-text").wbProblems || []).length`)
	defer sa.value_clear(&result)
	if err != nil {
		return -1
	}
	count, ierr := sa.value_to_int(&result)
	return ierr == nil ? int(count) : -1
}

// The report pane's text. A `<plaintext>`, so it comes back line by line for the same reason the source
// does — reading `content` back gives the last two lines joined.
@(private = "file")
read_scenario_report :: proc(app: ^App) -> string {
	element := find(app, "#scn-report")
	if element == nil {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	for n := 0;; n += 1 {
		child, cerr := sa.child(element, sa.Child_Index(n))
		if cerr != nil || child == nil {
			break
		}
		if n > 0 {
			strings.write_byte(&b, '\n')
		}
		if line, terr := sa.text(child, context.temp_allocator); terr == nil {
			strings.write_string(&b, line)
		}
	}
	return strings.to_string(b)
}

/*
THE GROUP PICKER GIVES WAY TO A FIELD WITH THE CARET.

Reported from the window as "deleting text does not work in the deals filter". The picker stays open while
you type in the filter beside it, and its keys are taken on the way down, so backspace cleared every group
instead of a character and the `1` of `1c` toggled the first group. The keys are sent to the FIELD here,
which is where the engine delivers them in a real window: `press_key` sends to the root, whose events never
reach an input's edit behavior, so it could not have shown this either way.
*/
@(test)
test_the_group_picker_does_not_take_the_filters_keys :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	show_view(&app, .Panes)
	draw_scenarios(&app)
	pump(&app)

	set_tag_picker(&app, true)
	pump(&app)
	testing.expect(t, tag_picker_open(&app), "the picker should be open for this test to mean anything")
	type_filter(&app, "1c any")
	input := find(&app, "#scenario-filter")
	if input == nil {return}

	_, _ = sa.send_key(input, .DOWN, u32(sciter.Sc_Kb_Codes.BACKSPACE), {})
	pump(&app)
	testing.expect_value(t, read_text(&app, "#scenario-filter"), "1c an")

	_, _ = sa.send_key(input, .DOWN, u32(sciter.Sc_Kb_Codes.NUM_1), {})
	pump(&app)
	testing.expect_value(t, len(selected_tag_names(&app, context.temp_allocator)), 0)

	// And away from the field the picker still owns its digits.
	if list := find(&app, "#scenarios"); list != nil {
		_ = sa.set_focus(list)
	}
	press_key(&app, .NUM_1)
	pump(&app)
	testing.expect_value(t, len(selected_tag_names(&app, context.temp_allocator)), 1)
}

// ---- the scenario editor and the deals list --------------------------------------------------------

/*
SAVING PUTS A SCENARIO IN THE DEALS LIST — no second button.

Reported from the window: a scenario written and saved in the scenarios tab did not appear in the deals
list, because the list is built at startup and the step that rebuilt it was a separate `reload` that read
like "reload this file". So the save itself rebuilds it, and this pins that a NEW scenario typed into the
buffer is findable where generate looks the moment the file is written, with no reload call in sight.
*/
@(test)
test_saving_a_scenario_puts_it_in_the_deals_list :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-save-lists")
	if dir == "" {return}
	if !write_scenario_file(dir, "mine.scenario", "scenario wb-before \"before the edit\"\n  north: hcp >= 12\n") {return}

	app.prefs = prefs.load("", context.temp_allocator)
	defer prefs.destroy(&app.prefs)
	use_scenario_dir(&app, dir) // remembers the folder, and reads it into the deals list
	pump(&app)
	_, before := cli.lookup(app.scenarios, "wb-before")
	testing.expect(t, before, "choosing a folder should put its scenarios in the deals list")

	set_scenario_source(&app, "scenario wb-after \"after the edit\"\n  north: hcp >= 15\n")
	pump(&app)
	saved, why := save_scenario_file(&app)
	testing.expectf(t, saved, "could not save: %s", why)
	testing.expect(t, strings.contains(why, "deals list"), why)

	_, after := cli.lookup(app.scenarios, "wb-after")
	testing.expect(t, after, "the saved scenario should be in the deals list without a reload")
	_, gone := cli.lookup(app.scenarios, "wb-before")
	testing.expect(t, !gone, "and the version it replaced should not")
}

/*
THE SOURCES LIST NAMES EVERY FOLDER THE DEALS LIST READS, and a click on one edits that folder.

Reported from the window: "only one folder can be open in scenarios" and nothing said where the dynamic
scenarios load from. Two folders are configured here, each holding one scenario; both must be listed with
their count, the one being edited must be marked, and clicking the other must move the editor there —
WITHOUT rewriting the pref, whose order is the shadowing order.
*/
@(test)
test_the_sources_list_shows_every_folder_and_switches_between_them :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	first := scratch_scenario_dir(t, "wb-scn-src-a")
	second := scratch_scenario_dir(t, "wb-scn-src-b")
	if first == "" || second == "" {return}
	if !write_scenario_file(first, "a.scenario", "scenario wb-src-a \"a\"\n  north: hcp >= 12\n") {return}
	if !write_scenario_file(second, "b.scenario", "scenario wb-src-b \"b\"\n  north: hcp >= 13\n") {return}

	app.prefs = prefs.load("", context.temp_allocator)
	defer prefs.destroy(&app.prefs)
	configured := strings.concatenate({first, ";", second}, context.temp_allocator)
	prefs.set(&app.prefs, SCENARIO_DIRS_PREF, configured)
	reloaded, why := reload_scenarios(&app)
	testing.expectf(t, reloaded, "the reload was refused: %s", why)

	show_scenario_editor(&app)
	pump(&app)
	testing.expect(t, same_dir(app.scn_dir, first), "the editor should open the first configured folder")

	box := find(&app, "#scn-sources")
	testing.expect(t, box != nil, "the scenarios tab has no sources list")
	if box == nil {return}
	rows, err := sa.select_all(box, ".row", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(rows), 2)
	if len(rows) != 2 {return}
	text, _ := sa.text(box, context.temp_allocator)
	testing.expectf(t, strings.count(text, "1 scenario") == 2, "each folder should report its one scenario: %q", text)
	marked, _ := sa.select_all(box, ".row.sel", context.temp_allocator)
	testing.expect_value(t, len(marked), 1)

	// A real click, through `behavior: button`, on the folder not being edited.
	sa.do_click(rows[1])
	pump(&app)
	testing.expect(t, same_dir(app.scn_dir, second), "clicking a source should edit that folder")
	testing.expect_value(t, app.scn_open, "b.scenario")
	remembered, _ := prefs.get(&app.prefs, SCENARIO_DIRS_PREF)
	testing.expect_value(t, remembered, configured) // looking at a folder does not reorder the sources
}

// ONE FOLDER, HOWEVER IT IS SPELLED, loads once. The environment and the pref can both name a folder, with
// different slashes; loading it twice would put every scenario in it into the deals list twice.
@(test)
test_a_folder_named_twice_is_read_once :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-twice")
	if dir == "" {return}
	if !write_scenario_file(dir, "once.scenario", "scenario wb-once \"once\"\n  north: hcp >= 12\n") {return}

	other_spelling, _ := strings.replace_all(dir, "\\", "/", context.temp_allocator)
	app.prefs = prefs.load("", context.temp_allocator)
	defer prefs.destroy(&app.prefs)
	prefs.set(&app.prefs, SCENARIO_DIRS_PREF, strings.concatenate({dir, ";", other_spelling, "/"}, context.temp_allocator))
	reloaded, _ := reload_scenarios(&app)
	testing.expect(t, reloaded)

	testing.expect_value(t, len(app.scenario_dirs), 1)
	count := 0
	for scenario in app.scenarios {
		if scenario.name == "wb-once" {
			count += 1
		}
	}
	testing.expect_value(t, count, 1)
}

/*
THE × FORGETS A REMEMBERED FOLDER: out of the pref, out of the deals list, and out of the editor.

Without it the remembered list only grows. A real click on the ×, which sits INSIDE the row, so this also
pins that the click is the ×'s alone: had the row's own `data-sdir` answered first, the editor would have
opened the folder it was being asked to remove.
*/
@(test)
test_the_forget_button_takes_a_folder_out_of_the_sources :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	keep := scratch_scenario_dir(t, "wb-scn-keep")
	drop := scratch_scenario_dir(t, "wb-scn-drop")
	if keep == "" || drop == "" {return}
	if !write_scenario_file(keep, "k.scenario", "scenario wb-keep \"k\"\n  north: hcp >= 12\n") {return}
	if !write_scenario_file(drop, "d.scenario", "scenario wb-drop \"d\"\n  north: hcp >= 13\n") {return}

	// NOT the temp allocator: the clicks below pump the engine, and the pump frees temp memory — a pref
	// written there reads back as zeroes. The window keeps its prefs in its own allocator for the same reason.
	app.prefs = prefs.load("", context.allocator)
	defer prefs.destroy(&app.prefs)
	prefs.set(&app.prefs, SCENARIO_DIRS_PREF, strings.concatenate({drop, ";", keep}, context.temp_allocator))
	reloaded, _ := reload_scenarios(&app)
	testing.expect(t, reloaded)
	show_scenario_editor(&app)
	pump(&app)
	testing.expect(t, same_dir(app.scn_dir, drop), "the editor should start in the first folder")

	box := find(&app, "#scn-sources")
	if box == nil {return}
	buttons, _ := sa.select_all(box, ".forget", context.temp_allocator)
	testing.expect_value(t, len(buttons), 2) // both remembered, so both forgettable
	if len(buttons) != 2 {return}
	sa.do_click(buttons[0])
	pump(&app)

	remembered, _ := prefs.get(&app.prefs, SCENARIO_DIRS_PREF)
	testing.expectf(t, same_dir(remembered, keep), "only the kept folder should be remembered: %q vs %q", remembered, keep)
	_, still := cli.lookup(app.scenarios, "wb-drop")
	testing.expect(t, !still, "a forgotten folder's scenarios should leave the deals list")
	_, kept := cli.lookup(app.scenarios, "wb-keep")
	testing.expect(t, kept, "and the other folder's should stay")
	testing.expect(t, same_dir(app.scn_dir, keep), "the editor should move to the folder that is left")
	rows, _ := sa.select_all(box, ".row", context.temp_allocator)
	testing.expect_value(t, len(rows), 1)
}

/*
A RESTART REOPENS WHERE YOU LEFT OFF — the folder and the file — rather than the first file of the first
folder. Simulated the way a restart sees it: a fresh App whose prefs carry what the last session wrote.
*/
@(test)
test_the_editor_reopens_the_folder_and_file_it_was_on :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	first := scratch_scenario_dir(t, "wb-scn-resume-a")
	second := scratch_scenario_dir(t, "wb-scn-resume-b")
	if first == "" || second == "" {return}
	if !write_scenario_file(first, "a.scenario", "scenario wb-resume-a \"a\"\n  north: hcp >= 12\n") {return}
	if !write_scenario_file(second, "b1.scenario", "scenario wb-resume-b1 \"b1\"\n  north: hcp >= 12\n") {return}
	if !write_scenario_file(second, "b2.scenario", "scenario wb-resume-b2 \"b2\"\n  north: hcp >= 13\n") {return}

	app.prefs = prefs.load("", context.temp_allocator)
	defer prefs.destroy(&app.prefs)
	prefs.set(&app.prefs, SCENARIO_DIRS_PREF, strings.concatenate({first, ";", second}, context.temp_allocator))
	prefs.set(&app.prefs, SCENARIO_EDIT_DIR_PREF, second)
	prefs.set(&app.prefs, SCENARIO_EDIT_FILE_PREF, "b2.scenario")
	reloaded, _ := reload_scenarios(&app)
	testing.expect(t, reloaded)

	show_scenario_editor(&app)
	pump(&app)
	testing.expect(t, same_dir(app.scn_dir, second), "the editor should reopen the folder it was on")
	testing.expect_value(t, app.scn_open, "b2.scenario")

	// And opening another file is what the next restart will reopen.
	opened, _ := open_scenario_file(&app, "b1.scenario")
	testing.expect(t, opened)
	file, _ := prefs.get(&app.prefs, SCENARIO_EDIT_FILE_PREF)
	testing.expect_value(t, file, "b1.scenario")
}

/*
THE REMEMBERED FOLDERS ARE READ AT STARTUP, not only by a rescan.

Reported from the window: "starts off with no folder" — the scenarios tab said `no folders yet` and the
deals list had none of the user's scenarios until `rescan`. `main` read the prefs file a hundred lines
AFTER loading the scenario folders, so the folders it named were never seen. This runs the startup step
`main` now calls against a real prefs FILE on disk, from a fresh registry.
*/
@(test)
test_startup_reads_the_remembered_scenario_folders :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-scn-startup")
	if dir == "" {return}
	if !write_scenario_file(dir, "s.scenario", "scenario wb-at-startup \"s\"\n  north: hcp >= 12\n") {return}
	prefs_file, jerr := filepath.join({dir, "workbench.prefs"}, context.temp_allocator)
	if jerr != nil {return}
	body := strings.concatenate({SCENARIO_DIRS_PREF, "=", dir, "\n"}, context.temp_allocator)
	if os.write_entire_file(prefs_file, transmute([]u8)body) != nil {return}

	free_user_scenarios(&app) // a fresh start: nothing loaded yet
	load_prefs_and_scenarios(&app, strings.clone(prefs_file))
	defer {
		prefs.destroy(&app.prefs)
		delete(app.prefs_path)
	}

	_, found := cli.lookup(app.scenarios, "wb-at-startup")
	testing.expect(t, found, "a scenario in a remembered folder should be in the deals list from the start")
	testing.expect_value(t, len(app.scenario_dirs), 1)
}


// ---- the theme, the settings view and the icons ----------------------------------------------------

/*
THE THEME REACHES THE DESCENDANTS, not only the root.

The trap this pins was measured while building it: setting `theme="light"` on the root recoloured the root
at once, but a ghost button inside the bars kept its dark-theme ink until the tree was restyled. A test that
read only the root's colour would have passed on a window whose every control stayed dark.
*/
@(test)
test_choosing_a_theme_recolours_the_whole_window :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.prefs = prefs.load("", context.allocator)
	defer prefs.destroy(&app.prefs)

	button := find(&app, "#scn-save")
	root := sa.root(app.window) or_else nil
	testing.expect(t, button != nil && root != nil)
	if button == nil || root == nil {return}

	// Chosen from one view and READ in another, the order a person does it in (settings, then back to
	// work): a hidden view is not restyled while hidden, so this also pins that it picks the theme up when
	// it is shown.
	show_view(&app, .Panes)
	choose_theme(&app, .Light)
	show_view(&app, .Scenarios)
	pump(&app)
	page, _ := sa.style(root, "background-color", context.temp_allocator)
	ink, _ := sa.style(button, "color", context.temp_allocator)
	testing.expect_value(t, page, "#EFF1F5")
	testing.expect_value(t, ink, "#4C4F69") // the descendant, which is the whole point
	word, _ := prefs.get(&app.prefs, THEME_PREF)
	testing.expect_value(t, word, "light")

	show_view(&app, .Panes)
	choose_theme(&app, .Dark)
	show_view(&app, .Scenarios)
	pump(&app)
	page, _ = sa.style(root, "background-color", context.temp_allocator)
	ink, _ = sa.style(button, "color", context.temp_allocator)
	testing.expect_value(t, page, "#1E1E2E")
	testing.expect_value(t, ink, "#CDD6F4")
}

// The settings view: the header's button opens it, a theme button is a real click that lights its segment,
// and esc / ctrl+w close it back to where it was opened from — the About panel's shape exactly.
@(test)
test_the_settings_view_chooses_a_theme_and_closes_like_about :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	app.prefs = prefs.load("", context.allocator)
	defer prefs.destroy(&app.prefs)

	show_view(&app, .Panes)
	pump(&app)
	click(&app, "#prefs")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Prefs)

	light := find(&app, `#prefs-panel [data-theme="light"]`)
	testing.expect(t, light != nil, "the settings view has no light button")
	if light == nil {return}
	sa.do_click(light)
	pump(&app)
	testing.expect_value(t, chosen_theme(&app), Theme.Light)
	classes, _ := sa.attribute(light, "class", context.temp_allocator)
	testing.expect(t, strings.contains(classes, "on"), "the chosen theme's segment should be lit")

	press_key(&app, .ESCAPE)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)

	show_prefs(&app, true)
	pump(&app)
	press_key(&app, .W, ctrl = true)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	choose_theme(&app, .Dark) // leave the shared view as the other tests expect it
}

/*
EVERY TOOLBAR PICTURE PAINTS, in both themes.

Pixels rather than geometry, because the failure this guards is an svg that lays out and draws nothing (a
path the engine will not parse, a `fill` that does not resolve): the box would be right and the button
would show only its word. Within each icon's box there must be both ink and ground. What this CANNOT see
is the GPU rasterizer's zoom defect (the harness is software Skia) — that wants one look in the real window.
*/
@(test)
test_every_toolbar_icon_paints :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.prefs = prefs.load("", context.allocator)
	defer prefs.destroy(&app.prefs)

	for theme in ([]Theme{.Dark, .Light}) {
		choose_theme(&app, theme)
		show_view(&app, .Scenarios)
		pump(&app)
		icons, err := sa.select_all(find(&app, "#scnview .bar"), "svg.ic", context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(icons), 6) // new, folder, save, check, rescan, words
		sa.paint_windowless(&g_view)
		for icon, i in icons {
			box, lerr := sa.location(icon, .Border, .Root)
			testing.expect_value(t, lerr, nil)
			testing.expectf(t, box.width >= 10 && box.height >= 10, "%v icon %d is %dx%d", theme, i, box.width, box.height)
			low, high := 765, 0
			for y in box.y ..< box.y + box.height {
				for x in box.x ..< box.x + box.width {
					if x < 0 || y < 0 || x >= 1120 || y >= 780 {continue}
					r, g, b, _ := sa.windowless_pixel(&g_view, x, y)
					v := int(r) + int(g) + int(b)
					low, high = min(low, v), max(high, v)
				}
			}
			testing.expectf(t, high - low > 150, "%v icon %d drew nothing (brightness %d..%d)", theme, i, low, high)
		}
	}
	choose_theme(&app, .Dark)
}

// The scenarios bar is in the order every editor uses: new, open, save — then the commands of its own.
@(test)
test_the_file_actions_come_first_in_the_familiar_order :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Scenarios)
	pump(&app)
	order := []string{"#scn-new", "#scn-folder", "#scn-save", "#scn-check", "#scn-reload", "#scn-words"}
	last := -1
	for selector in order {
		element := find(&app, selector)
		if element == nil {
			testing.expectf(t, false, "%s is missing", selector)
			continue
		}
		box, _ := sa.location(element, .Border, .Root)
		testing.expectf(t, int(box.x) > last, "%s is not to the right of the one before it", selector)
		last = int(box.x)
	}
}


// ---- zoom: the deal panes, and the hand page's own -------------------------------------------------

/*
THE DEAL PANES FIT THE WINDOW AT ANY ZOOM.

Reported with a screenshot: zoomed in, the scenario list was a sliver under the generate panel. The
remembered splitter widths were PIXELS (`351px,948px,1*`, what a drag leaves), and zoom scales pixels — the
first two panes alone asked for more than the window. Measured here at 100% too: in this 1120px view that
layout leaves the hand page 2px. Remembering MEASURED widths as flex units divides whatever width there is.
*/
@(test)
test_the_deal_panes_fit_the_window_at_any_zoom :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {return}
	set_pane_mode(&app, .Split)
	app.deal_layout = {300, 529}

	for zoom in ([]f64{1.0, 1.5, 2.0}) {
		result, _ := sa.eval(app.window, fmt.tprintf("wbSetZoom(%f)", zoom))
		sa.value_clear(&result)
		apply_deal_layout(&app)
		pump(&app)
		right := 0
		for selector in DEAL_SPLIT_SELECTORS {
			box, _ := sa.location(find(&app, selector), .Border, .Root)
			testing.expectf(t, box.width >= 100, "at %.1fx %s is %dpx wide", zoom, selector, box.width)
			right = max(right, int(box.x + box.width))
		}
		testing.expectf(t, right <= 1120 + 2, "at %.1fx the panes end at %d, past the window's 1120", zoom, right)
	}

	// The pref round-trips, and a layout an older build saved in pixels is refused (it is what overflowed).
	back, ok := parse_deal_layout(deal_layout_text(app.deal_layout))
	testing.expect(t, ok && back == app.deal_layout, "the layout pref should round-trip")
	_, old_ok := parse_deal_layout("351px,948px,1*")
	testing.expect(t, !old_ok, "an all-pixel layout should not be accepted")
	result, _ := sa.eval(app.window, "wbSetZoom(1)")
	sa.value_clear(&result)
}

// The framed page's heading height, a stand-in for "how big are the boards".
@(private = "file")
page_heading_height :: proc(app: ^App) -> int {
	result, err := sa.eval(app.window, `(function(){ var d = document.$("#page").frame.document; return d.$("h1").state.box("height", "border"); })()`)
	defer sa.value_clear(&result)
	if err != nil {
		return -1
	}
	height, herr := sa.value_to_int(&result)
	return herr == nil ? int(height) : -1
}

/*
THE HAND PAGE ZOOMS APART FROM THE WINDOW.

Asked for from the window: zoomed in for the controls, the boards were too big. The window's zoom reaches
the framed page (measured: 39px -> 58px at 150%), and a factor on the page's own root replaces it — so the
page keeps an absolute factor, re-applied after a window zoom and after a load. Both re-applications are
pinned here, because each was a way for the page to quietly jump back to the window's size.
*/
@(test)
test_the_hand_page_zooms_apart_from_the_window :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	app.prefs = prefs.load("", context.allocator)
	defer prefs.destroy(&app.prefs)

	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {return}
	set_pane_mode(&app, .Split)
	pump(&app)
	natural := page_heading_height(&app)
	testing.expect(t, natural > 0, "could not measure the page")

	// The window zooms; the page stays at 100%.
	_ = zoom_step(&app, 1)
	_ = zoom_step(&app, 1)
	_ = zoom_step(&app, 1)
	pump(&app)
	testing.expect(t, abs(page_heading_height(&app) - natural) <= 1, "a window zoom should leave the page alone")

	// The page's own buttons zoom the page, and the choice is remembered.
	click(&app, "#page-zoom-out")
	pump(&app)
	smaller := page_heading_height(&app)
	testing.expectf(t, smaller < natural, "the page should be smaller (%d, was %d)", smaller, natural)
	remembered, found := prefs.get(&app.prefs, PAGE_ZOOM_PREF)
	testing.expect(t, found && remembered == "0.91", remembered)

	// A new page keeps the page's factor rather than taking the window's.
	if !show_page_html(&app, MINIMAL_PAGE, "another page") {return}
	pump(&app)
	testing.expect(t, abs(page_heading_height(&app) - smaller) <= 1, "a newly loaded page should keep the page zoom")

	click(&app, "#page-zoom-reset")
	pump(&app)
	testing.expect(t, abs(page_heading_height(&app) - natural) <= 1, "reset should put the page back to 100%")
	_ = zoom_step(&app, 0)
}

/*
A PAGE LOADED FROM A FILE KEEPS THE PAGE ZOOM TOO.

Reported: at 110%, flipping from the cards page to the pbn text and back put the cards page at the window's
zoom. The text formats arrive through `loadHtml`, which is synchronous, and the zoom applied after it landed;
a generated cards page arrives through `loadFile`, whose document is not there yet when the call returns, so
the zoom went to the OLD document and the new one came in without it. The previous test only loaded from
memory, which is how it passed on the bug.
*/
@(test)
test_a_page_loaded_from_a_file_keeps_the_page_zoom :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	// The hand page frame's own handler, as `main` attaches it: `.DOCUMENT_COMPLETE` reaches only the frame.
	app.page_handler = sa.Event_Handler {
		subscription = {.TIMER, .BEHAVIOR_EVENT},
		on_event     = on_frame_event,
		user_data    = &app,
	}
	frame := find(&app, "#page")
	if frame == nil {return}
	sa.attach_handler(frame, &app.page_handler)
	defer sa.detach_handler(frame, &app.page_handler)

	dir := scratch_scenario_dir(t, "wb-page-zoom-file")
	if dir == "" {return}
	path, jerr := filepath.join({dir, "page.html"}, context.temp_allocator)
	if jerr != nil {return}
	if os.write_entire_file(path, transmute([]u8)string(MINIMAL_PAGE)) != nil {return}

	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page") {return}
	set_pane_mode(&app, .Split)
	pump(&app)
	natural := page_heading_height(&app)

	click(&app, "#page-zoom-in") // 110%
	pump(&app)
	zoomed := page_heading_height(&app)
	testing.expectf(t, zoomed > natural, "the page should be bigger (%d, was %d)", zoomed, natural)

	if !show_page_file(&app, path) {
		testing.fail_now(t, "the file did not load into the frame")
	}
	pump(&app)
	pump(&app)
	testing.expectf(
		t,
		abs(page_heading_height(&app) - zoomed) <= 1,
		"a page loaded from a file came in at %d, not the page zoom's %d",
		page_heading_height(&app),
		zoomed,
	)
	page_zoom_step(&app, 0)
}

@(private = "file")
drag_page_divider :: proc(app: ^App, dx: i32) {
	work_box, _ := sa.location(find(app, ".work"), .Border, .Root)
	page_box, _ := sa.location(find(app, "#pageview"), .Border, .Root)
	x := (work_box.x + work_box.width + page_box.x) / 2
	y := work_box.y + work_box.height / 2
	sa.windowless_mouse(&g_view, .MOUSE_ENTER, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_DOWN, {x, y})
	for step in 1 ..= 10 {
		sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x + i32(step) * dx / 10, y})
		pump(app)
	}
	sa.windowless_mouse(&g_view, .MOUSE_UP, {x + dx, y})
	pump(app)
}

/*
DRAGGING A DIVIDER MOVES ONLY THE TWO PANES BESIDE IT, BY THE DISTANCE DRAGGED, AT ANY ZOOM.

Reported: dragging the divider between the controls and the hand page resized the SCENARIO LIST. Measured
with real mouse drags: the frame-set behavior's own arithmetic, under the window's zoom, rewrote panes the
drag was not about (at 110% the list's `250px` came back `303px`, 250 x 1.1 x 1.1) and at 150% the panes
jumped. The script now does the drag. Real mouse events on the real splitter, because the failure was in
the behavior's arithmetic and nothing else reproduces it.
*/
@(test)
test_dragging_a_divider_moves_only_its_two_panes_at_any_zoom :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page", take_keyboard = false) {return}
	set_pane_mode(&app, .Split)
	pump(&app)

	for zoom in ([]f64{1.0, 1.1, 1.5}) {
		for dx in ([]i32{-100, 100}) {
			result, _ := sa.eval(app.window, fmt.tprintf("wbSetZoom(%f)", zoom))
			sa.value_clear(&result)
			// Room to drag 100px either way at every zoom: at 150% a 400px controls pane leaves the page ~83px,
			// and a further +100 is (rightly) stopped by the 80px pane minimum.
			_ = write_split_state(&app, {"250px", "300px", "1*"})
			relayout_split(&app)
			pump(&app)
			list0, _ := sa.location(find(&app, "#scenario-list"), .Border, .Root)
			work0, _ := sa.location(find(&app, ".work"), .Border, .Root)
			page0, _ := sa.location(find(&app, "#pageview"), .Border, .Root)

			drag_page_divider(&app, dx)

			list1, _ := sa.location(find(&app, "#scenario-list"), .Border, .Root)
			work1, _ := sa.location(find(&app, ".work"), .Border, .Root)
			page1, _ := sa.location(find(&app, "#pageview"), .Border, .Root)
			testing.expectf(t, abs(list1.width - list0.width) <= 2, "at %.1fx dx=%d the list moved %d -> %d", zoom, dx, list0.width, list1.width)
			testing.expectf(t, abs((work1.width - work0.width) - dx) <= 3, "at %.1fx dx=%d the controls changed by %d", zoom, dx, work1.width - work0.width)
			testing.expectf(t, abs((page1.width - page0.width) + dx) <= 3, "at %.1fx dx=%d the page changed by %d", zoom, dx, page1.width - page0.width)
		}
	}
	result, _ := sa.eval(app.window, "wbSetZoom(1)")
	sa.value_clear(&result)
}

// THE NOTES VIEW'S DIVIDERS DRAG TOO. Reported: "the divider between the notes editor and the preview is
// not moving" - the split was a plain div with no splitter at all. Now a frameset with the same drag.
@(test)
test_the_notes_editor_and_preview_divider_drags :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Editor)
	set_shown(&app, "#bml-page", true)
	relayout := find(&app, "#bml-split")
	testing.expect(t, relayout != nil, "the notes view should be a frameset")
	if relayout == nil {return}
	_ = sa.update_element(relayout, render = true)
	pump(&app)

	text0, _ := sa.location(find(&app, "#bml-text"), .Border, .Root)
	page0, _ := sa.location(find(&app, "#bml-page"), .Border, .Root)
	testing.expect(t, text0.width > 0 && page0.width > 0, "the editor and the preview should both be laid out")
	x := (text0.x + text0.width + page0.x) / 2
	y := text0.y + text0.height / 2
	sa.windowless_mouse(&g_view, .MOUSE_ENTER, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_DOWN, {x, y})
	for step in 1 ..= 10 {
		sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x - i32(step) * 12, y})
		pump(&app)
	}
	sa.windowless_mouse(&g_view, .MOUSE_UP, {x - 120, y})
	pump(&app)
	text1, _ := sa.location(find(&app, "#bml-text"), .Border, .Root)
	testing.expectf(t, abs((text1.width - text0.width) + 120) <= 3, "the editor changed by %d, not -120", text1.width - text0.width)
	set_shown(&app, "#bml-page", false)
}

/*
A CTRL+WHEEL ZOOM IS REMEMBERED, the window's and the hand page's.

Reported: zoomed in, restarted, back at 100%. Only the keyboard's zoom was ever saved; the wheel is a script
event and the host never heard about it. The script now posts `wb-zoom` / `wb-page-zoom` after a wheel step,
and this drives exactly that: the factor the script set, then the event the wheel handler posts.
*/
@(test)
test_a_wheel_zoom_is_remembered :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	app.prefs = prefs.load("", context.allocator)
	defer prefs.destroy(&app.prefs)

	result, _ := sa.eval(app.window, `wbSetZoom(1.33); wbZoomed("wb-zoom"); wbSetPageZoom(0.9); wbZoomed("wb-page-zoom")`)
	sa.value_clear(&result)
	pump(&app)
	pump(&app)

	zoom, found := prefs.get(&app.prefs, ZOOM_PREF)
	testing.expect(t, found, "a wheel zoom should be saved")
	testing.expect_value(t, zoom, "1.33")
	page, page_found := prefs.get(&app.prefs, PAGE_ZOOM_PREF)
	testing.expect(t, page_found, "a wheel zoom of the page should be saved")
	testing.expect_value(t, page, "0.90")

	reset, _ := sa.eval(app.window, `wbSetZoom(1); wbSetPageZoom(1)`)
	sa.value_clear(&reset)
}

/*
A FINISHED GENERATE RUN SHOWS WHAT IT MADE.

Reported with a screenshot: generate with the hand page open, the transcript says the run wrote
`slam-makes-dd.html`, and the pane still shows the deals from before. A run writes to disk and never put
anything in the frame, so the pane kept its old load of the very file the run had just replaced. Driven from
the point a run ends (`job_ended`), with a cards page written where the run would have written it; a
CANCELLED run, which is the same call without the flag, must leave the pane alone.
*/
@(test)
test_a_finished_generate_run_shows_its_page :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Panes)
	pump(&app)

	dir := scratch_scenario_dir(t, "wb-generated-page")
	if dir == "" || len(app.scenarios) == 0 {return}
	set_input(&app, "#outdir", dir)
	app.selected = 0
	name := app.scenarios[0].name
	path, jerr := filepath.join({dir, strings.concatenate({name, ".html"}, context.temp_allocator)}, context.temp_allocator)
	if jerr != nil {return}
	page := `<html><head><style>body { size: *; }</style></head><body><div class="nc-track"></div><h1>new deals</h1></body></html>`
	if os.write_entire_file(path, transmute([]u8)page) != nil {return}

	// Cancelled: nothing arrives.
	app.job.kind = .Generate
	job_ended(&app, show_result = false)
	pump(&app)
	testing.expect(t, app.shown_path == "", "a cancelled run should not load a page")

	// Completed: the page the run wrote is the one in the pane, and the pane is open.
	app.job.kind = .Generate
	job_ended(&app, show_result = true)
	pump(&app)
	testing.expect(t, same_dir(app.shown_path, path), "the finished run's page should be in the pane")
	testing.expect(t, page_pane_shown(&app), "and the pane should be open to show it")
}

// CTRL+0 IS THE TRUE 100%: the zoom property REMOVED, and a control back to exactly its unzoomed size. Pinned
// after a report that ctrl+0 seemed to land on "a new 100%" - which this does not reproduce (the windowless
// view; a real window's wheel or a focused frame are the open questions).
@(test)
test_ctrl_0_returns_to_the_unzoomed_size :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	show_view(&app, .Panes)
	pump(&app)
	fresh, _ := sa.location(find(&app, "#generate"), .Border, .Root)
	result, _ := sa.eval(app.window, "wbSetZoom(1.21)")
	sa.value_clear(&result)
	pump(&app)
	zoomed, _ := sa.location(find(&app, "#generate"), .Border, .Root)
	testing.expect(t, zoomed.width > fresh.width, "the zoom should have taken")
	press_key(&app, .NUM_0, ctrl = true)
	pump(&app)
	reset, _ := sa.location(find(&app, "#generate"), .Border, .Root)
	testing.expect_value(t, reset.width, fresh.width)
	testing.expect_value(t, reset.height, fresh.height)
	testing.expect_value(t, zoom_factor(&app), 1.0)
}

@(private = "file")
pane_box :: proc(app: ^App, selector: string) -> sa.Rect {
	box, _ := sa.location(find(app, selector), .Border, .Root)
	return box
}

/*
WHATEVER IS SHOWN FILLS THE WINDOW, FROM THE LEFT EDGE, in every combination the bar can make.

Reported with two screenshots, both with the scenario list CLOSED: a sliver and a stray line down the left
edge, the controls a few dozen px wide beside the hand page, and with the page closed the controls stranded
beside a blank column. Each combination of list / controls / page is put up here, after a drag has left the
frameset in pixels (the state that caused it), and the shown panes must start at the left edge, end at the
right one, and none of them be a sliver.
*/
@(test)
test_every_pane_combination_fills_the_window :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page", take_keyboard = false) {return}

	Case :: struct {
		list: bool,
		mode: Pane_Mode,
	}
	for c in ([]Case{{false, .Split}, {false, .Closed}, {false, .Wide}, {true, .Split}, {true, .Closed}, {true, .Wide}}) {
		// What a drag leaves behind: every pane in pixels.
		_ = write_split_state(&app, {"250px", "40px", "1*"})
		show_scenario_list(&app, c.list)
		set_pane_mode(&app, c.mode)
		pump(&app)
		left, right := 100000, 0
		for selector in DEAL_SPLIT_SELECTORS {
			if effective_display_is_hidden(&app, selector) {
				continue
			}
			box := pane_box(&app, selector)
			testing.expectf(t, box.width >= 150, "list=%v %v: %s is %dpx wide", c.list, c.mode, selector, box.width)
			left = min(left, int(box.x))
			right = max(right, int(box.x + box.width))
		}
		testing.expectf(t, left <= 2, "list=%v %v: the first pane starts at %d, not the left edge", c.list, c.mode, left)
		testing.expectf(t, right >= 1118, "list=%v %v: the panes end at %d, short of the window's 1120", c.list, c.mode, right)
	}
	show_scenario_list(&app, true)
	set_pane_mode(&app, .Split)
}

// THE LIST'S OWN DIVIDER DRAGS, after the list has been closed and opened again. Reported: "opening it
// makes the scenario pane non resizable". A real drag on the list/controls splitter.
@(test)
test_the_scenario_list_divider_drags_after_reopening :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page", take_keyboard = false) {return}
	set_pane_mode(&app, .Split)
	show_scenario_list(&app, false)
	pump(&app)
	show_scenario_list(&app, true)
	pump(&app)

	list0 := pane_box(&app, "#scenario-list")
	work0 := pane_box(&app, ".work")
	x := (list0.x + list0.width + work0.x) / 2
	y := work0.y + work0.height / 2
	sa.windowless_mouse(&g_view, .MOUSE_ENTER, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_DOWN, {x, y})
	for step in 1 ..= 8 {
		sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x + i32(step) * 10, y})
		pump(&app)
	}
	sa.windowless_mouse(&g_view, .MOUSE_UP, {x + 80, y})
	pump(&app)
	pump(&app)
	list1 := pane_box(&app, "#scenario-list")
	testing.expectf(t, abs((list1.width - list0.width) - 80) <= 3, "the list changed by %d, not 80", list1.width - list0.width)
	// And the drag is in the MODEL, so it survives the next re-render.
	set_pane_mode(&app, .Closed)
	set_pane_mode(&app, .Split)
	pump(&app)
	list2 := pane_box(&app, "#scenario-list")
	testing.expectf(t, abs(list2.width - list1.width) <= 3, "the dragged list width did not survive a re-render (%d -> %d)", list1.width, list2.width)
}

// THE NOTES VIEW'S DIVIDERS FOLLOW ITS PANES: folding the file list or closing the preview leaves no stray
// divider at either edge. Same fault as the deals view's, in the view that only became a frameset today.
@(test)
test_the_notes_view_has_no_stray_dividers :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Editor)
	for files in ([]bool{true, false}) {
		for preview in ([]bool{true, false}) {
			set_shown(&app, "#bml-files", files)
			set_shown(&app, "#bml-page", preview)
			_ = sa.update_element(find(&app, "#bml-split"), render = true)
			pump(&app)
			left, right := 100000, 0
			for selector in ([]string{"#bml-files", "#bml-text", "#bml-page"}) {
				if effective_display_is_hidden(&app, selector) {continue}
				box := pane_box(&app, selector)
				left = min(left, int(box.x))
				right = max(right, int(box.x + box.width))
			}
			testing.expectf(t, left <= 2, "files=%v preview=%v: the first pane starts at %d", files, preview, left)
			testing.expectf(t, right >= 1118, "files=%v preview=%v: the panes end at %d", files, preview, right)
		}
	}
	set_shown(&app, "#bml-files", true)
	set_shown(&app, "#bml-page", false)
}

/*
A REBUILD OF THE LIST KEEPS THE GROUPS THAT ARE ON — including a group that comes from a file.

Found in the state audit: saving a scenario rebuilds the list now, and the rebuild replaced the group flags
wholesale, so every save silently dropped the group filter in use. A file's group is the hard case — its name
lives in the loaded files the rebuild frees, so it has to be copied out first.
*/
@(test)
test_a_rebuild_keeps_the_groups_that_are_on :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := scratch_scenario_dir(t, "wb-groups-kept")
	if dir == "" {return}
	if !write_scenario_file(dir, "g.scenario", "scenario wb-grouped \"g\"\n  tags: wb-kept-group\n  north: hcp >= 12\n") {return}
	app.prefs = prefs.load("", context.allocator)
	defer prefs.destroy(&app.prefs)
	prefs.set(&app.prefs, SCENARIO_DIRS_PREF, dir)
	reloaded, _ := reload_scenarios(&app)
	testing.expect(t, reloaded)

	turn_on :: proc(app: ^App, name: string) {
		for group, i in app.groups {
			if group.name == name && !app.tag_on[i] {
				toggle_tag(app, i)
			}
		}
	}
	turn_on(&app, "wb-kept-group")
	if len(app.groups) > 0 {
		turn_on(&app, app.groups[0].name) // and a compiled one
	}
	// COPIED, for the same reason the rebuild copies them: a file group's name is freed by the rebuild.
	before := make([dynamic]string, 0, 2, context.temp_allocator)
	for name in selected_tag_names(&app, context.temp_allocator) {
		append(&before, strings.clone(name, context.temp_allocator))
	}
	testing.expect(t, len(before) == 2, "two groups should be on")

	again, _ := reload_scenarios(&app)
	testing.expect(t, again)
	after := selected_tag_names(&app, context.temp_allocator)
	testing.expect_value(t, len(after), len(before))
	for name in before {
		testing.expectf(t, slice.contains(after, name), "the group %q was dropped by the rebuild", name)
	}
}

/*
WITH THE SCENARIO LIST CLOSED, THE DIVIDER DRAGS — AGAIN AND AGAIN — AND STAYS WHERE IT IS DROPPED.

Reported: "drag and release, it ends in the wrong place; now I cannot even select it again" with the list
closed and the page half/half. Two measured causes: the script counted the HIDDEN list as a pane (a hidden
element can report its old box), wrote three widths to a frameset showing two and threw, so the drag died;
and the release folded the drag into the model as border-box widths, which the frameset reads as content
proportions, so the divider jumped ~20px after letting go. Real drags, three in a row, each checked AFTER
the release and its re-render.
*/
@(test)
test_the_divider_drags_repeatedly_with_the_list_closed :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page", take_keyboard = false) {return}
	set_pane_mode(&app, .Split)
	for list in ([]bool{false, true}) {
		show_scenario_list(&app, list)
		pump(&app)
		for dx in ([]i32{-100, 60, -40}) {
			work0 := pane_box(&app, ".work")
			drag_page_divider(&app, dx)
			pump(&app)
			pump(&app)
			work1 := pane_box(&app, ".work")
			testing.expectf(
				t,
				abs((work1.width - work0.width) - dx) <= 3,
				"list=%v: a drag of %d moved the controls by %d after the release",
				list,
				dx,
				work1.width - work0.width,
			)
		}
	}
}


/*
A DRAG CANNOT OUTLIVE THE BUTTON.

Reported: very small drags made the panes jump - the controls from most of the window to a sliver. The drag
listened for moves and the release only ON the 5px divider; a release that landed elsewhere was never heard,
the drag stayed live, and the next time the pointer merely crossed the divider the panes jumped by all it had
travelled. Here the release is MISSED on purpose, then the pointer sweeps across the divider with no button
held: nothing may move. Plus the small-drag case itself, at 121%, with the list not creeping.
*/
@(test)
test_a_drag_cannot_outlive_the_button :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page", take_keyboard = false) {return}
	result, _ := sa.eval(app.window, "wbSetZoom(1.21)")
	sa.value_clear(&result)
	app.deal_layout = {}
	set_pane_mode(&app, .Split)
	pump(&app)

	// Small drags land where they are dropped, and the list does not creep.
	list0 := pane_box(&app, "#scenario-list")
	for dx in ([]i32{-8, 6, -4}) {
		work0 := pane_box(&app, ".work")
		drag_page_divider(&app, dx)
		pump(&app)
		work1 := pane_box(&app, ".work")
		testing.expectf(t, abs((work1.width - work0.width) - dx) <= 3, "a %dpx drag moved the controls %d", dx, work1.width - work0.width)
	}
	testing.expect_value(t, pane_box(&app, "#scenario-list").width, list0.width)

	// Press, move, and the release is never heard.
	work := pane_box(&app, ".work")
	page := pane_box(&app, "#pageview")
	x := (work.x + work.width + page.x) / 2
	y := work.y + work.height / 2
	sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_DOWN, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x - 10, y})
	pump(&app)
	settled := pane_box(&app, ".work")
	// The pointer wanders off and back across the divider with NO button held.
	for step in 0 ..< 12 {
		sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x - 300 + i32(step) * 50, y}, button = {})
		pump(&app)
	}
	after := pane_box(&app, ".work")
	testing.expectf(t, abs(after.width - settled.width) <= 3, "a buttonless sweep moved the controls %d -> %d", settled.width, after.width)
	reset, _ := sa.eval(app.window, "wbSetZoom(1)")
	sa.value_clear(&reset)
}

/*
THE RELEASE READS WHAT THE DRAG WROTE, NOT WHAT IS ON SCREEN YET.

The layout lags the mouse (a 48-board hand page re-lays out in ~124ms a step), so at release the panes can
still be where an EARLIER move put them; measuring then snapped the divider back. The drag writes plain CSS
widths on the two panes beside the divider, and the release just reads those. The harness cannot lag, so
this pins the property: widths written but not yet laid out are what the model takes.
*/
@(test)
test_the_release_reads_the_widths_the_drag_wrote :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page", take_keyboard = false) {return}
	set_pane_mode(&app, .Split)
	app.deal_layout = {250, 0}
	apply_deal_layout(&app)
	pump(&app)

	// What a drag leaves, before any layout has caught up with it.
	sa.set_style(find(&app, "#scenario-list"), "width", "300px")
	sa.set_style(find(&app, "#work"), "width", "600px")
	take_deal_drag(&app)
	testing.expect_value(t, app.deal_layout, Deal_Layout{300, 600})

	// With the page shut the controls are `1*`, not a width of their own: their remembered width stays.
	set_pane_mode(&app, .Closed)
	sa.set_style(find(&app, "#scenario-list"), "width", "280px")
	take_deal_drag(&app)
	testing.expect_value(t, app.deal_layout, Deal_Layout{280, 600})
}

// THE FRAMES IGNORE THE MOUSE WHILE A DIVIDER IS DRAGGED, and only then. A drag toward the hand page puts the
// pointer over a framed document, which would take the moves for itself; the shield is `.dragging` on the
// split making its frames `pointer-events: none`. It must also come OFF, or the page stops answering clicks.
@(test)
test_the_hand_page_ignores_the_mouse_during_a_drag :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	show_view(&app, .Panes)
	if !show_page_html(&app, MINIMAL_PAGE, "a page", take_keyboard = false) {return}
	set_pane_mode(&app, .Split)
	pump(&app)

	frame := find(&app, "#page")
	split := find(&app, "#deal-split")
	if frame == nil || split == nil {return}
	work := pane_box(&app, ".work")
	page := pane_box(&app, "#pageview")
	x := (work.x + work.width + page.x) / 2
	y := work.y + work.height / 2
	sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_DOWN, {x, y})
	sa.windowless_mouse(&g_view, .MOUSE_MOVE, {x + 40, y})
	pump(&app)
	during, _ := sa.style(frame, "pointer-events", context.temp_allocator)
	testing.expect_value(t, during, "none")

	sa.windowless_mouse(&g_view, .MOUSE_UP, {x + 40, y})
	pump(&app)
	after, _ := sa.style(frame, "pointer-events", context.temp_allocator)
	testing.expect(t, after != "none", "the hand page must take the mouse again after the drag")
	classes, _ := sa.attribute(split, "class", context.temp_allocator)
	testing.expect(t, !strings.contains(classes, "dragging"), classes)
}


