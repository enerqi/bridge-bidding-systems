/*
THE `share link` BUTTON: the hand pane's page as a LINK (SHARING_PLAN.md, Tier B).

The boards are read back out of the page on screen (`share.boards_from_page`: every board's `data-hv` and its
marked dealer), so any card page can be shared - a generated file, or an analysed page that only exists in
memory - with nothing regenerated. They are packed into a fragment (`share.encode`, ~19 characters a board)
and put after the address of the PLAYER: one fixed page, norn compiled to wasm, that rebuilds the card page in
the reader's browser. Nothing is uploaded anywhere; the deals travel in the link.

WHERE THE PLAYER IS. A link is only as good as the address in front of it, so:
  - the `share.player` setting: the address of a published `player.html` (any static host - it never
    changes, so it is published once). This is what makes a link someone else can open.
  - otherwise the copy BUILT INTO this program (`ui/player.html`, vendored by `just sims vendor-player`), written
    to the deals folder and linked as a `file:///` address. That opens on this computer only, and the status
    line says so - it is for trying a link, not for sending one.

WHAT A LINK CARRIES. The player has norn and the card-combination analysis (`combo`), so a page that had that
analysis gets it again, recomputed. Par comes from DDS, which the player does not have, so a board's par travels
as the solver's NUMBERS (~16 bytes) and the player writes the caption from them (`par_caption`). The analysed
advisor's sampled and exact figures (`data-sim`) do not travel; the status line says when something stays behind.
*/
package main

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sa "sciter:sciter_app"

import "norn:norn"
import "../prefs"
import "../share"

// The player page, compiled in (`just sims vendor-player` refreshes it).
PLAYER_BUILTIN :: #load("../ui/player.html", string)

// Where a published player is: a URL, or empty for the built-in copy.
SHARE_PLAYER_PREF :: "share.player"

// The link for `page`, opening the player at `player` (an address with no fragment). `boards` is how many it
// carries; `left_behind` is true when the page held solver figures the player cannot recompute.
share_link_for :: proc(
	page: string,
	player: string,
	allocator := context.allocator,
) -> (
	link: string,
	boards: int,
	left_behind: bool,
	ok: bool,
) {
	title, found, read_ok := share.boards_from_page(page, context.temp_allocator)
	if !read_ok {
		return
	}
	fragment := share.encode(
		{title = title, analyse = strings.contains(page, `<div class="combo"`), boards = found},
		context.temp_allocator,
	)
	base := player
	if hash := strings.index_byte(base, '#'); hash >= 0 {
		base = base[:hash]
	}
	return strings.concatenate({base, "#", fragment}, allocator), len(found), leaves_figures_behind(page, found), true
}

// Does the page hold solver figures the link cannot carry: the analysed advisor's sampling or exact grids
// (`data-sim`), or a par caption `share` could not read back (the ones it can read travel as numbers)?
@(private = "file")
leaves_figures_behind :: proc(page: string, boards: []share.Board) -> bool {
	if strings.contains(page, "data-sim=") {
		return true
	}
	carried := 0
	for board in boards {
		if _, has := board.par.?; has {
			carried += 1
		}
	}
	return strings.count(page, `">Par: `) > carried
}

// `C:\deals\player.html` -> `file:///C:/deals/player.html`, with the characters a URL cannot hold escaped.
file_url :: proc(path: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "file:///")
	for i in 0 ..< len(path) {
		c := path[i]
		switch {
		case c == '\\':
			strings.write_byte(&b, '/')
		case c == ' ' || c == '#' || c == '%' || c == '?':
			fmt.sbprintf(&b, "%%%02X", c)
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// THE PLAYER BESIDE THE PAGES. The deals folder always holds a current `player.html`, written whenever this window
// reads the folder (startup, after a run, a new folder), so a card page's OWN Share button has a player next to it
// even with nothing published: with no address in the page it links to `player.html` beside itself - on this
// computer, or anywhere once the folder is put online. Rewritten only when it differs (a link made earlier keeps
// working), and checked once per folder per run: `checked_player_dir` is the hash of the last folder checked,
// not a copy of its path, so nothing is allocated for the life of the program.
@(private = "file")
checked_player_dir: u64

ensure_local_player :: proc(dir: string) {
	key := hash.fnv64a(transmute([]u8)dir)
	if key == checked_player_dir {
		return
	}
	checked_player_dir = key
	path, _ := filepath.join({dir, "player.html"}, context.temp_allocator)
	current, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr == nil && string(current) == PLAYER_BUILTIN {
		return
	}
	_ = os.write_entire_file(path, transmute([]u8)string(PLAYER_BUILTIN))
}

// The player's address: the setting, else the built-in copy written to the deals folder (rewritten only when
// it differs, so a link made earlier keeps working). `local` says the address is only good on this computer.
@(private = "file")
player_address :: proc(app: ^App) -> (address: string, local: bool, err: string) {
	if published, found := prefs.get(&app.prefs, SHARE_PLAYER_PREF); found && strings.trim_space(published) != "" {
		return strings.trim_space(published), false, ""
	}
	dir, derr := resolve_out_dir(strings.trim_space(read_text(app, "#outdir")))
	if derr != "" {
		return "", true, derr
	}
	path, _ := filepath.join({dir, "player.html"}, context.temp_allocator)
	current, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil || string(current) != PLAYER_BUILTIN {
		if werr := os.write_entire_file(path, transmute([]u8)string(PLAYER_BUILTIN)); werr != nil {
			return "", true, fmt.tprintf("could not write the player page to %s", path)
		}
	}
	return file_url(path, context.temp_allocator), true, ""
}

// The button.
share_shown_page :: proc(app: ^App) {
	page: string
	switch {
	case app.showing_analysed && app.analysed_page != "":
		page = app.analysed_page
	case app.shown_path != "":
		data, err := os.read_entire_file_from_path(app.shown_path, context.temp_allocator)
		if err != nil {
			set_note(app, fmt.tprintf("could not read %s", app.shown_path))
			return
		}
		page = string(data)
	case:
		set_note(app, "nothing in the pane to share - generate, analyse or pick a page first")
		return
	}
	player, local, perr := player_address(app)
	if perr != "" {
		set_note(app, perr)
		return
	}
	link, boards, left_behind, ok := share_link_for(page, player, context.temp_allocator)
	if !ok {
		set_note(app, "only a hand page can be shared as a link - this one has no boards in it")
		return
	}
	if !copy_text(app, link) {
		set_note(app, "the link could not be put on the clipboard")
		return
	}
	note := fmt.tprintf(
		"share link copied: %d board%s, %d characters",
		boards,
		"" if boards == 1 else "s",
		len(link),
	)
	if left_behind {
		note = fmt.tprintf("%s - the double-dummy figures it cannot carry stay behind", note)
	}
	if local {
		note = fmt.tprintf(
			"%s - it opens the player in the deals folder, so only on this computer: set where the player is published in Settings to send it",
			note,
		)
	}
	set_note(app, note)
}

// Put `text` on the system clipboard. The clipboard has no host API in this engine; the document's script
// has `Clipboard` (`wbCopyText` in ui/workbench.html).
@(private = "file")
copy_text :: proc(app: ^App, text: string) -> bool {
	value := sa.value_from(text)
	defer sa.value_clear(&value)
	result, err := sa.call(app.window, "wbCopyText", value)
	defer sa.value_clear(&result)
	if err != nil {
		return false
	}
	done, _ := sa.value_to_bool(&result)
	return done
}

// ---------------------------------------------------------------------------------------------------
// The setting

draw_share_prefs :: proc(app: ^App) {
	player, _ := prefs.get(&app.prefs, SHARE_PLAYER_PREF)
	set_input(app, "#prefs-share-player", player)
}

// The settings field was left: remember it. Returns whether `id` was it.
remember_share_pref :: proc(app: ^App, id: string) -> bool {
	if id != "prefs-share-player" {
		return false
	}
	value := strings.trim(strings.trim_space(read_text(app, "#prefs-share-player")), `"`)
	if app.prefs.values != nil {
		prefs.set(&app.prefs, SHARE_PLAYER_PREF, value)
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	apply_share_player(app)
	draw_share_prefs(app)
	return true
}

// The card pages this window writes carry the player's address too, for their own Share button
// (`norn.share_player`, the page's `<meta name="nc-share-player">`). Set from the setting at startup and when
// it changes; a page written before keeps the address it was written with.
apply_share_player :: proc(app: ^App) {
	published, _ := prefs.get(&app.prefs, SHARE_PLAYER_PREF)
	published = strings.trim_space(published)
	if published == norn.share_player {
		return
	}
	if norn.share_player != "" {
		delete(norn.share_player)
	}
	// Empty is the literal, not an allocation: a window that never sets one holds nothing.
	norn.share_player = strings.clone(published) if published != "" else ""
}
