package prefs

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

/*
The window's remembered choices, one `key=value` line per file.

WHY A FILE THIS SIDE, and not the document's storage. The obvious guesses do not exist here: there are no
COOKIES in Sciter (nothing is served over http, so there is nothing to set them on), and `localStorage` is a
browser API this engine does not have. What it does have is `@storage`, a NoSQL store opened with
`await import("@storage")` - which is a real cross-session option, but it lives in the DOCUMENT's runtime,
which means the state a person chose would be owned by the projection rather than by the application, and
the host would have to eval script to read its own settings back. So: a plain file, written by the host.

It is deliberately dumb. `key=value` a line, last one wins, unknown lines are kept when the file is
rewritten so a hand-edit or a future key is not silently deleted, and a missing or unreadable file is simply
an empty set of preferences - a window that cannot remember what you chose last week is a small
disappointment, and one that refuses to start over it is a bug.
*/
Prefs :: struct {
	values:    map[string]string,
	// Lines the parser did not understand, kept in order so `save` can write them back.
	unknown:   [dynamic]string,
	allocator: mem.Allocator,
}

// Where the file lives: `%LOCALAPPDATA%\bridge-workbench\workbench.prefs` on Windows, `~/.config/...`
// elsewhere. Beside the corpus would be wrong - the notes are a git repository and this is not its business.
default_path :: proc(allocator := context.allocator) -> string {
	dir := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if dir == "" {
		dir = os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	}
	if dir == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {
			home = os.get_env("USERPROFILE", context.temp_allocator)
		}
		if home == "" {
			return strings.clone("workbench.prefs", allocator)
		}
		joined, err := filepath.join({home, ".config"}, context.temp_allocator)
		if err != nil {
			return strings.clone("workbench.prefs", allocator)
		}
		dir = joined
	}
	path, jerr := filepath.join({dir, "bridge-workbench", "workbench.prefs"}, allocator)
	if jerr != nil {
		return strings.clone("workbench.prefs", allocator)
	}
	return path
}

// Read what is there. A missing file is not an error: it is a first run.
load :: proc(path: string, allocator := context.allocator) -> Prefs {
	p := Prefs {
		values    = make(map[string]string, 16, allocator),
		unknown   = make([dynamic]string, 0, 4, allocator),
		allocator = allocator,
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return p
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		eq := strings.index_byte(trimmed, '=')
		if eq <= 0 || strings.has_prefix(trimmed, "#") {
			append(&p.unknown, strings.clone(trimmed, allocator))
			continue
		}
		key := strings.clone(strings.trim_space(trimmed[:eq]), allocator)
		value := strings.clone(strings.trim_space(trimmed[eq + 1:]), allocator)
		p.values[key] = value
	}
	return p
}

get :: proc(p: ^Prefs, key: string) -> (value: string, ok: bool) {
	value, ok = p.values[key]
	return
}

// Remember one choice. The value is cloned, so the caller's string can be temporary.
set :: proc(p: ^Prefs, key: string, value: string) {
	if existing, found := p.values[key]; found {
		if existing == value {
			return
		}
		delete(existing, p.allocator)
		// The KEY is already ours; only the value is replaced.
		p.values[key] = strings.clone(value, p.allocator)
		return
	}
	p.values[strings.clone(key, p.allocator)] = strings.clone(value, p.allocator)
}

/*
Write it back, creating the directory if it is not there.

Reports whether it worked, and the caller decides how much to care: the workbench says nothing, because
failing to remember a view preference is not worth a message in a transcript about bridge deals.
*/
save :: proc(p: ^Prefs, path: string) -> bool {
	if dir := filepath.dir(path); dir != "" {
		if !os.exists(dir) {
			os.make_directory(dir)
		}
	}
	b := strings.builder_make(context.temp_allocator)
	for line in p.unknown {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	for key, value in p.values {
		strings.write_string(&b, key)
		strings.write_byte(&b, '=')
		strings.write_string(&b, value)
		strings.write_byte(&b, '\n')
	}
	return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}

destroy :: proc(p: ^Prefs) {
	for key, value in p.values {
		delete(key, p.allocator)
		delete(value, p.allocator)
	}
	delete(p.values)
	for line in p.unknown {
		delete(line, p.allocator)
	}
	delete(p.unknown)
}
