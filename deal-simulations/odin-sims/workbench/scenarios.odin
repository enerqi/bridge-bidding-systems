package main

/*
	scenarios.odin — the SCENARIO EDITOR: writing `.scenario` files, and finding out what they mean.

	THE OTHER HALF OF THE LANGUAGE. `scenario_dsl` gave this window the ability to READ scenarios from
	text — they load at startup and are indistinguishable from the compiled ones in the list, the filter,
	the groups and `--frequency`. What it did not give anybody is a way to WRITE one: the file was
	authored in some other editor, and the only way to find out whether it parsed was to restart this
	program and look at whether the list had grown. That is the gap this file closes.

	THE SHAPE IS THE NOTES EDITOR'S, on purpose (see `ui/workbench.html`): a bar, a folder of files on the
	left, the source in the middle, the answer on the right. It is the same activity — edit a text file,
	look at what it renders to, save it — so learning one is learning both, and the structural CSS is
	literally shared.

	WHAT `check` ANSWERS is the one thing that differs, and it is what a scenario has instead of a
	rendered page. Three questions, all of which a person staring at their own text cannot answer:

	  * WHAT DID THE PARSER UNDERSTAND? Answered by printing the tree back out (`scenario_dsl.write_program`),
	    so `hcp >= 8 and hcp <= 11` comes back as itself and the brackets appear where the PRECEDENCE put
	    them rather than where they were typed. A summary in prose would be a second description of the
	    language, free to drift from the first.
	  * WHAT IS WRONG WITH IT? The parser's own diagnostics, with a line and a column — listed in the
	    report AND squiggled on the text they are about, the same two-place treatment the BML editor gives
	    a mistyped directive.
	  * HOW OFTEN DOES IT HAPPEN? Measured, over sample deals. This is the question a constraint language
	    cannot help getting wrong: a condition that is one point too tight is not a parse error and not a
	    logic error, it is a generate run that never finishes. `--frequency` has always been able to answer
	    it from the command line; the point of having it HERE is that it answers for the BUFFER, before the
	    file is saved and before the registry is rebuilt.

	SAVING IS THE SEAM to the rest of the window. The registry is built at startup, so a file on disk means
	nothing to the deals view until it is built again — and that used to be a separate `reload` button,
	which read as "reload this file into the editor" and left people saving and then hunting the deals list
	for a scenario nothing had rebuilt. So `save`, `new…` and `folder…` rebuild it themselves
	(`update_deals_list`); the button survives as `rescan`, for files changed outside this window. Rebuilding
	never touches the editor's buffer, which was the worry that kept it manual.

	WHERE THE DEALS LIST READS FROM is drawn at the foot of the file list (`draw_scenario_sources`): every
	folder, where it was configured, and what it gave. This view edits ONE folder while the list can read
	several, and before that was on screen the others were invisible.
*/

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../bidding"
import "../prefs"
import "../scenario_dsl"
import "norn:norn"
import sa "sciter:sciter_app"

// The extension, and the one place this program spells it. `scenario_dsl` has its own copy for reading a
// directory; this one is for WRITING, which is a different decision (what a new file is called).
SCENARIO_EXT :: ".scenario"

/*
HOW MANY DEALS `check` SAMPLES, and why it is a fixed number rather than a setting.

It runs on the ENGINE THREAD, between a button press and a redraw, so it has a budget: this must feel
like pressing a button, not like starting a job. 20,000 deals is ~30ms of shuffling and summarising —
under a frame's worth of latency at 60Hz — and it resolves anything down to about one deal in a thousand,
which is the range where "is this too tight to generate?" is a live question. Below that the answer the
report gives is "not once in 20,000", which is the useful answer anyway: it does not matter whether the
true rate is 1 in 50,000 or 1 in 5,000,000, both of them mean the generate run will not finish.

Somebody who wants a real measurement has `--frequency`, on the command line, with a count of their own
and a thread per scenario. This is the cheap first look that stops them needing it.
*/
CHECK_TRIALS :: 20_000

// The sample's seed. FIXED, so pressing `check` twice on unchanged text gives the same number twice:
// a percentage that moved when nothing moved reads as an unstable condition rather than as noise.
CHECK_SEED :: u64(0x5CE7_A1_0D_5EED_0001)

// ---------------------------------------------------------------------------------------------------
// The view

/*
Open the scenario editor, loading the first file the first time.

Later visits leave the buffer alone — the text somebody was editing is the thing they came back to —
which is the notes editor's rule, and for the same reason.

A folder is NOT invented if none is configured. `load_user_scenarios` refuses to guess where a person
keeps their scenario files and so does this: the view opens empty with `folder…` in the bar, which is the
thing to press. What it will do is adopt a folder that IS configured (`BRIDGE_SCENARIOS`, or the
remembered pref), because that folder is already this program's answer to "where are the scenarios" and
opening a different one by default would be two answers to one question.
*/
show_scenario_editor :: proc(app: ^App) {
	show_view(app, .Scenarios)
	if app.scn_dir == "" {
		// WHERE YOU LEFT OFF, if it is still a source: a restart used to drop you in the first folder at
		// its first file, whatever you had been editing.
		configured := remembered_editing_dir(app)
		if configured == "" {
			configured = first_scenario_dir(app)
		}
		if configured != "" {
			adopt_scenario_dir(app, configured)
		}
	}
	draw_scenario_files(app)
	if app.scn_dir == "" {
		scenario_status(app, "choose a folder of .scenario files")
		return
	}
	if app.scn_open == "" && len(app.scn_names) > 0 {
		name := app.scn_names[0]
		// The remembered FILE only means something in the remembered folder.
		edited, _ := prefs.get(&app.prefs, SCENARIO_EDIT_DIR_PREF)
		if remembered, found := prefs.get(&app.prefs, SCENARIO_EDIT_FILE_PREF); found && same_dir(edited, app.scn_dir) {
			for candidate in app.scn_names {
				if candidate == remembered {
					name = candidate
					break
				}
			}
		}
		if ok, why := open_scenario_file(app, name); !ok {
			scenario_status(app, why)
		}
	}
	// The source pane takes the FOCUS, because the engine paints a caret only in a focused widget and a
	// pane with text in it and no caret reads as a viewer. Same lesson as `show_editor`.
	if text := find(app, "#scn-text"); text != nil {
		_ = sa.set_focus(text)
	}
}

// The folder and file the editor had open, remembered across a restart. Kept apart from `scenarios.dirs`,
// which is the list of SOURCES: what is being edited is a place in that list, not a member of it.
SCENARIO_EDIT_DIR_PREF :: "scenarios.editing.dir"
SCENARIO_EDIT_FILE_PREF :: "scenarios.editing.file"

// The remembered editing folder, if it is still one of the sources and still there; otherwise "". A folder
// that was forgotten, or removed from the environment, is not reopened behind the sources list's back.
remembered_editing_dir :: proc(app: ^App) -> string {
	remembered, found := prefs.get(&app.prefs, SCENARIO_EDIT_DIR_PREF)
	if !found || remembered == "" {
		return ""
	}
	for directory in app.scenario_dirs {
		if same_dir(directory, remembered) && os.is_dir(directory) {
			return directory
		}
	}
	return ""
}

// Set a pref and write the file. A test's App has no store and no path, so both are checked: setting a key
// on a nil map is a crash, not a no-op.
@(private = "file")
set_pref :: proc(app: ^App, key: string, value: string) {
	if app.prefs.values == nil {
		return
	}
	prefs.set(&app.prefs, key, value)
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
}

// The first configured scenario directory that is actually there, or "". `app.scenario_dirs` is what
// `load_user_scenarios` assembled from the environment and the prefs, in that order, so this adopts the
// same folder the deals list was built from rather than a second opinion about it.
first_scenario_dir :: proc(app: ^App) -> string {
	for directory in app.scenario_dirs {
		if directory != "" && os.is_dir(directory) {
			return directory
		}
	}
	return ""
}

// ---------------------------------------------------------------------------------------------------
// The folder, and its files

// The `.scenario` files in `dir`, by name, sorted. Names rather than paths, for the same reason the notes
// editor keeps names: the name is what a row shows, what `scn_open` remembers and what `save` rejoins
// with the folder — one directory, decided once.
list_scenario_files :: proc(dir: string, allocator := context.allocator) -> []string {
	if dir == "" {
		return nil
	}
	infos, err := os.read_directory_by_path(dir, 0, context.temp_allocator)
	if err != nil {
		return nil
	}
	names := make([dynamic]string, 0, len(infos), allocator)
	for info in infos {
		if info.type == .Directory {
			continue
		}
		if !strings.has_suffix(strings.to_lower(info.name, context.temp_allocator), SCENARIO_EXT) {
			continue
		}
		append(&names, strings.clone(info.name, allocator))
	}
	slice.sort(names[:])
	return names[:]
}

// The file list, and the folder above it. One row per file carrying its own NAME in `data-sfile` — a
// different attribute from the notes editor's `data-file` on purpose: both lists are `.row`s and the
// click handler tells them apart by which attribute they carry, so sharing one would route a scenario
// file into the BML editor.
draw_scenario_files :: proc(app: ^App) {
	draw_scenario_sources(app)
	folder := app.scn_dir if app.scn_dir != "" else "no folder chosen"
	// "files in", because the folders are listed just above and this line is the label for the second level.
	// With no folder there is no second level, and the heading would only repeat the list's own "no folder
	// chosen" — the window said it three times — so it is left empty.
	set_text_at(app, "#scn-dir", fmt.tprintf("files in %s", folder) if app.scn_dir != "" else "")
	set_shown(app, "#scn-dir", app.scn_dir != "")
	if head := find(app, "#scn-dir"); head != nil {
		sa.set_attribute(head, "title", folder)
	}

	list := find(app, "#scn-list")
	if list == nil {
		return
	}
	if len(app.scn_names) == 0 {
		sa.set_html(
			list,
			`<div class="empty">no .scenario files here</div>` if app.scn_dir != "" else `<div class="empty">no folder chosen</div>`,
		)
		return
	}
	modified := app.scn_open != "" && scenario_modified(app)
	b := strings.builder_make(context.temp_allocator)
	for name in app.scn_names {
		escaped := escape_html(name, context.temp_allocator)
		classes := "row"
		if name == app.scn_open {
			classes = "row sel dirty" if modified else "row sel"
		}
		fmt.sbprintf(&b, `<div class="%s" data-sfile="%s">%s</div>`, classes, escaped, escaped)
	}
	sa.set_html(list, strings.to_string(b))
}

/*
The native folder dialog, and the only route to one: file and folder dialogs have no host API in this
engine — `Window.this` in the document's own runtime is the only object that reaches them. So the host
asks the document to ask the engine, exactly as `choose_bml_folder` does.

This BLOCKS in native modal code, so nothing tests it. What is testable is everything after it, which is
why `use_scenario_dir` is a procedure of its own.
*/
choose_scenario_folder :: proc(app: ^App) {
	script := `(function () {
		var picked = Window.this.selectFolder({ caption: "Choose the folder your .scenario files are in" });
		return picked ? String(picked) : "";
	})()`
	result, err := sa.eval(app.window, script)
	defer sa.value_clear(&result)
	if err != nil {
		scenario_status(app, "this build cannot open a folder dialog")
		log.warnf("selectFolder did not run: %v", err)
		return
	}
	url, serr := sa.value_to_string(&result, context.temp_allocator)
	if serr != nil || url == "" {
		return // cancelled
	}
	path, ok := file_url_to_path(url, context.temp_allocator)
	if !ok {
		scenario_status(app, fmt.tprintf("could not read that folder's path (%s)", url))
		return
	}
	use_scenario_dir(app, path)
}

/*
Point the editor at a folder, AND REMEMBER IT — which is the part that makes this button do two jobs.

The pref it writes (`scenarios.dirs`) is the one `load_user_scenarios` reads at startup, so choosing a
folder here is also how somebody tells this program where their scenarios live. Before this there was no
UI for that at all: the pref was read and nothing ever set it, so the only way in was an environment
variable, which is a thing to name at a developer and not at somebody holding a mouse.

WHAT IT WRITES IS THE WHOLE LIST, with the chosen folder first and the previously remembered ones after
it, deduplicated. Not just the one folder: a person can have several (their own, a partner's, a set
checked into a repository) and choosing one to EDIT is not saying to forget the others. Folders that came
from the ENVIRONMENT are not written down — `BRIDGE_SCENARIOS` is that shell's business and copying it
into a preferences file would make it outlive the shell that set it.
*/
use_scenario_dir :: proc(app: ^App, path: string) {
	adopt_scenario_dir(app, path)
	remember_scenario_dir(app, path)
	draw_scenario_files(app)

	if len(app.scn_names) == 0 {
		scenario_status(app, fmt.tprintf("no .scenario files in %s — press new… to write one", path))
		return
	}
	if ok, why := open_scenario_file(app, app.scn_names[0]); !ok {
		scenario_status(app, why)
		return
	}
	// A NEW FOLDER IS A NEW SOURCE for the deals list, so it is read now rather than at the next start.
	scenario_status(app, fmt.tprintf("%s · %s", app.scn_open, update_deals_list(app)))
}

/*
A row in the SOURCES list was clicked: edit that folder's files.

The pref is NOT rewritten — the folder is already a source, and its place in the list is its shadowing
order (a later folder's scenario of the same name loses), which a click to look at it must not change.
Unsaved text gets the same two-step guard leaving a file does: the first click is refused and says so.
*/
switch_scenario_dir :: proc(app: ^App, dir: string) {
	if dir == "" || same_dir(dir, app.scn_dir) {
		return
	}
	if app.scn_open != "" && scenario_modified(app) && !app.scn_armed {
		app.scn_armed = true
		scenario_status(
			app,
			fmt.tprintf("%s has unsaved changes — save, or click again to discard them", app.scn_open),
		)
		draw_scenario_files(app)
		return
	}
	adopt_scenario_dir(app, dir)
	draw_scenario_files(app)
	if len(app.scn_names) == 0 {
		scenario_status(app, fmt.tprintf("no .scenario files in %s", dir))
		return
	}
	if ok, why := open_scenario_file(app, app.scn_names[0]); !ok {
		scenario_status(app, why)
	}
}

// Two spellings of one folder. Windows paths arrive with either slash and either case (the dialog, the
// environment and `filepath.join` do not agree), and a folder counted twice is a scenario loaded twice.
same_dir :: proc(a, b: string) -> bool {
	return dir_key(a) == dir_key(b)
}

@(private = "file")
dir_key :: proc(path: string) -> string {
	key, _ := strings.replace_all(strings.to_lower(path, context.temp_allocator), "\\", "/", context.temp_allocator)
	return strings.trim_right(key, "/")
}

/*
THE SOURCES: every folder the deals list reads `.scenario` files from, drawn under the file list.

One row per folder, in load order (which is shadowing order), with where it was configured and what it
gave — scenarios, and problems if any. The folder this view is editing is marked. Counted from what was
LOADED rather than by listing the folders again, so the numbers are the deals list's own and a file that
did not parse shows up as a problem rather than as a silently missing scenario.
*/
draw_scenario_sources :: proc(app: ^App) {
	box := find(app, "#scn-sources")
	if box == nil {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<div class="head">folders · the deals list reads all of these</div>`)
	if len(app.scenario_dirs) == 0 {
		strings.write_string(&b, `<div class="empty">no folders yet — folder… adds one</div>`)
		sa.set_html(box, strings.to_string(b))
		return
	}

	for dir in app.scenario_dirs {
		from_env := dir_from_env(dir)
		origin := "BRIDGE_SCENARIOS" if from_env else "remembered"
		count := 0
		for program in app.loaded.programs {
			if same_dir(parent_dir(program.source), dir) {
				count += 1
			}
		}
		problems := 0
		for diagnostic in app.loaded.diagnostics {
			if same_dir(parent_dir(diagnostic.pos.file), dir) {
				problems += 1
			}
		}
		what := "not found" if !os.is_dir(dir) else fmt.tprintf("%d scenario%s", count, plural(count))
		if problems > 0 {
			what = fmt.tprintf("%s · %d problem%s", what, problems, plural(problems))
		}
		escaped := escape_html(dir, context.temp_allocator)
		// The `×` only where forgetting means something: a remembered folder. Its own attribute, checked
		// before the row's, so a click on it does not also open the folder it is removing.
		forget := "" if from_env else fmt.tprintf(`<span class="forget" data-forget="%s" title="Forget this folder">×</span>`, escaped)
		fmt.sbprintf(
			&b,
			`<div class="row%s" data-sdir="%s" title="%s"><span class="path">%s</span><div class="what"><span class="lbl">%s · %s</span>%s</div></div>`,
			" sel" if same_dir(dir, app.scn_dir) else "",
			escaped,
			escaped,
			escaped,
			origin,
			what,
			forget,
		)
	}
	sa.set_html(box, strings.to_string(b))
}

@(private = "file")
parent_dir :: proc(path: string) -> string {
	context.allocator = context.temp_allocator
	return filepath.dir(path)
}

// Everything about pointing at a folder EXCEPT remembering it and opening a file: the state, and dropping
// what belonged to the folder being left. Separate because `show_scenario_editor` adopts an
// already-configured folder, which must not rewrite the pref it came from.
adopt_scenario_dir :: proc(app: ^App, path: string) {
	names := list_scenario_files(path, app.allocator)

	for name in app.scn_names {
		delete(name, app.allocator)
	}
	delete(app.scn_names, app.allocator)
	delete(app.scn_dir, app.allocator)
	delete(app.scn_open, app.allocator)

	app.scn_dir = strings.clone(path, app.allocator)
	app.scn_names = names
	app.scn_open = ""
	app.scn_armed = false
	set_scenario_source(app, "")
	clear_scenario_problems(app)
	set_scenario_report(app, "")
}

// Write the folder list back to the prefs, chosen-folder first. A test's App has no store and no path, so
// both are checked: setting a key on a nil map is a crash, not a no-op.
remember_scenario_dir :: proc(app: ^App, path: string) {
	if app.prefs.values == nil {
		return
	}
	joined := strings.builder_make(0, 128, context.temp_allocator)
	strings.write_string(&joined, path)
	if remembered, found := prefs.get(&app.prefs, SCENARIO_DIRS_PREF); found {
		for part in strings.split(remembered, ";", context.temp_allocator) {
			trimmed := strings.trim_space(part)
			if trimmed == "" || trimmed == path {
				continue
			}
			strings.write_byte(&joined, ';')
			strings.write_string(&joined, trimmed)
		}
	}
	set_pref(app, SCENARIO_DIRS_PREF, strings.to_string(joined))
}

/*
Take a folder OUT of the sources: the `×` on a remembered row.

Without this the remembered list only grows — every `folder…` adds one, nothing removes one, and a folder
that was a one-off test stays a source of scenarios forever. Only REMEMBERED folders can be forgotten: one
from `BRIDGE_SCENARIOS` belongs to the shell that set it, so the row has no `×` and this refuses.

Unsaved text in the folder being forgotten is refused outright rather than armed: forgetting is not a
click you meant to repeat, and the text would go with the folder.
*/
forget_scenario_dir :: proc(app: ^App, dir: string) -> (ok: bool, why: string) {
	if dir_from_env(dir) {
		return false, "that folder comes from BRIDGE_SCENARIOS — change it there"
	}
	editing := same_dir(dir, app.scn_dir)
	if editing && app.scn_open != "" && scenario_modified(app) {
		return false, fmt.tprintf("%s has unsaved changes — save or discard them first", app.scn_open)
	}

	kept := strings.builder_make(0, 128, context.temp_allocator)
	if remembered, found := prefs.get(&app.prefs, SCENARIO_DIRS_PREF); found {
		for part in strings.split(remembered, ";", context.temp_allocator) {
			trimmed := strings.trim_space(part)
			if trimmed == "" || same_dir(trimmed, dir) {
				continue
			}
			if strings.builder_len(kept) > 0 {
				strings.write_byte(&kept, ';')
			}
			strings.write_string(&kept, trimmed)
		}
	}
	set_pref(app, SCENARIO_DIRS_PREF, strings.to_string(kept))
	shown := strings.clone(dir, context.temp_allocator) // `dir` may be a row of the list about to be rebuilt
	deals := update_deals_list(app)

	// The editor moves to the next source, or to nothing — never stays in a folder that is not a source.
	if editing {
		next := first_scenario_dir(app)
		adopt_scenario_dir(app, next)
		if next != "" && len(app.scn_names) > 0 {
			_, _ = open_scenario_file(app, app.scn_names[0])
		}
	}
	draw_scenario_files(app)
	return true, fmt.tprintf("forgot %s · %s", shown, deals)
}

// Is `dir` one of the folders `BRIDGE_SCENARIOS` names?
dir_from_env :: proc(dir: string) -> bool {
	for part in strings.split(os.get_env("BRIDGE_SCENARIOS", context.temp_allocator), ";", context.temp_allocator) {
		trimmed := strings.trim_space(part)
		if trimmed != "" && same_dir(trimmed, dir) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------------
// One file

// Load a file into the editor. The line endings it arrived with are remembered, so saving a one-word
// change does not rewrite every line of a CRLF file — the same care `open_bml` takes and for the same
// reason.
open_scenario_file :: proc(app: ^App, name: string) -> (ok: bool, why: string) {
	path, jerr := filepath.join({app.scn_dir, name}, context.temp_allocator)
	if jerr != nil {
		return false, fmt.tprintf("could not resolve %s", name)
	}
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		return false, fmt.tprintf("could not read %s: %v", name, rerr)
	}
	source := string(data)

	delete(app.scn_open, app.allocator)
	app.scn_open = strings.clone(name, app.allocator)
	set_pref(app, SCENARIO_EDIT_DIR_PREF, app.scn_dir)
	set_pref(app, SCENARIO_EDIT_FILE_PREF, name)
	app.scn_crlf = strings.contains(source, "\r\n")
	app.scn_armed = false

	text := source
	if app.scn_crlf {
		text, _ = strings.replace_all(source, "\r\n", "\n", context.temp_allocator)
	}
	// No trailing blank line: a trailing newline becomes a line the plaintext then reports at the FRONT of
	// its content (measured — see `draw_transcript`), which would come back on save as a blank first line.
	set_scenario_source(app, strings.trim_right(text, "\n"))
	colorize_scenario(app)
	// The buffer is not the text the last check saw, so nothing that was marked still applies.
	clear_scenario_problems(app)
	set_scenario_report(app, "")
	draw_scenario_files(app)
	scenario_status(app, name)
	return true, ""
}

// Write the buffer back to the file it came from. The one destructive thing in this view, so it says what
// it wrote — and it restores the file's own line endings and its single trailing newline rather than
// imposing the widget's.
save_scenario_file :: proc(app: ^App) -> (ok: bool, why: string) {
	if app.scn_open == "" {
		return false, "nothing is open"
	}
	text, got := scenario_source(app, context.temp_allocator)
	if !got {
		return false, "the editor's text could not be read"
	}
	body := strings.concatenate({strings.trim_right(text, "\n"), "\n"}, context.temp_allocator)
	if app.scn_crlf {
		body, _ = strings.replace_all(body, "\n", "\r\n", context.temp_allocator)
	}
	path, jerr := filepath.join({app.scn_dir, app.scn_open}, context.temp_allocator)
	if jerr != nil {
		return false, fmt.tprintf("could not resolve %s", app.scn_open)
	}
	if werr := os.write_entire_file(path, transmute([]u8)body); werr != nil {
		return false, fmt.tprintf("could not write %s: %v", app.scn_open, werr)
	}
	app.scn_armed = false
	draw_scenario_files(app) // the dirty dot goes
	// SAVING PUTS IT IN THE DEALS LIST. It used to stop at the file and say "press reload", which was how
	// somebody generated the previous version of a scenario, or looked for a new one that was not there.
	return true, fmt.tprintf("saved %s · %s", app.scn_open, update_deals_list(app))
}

/*
Rebuild the deals list from the scenario folders, and say what happened in a few words for the status line.

The one call `save`, `new…` and `folder…` share. A rebuild is REFUSED while a generate run is in progress
(see `reload_scenarios`), and that is the one outcome somebody has to act on, so it says what to press.
*/
update_deals_list :: proc(app: ^App) -> string {
	ok, why := reload_scenarios(app)
	if !ok {
		return "the deals list is unchanged while a run is in progress — press rescan when it has finished"
	}
	return why
}

/*
A file was clicked. Loading it is the obvious thing and it is what happens — except over UNSAVED text,
which would go without a trace and with nothing to undo it from.

The guard is a two-step rather than a dialog, the notes editor's shape exactly: the first attempt to
leave an edited buffer is REFUSED and the bar says what to do; the next one goes through and discards.
No modal, no third button, and the list never lies about which file is open in the meantime because the
marking comes from `scn_open` and that is what has not changed.
*/
switch_scenario_file :: proc(app: ^App, name: string) {
	if name == "" || name == app.scn_open {
		return
	}
	if app.scn_open != "" && scenario_modified(app) && !app.scn_armed {
		app.scn_armed = true
		scenario_status(
			app,
			fmt.tprintf("%s has unsaved changes — save, or click again to discard them", app.scn_open),
		)
		draw_scenario_files(app)
		return
	}
	if ok, why := open_scenario_file(app, name); !ok {
		scenario_status(app, why)
	}
}

/*
`new…` — the save dialog, then the file.

A DIALOG rather than a name typed into the bar, because the thing being chosen is a PATH: which folder,
what name, and this engine already has the native chooser that answers both. It blocks in modal code, so
the testable half is `create_scenario_file`.
*/
new_scenario_file :: proc(app: ^App) {
	script := `(function () {
		var picked = Window.this.selectFile({
			mode: "save",
			caption: "New scenario file",
			filter: "Scenario files (*.scenario)|*.scenario",
			extension: "scenario"
		});
		return picked ? String(picked) : "";
	})()`
	result, err := sa.eval(app.window, script)
	defer sa.value_clear(&result)
	if err != nil {
		scenario_status(app, "this build cannot open a file dialog")
		log.warnf("selectFile did not run: %v", err)
		return
	}
	url, serr := sa.value_to_string(&result, context.temp_allocator)
	if serr != nil || url == "" {
		return // cancelled
	}
	path, ok := file_url_to_path(url, context.temp_allocator)
	if !ok {
		scenario_status(app, fmt.tprintf("could not read that path (%s)", url))
		return
	}
	written, why := create_scenario_file(app, path)
	scenario_status(app, why)
	if !written {
		log.warnf("the new scenario file was not created: %s", why)
	}
}

/*
Create a scenario file at `path` and open it.

IT STARTS AS A WORKING SCENARIO, not an empty buffer and not a wall of commented-out syntax: the grammar
is in a comment above a scenario that parses, generates and is entirely made of things to edit. An empty
file would be correct and useless — the first question a new user has is not "what do I type" but "what
CAN I type", and the answer belongs where they are about to type it.

The scenario's name comes from the FILENAME, because that is the one name the person has already chosen,
and a file called `strong-club.scenario` holding a scenario called `untitled` is a trap for later.

AN EXISTING FILE IS NOT OVERWRITTEN. The save dialog has already asked about replacing it, but what it
asked about is replacing a FILE — and what would be lost here is somebody's scenario, so this refuses and
opens it instead. Nothing is lost by being asked to delete it yourself first.

A path in ANOTHER folder is honoured and the editor MOVES to that folder: the dialog let them go there,
so refusing afterwards would be the program disagreeing with its own file chooser.
*/
create_scenario_file :: proc(app: ^App, path: string) -> (ok: bool, why: string) {
	full := path
	if !strings.has_suffix(strings.to_lower(full, context.temp_allocator), SCENARIO_EXT) {
		full = strings.concatenate({full, SCENARIO_EXT}, context.temp_allocator)
	}
	// `filepath.dir` has no allocator parameter and takes the context's, so the context is redirected at
	// scratch for the one call — the same care `bml_docs_dir` takes, and for the same reason.
	directory: string
	{
		context.allocator = context.temp_allocator
		directory = filepath.dir(full)
	}
	name := filepath.base(full)
	if directory == "" || name == "" {
		return false, fmt.tprintf("could not read a folder and a name out of %s", path)
	}

	if os.exists(full) {
		if directory != app.scn_dir {
			use_scenario_dir(app, directory)
		}
		if opened, message := open_scenario_file(app, name); !opened {
			return false, message
		}
		return false, fmt.tprintf("%s already exists — opened it instead", name)
	}

	stem := name[:len(name) - len(SCENARIO_EXT)]
	body := fmt.tprintf(NEW_SCENARIO_TEMPLATE, stem)
	if werr := os.write_entire_file(full, transmute([]u8)body); werr != nil {
		return false, fmt.tprintf("could not write %s: %v", full, werr)
	}
	created := strings.clone(name, context.temp_allocator)

	// Re-list the folder rather than appending the name to the list in memory: the folder is the truth
	// about what is in it, and this is the moment it changed.
	if directory != app.scn_dir {
		adopt_scenario_dir(app, directory)
		remember_scenario_dir(app, directory)
	} else {
		relist_scenario_files(app)
	}
	draw_scenario_files(app)
	if opened, message := open_scenario_file(app, name); !opened {
		return false, message
	}
	check_scenario(app) // it parses, and saying so is the point of a template that does
	return true, fmt.tprintf("created %s · %s", created, update_deals_list(app))
}

// Read the folder again, keeping whatever is open. What `create_scenario_file` needs and what a folder
// that changed underneath the window would need; `adopt_scenario_dir` is the heavier version that also
// drops the buffer.
relist_scenario_files :: proc(app: ^App) {
	names := list_scenario_files(app.scn_dir, app.allocator)
	for name in app.scn_names {
		delete(name, app.allocator)
	}
	delete(app.scn_names, app.allocator)
	app.scn_names = names
}

/*
A NEW FILE'S CONTENTS.

A working scenario with the grammar above it. The named helpers are deliberately absent from the scenario
itself — `words` lists them and they belong to this bidding system, whereas `hcp`, `balanced` and a suit
length are true in every system, so a template that opened with `is_2cd_swedish_club_resp` would be
teaching somebody else's notes. `%s` is the scenario's name, taken from the filename.
*/
NEW_SCENARIO_TEMPLATE :: `# A scenario is a name, a description, and one line per seat.
# The seat lines AND together. Within a line: and, or, not, and parentheses.
#
#   quantities   hcp  controls  spades  hearts  diamonds  clubs  longest
#   comparisons  <  <=  =  !=  >=  >        or a range:  hcp in 15..17
#   other atoms  balanced   holds(spades, ace)
#   names        this system's own helpers - press words in the bar to list them
#
# north-south: and east-west: lines read BOTH hands of a side together:
#   north-south: hcp >= 32 and (spades >= 8 or hearts >= 8)
#
# Press check to parse this and measure how often it happens. save writes the file;
# reload then makes it a scenario in the deals list.

scenario %s "say what this auction is, in a few words"
  tags: mine
  north: hcp in 15..17 and balanced
  south: hearts >= 5 and hcp in 8..11
`

// ---------------------------------------------------------------------------------------------------
// The buffer, the colours and the squiggles
//
// The same three seams the BML editor has, against the same document-side functions — which now take the
// editor's selector, because there are two editors and they run different rules.

/*
The buffer, as text.

LINE BY LINE, over the `<text>` children, and NOT through `content=` — which is the same measured trap
`bml_source` documents: reading the widget's whole content back gives the LAST TWO LINES JOINED, and no
amount of splitting recovers them. Saving through that would silently glue the end of somebody's file
together.
*/
scenario_source :: proc(app: ^App, allocator := context.allocator) -> (text: string, ok: bool) {
	element := find(app, "#scn-text")
	if element == nil {
		return "", false
	}
	b := strings.builder_make(allocator)
	for n := 0;; n += 1 {
		child, cerr := sa.child(element, sa.Child_Index(n))
		if cerr != nil || child == nil {
			break
		}
		if n > 0 {
			strings.write_byte(&b, '\n')
		}
		line, terr := sa.text(child, context.temp_allocator)
		if terr == nil {
			strings.write_string(&b, line)
		}
	}
	return strings.to_string(b), true
}

set_scenario_source :: proc(app: ^App, text: string) {
	element := find(app, "#scn-text")
	if element == nil {
		return
	}
	if asset, err := sa.element_asset(element, "plaintext"); err == nil {
		value := sa.value_from(text)
		defer sa.value_clear(&value)
		if sa.asset_set(asset, "content", &value) == nil {
			return
		}
	}
	sa.set_text(element, text)
}

// Has the buffer been edited since it was loaded or saved? The widget's own flag, so nothing here keeps a
// shadow copy of the text to compare against.
scenario_modified :: proc(app: ^App) -> bool {
	element := find(app, "#scn-text")
	if element == nil {
		return false
	}
	asset, aerr := sa.element_asset(element, "plaintext")
	if aerr != nil {
		return false
	}
	value, gerr := sa.asset_get(asset, "isModified")
	if gerr != nil {
		return false
	}
	defer sa.value_clear(&value)
	modified, berr := sa.value_to_bool(&value)
	return berr == nil && modified
}

// Colour the buffer, and hand back how many marks landed — the only thing this side can see of the
// result, since a mark leaves no attribute behind. Zero from a buffer with text in it means the script
// did not run.
colorize_scenario :: proc(app: ^App) -> int {
	result, err := sa.eval(app.window, "scnColorize()")
	defer sa.value_clear(&result)
	if err != nil {
		log.warnf("the scenario colorizer did not run: %v", err)
		return 0
	}
	marks, ierr := sa.value_to_int(&result)
	return ierr == nil ? int(marks) : 0
}

/*
Squiggle the parse's diagnostics on the text they are about, and say how many marks landed.

The json goes over as a STRING ARGUMENT rather than spliced into the script as a literal, for the reason
`show_bml_problems` records: a message quoting the source would otherwise need escaping twice, once as
json and once as a script literal, and the second is the one everybody forgets.

`scenario_dsl.Diagnostic` has a position and no LENGTH, so every one of these is sent with `len: 0` —
the script's convention for "to the end of the line", which is the honest extent for a diagnostic that
knows where a thing started and not where it stopped.
*/
show_scenario_problems :: proc(app: ^App, diagnostics: []scenario_dsl.Diagnostic) -> int {
	payload := strings.builder_make(0, 256, context.temp_allocator)
	strings.write_byte(&payload, '[')
	first := true
	for diagnostic in diagnostics {
		if diagnostic.pos.line <= 0 {
			continue // a whole-file problem (a file that could not be read) has no line to mark
		}
		if !first {
			strings.write_byte(&payload, ',')
		}
		first = false
		strings.write_string(&payload, `{"line":`)
		strings.write_int(&payload, diagnostic.pos.line)
		strings.write_string(&payload, `,"col":`)
		strings.write_int(&payload, diagnostic.pos.col)
		strings.write_string(&payload, `,"len":0,"severity":"error","message":`)
		write_json_string(&payload, diagnostic.message)
		strings.write_byte(&payload, '}')
	}
	strings.write_byte(&payload, ']')

	script := strings.concatenate(
		{"bmlSetProblems(", json_string(strings.to_string(payload), context.temp_allocator), `, "#scn-text")`},
		context.temp_allocator,
	)
	result, err := sa.eval(app.window, script)
	defer sa.value_clear(&result)
	if err != nil {
		log.warnf("the scenario diagnostics were not marked: %v", err)
		return 0
	}
	marks, ierr := sa.value_to_int(&result)
	return ierr == nil ? int(marks) : 0
}

clear_scenario_problems :: proc(app: ^App) {
	result, err := sa.eval(app.window, `bmlClearProblems("#scn-text")`)
	sa.value_clear(&result)
	if err != nil {
		log.warnf("the scenario diagnostics were not cleared: %v", err)
	}
}

// The editor's own status line, in its own bar — separate from the notes editor's and from the deals
// view's, because the three views are never on screen together and a message about one has no business
// in another.
scenario_status :: proc(app: ^App, text: string) {
	set_text_at(app, "#scn-status", text)
}

// The right-hand pane. A `<plaintext>` like the transcript, so it takes text and not markup.
set_scenario_report :: proc(app: ^App, text: string) {
	element := find(app, "#scn-report")
	if element == nil {
		return
	}
	if asset, err := sa.element_asset(element, "plaintext"); err == nil {
		value := sa.value_from(text)
		defer sa.value_clear(&value)
		if sa.asset_set(asset, "content", &value) == nil {
			return
		}
	}
	sa.set_text(element, text)
}

// ---------------------------------------------------------------------------------------------------
// check — what the text means, and how often it happens

/*
Parse the BUFFER, mark what is wrong with it, and report what it says and how often it happens.

THE BUFFER AND NOT THE FILE, which is the same bargain the BML preview makes: what is checked is what is
on screen, so the answer arrives before the save rather than after it. `scenario_dsl.parse` takes source
TEXT for exactly this reason.

THE VOCABULARY IS RE-INSTALLED FIRST. Names resolve at PARSE time against whatever table is installed, and
this is the only entry point in the program that parses after startup — so it makes sure the table is
this bidding system's rather than assuming nothing has touched it since `load_user_scenarios`.

EVERY PROGRAM IS FREED before returning: a check is a measurement and owns nothing afterwards. The
programs the REGISTRY points at are `app.loaded`'s, built by `reload_scenarios`, and are untouched by
this — which is why pressing `check` cannot change what generate would run.
*/
check_scenario :: proc(app: ^App) {
	text, got := scenario_source(app, context.temp_allocator)
	if !got {
		scenario_status(app, "the editor's text could not be read")
		return
	}
	scenario_dsl.set_vocabulary(bidding.vocabulary)

	file := app.scn_open if app.scn_open != "" else "the editor"
	programs, diagnostics := scenario_dsl.parse(text, file, context.temp_allocator)
	defer {
		for &program in programs {
			scenario_dsl.destroy_program(&program)
		}
	}

	marked := show_scenario_problems(app, diagnostics)
	set_scenario_report(app, check_report(app, programs, diagnostics, context.temp_allocator))

	switch {
	case len(diagnostics) > 0 && len(programs) > 0:
		scenario_status(
			app,
			fmt.tprintf(
				"%d scenario%s · %d problem%s",
				len(programs),
				plural(len(programs)),
				len(diagnostics),
				plural(len(diagnostics)),
			),
		)
	case len(diagnostics) > 0:
		scenario_status(
			app,
			fmt.tprintf("%d problem%s — nothing parsed", len(diagnostics), plural(len(diagnostics))),
		)
	case len(programs) == 0:
		scenario_status(app, "no scenarios in this file")
	case:
		scenario_status(app, fmt.tprintf("%d scenario%s, no problems", len(programs), plural(len(programs))))
	}
	_ = marked
}

@(private = "file")
plural :: proc(n: int) -> string {
	return "" if n == 1 else "s"
}

/*
The report `check` writes: every scenario the parse understood, spelled back canonically and measured,
then everything that was wrong with the file.

THE CANONICAL SPELLING IS THE POINT of printing the tree rather than echoing the source. What comes back
is what the parser UNDERSTOOD — the brackets where precedence put them, a range where two comparisons
were written — so an expression that reads one way and parses another says so here instead of surprising
somebody a thousand deals later.
*/
check_report :: proc(
	app: ^App,
	programs: []scenario_dsl.Program,
	diagnostics: []scenario_dsl.Diagnostic,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(0, 1024, allocator)

	if len(programs) == 0 && len(diagnostics) == 0 {
		strings.write_string(&b, "nothing to check — this file holds no scenarios yet.\n")
		return strings.to_string(b)
	}

	for &program, i in programs {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		scenario_dsl.write_program_into(&b, &program)
		write_frequency(&b, &program)
	}

	if len(diagnostics) > 0 {
		if len(programs) > 0 {
			strings.write_byte(&b, '\n')
		}
		fmt.sbprintf(&b, "%d problem%s\n", len(diagnostics), plural(len(diagnostics)))
		for diagnostic in diagnostics {
			strings.write_string(&b, "  ")
			strings.write_string(&b, scenario_dsl.diagnostic_text(diagnostic, context.temp_allocator))
			strings.write_byte(&b, '\n')
		}
	}

	// The name clash is a REPORT rather than a refusal, because it is not an error: `cli.lookup` takes the
	// first exact match and the compiled registry comes first, so a file may define `1c-any` all it likes
	// and the compiled one is what generates. Silently is the wrong way for that to be true.
	for &program in programs {
		if shadowed_by_compiled(app, program.name) {
			fmt.sbprintf(
				&b,
				"\nnote: `%s` is also a compiled scenario, and the compiled one wins — rename this to reach it.\n",
				program.name,
			)
		}
	}
	return strings.to_string(b)
}

// Measure one scenario over `CHECK_TRIALS` deals and say what came back, in the terms the question is
// actually asked in: a percentage is unreadable at these rates, so the useful form is "one deal in N".
write_frequency :: proc(b: ^strings.Builder, program: ^scenario_dsl.Program) {
	condition := norn.Condition(norn.Interpreted_Predicate{scenario_dsl.evaluate, program})
	hits := norn.count_accepted_seeded(CHECK_TRIALS, condition, CHECK_SEED)
	switch {
	case hits == 0:
		fmt.sbprintf(b, "  happens: not once in %d deals — too tight to generate as it stands\n", CHECK_TRIALS)
	case:
		fmt.sbprintf(
			b,
			"  happens: %d in %d deals (%.2f%%) — about 1 deal in %d\n",
			hits,
			CHECK_TRIALS,
			100.0 * f64(hits) / f64(CHECK_TRIALS),
			CHECK_TRIALS / hits,
		)
	}
}

// Is there a COMPILED scenario of this name? `cli.lookup` takes the first exact match and the compiled
// registry is concatenated first, so a compiled name shadows a file's — see `load_user_scenarios`.
shadowed_by_compiled :: proc(app: ^App, name: string) -> bool {
	for scenario in bidding.registry {
		if scenario.name == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------------
// words — the vocabulary, and the grammar

/*
Everything a `.scenario` file may say, in the report pane.

WHY THIS EXISTS AT ALL: the generic half of the language is small enough to put in a template comment,
and the NAMED half is 58 entries that live in `bidding/vocabulary.odin` and are invisible from inside the
editor. Without this the only way to find out what may be written is to read the source of the program
you are running, which is a fine answer for its author and no answer for anybody else.

It reads the table `scenario_dsl` was given rather than `bidding.vocabulary` directly, because what a
file may name is whatever was INSTALLED — and if those two ever differ, the one that decides is the
installed one.
*/
scenario_words :: proc(app: ^App) {
	b := strings.builder_make(0, 4096, context.temp_allocator)
	strings.write_string(
		&b,
		`A scenario file holds one or more scenarios:

    scenario <name> "<description>"
      tags: <name>, <name>          groups it appears in, in the picker
      <seat>: <condition>           north / east / south / west
      <side>: <condition>           north-south / east-west

The lines AND together. Within a condition:

    and  or  not  ( )              the operators, loosest to tightest
    hcp  controls  longest         numbers off the hand
    spades  hearts  diamonds  clubs
    <  <=  =  !=  >=  >            comparisons     hcp >= 15
    in <low>..<high>               a range         hcp in 15..17
    balanced                       norn's own definition
    holds(<suit>, <rank>)          holds(spades, ace)
    # anything after a hash        a comment

On a <side> line every number is the two hands COMBINED: hcp and controls
are the side's total, a suit is the side's length (spades >= 8 is a fit),
longest is the side's longest combined suit, and holds(...) means either
hand. balanced and the named helpers describe one hand, so they belong on
a seat line.

    north-south: hcp >= 32 and (spades >= 8 or hearts >= 8)

`,
	)

	vocabulary := scenario_dsl.vocabulary()
	if len(vocabulary) == 0 {
		strings.write_string(&b, "No named helpers are installed in this build.\n")
		set_scenario_report(app, strings.to_string(b))
		return
	}

	fmt.sbprintf(
		&b,
		"And %d named helpers from this bidding system — the half a form of ranges cannot express.\nEach one takes ONE seat, so it is written as a whole seat's condition or as part of one:\n\n",
		len(vocabulary),
	)
	for entry in vocabulary {
		strings.write_string(&b, "    ")
		strings.write_string(&b, entry.name)
		if entry.description != "" {
			strings.write_string(&b, "   ")
			strings.write_string(&b, entry.description)
		}
		strings.write_byte(&b, '\n')
	}
	set_scenario_report(app, strings.to_string(b))
	scenario_status(app, fmt.tprintf("%d named helpers", len(vocabulary)))
}

// ---------------------------------------------------------------------------------------------------
// reload — the seam between a saved file and the deals list

/*
Read every configured scenario folder again and rebuild the registry, the groups and the list from it.

THIS IS THE ONLY PLACE THE REGISTRY IS REBUILT after startup, and everything that points into it has to
be rebuilt with it — which is what makes this more than a call to `load_user_scenarios`:

  * REFUSED WHILE A JOB IS RUNNING. The worker thread reads `app.scenarios` (see `work_generate`), and
    the interpreted conditions in it point at programs this frees. Freeing them mid-run is a crash, and
    a crash that would happen on somebody else's schedule.
  * THE SELECTION IS RESTORED BY NAME, not by index. A file gaining or losing a scenario moves every
    index after it, so an index kept across a reload silently means a different auction. A name that has
    gone falls back to the top of the list rather than to a stale row.
  * THE GROUPS AND THEIR FLAGS GO TOGETHER. `build_groups` rebuilds both, and the picker's flags are
    positional, so a stale `tag_on` would filter by a group that no longer exists.
  * THE FILTER SURVIVES. Whatever is typed in the filter box still applies afterwards, because it is a
    projection of the list rather than a state of the registry — `filter_scenarios` is the redraw.
*/
reload_scenarios :: proc(app: ^App) -> (ok: bool, why: string) {
	if app.running {
		return false, "a run is in progress — rescan when it has finished"
	}

	// The name the selection is on now, cloned: the registry it points into is about to be freed.
	wanted := ""
	if app.selected >= 0 && app.selected < len(app.scenarios) {
		wanted = strings.clone(app.scenarios[app.selected].name, context.temp_allocator)
	}

	// THE GROUPS THAT ARE ON, by name and COPIED: a group from a file borrows its name from `app.loaded`,
	// which the free below destroys. Saving a scenario rebuilds the list (since 2026-10-03), so without this
	// every save silently dropped the group filter somebody was working in.
	kept := make([dynamic]string, 0, 4, context.temp_allocator)
	for name in selected_tag_names(app, context.temp_allocator) {
		append(&kept, strings.clone(name, context.temp_allocator))
	}

	before := len(app.scenarios)
	free_user_scenarios(app)
	load_user_scenarios(app)
	for group, i in app.groups {
		for name in kept {
			if group.name == name {
				app.tag_on[i] = true
			}
		}
	}

	app.selected = 0
	if wanted != "" {
		for scenario, i in app.scenarios {
			if scenario.name == wanted {
				app.selected = i
				break
			}
		}
	}

	// The list, the chips and the picker's rows, from the (kept) flags. The picker redraw once hung off
	// `app.goto_open` - the NOTES palette's flag - so an open picker kept its old rows; one render for all
	// three is what stops that kind of mismatch.
	render_groups(app)
	draw_scenario_sources(app)
	set_text_at(app, "#engine", fmt.tprintf("%d scenarios", len(app.scenarios)))
	note_selected_page(app)

	loaded := len(app.loaded.scenarios)
	problems := len(app.loaded.diagnostics)
	for diagnostic in app.loaded.diagnostics {
		log.warnf("scenario file: %s", scenario_dsl.diagnostic_text(diagnostic, context.temp_allocator))
	}
	added := len(app.scenarios) - before
	switch {
	case problems > 0:
		return true, fmt.tprintf(
			"deals list: %d scenario%s from files, %d problem%s — press check on the file to see them",
			loaded,
			plural(loaded),
			problems,
			plural(problems),
		)
	case added != 0:
		return true, fmt.tprintf("deals list: %d scenario%s from files (%+d)", loaded, plural(loaded), added)
	case:
		return true, fmt.tprintf("deals list: %d scenario%s from files", loaded, plural(loaded))
	}
}
