#+build !windows
package main

// Pasting a picture or a file is Windows-only for now (see `clipboard_windows.odin`); elsewhere a paste is
// always the widget's.

Clipboard_Picture :: struct {
	bytes:     []u8,
	extension: string,
}

clipboard_take :: proc(allocator := context.allocator) -> (path: string, picture: Clipboard_Picture, ok: bool) {
	return "", {}, false
}

clipboard_has_text :: proc() -> bool {
	return true
}
