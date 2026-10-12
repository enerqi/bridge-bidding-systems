#+build js
// The shared-deals PLAYER: norn compiled to js_wasm32, rendering the card page a link carries (`share`).
// `page.js` (in `player.html`) is the only caller: it hands over the fragment, steps through the boards so it
// can show progress while the card-combination analysis runs (~100ms a board), then takes the page.
package main

import "base:runtime"
import "core:strings"
import "../share"

@(private)
global_context: runtime.Context

// The page being built. Lives until the next `pl_open`; the host copies it out at once.
page: strings.Builder
shared: share.Shared
next_board: int

main :: proc() {
	global_context = context
	page = strings.builder_make(0, 512 * 1024)
}

// Somewhere to write `size` bytes (the fragment). Temp memory: valid until `pl_open` returns.
@(export)
pl_alloc :: proc "c" (size: i32) -> rawptr {
	context = global_context
	free_all(context.temp_allocator)
	bytes, _ := make([]u8, int(size), context.temp_allocator)
	return raw_data(bytes)
}

// Read a link's fragment (without the `#`) and start its page. Returns the number of boards, or minus the
// `share.Decode_Error` when it is not a link this player can read.
@(export)
pl_open :: proc "c" (data: [^]u8, size: i32) -> i32 {
	context = global_context
	share.destroy(shared)
	err: share.Decode_Error
	// On the heap: `combo.annotate` frees all temp memory after each board.
	shared, err = share.decode(string(data[:size]))
	if err != .None {
		shared = {}
		return -i32(err)
	}
	next_board = 0
	strings.builder_reset(&page)
	share.render_start(&page, shared.title)
	return i32(len(shared.boards))
}

// 1 when the link asks for the card-combination analysis (the slow part), else 0.
@(export)
pl_analyse :: proc "c" () -> i32 {
	return 1 if shared.analyse else 0
}

// Render the next board. Returns how many are left.
@(export)
pl_step :: proc "c" () -> i32 {
	context = global_context
	if next_board < len(shared.boards) {
		share.render_board(&page, shared.boards[next_board], shared.analyse)
		next_board += 1
	}
	return i32(len(shared.boards) - next_board)
}

// Finish the page (after the last `pl_step`) and return its length; `pl_result` points at it.
@(export)
pl_finish :: proc "c" () -> i32 {
	context = global_context
	share.render_end(&page)
	return i32(strings.builder_len(page))
}

@(export)
pl_result :: proc "c" () -> rawptr {
	return raw_data(page.buf)
}
