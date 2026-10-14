/*
THE `share link` BUTTON: the hand pane's page as a LINK (SHARING_PLAN.md, Tier B).

The boards are read back out of the page on screen (`share.boards_from_page`: every board's `data-hv` and its
marked dealer), so any card page can be shared - a generated file, or an analysed page that only exists in
memory - with nothing regenerated. They are packed into a fragment (`share.encode`, ~19 characters a board)
and put after the address of the PLAYER: one fixed page, norn compiled to wasm, that rebuilds the card page in
the reader's browser. Nothing is uploaded anywhere; the deals travel in the link.

WHERE THE PLAYER IS. A link is only as good as the address in front of it, so:
  - the `share.player` setting: the address of a published `player.html` (any static host - it never
    changes, so it is published once). EMPTY means this project's own, `share.PUBLISHED_PLAYER`
    (bridge-workbench.netlify.app, deployed by `just sims publish-player`). This is what makes a link someone
    else can open.
  - only when the setting is not an address at all (`share.usable_player_address`), the copy BUILT INTO this
    program (`ui/player.html`, vendored by `just sims vendor-player`), written to the deals folder and linked as
    a `file:///` address. That opens on this computer only, and the status line says so and why.

WHAT A LINK CARRIES. The player has norn and the card-combination analysis (`combo`), so a page that had that
analysis gets it again, recomputed. Par comes from DDS, which the player does not have, so a board's par travels
as the solver's NUMBERS (~16 bytes) and the player writes the caption from them (`par_caption`). The analysed
advisor's sampled and exact figures (`data-sim`) do not travel; the status line says when something stays behind.

THE `QR` BUTTON: the same link as a QR code (SHARING_PLAN.md, Tier C), for phones at the table - scan, no
typing, no server. It opens a panel with the code, the link and what was left out of it. A link is long
(~19 characters a board, ~22 more with par), and a phone reads a big symbol badly, so the panel first tries
the whole link and, when that needs more than `QR_READABLE_VERSION`, drops the par numbers (the player still
draws every board) and says so; a set still too big gets the code anyway, with a warning to share fewer boards.
The encoder is `qr/`, pure Odin, held to a reference encoder's matrices.
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
import "../qr"
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
	with_par := true, // false leaves every board's par numbers out (the player then draws no caption)
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
	if !with_par {
		for &board in found {
			board.par = nil
		}
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

// The published player's address: the setting, or this project's own (`share.PUBLISHED_PLAYER`) when it is
// empty. Not `ok` when the setting holds something no link can start with.
published_player :: proc(app: ^App) -> (address: string, ok: bool) {
	setting, _ := prefs.get(&app.prefs, SHARE_PLAYER_PREF)
	setting = strings.trim_space(setting)
	if setting == "" {
		return share.PUBLISHED_PLAYER, true
	}
	return setting, share.usable_player_address(setting)
}

// The player's address: the published one, else - when the setting is not an address at all - the built-in copy
// written to the deals folder (rewritten only when it differs, so a link made earlier keeps working). `local`
// says the address is only good on this computer.
@(private = "file")
player_address :: proc(app: ^App) -> (address: string, local: bool, err: string) {
	if published, ok := published_player(app); ok {
		return published, false, ""
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

// What the hand pane shows, as page text: the analysed page in memory, or the file behind the pane. Says why
// not in the status line.
@(private = "file")
shown_page :: proc(app: ^App) -> (page: string, ok: bool) {
	switch {
	case app.showing_analysed && app.analysed_page != "":
		return app.analysed_page, true
	case app.shown_path != "":
		data, err := os.read_entire_file_from_path(app.shown_path, context.temp_allocator)
		if err != nil {
			set_note(app, fmt.tprintf("could not read %s", app.shown_path))
			return
		}
		return string(data), true
	case:
		set_note(app, "nothing in the pane to share - generate, analyse or pick a page first")
		return
	}
}

// The button.
share_shown_page :: proc(app: ^App) {
	page, have_page := shown_page(app)
	if !have_page {
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
			"%s - Settings' `player at` is not a web address, so it opens the player in the deals folder, on this computer only",
			note,
		)
	}
	set_note(app, note)
}

// ---------------------------------------------------------------------------------------------------
// The QR code

// The error correction asked for: L restores ~7% of the code. The code is read off a screen, clean and flat, where
// M's ~15% is almost never used, and L is 3-4 versions smaller at every size: with par, 28 boards are version 25
// at L and 28 at M (measured 2026-10-12). It is raised when the link still fits the same version (`boost_ecc`),
// which costs nothing. A printed code would want M back.
QR_ECC :: qr.Ecc.L

// THE BIGGEST CODE OFFERED WITHOUT A WARNING, and the point at which par is dropped to get under it. 25 is 117
// modules a side, and measured as the ceiling (2026-10-12): a phone camera read version 25 off the workbench
// screen, struggled with 26 and read 38 only with the window zoomed in and much patience. 48 boards without par
// come to ~960 characters: version 22 at L.
QR_READABLE_VERSION :: 25

Share_Qr :: struct {
	link:        string,
	code:        qr.Code, // empty (`size` 0) when even version 40 cannot hold the link
	boards:      int,
	has_par:     bool, // the page's boards carry par numbers, so there is a smaller link without them
	par_dropped: bool, // this is that smaller link: the one with par was over `QR_READABLE_VERSION`
	left_behind: bool, // solver figures the link cannot carry at all (as `share_link_for`)
}

// The QR code for `page`'s link. Par is dropped when the code with it would be over `QR_READABLE_VERSION`,
// unless `keep_par` (the panel's `keep par` button: a bigger code, the reader's choice). Everything is
// allocated with `allocator`.
share_qr_for :: proc(
	page, player: string,
	allocator := context.allocator,
	keep_par := false,
) -> (
	result: Share_Qr,
	ok: bool,
) {
	link, boards, left_behind := share_link_for(page, player, allocator) or_return
	bare, _, _, _ := share_link_for(page, player, allocator, with_par = false)
	result = {
		link        = link,
		boards      = boards,
		has_par     = bare != link,
		left_behind = left_behind,
	}
	options := qr.DEFAULT_OPTIONS
	options.ecc = QR_ECC
	code, fits := qr.encode_string(link, options, allocator)
	if keep_par || !result.has_par || (fits && code.version <= QR_READABLE_VERSION) {
		delete(bare, allocator)
		result.code = code if fits else {}
		return result, true
	}
	if fits {
		qr.destroy(code, allocator)
	}
	delete(link, allocator)
	result.link = bare
	result.par_dropped = true
	result.code, _ = qr.encode_string(result.link, options, allocator)
	return result, true
}

share_qr_destroy :: proc(result: Share_Qr, allocator := context.allocator) {
	delete(result.link, allocator)
	qr.destroy(result.code, allocator)
}

// The `QR` button: the panel, filled. Pressed again it closes (as `about` does). Each opening starts from the
// small code; `keep par` is a choice made for the code on screen.
show_share_qr :: proc(app: ^App, shown: bool) {
	if !shown || current_view(app) == .Qr {
		show_view(app, app.before_qr)
		return
	}
	app.qr_keep_par = false
	if !draw_share_qr(app) {
		return
	}
	app.before_qr = place_underneath(app)
	show_view(app, .Qr)
}

// The panel's `keep par` / `drop par`: the same boards, the other code.
toggle_qr_par :: proc(app: ^App) {
	app.qr_keep_par = !app.qr_keep_par
	draw_share_qr(app)
}

// Fill the panel from what the pane shows. False (with the reason in the status line) when there is no code.
@(private = "file")
draw_share_qr :: proc(app: ^App) -> bool {
	page, have_page := shown_page(app)
	if !have_page {
		return false
	}
	player, local, perr := player_address(app)
	if perr != "" {
		set_note(app, perr)
		return false
	}
	result, ok := share_qr_for(page, player, context.temp_allocator, keep_par = app.qr_keep_par)
	if !ok {
		set_note(app, "only a hand page can be shared - this one has no boards in it")
		return false
	}

	code := result.code
	if box := find(app, "#qr-code"); box != nil {
		sa.set_html(box, qr.svg(code, allocator = context.temp_allocator) if code.size > 0 else "")
	}
	facts := fmt.tprintf("%d board%s, %d characters", result.boards, "" if result.boards == 1 else "s", len(result.link))
	if code.size > 0 {
		facts = fmt.tprintf(
			"%s - version %d, %d modules a side, error correction %v",
			facts,
			code.version,
			code.size,
			code.ecc,
		)
	}
	set_text_at(app, "#qr-facts", facts)
	set_text_at(app, "#qr-link", result.link)

	// The par button: only for a set that HAS par, and only when it changes something - a code already
	// small enough with par has nothing to choose.
	set_shown(app, "#qr-par", result.par_dropped || (app.qr_keep_par && result.has_par))
	set_text_at(app, "#qr-par", "drop par (smaller code)" if app.qr_keep_par else "keep par (bigger code)")

	notes := make([dynamic]string, context.temp_allocator)
	switch {
	case code.size == 0:
		append(&notes, "Too many boards for any QR code: send the link instead, or share a page with fewer boards.")
	case code.version > QR_READABLE_VERSION:
		append(&notes, "A code this big is hard for a phone to read, from paper especially: a page with fewer boards makes a smaller one.")
	}
	if result.par_dropped {
		append(&notes, "Par is left out to keep the code small enough to scan: every board is there, without its par caption. `keep par` puts it back, in a bigger code.")
	}
	if result.left_behind {
		append(&notes, "The double-dummy figures a link cannot carry stay behind.")
	}
	if local {
		append(&notes, "A phone cannot open this: Settings' `player at` is not a web address, so the link points at the player in the deals folder, on this computer. Correct it, or empty it for the published player.")
	}
	set_text_at(app, "#qr-notes", strings.join(notes[:], " ", context.temp_allocator))
	set_shown(app, "#qr-notes", len(notes) > 0)
	if element := find(app, "#qr-notes"); element != nil {
		sa.set_attribute(element, "class", "about-line qr-warn" if local || code.size == 0 else "about-line")
	}
	return true
}

// The panel's `copy link`: the link it shows, which may be the one without par.
copy_qr_link :: proc(app: ^App) {
	element := find(app, "#qr-link")
	if element == nil {
		return
	}
	link, _ := sa.text(element, context.temp_allocator)
	if link == "" {
		return
	}
	if copy_text(app, link) {
		set_note(app, fmt.tprintf("link copied: %d characters", len(link)))
	} else {
		set_note(app, "the link could not be put on the clipboard")
	}
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
// it changes; a page written before keeps the address it was written with. An unusable setting writes none, and
// the page's button then links to the `player.html` beside it.
apply_share_player :: proc(app: ^App) {
	published, ok := published_player(app)
	if !ok {
		published = ""
	}
	if published == norn.share_player {
		return
	}
	if norn.share_player != "" && norn.share_player != share.PUBLISHED_PLAYER {
		delete(norn.share_player)
	}
	// Empty and the published address are literals, not allocations: a window left on the default holds nothing.
	switch published {
	case "", share.PUBLISHED_PLAYER:
		norn.share_player = published
	case:
		norn.share_player = strings.clone(published)
	}
}
