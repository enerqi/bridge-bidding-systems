#+build !js
package qr

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"

// The reference encoder's matrices for the same text, level, version and mask, each scanned back by a real
// reader before it was recorded (`testdata/make_goldens.py`).
@(private = "file")
GOLDENS :: #load("testdata/goldens.txt", string)

@(private = "file")
Golden :: struct {
	ecc:     Ecc,
	version: int, // 0 = the encoder chooses
	mask:    int, // -1 = the encoder chooses
	text:    string,
	chose:   [2]int, // what the reference chose, for an `auto` case
	rows:    []string,
}

@(private = "file")
number :: proc(s: string) -> int {
	value, _ := strconv.parse_int(s) // `auto` reads as 0
	return value
}

@(private = "file")
read_goldens :: proc() -> []Golden {
	goldens := make([dynamic]Golden, context.temp_allocator)
	lines := strings.split_lines(GOLDENS, context.temp_allocator)
	for i := 0; i < len(lines); i += 1 {
		line := lines[i]
		if !strings.has_prefix(line, "case ") {
			continue
		}
		fields := strings.split_n(line, " ", 5, context.temp_allocator)
		g := Golden {
			text = fields[4],
		}
		switch fields[1] {
		case "L":
			g.ecc = .L
		case "M":
			g.ecc = .M
		case "Q":
			g.ecc = .Q
		case "H":
			g.ecc = .H
		}
		g.version = number(fields[2])
		g.mask = -1 if fields[3] == "auto" else number(fields[3])
		if strings.has_prefix(lines[i + 1], "chose ") {
			i += 1
			chose := strings.fields(lines[i], context.temp_allocator)
			g.chose = {number(chose[1]), number(chose[2])}
		} else {
			g.chose = {g.version, g.mask}
		}
		start := i + 1
		size := len(lines[start])
		g.rows = lines[start:][:size]
		i += size
		append(&goldens, g)
	}
	return goldens[:]
}

@(test)
test_every_golden_matrix_matches :: proc(t: ^testing.T) {
	goldens := read_goldens()
	testing.expect(t, len(goldens) >= 20, "the goldens file did not parse")
	for g, n in goldens {
		options := Options {
			ecc         = g.ecc,
			min_version = g.version,
			max_version = g.version,
			mask        = g.mask,
		}
		code, ok := encode_string(g.text, options)
		defer destroy(code)
		if !testing.expectf(t, ok, "case %d: did not encode", n) {
			continue
		}
		testing.expectf(t, code.version == g.chose[0], "case %d: version %d, reference %d", n, code.version, g.chose[0])
		testing.expectf(t, code.mask == g.chose[1], "case %d: mask %d, reference %d", n, code.mask, g.chose[1])
		testing.expectf(t, code.ecc == g.ecc, "case %d: boosted without being asked", n)
		if code.size != len(g.rows) {
			testing.expectf(t, false, "case %d: size %d, reference %d", n, code.size, len(g.rows))
			continue
		}
		wrong := 0
		for row, y in g.rows {
			for c, x in row {
				if (c == '1') != is_dark(code, x, y) {
					wrong += 1
				}
			}
		}
		testing.expectf(t, wrong == 0, "case %d (%v v%d mask %d): %d modules differ", n, g.ecc, code.version, code.mask, wrong)
	}
}

// The standard's byte-mode capacity table, at its corners.
@(test)
test_byte_capacity :: proc(t: ^testing.T) {
	testing.expect_value(t, byte_capacity(1, .L), 17)
	testing.expect_value(t, byte_capacity(1, .H), 7)
	testing.expect_value(t, byte_capacity(10, .M), 213)
	testing.expect_value(t, byte_capacity(40, .L), 2953)
	testing.expect_value(t, byte_capacity(40, .M), 2331)
	testing.expect_value(t, byte_capacity(40, .Q), 1663)
	testing.expect_value(t, byte_capacity(40, .H), 1273)
}

@(test)
test_too_long_is_refused :: proc(t: ^testing.T) {
	data := make([]u8, 2954)
	defer delete(data)
	_, ok := encode(data, Options{ecc = .L, mask = -1})
	testing.expect(t, !ok, "2,954 bytes do not fit version 40 at L")
	code, ok2 := encode(data[:2953], Options{ecc = .L, mask = -1})
	defer destroy(code)
	testing.expect(t, ok2 && code.version == 40, "2,953 bytes fill version 40 at L")
}

// With room to spare, the level rises - and only while the data still fits the same version.
@(test)
test_boost_keeps_the_version :: proc(t: ^testing.T) {
	plain, _ := encode_string("HELLO WORLD", Options{ecc = .L, mask = -1})
	defer destroy(plain)
	boosted, _ := encode_string("HELLO WORLD", Options{ecc = .L, boost_ecc = true, mask = -1})
	defer destroy(boosted)
	testing.expect_value(t, boosted.version, plain.version)
	testing.expect_value(t, boosted.ecc, Ecc.Q) // 11 bytes: Q holds 11 in version 1, H only 7
}

@(test)
test_svg :: proc(t: ^testing.T) {
	code, _ := encode_string("HELLO WORLD", Options{ecc = .M, mask = 2})
	defer destroy(code)
	s := svg(code)
	defer delete(s)
	testing.expect(t, strings.has_prefix(s, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 29 29"`), s[:60])
	testing.expect(t, strings.has_suffix(s, `"/></svg>`))
	// the top-left finder's first row is a run of 7 dark modules, starting inside the quiet zone
	testing.expect(t, strings.contains(s, `d="M4 4h7v1h-7z`), "the first run is the finder's top edge")
	dark := 0
	for d in code.dark {
		dark += 1 if d else 0
	}
	runs := 0
	for y in 0 ..< code.size {
		for x in 0 ..< code.size {
			if is_dark(code, x, y) && (x == 0 || !is_dark(code, x - 1, y)) {
				runs += 1
			}
		}
	}
	testing.expect_value(t, strings.count(s, "z"), runs)
	sized := svg(code, module_px = 4)
	defer delete(sized)
	testing.expect(t, strings.contains(sized, fmt.tprintf(`width="%d" height="%d"`, 29 * 4, 29 * 4)))
}
