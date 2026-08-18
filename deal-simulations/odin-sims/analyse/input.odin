package analyse

/*
	input.odin — resolving raw input text to boards (part of package `analyse`; see analyse.odin).

	The deal string may be PBN (a `[Deal "..."]` tag or a bare `N:...` value) OR a LIN deal from a
	bridge site: a whole BBO / IntoBridge hand URL (`...?lin=pn|...|md|...`) — the `lin=` query parameter
	is extracted and percent-decoded — or a bare LIN record (`...md|...`). The `md|` deal is read; the
	auction and play are ignored. LIN input is always one whole board.
*/

import "core:fmt"
import "core:os"
import "core:strings"

import "norn:norn"

// Resolve raw input text to boards, dispatching on format. LIN input — a bridge-site hand URL
// (`...?lin=...`) or a bare LIN record (`...md|...`) — is routed to the LIN reader; everything else is
// treated as PBN. Returns an error MESSAGE ("" == ok) rather than a typed error, since the two readers
// have distinct error enums. LIN yields exactly one board; PBN may yield several.
resolve_boards :: proc(text: string) -> (boards: [dynamic]norn.Board, errmsg: string) {
	is_url_lin := strings.contains(text, "lin=")
	// A bare LIN record has an `md|` token and no `[Deal "` tag (which would mark it as PBN).
	is_bare_lin := !is_url_lin && strings.contains(text, "md|") && !strings.contains(text, DEAL_TAG)

	if is_url_lin || is_bare_lin {
		lin_str := text
		if is_url_lin {
			lin_str = lin_query_param(text, context.temp_allocator)
		}
		b, e := norn.parse_lin_deal(lin_str)
		if e != .None {
			return nil, fmt.tprintf("could not parse LIN deal: %v", e)
		}
		append(&boards, b)
		return boards, ""
	}

	b, e := parse_boards(text)
	if e != .None {
		return nil, fmt.tprintf("could not parse PBN deal: %v", e)
	}
	return b, ""
}

// Extract the `lin=` query-parameter value from a URL (or any string containing `lin=`) and
// percent-decode it. The value runs to the next `&` (start of the next query parameter) or the end of
// the string — LIN's own `|` separators are part of the value, not query delimiters. Returns "" when
// there is no `lin=` (which parse_lin_deal then reports as a missing `md` tag). Allocates on `alloc`.
lin_query_param :: proc(text: string, alloc := context.allocator) -> string {
	li := strings.index(text, "lin=")
	if li < 0 {
		return ""
	}
	rest := text[li + len("lin="):]
	if amp := strings.index_byte(rest, '&'); amp >= 0 {
		rest = rest[:amp]
	}
	return url_decode(rest, alloc)
}

// Percent-decode a URL query value: `%XX` -> the byte, `+` -> space, everything else verbatim. A `%`
// not followed by two hex digits is passed through literally (real LIN URLs are well-formed; this just
// avoids losing data on a malformed one). Allocates the result on `alloc`.
url_decode :: proc(s: string, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			hi, hi_ok := hex_nibble(s[i + 1])
			lo, lo_ok := hex_nibble(s[i + 2])
			if hi_ok && lo_ok {
				strings.write_byte(&b, hi << 4 | lo)
				i += 3
				continue
			}
		}
		if c == '+' {
			strings.write_byte(&b, ' ')
		} else {
			strings.write_byte(&b, c)
		}
		i += 1
	}
	return strings.to_string(b)
}

// Value of a single hex digit (0-9, a-f, A-F). ok = false on any other byte.
hex_nibble :: proc(c: u8) -> (v: u8, ok: bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// The `[Deal` tag opener, including the space + quote that START its value: `[Deal "`. Matching this
// (rather than bare `[Deal`) is what keeps a standard `.pbn` file's `[Dealer "..."]` and `[Declarer
// "..."]` tags — which share the `[Deal` prefix — from being mistaken for deals.
@(private = "file")
DEAL_TAG :: `[Deal "`

// Parse every `[Deal "..."]` tag in `text` into a board (a hand-ocr session or a `.pbn` file may carry
// several). Each occurrence is parsed from its position (parse_pbn_deal reads the first tag it finds), so
// all other PBN tags ([Board]/[Dealer]/[Vulnerable]/...) are ignored. With NO `[Deal "` tag the whole input
// is treated as a single bare `N:...` value. Returns the first parse error hit.
parse_boards :: proc(text: string) -> (boards: [dynamic]norn.Board, err: norn.Pbn_Parse_Error) {
	idx := strings.index(text, DEAL_TAG)
	if idx < 0 {
		b, e := norn.parse_pbn_deal(text)
		if e != .None {
			return nil, e
		}
		append(&boards, b)
		return boards, .None
	}
	for idx >= 0 {
		b, e := norn.parse_pbn_deal(text[idx:])
		if e != .None {
			delete(boards)
			return nil, e
		}
		append(&boards, b)
		next := strings.index(text[idx + len(DEAL_TAG):], DEAL_TAG)
		if next < 0 {
			break
		}
		idx = idx + len(DEAL_TAG) + next
	}
	return boards, .None
}

// Read all of stdin into a string (for `hand-ocr ... | analyse_deal`). Best-effort: stops at EOF or any
// read error, returning whatever was gathered.
//
// A GUI must never reach this — a windowed process' stdin blocks with nobody to type into it — which is
// why `parse_args` takes `allow_stdin`.
read_stdin :: proc() -> string {
	sb: strings.Builder
	buf: [4096]u8
	for {
		n, _ := os.read(os.stdin, buf[:])
		if n > 0 {
			strings.write_bytes(&sb, buf[:n])
		}
		if n <= 0 { 	// EOF (0) or an error (< 0): stop, return what we have
			break
		}
	}
	return strings.to_string(sb)
}
