package main

/*
	notes_dirs.odin — the notes view's FOLDERS: several, as the scenarios view has, one of them open.

	The notes used to have one folder: the one found at startup (`BML_DOCS_DIRECTORY`, or the corpus above
	where the program was started), which `add…` replaced for the session and nothing remembered. Now:

	  * the FOUND folder is always first in the list, and has no `×` - it is where this program is running,
	    not a choice anybody made;
	  * `add…` ADDS a folder (remembered in `notes.dirs`, newest first) and opens it;
	  * a row opens that folder; its `×` forgets a remembered one;
	  * the folder that was open is remembered too (`notes.dir`), so a restart comes back to it.

	Opening a folder drops the open buffer (it belongs to the folder being left), so a buffer with unsaved
	changes gets the same two-step guard leaving a file does: the first click is refused and says so.
*/

import "core:fmt"
import "core:os"
import "core:strings"

import "../prefs"
import sa "sciter:sciter_app"

NOTES_DIRS_PREF :: "notes.dirs"
NOTES_DIR_PREF :: "notes.dir"

// Every folder in the list: the found one, then the remembered ones, without repeats. Scratch memory.
notes_dirs :: proc(app: ^App) -> []string {
	dirs := make([dynamic]string, 0, 4, context.temp_allocator)
	if app.notes_found != "" {
		append(&dirs, app.notes_found)
	}
	if remembered, found := prefs.get(&app.prefs, NOTES_DIRS_PREF); found {
		next: for part in strings.split(remembered, ";", context.temp_allocator) {
			trimmed := strings.trim_space(part)
			if trimmed == "" {
				continue
			}
			for dir in dirs {
				if same_dir(dir, trimmed) {
					continue next
				}
			}
			append(&dirs, trimmed)
		}
	}
	// The open folder, even if it is in neither (a test, or a folder chosen before this list existed).
	if app.docs != "" {
		for dir in dirs {
			if same_dir(dir, app.docs) {
				return dirs[:]
			}
		}
		append(&dirs, app.docs)
	}
	return dirs[:]
}

// At startup: the folder that was open last time, if it is still remembered and still there; else the found one.
startup_notes_dir :: proc(app: ^App, found: string) -> string {
	if last, ok := prefs.get(&app.prefs, NOTES_DIR_PREF); ok && last != "" && os.is_dir(last) {
		for dir in notes_dirs(app) {
			if same_dir(dir, last) {
				return last
			}
		}
	}
	return found
}

@(private = "file")
set_notes_pref :: proc(app: ^App, key, value: string) {
	if app.prefs.values == nil {
		return
	}
	prefs.set(&app.prefs, key, value)
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
}

// `add…` chose a folder: put it first among the remembered ones (the found one is not written down).
remember_notes_dir :: proc(app: ^App, path: string) {
	if app.prefs.values == nil || same_dir(path, app.notes_found) {
		return
	}
	joined := strings.builder_make(0, 128, context.temp_allocator)
	strings.write_string(&joined, path)
	if remembered, found := prefs.get(&app.prefs, NOTES_DIRS_PREF); found {
		for part in strings.split(remembered, ";", context.temp_allocator) {
			trimmed := strings.trim_space(part)
			if trimmed == "" || same_dir(trimmed, path) {
				continue
			}
			strings.write_byte(&joined, ';')
			strings.write_string(&joined, trimmed)
		}
	}
	set_notes_pref(app, NOTES_DIRS_PREF, strings.to_string(joined))
}

// The folder now open, for the next start.
remember_open_notes_dir :: proc(app: ^App) {
	set_notes_pref(app, NOTES_DIR_PREF, app.docs)
}

// A row was clicked: open that folder, unless that would throw away unsaved text without a second click.
switch_notes_dir :: proc(app: ^App, dir: string) {
	if dir == "" || same_dir(dir, app.docs) {
		return
	}
	if app.bml_open != "" && bml_modified(app) && !app.bml_armed {
		app.bml_armed = true
		bml_status(app, fmt.tprintf("%s has unsaved changes — save, or click again to discard them", app.bml_open))
		return
	}
	use_bml_dir(app, strings.clone(dir, context.temp_allocator)) // `dir` is a row of the list about to be redrawn
}

// The `×`: forget a remembered folder. The found one cannot be. Forgetting the open folder opens the found one.
forget_notes_dir :: proc(app: ^App, dir: string) -> (ok: bool, why: string) {
	if same_dir(dir, app.notes_found) {
		return false, "that is the folder this program found its notes in - it is always listed"
	}
	open := same_dir(dir, app.docs)
	if open && app.bml_open != "" && bml_modified(app) {
		return false, fmt.tprintf("%s has unsaved changes — save or discard them first", app.bml_open)
	}
	shown := strings.clone(dir, context.temp_allocator)
	kept := strings.builder_make(0, 128, context.temp_allocator)
	if remembered, found := prefs.get(&app.prefs, NOTES_DIRS_PREF); found {
		for part in strings.split(remembered, ";", context.temp_allocator) {
			trimmed := strings.trim_space(part)
			if trimmed == "" || same_dir(trimmed, shown) {
				continue
			}
			if strings.builder_len(kept) > 0 {
				strings.write_byte(&kept, ';')
			}
			strings.write_string(&kept, trimmed)
		}
	}
	set_notes_pref(app, NOTES_DIRS_PREF, strings.to_string(kept))
	if open {
		use_bml_dir(app, strings.clone(app.notes_found, context.temp_allocator))
	} else {
		draw_notes_sources(app)
	}
	return true, fmt.tprintf("forgot %s", shown)
}

// The list, drawn in the scenarios view's shape: the path, where it came from and how many files, the open one marked.
draw_notes_sources :: proc(app: ^App) {
	box := find(app, "#bml-sources")
	if box == nil {
		return
	}
	dirs := notes_dirs(app)
	if len(dirs) == 0 {
		sa.set_html(box, `<div class="empty">no folders yet — press add… to choose one</div>`)
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for dir in dirs {
		found := same_dir(dir, app.notes_found)
		what := "not found"
		if os.is_dir(dir) {
			count := len(list_bml_files(dir, context.temp_allocator))
			what = fmt.tprintf("%d file%s", count, "" if count == 1 else "s")
		}
		escaped := escape_html(dir, context.temp_allocator)
		forget := "" if found else fmt.tprintf(`<span class="forget" data-nforget="%s" title="Forget this folder">×</span>`, escaped)
		fmt.sbprintf(
			&b,
			`<div class="row%s" data-ndir="%s" title="%s"><span class="path">%s</span><div class="what"><span class="lbl">%s · %s</span>%s</div></div>`,
			" sel" if same_dir(dir, app.docs) else "",
			escaped,
			escaped,
			escaped,
			"found here" if found else "remembered",
			what,
			forget,
		)
	}
	sa.set_html(box, strings.to_string(b))
}
