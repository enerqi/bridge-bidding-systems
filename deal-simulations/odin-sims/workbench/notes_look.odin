package main

/*
	notes_look.odin — how the NOTES look: page colours, suit colours and font, picked in Settings.

	A LOOK IS A SECOND `:root` BLOCK. `bml.css` names every colour and its font once, as `--bml-*` tokens on
	`:root` (the bml repo's stylesheet; its values are the original look), so a look is a small block placed
	AFTER that sheet which redefines some of them. No rule is rewritten, nothing in the html changes, and a
	stylesheet without the tokens (an older `bml.css`) simply ignores the block and keeps its own look.

	THREE CHOICES, EACH A FEW PRESETS, because the person choosing is not writing CSS:

	  * page  - classic (antique white, the original), white, dark;
	  * suits - four-colour (the original: green clubs, orange diamonds), two-colour (red and black, as most
	            players learned), colour-blind safe (Okabe-Ito blue / orange / vermillion: the original's green
	            clubs against red hearts is exactly the red-green pair a colour-blind reader cannot tell apart);
	  * font  - Open Sans (the original), the system's, serif.

	Spades (and two-colour clubs) are the page's INK rather than black, so they stay readable on the dark page.

	WHERE IT APPLIES: the notes preview and the quiz page's notes panel, which inline the stylesheet and append
	this. And, when Settings says so, the pages BUILT from the notes: those link `bml.css` itself, so the block
	is written to `bml-look.css` in the notes folder and the `bml` recipe appends it to the `bml.css` it copies
	there. The html never changes - only the stylesheet beside it. The file's EXISTENCE is the setting (the
	read-from-the-document rule, here the folder): no pref to disagree with it.
*/

import "core:os"
import "core:path/filepath"
import "core:strings"

import "../prefs"
import sa "sciter:sciter_app"

NOTES_PAGE_PREF :: "notes.page"
NOTES_SUITS_PREF :: "notes.suits" // read only when `suits` is absent (hand_look.odin: the suits are shared now)
NOTES_FONT_PREF :: "notes.font"

// The words, in the order Settings shows them. The first of each is the original look.
NOTES_PAGES :: [?]string{"classic", "white", "dark"}
NOTES_SUITS :: [?]string{"four-colour", "two-colour", "colour-blind"}
NOTES_FONTS :: [?]string{"open-sans", "system", "serif"}

Notes_Look :: struct {
	page:  string,
	suits: string,
	font:  string,
}

// The remembered look; a missing or unknown word is the original.
notes_look :: proc(p: ^prefs.Prefs) -> Notes_Look {
	pick :: proc(p: ^prefs.Prefs, key: string, words: []string) -> string {
		if word, found := prefs.get(p, key); found {
			for known in words {
				if word == known {
					return known
				}
			}
		}
		return words[0]
	}
	pages, fonts := NOTES_PAGES, NOTES_FONTS
	return {page = pick(p, NOTES_PAGE_PREF, pages[:]), suits = chosen_suits(p), font = pick(p, NOTES_FONT_PREF, fonts[:])}
}

// The `:root` block as a complete `<style>` element, for a page that inlines its stylesheet.
notes_look_css :: proc(look: Notes_Look, allocator := context.allocator) -> string {
	return strings.concatenate({"<style>", notes_look_rules(look, context.temp_allocator), "</style>"}, allocator)
}

/*
The `:root` block for a look, as CSS. CONCATENATED, not formatted: `fmt` reads a brace as a directive (see
`preview_override_css`).
*/
notes_look_rules :: proc(look: Notes_Look, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, ":root {")
	token :: proc(b: ^strings.Builder, name, value: string) {
		strings.write_string(b, " --bml-")
		strings.write_string(b, name)
		strings.write_string(b, ": ")
		strings.write_string(b, value)
		strings.write_string(b, ";")
	}

	switch look.page {
	case "white":
		token(&b, "page-bg", "white")
		token(&b, "ink", "#1a1a1a")
		token(&b, "bid-col", "rgb(165, 252, 247, 0.3)")
		token(&b, "bid-col-alt", "rgb(135, 206, 250, 0.3)")
		token(&b, "link", "rgb(0, 102, 204)")
	case "dark":
		token(&b, "page-bg", "#1e1f26")
		token(&b, "ink", "#e4e4e8")
		token(&b, "bid-col", "rgb(70, 140, 150, 0.35)")
		token(&b, "bid-col-alt", "rgb(80, 120, 170, 0.35)")
		token(&b, "link", "#7cb8ff")
		strings.write_string(&b, " --nav-link-color: #e0a070;")
	case:
		token(&b, "page-bg", "antiquewhite")
		token(&b, "ink", "black")
		token(&b, "bid-col", "rgb(165, 252, 247, 0.4)")
		token(&b, "bid-col-alt", "rgb(135, 206, 250, 0.4)")
		token(&b, "link", "rgb(0, 102, 204)")
	}

	// The red on the dark page is lifted, or it sinks into the background.
	red := "#ff6b6b" if look.page == "dark" else "Red"
	switch look.suits {
	case "two-colour":
		token(&b, "club", "var(--bml-ink)")
		token(&b, "diamond", red)
		token(&b, "heart", red)
	case "colour-blind":
		token(&b, "club", "#56b4e9" if look.page == "dark" else "#0072b2")
		token(&b, "diamond", "#e69f00")
		token(&b, "heart", "#ff7a3d" if look.page == "dark" else "#d55e00")
	case:
		token(&b, "club", "MediumSeaGreen")
		token(&b, "diamond", "Orange")
		token(&b, "heart", red)
	}
	token(&b, "spade", "var(--bml-ink)")

	switch look.font {
	case "system":
		token(&b, "font", "'Segoe UI', system-ui, sans-serif")
	case "serif":
		token(&b, "font", "Georgia, 'Times New Roman', serif")
	case:
		token(&b, "font", "'Open Sans', 'Segoe UI', sans-serif")
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// ---- the built pages ----------------------------------------------------------------------------------

NOTES_LOOK_FILE :: "bml-look.css"

NOTES_LOOK_FILE_HEADER ::
	"/* Written by Bridge Workbench (Settings, Notes look: built pages). `just bml` appends this to the\n" +
	"   bml.css it copies beside the pages. Delete it, or choose \"own look\", to build with the stylesheet alone. */\n"

notes_look_file :: proc(app: ^App) -> string {
	if app.docs == "" {
		return ""
	}
	path, _ := filepath.join({app.docs, NOTES_LOOK_FILE}, context.temp_allocator)
	return path
}

// Do the built pages use the chosen look? Whether the file is there.
built_pages_use_look :: proc(app: ^App) -> bool {
	path := notes_look_file(app)
	return path != "" && os.exists(path)
}

// Write the chosen look for the built pages, or take it away. Says what happened.
set_built_pages_look :: proc(app: ^App, on: bool) -> string {
	path := notes_look_file(app)
	if path == "" {
		return "no notes folder to write the look into"
	}
	if !on {
		if os.exists(path) {
			if err := os.remove(path); err != nil {
				return strings.concatenate({"could not remove ", path}, context.temp_allocator)
			}
		}
		return "built pages: the stylesheet's own look (next `just bml`)"
	}
	body := strings.concatenate(
		{NOTES_LOOK_FILE_HEADER, notes_look_rules(notes_look(&app.prefs), context.temp_allocator), "\n"},
		context.temp_allocator,
	)
	if err := os.write_entire_file(path, transmute([]u8)body); err != nil {
		return strings.concatenate({"could not write ", path}, context.temp_allocator)
	}
	return "built pages: this look (next `just bml`)"
}

// A look button was pressed: remember it, and re-render the preview the next time the notes are shown (the
// settings view hides them, and a frame is not rendered into while hidden).
choose_notes_look :: proc(app: ^App, key, word: string) {
	if app.prefs.values != nil {
		prefs.set(&app.prefs, key, word)
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	app.notes_look_stale = true
	// The built pages follow a change too, when they are set to use the look.
	if built_pages_use_look(app) {
		set_text_at(app, "#prefs-notes-note", set_built_pages_look(app, true))
	}
	draw_notes_look_prefs(app)
}

// Light the remembered word in each of the three rows.
draw_notes_look_prefs :: proc(app: ^App) {
	look := notes_look(&app.prefs)
	light :: proc(app: ^App, attribute, chosen: string, words: []string) {
		for word in words {
			selector := strings.concatenate({`#prefs-panel [`, attribute, `="`, word, `"]`}, context.temp_allocator)
			if button := find(app, selector); button != nil {
				sa.set_attribute(button, "class", "segbtn on" if word == chosen else "segbtn")
			}
		}
	}
	pages, fonts := NOTES_PAGES, NOTES_FONTS
	light(app, "data-notes-page", look.page, pages[:])
	light(app, "data-notes-font", look.font, fonts[:])
	built := "on" if built_pages_use_look(app) else "off"
	light(app, "data-notes-built", built, {"off", "on"})
}
