#+build windows
package main

/*
	The system clipboard's PICTURES and FILES, read through Win32.

	The engine's own `Clipboard` (script) does not see a screenshot: with Windows holding `Bitmap, PNG`
	(Snipping Tool, Win+Shift+S) `Clipboard.has("image")` answered false and `Clipboard.read()` came back
	with no keys at all (measured 2026-10-20). So the host reads the clipboard itself: the registered `PNG`
	format first (what screenshot tools and browsers put there, the file's own bytes), then `CF_DIB` (what a
	bare PrtScn leaves), written out as a `.bmp` - a BITMAPFILEHEADER in front of the DIB is the whole format.
	`CF_HDROP` is a file copied in the file manager.
*/

import "core:strings"
import win "core:sys/windows"

Clipboard_Picture :: struct {
	bytes:     []u8,
	extension: string, // ".png" or ".bmp"
}

// What the clipboard holds that a paste can use: a file's path, or a picture's bytes. Both in `allocator`.
clipboard_take :: proc(allocator := context.allocator) -> (path: string, picture: Clipboard_Picture, ok: bool) {
	if !win.OpenClipboard(nil) {
		return "", {}, false
	}
	defer win.CloseClipboard()

	if win.IsClipboardFormatAvailable(win.CF_HDROP) {
		if handle := win.GetClipboardData(win.CF_HDROP); handle != nil {
			drop := win.HDROP(handle)
			n := win.DragQueryFileW(drop, 0, nil, 0)
			if n > 0 {
				buf := make([]u16, n + 1, context.temp_allocator)
				win.DragQueryFileW(drop, 0, raw_data(buf), n + 1)
				if s, err := win.utf16_to_utf8(buf[:n], allocator); err == nil {
					return s, {}, true
				}
			}
		}
	}

	png_format := win.RegisterClipboardFormatW(win.L("PNG"))
	if png_format != 0 && win.IsClipboardFormatAvailable(png_format) {
		if bytes, got := global_bytes(win.GetClipboardData(png_format), allocator); got {
			return "", {bytes, ".png"}, true
		}
	}
	if win.IsClipboardFormatAvailable(win.CF_DIB) {
		if dib, got := global_bytes(win.GetClipboardData(win.CF_DIB), context.temp_allocator); got {
			if bmp, made := bmp_from_dib(dib, allocator); made {
				return "", {bmp, ".bmp"}, true
			}
		}
	}
	return "", {}, false
}

@(private = "file")
global_bytes :: proc(handle: win.HANDLE, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	if handle == nil {
		return nil, false
	}
	hglobal := win.HGLOBAL(handle)
	p := win.GlobalLock(hglobal)
	if p == nil {
		return nil, false
	}
	defer win.GlobalUnlock(hglobal)
	size := int(win.GlobalSize(win.LPVOID(handle)))
	if size <= 0 {
		return nil, false
	}
	out := make([]u8, size, allocator)
	copy(out, ([^]u8)(p)[:size])
	return out, true
}

// A packed DIB (BITMAPINFOHEADER, colour table or masks, pixels) as a .bmp file: the 14-byte file header
// says where the pixels start, which is the only thing to work out.
bmp_from_dib :: proc(dib: []u8, allocator := context.allocator) -> (bmp: []u8, ok: bool) {
	if len(dib) < 40 {
		return nil, false
	}
	le32 :: proc(b: []u8, at: int) -> u32 {
		return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
	}
	header_size := le32(dib, 0)
	bit_count := u32(dib[14]) | u32(dib[15]) << 8
	compression := le32(dib, 16)
	colours_used := le32(dib, 32)
	if colours_used == 0 && bit_count <= 8 {
		colours_used = 1 << bit_count
	}
	masks: u32 = 0
	if header_size == 40 && (compression == 3 || compression == 6) { // BI_BITFIELDS, BI_ALPHABITFIELDS
		masks = compression == 3 ? 12 : 16
	}
	offset := 14 + header_size + masks + colours_used * 4
	total := 14 + len(dib)
	if int(offset) > total {
		return nil, false
	}

	b := strings.builder_make(0, total, allocator)
	strings.write_string(&b, "BM")
	for v in ([]u32{u32(total), 0, offset}) {
		strings.write_byte(&b, u8(v))
		strings.write_byte(&b, u8(v >> 8))
		strings.write_byte(&b, u8(v >> 16))
		strings.write_byte(&b, u8(v >> 24))
	}
	strings.write_bytes(&b, dib)
	return b.buf[:], true
}

// Text on the clipboard is the deal box's to paste, so a paste with any is left to the widget.
clipboard_has_text :: proc() -> bool {
	return bool(win.IsClipboardFormatAvailable(win.CF_UNICODETEXT))
}
