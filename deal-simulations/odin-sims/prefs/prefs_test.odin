package prefs

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

/*
The remembered choices, round-tripped through a real file.

What matters is the second SESSION: a preference that only survives while the window is open is not a
preference. So every test here writes, throws the `Prefs` away, loads it again, and asks.
*/

@(private = "file")
scratch_path :: proc(name: string) -> string {
	dir := os.get_env("TEMP", context.temp_allocator)
	if dir == "" {
		dir = "."
	}
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

@(test)
test_a_choice_survives_the_process :: proc(t: ^testing.T) {
	path := scratch_path("wb-prefs-round-trip.prefs")
	os.remove(path)
	defer os.remove(path)

	{
		p := load(path, context.temp_allocator)
		defer destroy(&p)
		set(&p, "preview.scope.nt-bidding.bml", "whole")
		set(&p, "preview.scope.uncontested-bidding.bml", "section")
		testing.expect(t, save(&p, path), "the file should have been written")
	}

	// A different `Prefs` entirely - the point is the file, not the map.
	again := load(path, context.temp_allocator)
	defer destroy(&again)
	whole, found_whole := get(&again, "preview.scope.nt-bidding.bml")
	testing.expect(t, found_whole, "the choice should have been remembered")
	testing.expect_value(t, whole, "whole")
	section, _ := get(&again, "preview.scope.uncontested-bidding.bml")
	testing.expect_value(t, section, "section")
}

@(test)
test_a_choice_can_be_changed :: proc(t: ^testing.T) {
	path := scratch_path("wb-prefs-change.prefs")
	os.remove(path)
	defer os.remove(path)

	p := load(path, context.temp_allocator)
	defer destroy(&p)
	set(&p, "preview.scope.x.bml", "section")
	set(&p, "preview.scope.x.bml", "whole")
	testing.expect(t, save(&p, path), "the file should have been written")

	again := load(path, context.temp_allocator)
	defer destroy(&again)
	value, _ := get(&again, "preview.scope.x.bml")
	testing.expect_value(t, value, "whole")

	// One line per key, not one per press: a settings file that grows every time a button is pressed is a
	// settings file nobody can read.
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.count(string(data), "preview.scope.x.bml"), 1)
}

@(test)
test_a_missing_file_is_a_first_run :: proc(t: ^testing.T) {
	// Not an error, and not a reason to refuse to start: an empty set of preferences.
	p := load(scratch_path("wb-prefs-not-there-at-all.prefs"), context.temp_allocator)
	defer destroy(&p)
	_, found := get(&p, "anything")
	testing.expect(t, !found, "a missing file holds no preferences")
}

@(test)
test_lines_this_version_does_not_understand_are_kept :: proc(t: ^testing.T) {
	// A hand-edited comment, or a key a later version writes: rewriting the file must not delete it.
	path := scratch_path("wb-prefs-unknown.prefs")
	defer os.remove(path)
	testing.expect_value(
		t,
		os.write_entire_file(path, transmute([]u8)string("# chosen by hand\nsomething.new=42\n")),
		nil,
	)

	p := load(path, context.temp_allocator)
	defer destroy(&p)
	set(&p, "preview.scope.y.bml", "section")
	testing.expect(t, save(&p, path), "the file should have been written")

	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	text := string(data)
	testing.expect(t, strings.contains(text, "# chosen by hand"), "a comment must survive a rewrite")
	// `something.new=42` parses as a key, so it comes back as one rather than as an unknown line.
	testing.expect(t, strings.contains(text, "something.new=42"), "an unknown key must survive a rewrite")
	testing.expect(t, strings.contains(text, "preview.scope.y.bml=section"), "and the new one is there")
}

@(test)
test_the_default_path_is_not_the_working_directory :: proc(t: ^testing.T) {
	// The notes are a git repository; a settings file does not belong beside them, and a bare filename in
	// the working directory is how that happens by accident.
	path := default_path(context.temp_allocator)
	testing.expect(t, strings.contains(path, "bridge-workbench"), "the path should name the application")
	testing.expect(t, strings.contains(path, "workbench.prefs"), "and the file")
}
