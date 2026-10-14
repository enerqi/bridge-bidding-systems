// A QR code ENCODER (ISO/IEC 18004, model 2): a shared link onto a phone by scanning (SHARING_PLAN.md, Tier C).
//
// Byte mode only - a share link is base64url, which has lowercase letters, so the denser alphanumeric mode
// cannot carry it, and byte mode carries anything. Versions 1-40, error correction L/M/Q/H, Reed-Solomon over
// GF(256), the eight masks chosen by the standard penalty score, format and version information.
//
// No engine and no allocation the caller does not own, so it is unit-tested natively against a reference
// encoder (`testdata/goldens.txt`: `qrcodegen`'s matrices, each scanned back by zxing-cpp, recorded by
// `testdata/make_goldens.py`). The card page carries a JS PORT of this file (norn's `html_cards_qr.js`), held to
// the same goldens by `check_js.mjs` (`just sims test-qr-js`): change one, change both.
//
// The layout follows the standard's own construction order: function patterns first (finders, timing,
// alignment, format and version areas), then the codewords in the two-column zigzag, then a mask over
// everything that is not a function pattern.
package qr

import "core:strings"

Ecc :: enum {
	L, // ~7% of the codewords can be restored
	M, // ~15%
	Q, // ~25%
	H, // ~30%
}

MIN_VERSION :: 1
MAX_VERSION :: 40

// A finished symbol. `dark` is row-major, `size * size`, without the quiet zone (the SVG adds it).
Code :: struct {
	version: int,
	size:    int,
	ecc:     Ecc,
	mask:    int,
	dark:    []bool,
}

Options :: struct {
	ecc:         Ecc, // the LEAST error correction acceptable
	boost_ecc:   bool, // raise it while the data still fits the chosen version (free robustness)
	min_version: int, // 0 = MIN_VERSION
	max_version: int, // 0 = MAX_VERSION
	mask:        int, // -1 = choose by penalty score (0 is mask 0, not "automatic")
}

DEFAULT_OPTIONS :: Options {
	ecc         = .M,
	boost_ecc   = true,
	mask        = -1,
}

// The QR code for `data`, at the smallest version that holds it. `ok` is false when no version in range
// does (a version 40 symbol holds 2,953 bytes at L, 1,273 at H).
encode :: proc(data: []u8, options := DEFAULT_OPTIONS, allocator := context.allocator) -> (code: Code, ok: bool) {
	min_v := options.min_version if options.min_version > 0 else MIN_VERSION
	max_v := options.max_version if options.max_version > 0 else MAX_VERSION
	assert(MIN_VERSION <= min_v && min_v <= max_v && max_v <= MAX_VERSION)
	assert(-1 <= options.mask && options.mask <= 7)

	version := 0
	for v in min_v ..= max_v {
		if data_bits_needed(len(data), v) <= data_codewords(v, options.ecc) * 8 {
			version = v
			break
		}
	}
	if version == 0 {
		return {}, false
	}
	ecc := options.ecc
	if options.boost_ecc {
		for e in Ecc {
			if e > ecc && data_bits_needed(len(data), version) <= data_codewords(version, e) * 8 {
				ecc = e
			}
		}
	}

	codewords := add_ecc_and_interleave(data_codewords_for(data, version, ecc), version, ecc)
	defer delete(codewords, context.temp_allocator)

	size := version * 4 + 17
	code = Code {
		version = version,
		size    = size,
		ecc     = ecc,
		dark    = make([]bool, size * size, allocator),
	}
	function := make([]bool, size * size, context.temp_allocator)
	defer delete(function, context.temp_allocator)
	m := Matrix{size, code.dark, function}
	draw_function_patterns(m, version)
	draw_codewords(m, codewords)

	mask := options.mask
	if mask < 0 {
		best := max(int)
		for candidate in 0 ..< 8 {
			apply_mask(m, candidate)
			draw_format_bits(m, ecc, candidate)
			score := penalty(m)
			if score < best {
				best = score
				mask = candidate
			}
			apply_mask(m, candidate) // XOR: a second application undoes it
		}
	}
	apply_mask(m, mask)
	draw_format_bits(m, ecc, mask)
	code.mask = mask
	return code, true
}

encode_string :: proc(text: string, options := DEFAULT_OPTIONS, allocator := context.allocator) -> (Code, bool) {
	return encode(transmute([]u8)text, options, allocator)
}

destroy :: proc(code: Code, allocator := context.allocator) {
	delete(code.dark, allocator)
}

is_dark :: proc(code: Code, x, y: int) -> bool {
	return code.dark[y * code.size + x]
}

// The most bytes a symbol of `version` holds at `ecc` (byte mode).
byte_capacity :: proc(version: int, ecc: Ecc) -> int {
	count_bits := 8 if version <= 9 else 16
	return (data_codewords(version, ecc) * 8 - 4 - count_bits) / 8
}

// The code as one SVG: a light ground, and the dark modules as ONE path of horizontal runs (crisp at any zoom,
// and it prints). `border` is the quiet zone in modules - the standard asks for 4; a scanner wants it.
// `module_px` sets the width/height attributes (0 = leave the size to the page).
svg :: proc(code: Code, border := 4, module_px := 0, dark := "#000", light := "#fff", allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	side := code.size + 2 * border
	strings.write_string(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 `)
	strings.write_int(&b, side)
	strings.write_byte(&b, ' ')
	strings.write_int(&b, side)
	strings.write_byte(&b, '"')
	if module_px > 0 {
		strings.write_string(&b, ` width="`)
		strings.write_int(&b, side * module_px)
		strings.write_string(&b, `" height="`)
		strings.write_int(&b, side * module_px)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, ` shape-rendering="crispEdges"><rect width="100%" height="100%" fill="`)
	strings.write_string(&b, light)
	strings.write_string(&b, `"/><path fill="`)
	strings.write_string(&b, dark)
	strings.write_string(&b, `" d="`)
	for y in 0 ..< code.size {
		x := 0
		for x < code.size {
			if !is_dark(code, x, y) {
				x += 1
				continue
			}
			run := 1
			for x + run < code.size && is_dark(code, x + run, y) {
				run += 1
			}
			strings.write_byte(&b, 'M')
			strings.write_int(&b, x + border)
			strings.write_byte(&b, ' ')
			strings.write_int(&b, y + border)
			strings.write_byte(&b, 'h')
			strings.write_int(&b, run)
			strings.write_string(&b, "v1h-")
			strings.write_int(&b, run)
			strings.write_byte(&b, 'z')
			x += run
		}
	}
	strings.write_string(&b, `"/></svg>`)
	return strings.to_string(b)
}

// ---------------------------------------------------------------- capacity --

// The error-correction codewords in each block, by level and version (index 0 unused).
@(private, rodata)
ECC_CODEWORDS_PER_BLOCK := [Ecc][MAX_VERSION + 1]int {
	.L = {0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
	.M = {0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28},
	.Q = {0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
	.H = {0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
}

// The error-correction blocks the codewords are split into, by level and version.
@(private, rodata)
ECC_BLOCKS := [Ecc][MAX_VERSION + 1]int {
	.L = {0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25},
	.M = {0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49},
	.Q = {0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68},
	.H = {0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81},
}

// The modules left for codewords once the function patterns are drawn (the remainder bits included).
@(private)
raw_data_modules :: proc(version: int) -> int {
	result := (16 * version + 128) * version + 64
	if version >= 2 {
		aligns := version / 7 + 2
		result -= (25 * aligns - 10) * aligns - 55
		if version >= 7 {
			result -= 36 // the two version-information blocks
		}
	}
	return result
}

@(private)
data_codewords :: proc(version: int, ecc: Ecc) -> int {
	return raw_data_modules(version) / 8 - ECC_CODEWORDS_PER_BLOCK[ecc][version] * ECC_BLOCKS[ecc][version]
}

// Mode indicator + character count + the data.
@(private)
data_bits_needed :: proc(n_bytes, version: int) -> int {
	count_bits := 8 if version <= 9 else 16
	if n_bytes >= 1 << uint(count_bits) {
		return max(int)
	}
	return 4 + count_bits + 8 * n_bytes
}

// ------------------------------------------------------------- codewords --

// The data codewords: byte-mode segment, terminator, padding to the version's capacity.
@(private)
data_codewords_for :: proc(data: []u8, version: int, ecc: Ecc) -> []u8 {
	capacity := data_codewords(version, ecc)
	out := make([]u8, capacity, context.temp_allocator)
	bits := Bit_Writer{bytes = out}
	write_bits(&bits, 0b0100, 4)
	write_bits(&bits, len(data), 8 if version <= 9 else 16)
	for byte in data {
		write_bits(&bits, int(byte), 8)
	}
	write_bits(&bits, 0, min(4, capacity * 8 - bits.n)) // terminator
	bits.n = (bits.n + 7) / 8 * 8 // to a byte boundary (the buffer starts zeroed)
	for pad := u8(0xEC); bits.n < capacity * 8; pad = 0x11 if pad == 0xEC else 0xEC {
		out[bits.n / 8] = pad
		bits.n += 8
	}
	return out
}

@(private)
Bit_Writer :: struct {
	bytes: []u8,
	n:     int, // bits written
}

@(private)
write_bits :: proc(w: ^Bit_Writer, value, count: int) {
	for i := count - 1; i >= 0; i -= 1 {
		if (value >> uint(i)) & 1 != 0 {
			w.bytes[w.n / 8] |= 0x80 >> uint(w.n % 8)
		}
		w.n += 1
	}
}

// Splits the data into blocks, appends each block's Reed-Solomon codewords and interleaves them, as the
// standard lays them out: the data codewords column by column across the blocks, then the error-correction
// codewords the same way. The short blocks come first and are one data codeword shorter.
@(private)
add_ecc_and_interleave :: proc(data: []u8, version: int, ecc: Ecc) -> []u8 {
	blocks := ECC_BLOCKS[ecc][version]
	ecc_len := ECC_CODEWORDS_PER_BLOCK[ecc][version]
	raw := raw_data_modules(version) / 8
	short_blocks := blocks - raw % blocks
	short_len := raw / blocks // a short block's length, error correction included

	divisor := rs_divisor(ecc_len)
	result := make([]u8, raw, context.temp_allocator)
	remainder := make([]u8, ecc_len, context.temp_allocator)
	k := 0
	for i in 0 ..< blocks {
		data_len := short_len - ecc_len + (0 if i < short_blocks else 1)
		block := data[k:][:data_len]
		rs_remainder(block, divisor, remainder)
		// data codeword j of block i: after j full columns (every block has the first short_len - ecc_len
		// codewords; only the long blocks have the last one)
		for j in 0 ..< data_len {
			at := j * blocks + i
			if j == short_len - ecc_len {
				at = j * blocks + (i - short_blocks)
			}
			result[at] = block[j]
		}
		for j in 0 ..< ecc_len {
			result[len(data) + j * blocks + i] = remainder[j]
		}
		k += data_len
	}
	return result
}

// The generator polynomial of degree `degree`, highest coefficient first and the leading 1 dropped.
@(private)
rs_divisor :: proc(degree: int) -> []u8 {
	result := make([]u8, degree, context.temp_allocator)
	result[degree - 1] = 1
	root := u8(1)
	for _ in 0 ..< degree {
		for j in 0 ..< degree {
			result[j] = gf_mul(result[j], root)
			if j + 1 < degree {
				result[j] ~= result[j + 1]
			}
		}
		root = gf_mul(root, 0x02)
	}
	return result
}

@(private)
rs_remainder :: proc(data, divisor, out: []u8) {
	for &b in out {
		b = 0
	}
	for b in data {
		factor := b ~ out[0]
		copy(out, out[1:])
		out[len(out) - 1] = 0
		for &r, i in out {
			r ~= gf_mul(divisor[i], factor)
		}
	}
}

// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
@(private)
gf_mul :: proc(x, y: u8) -> u8 {
	z := 0
	for i := 7; i >= 0; i -= 1 {
		z = (z << 1) ~ ((z >> 7) * 0x11D)
		z ~= int((y >> uint(i)) & 1) * int(x)
	}
	return u8(z)
}

// ---------------------------------------------------------------- matrix --

@(private)
Matrix :: struct {
	size:     int,
	dark:     []bool,
	function: []bool, // drawn by a function pattern: no data here, and the mask leaves it alone
}

@(private)
set_function :: proc(m: Matrix, x, y: int, dark: bool) {
	m.dark[y * m.size + x] = dark
	m.function[y * m.size + x] = true
}

@(private)
draw_function_patterns :: proc(m: Matrix, version: int) {
	for i in 0 ..< m.size {
		set_function(m, 6, i, i % 2 == 0)
		set_function(m, i, 6, i % 2 == 0)
	}
	draw_finder(m, 3, 3)
	draw_finder(m, m.size - 4, 3)
	draw_finder(m, 3, m.size - 4)

	positions: [7]int
	aligns := alignment_positions(version, positions[:])
	for i in 0 ..< aligns {
		for j in 0 ..< aligns {
			corner := (i == 0 && j == 0) || (i == 0 && j == aligns - 1) || (i == aligns - 1 && j == 0)
			if !corner {
				draw_alignment(m, positions[i], positions[j])
			}
		}
	}
	draw_format_bits(m, .L, 0) // reserves the area; the real bits are drawn once the mask is chosen
	draw_version_bits(m, version)
}

// The centres of the alignment patterns on each axis.
@(private)
alignment_positions :: proc(version: int, out: []int) -> int {
	if version == 1 {
		return 0
	}
	n := version / 7 + 2
	step := (version * 8 + n * 3 + 5) / (n * 4 - 4) * 2
	out[0] = 6
	pos := version * 4 + 17 - 7
	for i := n - 1; i >= 1; i -= 1 {
		out[i] = pos
		pos -= step
	}
	return n
}

@(private)
draw_finder :: proc(m: Matrix, cx, cy: int) {
	for dy in -4 ..= 4 {
		for dx in -4 ..= 4 {
			x, y := cx + dx, cy + dy
			if 0 <= x && x < m.size && 0 <= y && y < m.size {
				dist := max(abs(dx), abs(dy)) // Chebyshev: rings 2 and 4 are light (4 = the separator)
				set_function(m, x, y, dist != 2 && dist != 4)
			}
		}
	}
}

@(private)
draw_alignment :: proc(m: Matrix, cx, cy: int) {
	for dy in -2 ..= 2 {
		for dx in -2 ..= 2 {
			set_function(m, cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)
		}
	}
}

// The 15-bit format information (level + mask, BCH-protected), twice, plus the always-dark module.
@(private)
draw_format_bits :: proc(m: Matrix, ecc: Ecc, mask: int) {
	@(static, rodata) LEVEL_BITS := [Ecc]int {
		.L = 1,
		.M = 0,
		.Q = 3,
		.H = 2,
	}
	data := LEVEL_BITS[ecc] << 3 | mask
	rem := data
	for _ in 0 ..< 10 {
		rem = (rem << 1) ~ ((rem >> 9) * 0x537)
	}
	bits := (data << 10 | rem) ~ 0x5412
	bit :: proc(bits, i: int) -> bool {return (bits >> uint(i)) & 1 != 0}

	// around the top-left finder
	for i in 0 ..= 5 {
		set_function(m, 8, i, bit(bits, i))
	}
	set_function(m, 8, 7, bit(bits, 6))
	set_function(m, 8, 8, bit(bits, 7))
	set_function(m, 7, 8, bit(bits, 8))
	for i in 9 ..< 15 {
		set_function(m, 14 - i, 8, bit(bits, i))
	}
	// split between the other two finders
	for i in 0 ..< 8 {
		set_function(m, m.size - 1 - i, 8, bit(bits, i))
	}
	for i in 8 ..< 15 {
		set_function(m, 8, m.size - 15 + i, bit(bits, i))
	}
	set_function(m, 8, m.size - 8, true)
}

// From version 7: the version number (Golay-protected) in two 6x3 blocks.
@(private)
draw_version_bits :: proc(m: Matrix, version: int) {
	if version < 7 {
		return
	}
	rem := version
	for _ in 0 ..< 12 {
		rem = (rem << 1) ~ ((rem >> 11) * 0x1F25)
	}
	bits := version << 12 | rem
	for i in 0 ..< 18 {
		dark := (bits >> uint(i)) & 1 != 0
		a, b := m.size - 11 + i % 3, i / 3
		set_function(m, a, b, dark)
		set_function(m, b, a, dark)
	}
}

// The codewords in the zigzag: two-module columns from the right, alternately upwards and downwards, skipping
// the vertical timing column and every function module. Remainder bits stay light.
@(private)
draw_codewords :: proc(m: Matrix, codewords: []u8) {
	i := 0
	for right := m.size - 1; right >= 1; right -= 2 {
		if right == 6 {
			right = 5
		}
		upward := (right + 1) & 2 == 0
		for vert in 0 ..< m.size {
			y := m.size - 1 - vert if upward else vert
			for j in 0 ..< 2 {
				x := right - j
				if !m.function[y * m.size + x] && i < len(codewords) * 8 {
					m.dark[y * m.size + x] = (codewords[i >> 3] >> uint(7 - (i & 7))) & 1 != 0
					i += 1
				}
			}
		}
	}
}

@(private)
apply_mask :: proc(m: Matrix, mask: int) {
	for y in 0 ..< m.size {
		for x in 0 ..< m.size {
			invert: bool
			switch mask {
			case 0:
				invert = (x + y) % 2 == 0
			case 1:
				invert = y % 2 == 0
			case 2:
				invert = x % 3 == 0
			case 3:
				invert = (x + y) % 3 == 0
			case 4:
				invert = (x / 3 + y / 2) % 2 == 0
			case 5:
				invert = x * y % 2 + x * y % 3 == 0
			case 6:
				invert = (x * y % 2 + x * y % 3) % 2 == 0
			case 7:
				invert = ((x + y) % 2 + x * y % 3) % 2 == 0
			}
			if invert && !m.function[y * m.size + x] {
				m.dark[y * m.size + x] = !m.dark[y * m.size + x]
			}
		}
	}
}

// ---------------------------------------------------------------- penalty --

// The standard's mask evaluation: lower is better.
//   N1  a run of 5+ same-coloured modules in a row or column: 3, plus 1 per module beyond 5
//   N2  each 2x2 block of one colour: 3
//   N3  a finder-like n:n:3n:n:n dark-light-dark-light-dark run with 4n light on one side, in a row or
//       column, the area outside the symbol counting as light (it is: the quiet zone): 40
//   N4  the dark proportion's distance from 50%, in whole 5% steps: 10 each
// Any mask makes a valid code; this is the reference encoder's reading (qrcodegen's run-length form of N3,
// which counts the scaled patterns too), so the choice matches it.
@(private)
penalty :: proc(m: Matrix) -> int {
	n := m.size
	// line `a`, position `b`: a row when horizontal, else a column
	cell :: proc(m: Matrix, horizontal: bool, a, b: int) -> bool {
		return m.dark[a * m.size + b] if horizontal else m.dark[b * m.size + a]
	}
	score := 0
	for horizontal in ([2]bool{true, false}) {
		for a in 0 ..< n {
			colour := false
			run := 0
			history: Run_History
			for b in 0 ..< n {
				if cell(m, horizontal, a, b) == colour {
					run += 1
					if run == 5 {
						score += 3
					} else if run > 5 {
						score += 1
					}
				} else {
					add_run(&history, run, n)
					if !colour {
						score += finder_like(history) * 40
					}
					colour = !colour
					run = 1
				}
			}
			// close the line: a dark run ends, then the light quiet zone
			if colour {
				add_run(&history, run, n)
				run = 0
			}
			add_run(&history, run + n, n)
			score += finder_like(history) * 40
		}
	}
	for y in 0 ..< n - 1 {
		for x in 0 ..< n - 1 {
			d := m.dark[y * n + x]
			if d == m.dark[y * n + x + 1] && d == m.dark[(y + 1) * n + x] && d == m.dark[(y + 1) * n + x + 1] {
				score += 3
			}
		}
	}
	dark := 0
	for d in m.dark {
		dark += 1 if d else 0
	}
	total := n * n
	k := (abs(dark * 20 - total * 10) + total - 1) / total - 1
	score += k * 10
	return score
}

// The last seven run lengths in a line, newest first; runs alternate light/dark, starting light.
@(private)
Run_History :: [7]int

@(private)
add_run :: proc(history: ^Run_History, length, size: int) {
	length := length
	if history[0] == 0 {
		length += size // the line's first run: the quiet zone before it is light
	}
	copy(history[1:], history[:6])
	history[0] = length
}

// After a light run: whether the last five runs before it are n:n:3n:n:n, with 4n light on either side.
@(private)
finder_like :: proc(h: Run_History) -> int {
	n := h[1]
	core := n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n
	return int(core && h[0] >= n * 4 && h[6] >= n) + int(core && h[6] >= n * 4 && h[0] >= n)
}
