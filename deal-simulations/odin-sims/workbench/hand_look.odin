package main

/*
	hand_look.odin — how the HAND PAGE looks: the suits (the same choice as the notes'), the felt and the cards,
	picked in Settings beside the notes' look.

	A LOOK IS A FEW RULES ON THE PAGE'S OWN SELECTORS (`.suit.c`, `.compass`, `.seat`, ...), not tokens: the card
	pages already on disk were written before any token existed, and a look that only reached new pages would
	leave a whole deals folder in the old one. Each rule repeats the page's own selector, and the block comes
	after the page's stylesheet, so it wins at equal specificity - and the page's more specific rules (a
	selected button, a face-down hand's transparent card, a double-dummy card's tint) keep theirs.

	IT GOES INTO THE MARKUP, BEFORE THE PAGE LOADS. Measured (2026-10-20, windowless): a `<style>` appended to a
	loaded document's head - by `createElement` or by `insertAdjacentHTML`, with or without a forced restyle -
	is in the DOM and applies nothing, and a `CSS.set` style set given to the root did nothing either. So a page
	is read and loaded as HTML with the block in its head (`with_hand_look`), and a change of look RELOADS the
	page in the pane (`reshow_page_for_look`, on the deals view's next showing - Settings hides it). The file is
	read only when a look is chosen: the original is no rules, and keeps the engine's own `loadFile`.

	WHERE IT APPLIES:
	  * the hand pane, every page shown there, old ones included;
	  * pages WRITTEN by a run, when Settings says "generated pages: this look": `norn.page_look_css`, set as a
	    job starts (`set_page_look_for_run`), when no worker can be reading it;
	  * NOT a share link: a link carries deals, and the reader's player draws its own page.

	The original look (four-colour, green, white) is NO rules at all, so a default setting changes nothing in
	any page, written or shown.

	THE SUITS ARE ONE SETTING FOR BOTH (`suits`), asked for: a player wants the same colours in the notes and
	at the table. It was `notes.suits` for a day, which is still read when `suits` is absent.
*/

import "core:os"
import "core:strings"

import "../prefs"
import "norn:norn"
import sciter "sciter:."
import sa "sciter:sciter_app"

SUITS_PREF :: "suits"
HAND_FELT_PREF :: "hand.felt"
HAND_CARD_PREF :: "hand.card"
HAND_BUILT_PREF :: "hand.built"

// The words, in the order Settings shows them. The first of each is the original look.
HAND_FELTS :: [?]string{"green", "blue", "grey"}
HAND_CARDS :: [?]string{"white", "cream"}

Hand_Look :: struct {
	suits: string,
	felt:  string,
	card:  string,
}

// One remembered word of `words`, else the first (the original). `keys` are tried in order.
@(private = "file")
pick_word :: proc(p: ^prefs.Prefs, keys: []string, words: []string) -> string {
	for key in keys {
		if word, found := prefs.get(p, key); found {
			for known in words {
				if word == known {
					return known
				}
			}
		}
	}
	return words[0]
}

// The suits, shared with the notes: `suits`, else the notes' old key.
chosen_suits :: proc(p: ^prefs.Prefs) -> string {
	suits := NOTES_SUITS
	return pick_word(p, {SUITS_PREF, NOTES_SUITS_PREF}, suits[:])
}

hand_look :: proc(p: ^prefs.Prefs) -> Hand_Look {
	felts, cards := HAND_FELTS, HAND_CARDS
	return {suits = chosen_suits(p), felt = pick_word(p, {HAND_FELT_PREF}, felts[:]), card = pick_word(p, {HAND_CARD_PREF}, cards[:])}
}

/*
The rules for a look; empty for the original. CONCATENATED, not formatted: `fmt` reads a brace as a directive.
The suit colours are the notes' light-page ones (`notes_look_rules`), with black spades - the page's own.
*/
hand_look_css :: proc(look: Hand_Look, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	rule :: proc(b: ^strings.Builder, selector, declarations: string) {
		strings.write_string(b, selector)
		strings.write_string(b, " { ")
		strings.write_string(b, declarations)
		strings.write_string(b, " }\n")
	}
	suit :: proc(b: ^strings.Builder, letter, colour: string) {
		selector := strings.concatenate(
			{".suit.", letter, ", .ssym.", letter, ", .ct .suit-", letter, " .sl"},
			context.temp_allocator,
		)
		rule(b, selector, strings.concatenate({"color: ", colour, ";"}, context.temp_allocator))
	}
	switch look.suits {
	case "two-colour":
		suit(&b, "c", "Black")
		suit(&b, "d", "Red")
	case "colour-blind":
		suit(&b, "c", "#0072b2")
		suit(&b, "d", "#e69f00")
		suit(&b, "h", "#d55e00")
	}
	switch look.felt {
	case "blue":
		rule(&b, ".compass", "background: #2f5f8a; border-color: #244a6e;")
	case "grey":
		rule(&b, ".compass", "background: #59636d; border-color: #444c54;")
	}
	if look.card == "cream" {
		rule(&b, ".seat", "background: #fbf4e2;")
		rule(&b, ".trk .pc", "background: #fbf4e2;")
	}
	return strings.to_string(b)
}

// `page` with the look's `<style>` at the end of its head (before `</head>`, else at the front); `page` itself
// when the look is the original.
with_hand_look :: proc(app: ^App, page: string, allocator := context.allocator) -> string {
	css := hand_look_css(hand_look(&app.prefs), context.temp_allocator)
	if css == "" {
		return page
	}
	at := strings.index(page, "</head>")
	if at < 0 {
		at = 0
	}
	return strings.concatenate({page[:at], `<style id="wb-look">`, css, "</style>", page[at:]}, allocator)
}

/*
Load a page FILE into the frame with the look in it. False when there is no look to add (the caller then uses
`loadFile`), or the file is not an html page or cannot be read. The base URL is the file's own, so anything the
page names relative to itself resolves as it would have.
*/
load_file_with_look :: proc(app: ^App, asset: ^sciter.Som_Asset_T, path: string) -> bool {
	if hand_look_css(hand_look(&app.prefs), context.temp_allocator) == "" || !strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".html") {
		return false
	}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return false
	}
	defer delete(data)
	page := with_hand_look(app, string(data))
	defer delete(page)
	html_value := sa.value_from(page)
	defer sa.value_clear(&html_value)
	url, _ := strings.replace_all(path, `\`, "/", context.temp_allocator)
	base := sa.value_from(strings.concatenate({"file:///", strings.trim_left(url, "/")}, context.temp_allocator))
	defer sa.value_clear(&base)
	result, cerr := sa.asset_call(asset, "loadHtml", {html_value, base})
	defer sa.value_clear(&result)
	return cerr == nil && !sa.value_is_error(&result)
}

// Show the page in the pane again, with the look as it now is: the file, or the analysed page, whichever is up.
reshow_page_for_look :: proc(app: ^App) {
	if app.showing_analysed {
		_ = show_analysed_page(app)
	} else if app.shown_path != "" && strings.has_suffix(strings.to_lower(app.shown_path, context.temp_allocator), ".html") {
		path := strings.clone(app.shown_path, context.temp_allocator) // `show_page_file` replaces it
		_ = show_page_file(app, path, take_keyboard = false)
	}
}

// The look changed: the page in the pane is reloaded with it - now if it is on screen, else when it next is.
apply_hand_look :: proc(app: ^App) {
	if current_view(app) == .Panes {
		reshow_page_for_look(app)
	} else {
		app.hand_look_stale = true
	}
}

// Do runs write the look into their pages?
generated_pages_use_look :: proc(app: ^App) -> bool {
	word, _ := prefs.get(&app.prefs, HAND_BUILT_PREF)
	return word == "on"
}

/*
What the next run writes into its card pages. Called from `start_job` BEFORE the worker starts and never while
one runs (`app.running` is checked there first), so the worker is never reading the string this replaces.
*/
set_page_look_for_run :: proc(app: ^App) {
	if norn.page_look_css != "" {
		delete(norn.page_look_css)
		norn.page_look_css = ""
	}
	if generated_pages_use_look(app) {
		css := hand_look_css(hand_look(&app.prefs), context.temp_allocator)
		if css != "" {
			norn.page_look_css = strings.clone(css)
		}
	}
}

@(private = "file")
save_pref :: proc(app: ^App, key, word: string) {
	if app.prefs.values == nil {
		return
	}
	prefs.set(&app.prefs, key, word)
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
}

// A hand-look button was pressed: remember it and show it on the page in the pane now.
choose_hand_look :: proc(app: ^App, key, word: string) {
	save_pref(app, key, word)
	apply_hand_look(app)
	draw_hand_look_prefs(app)
}

// The shared suits button: both looks follow. The notes re-render on their next showing.
choose_suits :: proc(app: ^App, word: string) {
	save_pref(app, SUITS_PREF, word)
	app.notes_look_stale = true
	if built_pages_use_look(app) {
		set_text_at(app, "#prefs-notes-note", set_built_pages_look(app, true))
	}
	apply_hand_look(app)
	draw_notes_look_prefs(app)
	draw_hand_look_prefs(app)
}

choose_generated_look :: proc(app: ^App, on: bool) {
	save_pref(app, HAND_BUILT_PREF, "on" if on else "off")
	set_text_at(
		app,
		"#prefs-hand-note",
		"pages written from now on carry this look" if on else "pages written from now on keep the original look",
	)
	draw_hand_look_prefs(app)
}

draw_hand_look_prefs :: proc(app: ^App) {
	look := hand_look(&app.prefs)
	light :: proc(app: ^App, attribute, chosen: string, words: []string) {
		for word in words {
			selector := strings.concatenate({`#prefs-panel [`, attribute, `="`, word, `"]`}, context.temp_allocator)
			if button := find(app, selector); button != nil {
				sa.set_attribute(button, "class", "segbtn on" if word == chosen else "segbtn")
			}
		}
	}
	felts, cards, suits := HAND_FELTS, HAND_CARDS, NOTES_SUITS
	light(app, "data-suits", look.suits, suits[:])
	light(app, "data-hand-felt", look.felt, felts[:])
	light(app, "data-hand-card", look.card, cards[:])
	light(app, "data-hand-built", "on" if generated_pages_use_look(app) else "off", {"off", "on"})
}
