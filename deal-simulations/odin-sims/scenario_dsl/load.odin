package scenario_dsl

/*
	load.odin — `.scenario` files from directories the user chose, as `cli.Scenario` values.

	ARBITRARY DIRECTORIES, plural: a user's own scenarios, a set shared by a partner, a set checked into
	somebody else's repository. Nothing here knows a default location — the CALLER decides where to look,
	because "where do my scenarios live" is a question about a person's machine and not about a language.

	WHAT COMES BACK is a `[]cli.Scenario` that concatenates onto the compiled registry, so everything
	downstream — the list, the filter, the groups, `--frequency`, the chips — treats a parsed scenario
	exactly like a compiled one. That was the whole point of `norn.Condition` being a union.

	THE PROGRAMS ARE OWNED AND STABLE. Each `cli.Scenario` points at its `Program` through
	`Interpreted_Predicate.data`, so the programs must not move: they are allocated individually rather
	than living in a `[dynamic]Program` that reallocates as it grows, which would leave every scenario
	built so far pointing at freed memory. Measured the hard way in other codebases; not here, because
	this comment exists.
*/

import "core:os"
import "core:path/filepath"
import "core:strings"
import "norn:cli"
import "norn:norn"

// What a scenario file is called. One extension, so a directory can hold notes and data beside them.
SCENARIO_EXTENSION :: ".scenario"

// A loaded set: the scenarios to append to the registry, the programs they point into (to be freed
// together), and everything that was wrong with the files.
Loaded :: struct {
	scenarios:   []cli.Scenario,
	programs:    []^Program,
	tags:        [][]string, // parallel to `scenarios`: the groups each one declared
	diagnostics: []Diagnostic,
}

destroy_loaded :: proc(loaded: ^Loaded, allocator := context.allocator) {
	for program in loaded.programs {
		destroy_program(program)
		free(program, allocator)
	}
	delete(loaded.programs, allocator)
	delete(loaded.scenarios, allocator)
	delete(loaded.tags, allocator)
	for diagnostic in loaded.diagnostics {
		delete(diagnostic.message, allocator)
		delete(diagnostic.pos.file, allocator)
	}
	delete(loaded.diagnostics, allocator)
	loaded^ = {}
}

/*
Load every `.scenario` file in every directory named, in order.

ORDER IS MEANINGFUL and the caller sets it: later directories come later in the returned list, so when
the registry is concatenated a later scenario SHADOWS an earlier one of the same name under `cli.lookup`'s
"first exact match" rule. That is what lets someone override a scenario without editing the file it came
from.

A directory that does not exist is not an error — a configured-but-absent folder is a normal state for a
list of places to look, and failing the whole load because one is missing would be the wrong bargain.
*/
load_directories :: proc(directories: []string, allocator := context.allocator) -> (loaded: Loaded) {
	scenarios := make([dynamic]cli.Scenario, 0, 8, allocator)
	programs := make([dynamic]^Program, 0, 8, allocator)
	tags := make([dynamic][]string, 0, 8, allocator)
	problems := make([dynamic]Diagnostic, 0, 4, allocator)

	for directory in directories {
		if directory == "" || !os.is_dir(directory) {
			continue
		}
		handle, open_err := os.open(directory)
		if open_err != nil {
			continue
		}
		entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
		os.close(handle)
		if read_err != nil {
			continue
		}
		// SORTED, so a directory listing's order — which is the filesystem's business, not ours — cannot
		// change which of two same-named scenarios wins. A load has to be reproducible.
		names := make([dynamic]string, 0, len(entries), context.temp_allocator)
		for entry in entries {
			// `.type` rather than an `is_dir` flag: this Odin's `File_Info` reports a `File_Type`.
			if entry.type == .Regular &&
			   strings.has_suffix(strings.to_lower(entry.name, context.temp_allocator), SCENARIO_EXTENSION) {
				append(&names, entry.fullpath)
			}
		}
		sort_strings(names[:])

		for path in names {
			data, read_err2 := os.read_entire_file_from_path(path, context.temp_allocator)
			if read_err2 != nil {
				append(
					&problems,
					Diagnostic {
						pos = {file = strings.clone(path, allocator), line = 0, col = 0},
						message = strings.clone("could not read this file", allocator),
					},
				)
				continue
			}
			file_programs, file_problems := parse(string(data), path, allocator)
			for diagnostic in file_problems {
				append(&problems, diagnostic)
			}
			delete(file_problems, allocator)

			for program in file_programs {
				// One allocation per program, so the pointer handed to `Interpreted_Predicate` is stable
				// for the life of the run — see the header.
				held := new(Program, allocator)
				held^ = program
				append(&programs, held)
				append(&tags, held.tags)
				append(
					&scenarios,
					cli.Scenario {
						name = held.name,
						description = held.description,
						predicate = norn.Interpreted_Predicate{evaluate, held},
					},
				)
			}
			delete(file_programs, allocator)
		}
	}

	return Loaded{scenarios = scenarios[:], programs = programs[:], tags = tags[:], diagnostics = problems[:]}
}

// An insertion sort: a directory holds a handful of scenario files, and the alternative is importing a
// sort for a list that is almost always shorter than ten.
@(private)
sort_strings :: proc(values: []string) {
	for i in 1 ..< len(values) {
		current := values[i]
		j := i - 1
		for j >= 0 && values[j] > current {
			values[j + 1] = values[j]
			j -= 1
		}
		values[j + 1] = current
	}
}

// One diagnostic, as a line somebody can read. `file:line:col: message`, the spelling every compiler and
// editor already knows how to jump to.
diagnostic_text :: proc(diagnostic: Diagnostic, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, filepath.base(diagnostic.pos.file))
	if diagnostic.pos.line > 0 {
		strings.write_byte(&builder, ':')
		write_int(&builder, diagnostic.pos.line)
		if diagnostic.pos.col > 0 {
			strings.write_byte(&builder, ':')
			write_int(&builder, diagnostic.pos.col)
		}
	}
	strings.write_string(&builder, ": ")
	strings.write_string(&builder, diagnostic.message)
	return strings.to_string(builder)
}

@(private)
write_int :: proc(builder: ^strings.Builder, value: int) {
	if value >= 10 {
		write_int(builder, value / 10)
	}
	strings.write_byte(builder, byte('0' + value % 10))
}
