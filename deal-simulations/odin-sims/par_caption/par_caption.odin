// The PAR CAPTION a card page shows under a board ("Par: NS 420 [4♠ NS] — NS make: 4♠ 3NT ..."), written from
// the solver's NUMBERS rather than by the solver: a double-dummy trick table and a structured par result.
//
// It was part of `deal_solve`, typed in DDS's own structs, and that is what kept it out of the shared-deals
// player: the DDS bindings import the C library at package level, so anything typed in them cannot build for
// wasm. With the writing here and the solving there (`deal_solve.annotate` converts DDS's results into these
// types), a link can carry the numbers and the player writes the very same caption - `share` holds the two to
// byte-identical output.
//
// The enums mirror DDS's orders exactly (the conversion in `deal_solve` is a value cast), and those orders are
// load-bearing: the trick-table comment is written in `Strain` x `Hand` order, and the makeable list is sorted
// from `Strain` order with an unstable sort, so a different order would reorder equal-scoring contracts.
package par_caption

import "core:encoding/base64"
import "core:fmt"
import "core:slice"
import "core:strings"
import "norn:norn"

// A double-dummy strain, in DDS's `Strain` order.
Strain :: enum {
	Spades,
	Hearts,
	Diamonds,
	Clubs,
	NT,
}

// A declarer, in DDS's `Hand` order.
Hand :: enum {
	North,
	East,
	South,
	West,
}

// A par contract's denomination, in DDS's `Contract_Denom` order (NT first - not `Strain`'s order).
Denom :: enum {
	NT,
	Spades,
	Hearts,
	Diamonds,
	Clubs,
}

// Who declares a par contract, in DDS's `Seat` order: one hand, or either hand of a partnership.
Seats :: enum {
	N,
	E,
	S,
	W,
	NS,
	EW,
}

// Tricks each declarer takes in each strain, double dummy.
Tricks :: [Strain][Hand]int

// One par contract. `under_tricks > 0` is a doubled sacrifice; otherwise it makes, with `over_tricks`.
Contract :: struct {
	under_tricks: int,
	over_tricks:  int,
	level:        int,
	denom:        Denom,
	seats:        Seats,
}

// A side's par: its score (N/S's view) and the contracts that score it.
Par :: struct {
	score:     int,
	number:    int,
	contracts: [10]Contract,
}

// Everything a board's caption is written from. `have` is false when the solver gave no par result.
Board_Par :: struct {
	tricks: Tricks,
	par:    Par,
	have:   bool,
}

// The caption in a page, after the board it is about: a card page's `.par` div (tagged with N/S's par trick
// count, `data-target`, which the card page's CCA slider starts at) or a handviewer page's inline-styled one,
// then the whole trick table as a comment. `have` is false when there is no par (the solver failed it).
write_html_caption :: proc(
	builder: ^strings.Builder,
	tricks: ^Tricks,
	par: ^Par,
	have: bool,
	ds: norn.Deal_Summary,
	cards: bool,
) {
	// The two HTML formats wrap it differently: the iframe `Html_Handviewer` tucks the caption under the
	// iframe above with a negative top margin (inline-styled so norn's page CSS needs no change); the
	// `Html_Cards` carousel gives each caption a `.par` class its script pairs with the deal above and its
	// stylesheet already positions.
	if !cards {
		strings.write_string(
			builder,
			`<div style="max-width:900px;margin:-3.5rem auto 0;text-align:center;color:#555;font-size:0.9rem">`,
		)
	} else {
		// And the numbers themselves (`pack`, base64url): a shared link carries them, so the reader's page
		// can write this same caption without a solver.
		fmt.sbprintf(builder, `<div class="par" data-target="%d" data-par="`, target_tricks(par, have, tricks))
		bytes := make([dynamic]u8, 0, 32, context.temp_allocator)
		pack(&bytes, {tricks = tricks^, par = par^, have = have})
		strings.write_string(
			builder,
			base64.encode(bytes[:], base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding}),
		)
		strings.write_string(builder, `">`)
	}
	strings.write_string(builder, "Par: ")
	write_par(builder, par, have, glyphs = true)
	strings.write_string(builder, " &mdash; NS make:")
	write_makeable(builder, tricks, glyphs = true)
	write_par_opc_guide(builder, par, have, ds, " &middot; ", true)
	strings.write_string(builder, "</div>")
	// Machine-readable form: full trick table as a comment (strain x N/E/S/W).
	strings.write_string(builder, "<!-- deal_solve tricks[strain]NESW")
	for strain in Strain {
		fmt.sbprintf(builder, " %s:", strain_label(strain))
		for hand in Hand {
			fmt.sbprintf(builder, "%d/", tricks[strain][hand])
		}
	}
	strings.write_string(builder, " -->")
}

// A contract to preselect in the card page's picker: the one the board's record names.
Named_Contract :: struct {
	level:  int,
	strain: Strain,
}

// The EXACT double-dummy grid for a whole deal - the `data-sim` of the card page's `.sim-exact` element, which
// turns its contract picker and trick slider into a live double-dummy explorer:
//   {"n":1,"exact":true,"lvl":4,"strain":"s","ns":{"s":[p0..p13],"h":..,"d":..,"c":..,"nt":..},"ew":{..}}
// Each side's distribution is a single spike at its double-dummy tricks (the better of its two declarers), n=1:
// the deal is known, so there is nothing to sample. `lvl`/`strain` preselect the named contract, else N/S's
// best-making one (most tricks; the first strain in `Strain` order on a tie, NT when N/S make nothing).
//
// Here and not in `deal_solve` for the same reason as the caption: it is written from the trick table alone,
// so the shared-deals player, which solves the table in the reader's browser, writes the same element.
write_exact_sim :: proc(builder: ^strings.Builder, tricks: ^Tricks, named: Maybe(Named_Contract) = nil) {
	side_tricks :: proc(tricks: ^Tricks, strain: Strain, a, b: Hand) -> int {
		return clamp(max(tricks[strain][a], tricks[strain][b]), 0, 13)
	}
	best_strain := Strain.NT
	best_tricks := 0
	for strain in Strain {
		if k := side_tricks(tricks, strain, .North, .South); k > best_tricks {
			best_tricks = k
			best_strain = strain
		}
	}
	level, strain := clamp(best_tricks - 6, 1, 7), best_strain
	if n, ok := named.?; ok {
		level, strain = n.level, n.strain
	}
	strings.write_byte(builder, '{')
	fmt.sbprintf(builder, `"n":1,"exact":true,"lvl":%d,"strain":"%s"`, level, exact_key(strain))
	sides := [2]struct {
		key:  string,
		a, b: Hand,
	}{{"ns", .North, .South}, {"ew", .East, .West}}
	for side in sides {
		fmt.sbprintf(builder, `,"%s":`, side.key)
		strings.write_byte(builder, '{')
		order := [5]Strain{.Spades, .Hearts, .Diamonds, .Clubs, .NT}
		for s, i in order {
			if i > 0 {
				strings.write_byte(builder, ',')
			}
			fmt.sbprintf(builder, `"%s":[`, exact_key(s))
			spike := side_tricks(tricks, s, side.a, side.b)
			for k in 0 ..< 14 {
				if k > 0 {
					strings.write_byte(builder, ',')
				}
				strings.write_string(builder, "1.0000" if k == spike else "0.0000")
			}
			strings.write_byte(builder, ']')
		}
		strings.write_byte(builder, '}')
	}
	strings.write_byte(builder, '}')
}

// The card page's lowercase key for a strain.
@(private)
exact_key :: proc(s: Strain) -> string {
	switch s {
	case .Spades:
		return "s"
	case .Hearts:
		return "h"
	case .Diamonds:
		return "d"
	case .Clubs:
		return "c"
	case .NT:
		return "nt"
	}
	return "nt"
}

// The trick count NS's par contract needs — the natural DEFAULT target for the card page's per-deal
// combo (CCA) slider. Prefer a MAKING par contract that NS declares (its `level + 6` tricks; the
// highest if several qualify). When par is an EW contract (e.g. a doubled sacrifice against NS's game,
// so `sides[NS]` lists the EW contract), fall back to NS's best MAKEABLE strain — the contract EW is
// sacrificing over, i.e. the tricks NS would take. Clamped to 1..13; 9 (3NT/game) if all else fails.
target_tricks :: proc(m: ^Par, have: bool, tricks: ^Tricks) -> int {
	best := 0
	if have {
		for i in 0 ..< m.number {
			c := m.contracts[i]
			if c.under_tricks > 0 {
				continue // a sacrifice: not a making NS contract
			}
			#partial switch c.seats {
			case .N, .S, .NS:
				if t := c.level + 6; t > best {
					best = t
				}
			}
		}
	}
	if best == 0 {
		// No NS-declared making par contract: use NS's best makeable strain (max N/S declarer tricks).
		for strain in Strain {
			if t := max(tricks[strain][.North], tricks[strain][.South]); t > best {
				best = t
			}
		}
	}
	if best < 1 {
		return 9
	}
	return clamp(best, 1, 13)
}

// One makeable contract: the highest level NS can make in a strain (level = the better of N/S
// declarer tricks minus the 6-trick book), tagged with its bridge score for ranking.
@(private)
Makeable_Contract :: struct {
	strain: Strain,
	level:  int,
	score:  int,
}

// Write the contracts NS can make double-dummy as " <level><strain>" tokens, ordered BEST-SCORING
// first (6NT before 6S before 6C before 1H, etc.); "nothing" if none reach the 1-level.
write_makeable :: proc(builder: ^strings.Builder, tricks: ^Tricks, glyphs := false) {
	list: [len(Strain)]Makeable_Contract
	n := 0
	for strain in Strain {
		best := max(tricks[strain][.North], tricks[strain][.South])
		if best >= 7 { 	// 7 tricks = a 1-level contract; below that there is nothing to make
			level := best - 6
			list[n] = Makeable_Contract{strain, level, contract_score(strain, level)}
			n += 1
		}
	}
	if n == 0 {
		strings.write_string(builder, " nothing")
		return
	}
	// Best score first. n <= 5, so the sort is trivial; ties (e.g. 6H vs 6S, same score) keep an
	// arbitrary-but-deterministic order, which is fine — they are genuinely equal.
	slice.sort_by(list[:n], proc(a, b: Makeable_Contract) -> bool {return a.score > b.score})
	for m in list[:n] {
		fmt.sbprintf(builder, " %d", m.level)
		write_strain(builder, strain_label(m.strain), glyphs)
	}
}

// Duplicate-bridge score for making `level` (bid = tricks - 6, made exactly) in `strain`, NOT
// vulnerable and undoubled — matching the neutral vulnerability the par call uses. Only ever compared
// against other contracts to ORDER the makeable list, so the absolute value need not be authoritative
// (overtricks, doubling, vulnerability are irrelevant to the ranking of max-level makeables).
contract_score :: proc(strain: Strain, level: int) -> int {
	trick_pts: int
	switch strain {
	case .Clubs, .Diamonds:
		trick_pts = level * 20
	case .Hearts, .Spades:
		trick_pts = level * 30
	case .NT:
		trick_pts = 40 + (level - 1) * 30
	}
	bonus := 300 if trick_pts >= 100 else 50 // game vs part-score (not vulnerable)
	if level == 7 {
		bonus += 1000 // grand slam (not vulnerable)
	} else if level == 6 {
		bonus += 500 // small slam (not vulnerable)
	}
	return trick_pts + bonus
}

// Short label for a strain (suit letter, or NT), used in the caption and the trick-table comment.
strain_label :: proc(strain: Strain) -> string {
	switch strain {
	case .Spades:
		return "S"
	case .Hearts:
		return "H"
	case .Diamonds:
		return "D"
	case .Clubs:
		return "C"
	case .NT:
		return "NT"
	}
	return "?"
}

// OPC "trick conversion" reference (docs: optimal_point_count.py TRICK_CONVERSIONS): for a contract
// level and strain type, the three combined-partnership Optimal-Point-Count totals at which it makes
// with a roughly ~40-45% / ~50-55% / ~60%+ chance (the slam and grand rows use higher success bands).
// Thresholds are indexed by level; only 2..7 are populated (a level-1 contract is off the table). A
// "+"-capped top threshold (levels 6/7) is stored as a large sentinel. `opc_make_band` reads these to
// turn a combined total into one success band.
OPC_LEVELS_MIN :: 2
OPC_LEVELS_MAX :: 7
OPC_TOP :: 99 // stand-in for the table's open-ended "+" top threshold

@(private)
OPC_NT_THRESHOLDS := [8][3]int {
	2 = {22, 23, 24},
	3 = {25, 26, 27},
	4 = {28, 29, 30},
	5 = {31, 32, 33},
	6 = {33, 34, 35},
	7 = {36, 37, OPC_TOP},
}
@(private)
OPC_SUIT_THRESHOLDS := [8][3]int {
	2 = {20, 21, 22},
	3 = {23, 24, 25},
	4 = {26, 27, 28},
	5 = {29, 30, 31},
	6 = {32, 33, 34},
	7 = {35, 36, OPC_TOP},
}
@(private)
OPC_SUCCESS_BANDS := [8][3]string {
	2 = {"~40-45%", "~50-55%", "~60%+"},
	3 = {"~40-45%", "~50-55%", "~60%+"},
	4 = {"~40-45%", "~50-55%", "~60%+"},
	5 = {"~40-45%", "~50-55%", "~60%+"},
	6 = {"~50%", "~55-60%", "~65%+"},
	7 = {"~70%", "~70-75%", "~75%+"},
}
// The success band for a combined OPC total `x` at `level`/strain: which of the level's three
// thresholds `x` reaches (top band at/above the third). Below the FIRST (lowest listed) threshold the
// table gives no figure — the contract is well against the odds on points — so we say "LOW" rather
// than extrapolate a bogus percentage. `level` is assumed in OPC_LEVELS_MIN..MAX.
@(private)
opc_make_band :: proc(x: f32, level: int, is_nt: bool) -> string {
	t := OPC_NT_THRESHOLDS[level] if is_nt else OPC_SUIT_THRESHOLDS[level]
	bands := OPC_SUCCESS_BANDS[level]
	switch {
	case x >= f32(t[2]):
		return bands[2]
	case x >= f32(t[1]):
		return bands[1]
	case x >= f32(t[0]):
		return bands[0]
	}
	return "LOW"
}

// Append the par contract's OPC make-estimate after `sep` (written once, before the first entry;
// further entries joined with "; "). One entry per distinct (level, strain-type) among the MAKING par
// contracts — a doubled sacrifice (under_tricks > 0) has no "make" chance and a level-1 par is off the
// table, so both are skipped, and identical contracts (e.g. par 4S and 4H) are de-duplicated. Each
// entry reads `OPC total (naive) = X; make chance Y`, where X is the declaring side's combined OPC and
// Y its success band from the reference table (or "LOW" when X is under the level's lowest threshold).
//
// X is the declaring side's true partnership OPC (norn `combined_opc`): the stronger hand opens, the
// weaker responds with a capped base, then fit / misfit / semi-fit / wasted-honour / mirror adjustments
// are applied over both hands, keyed by the par contract's strain. Writes nothing (and no `sep`) when
// no par contract qualifies.
write_par_opc_guide :: proc(
	builder: ^strings.Builder,
	m: ^Par,
	have: bool,
	ds: norn.Deal_Summary,
	sep: string,
	html: bool,
) {
	if !have {
		return
	}
	shown: [8][2]bool // [level][is_nt] already-emitted marker; levels 1..7, two strain types
	wrote := false
	for i in 0 ..< m.number {
		c := m.contracts[i]
		if c.under_tricks > 0 {
			continue // doubled sacrifice: nothing to "make"
		}
		level := c.level
		if level < OPC_LEVELS_MIN || level > OPC_LEVELS_MAX {
			continue
		}
		is_nt := c.denom == .NT
		ti := 1 if is_nt else 0
		if shown[level][ti] {
			continue
		}
		side, ok := declaring_pair(c.seats)
		if !ok {
			continue // no side -> can't state a combined total
		}
		shown[level][ti] = true
		br := norn.combined_opc_breakdown(ds[side[0]], ds[side[1]], denom_trump(c.denom))
		band := opc_make_band(br.total, level, is_nt)
		strings.write_string(builder, "; " if wrote else sep)
		strings.write_string(builder, "OPC total = ")
		// In HTML the figure is a dotted-underlined <abbr>: hovering shows the per-adjustment breakdown
		// (opener/responder bases plus each fit / misfit / honour / ruffing / mirror term). Plain text
		// formats (Pretty/Pbn) just print the number.
		if html {
			strings.write_string(builder, `<abbr style="text-decoration:underline dotted;cursor:help" title="`)
			write_opc_breakdown_title(builder, br)
			fmt.sbprintf(builder, `">%.1f</abbr>`, br.total)
		} else {
			fmt.sbprintf(builder, "%.1f", br.total)
		}
		fmt.sbprintf(builder, "; make chance %s", band)
		wrote = true
	}
}

// The hover-tooltip text for an OPC breakdown — the full reference render_summary detail, one item per
// line (title-attribute newlines render as tooltip line breaks). The two bases show their H/L/D split,
// then every labelled adjustment entry ("<suit> <signed value> <reason>"), closing with the total:
//
//   opener 19.5 = H 12.0 + L 4.0 + D 3.5
//   responder 12.0 = H 10.0 + L 2.0 + D 0.0
//   S -2.0 singleton opp long
//   H +1.0 Kx/Qx/Jx/JT opp long
//   ... = 25.5
//
// Suit glyphs (norn.suit_glyph) are UTF-8; the card pages declare <meta charset=utf-8>, so they render
// in the native tooltip. The whole-hand mirror entry has no suit.
@(private)
write_opc_breakdown_title :: proc(builder: ^strings.Builder, br: norn.Opc_Breakdown) {
	fmt.sbprintf(
		builder,
		"opener %.1f = H %.1f + L %.1f + D %.1f",
		br.opener_base,
		br.opener_h,
		br.opener_l,
		br.opener_d,
	)
	fmt.sbprintf(
		builder,
		"\nresponder %.1f = H %.1f + L %.1f + D %.1f",
		br.responder_base,
		br.responder_h,
		br.responder_l,
		br.responder_d,
	)
	for i in 0 ..< br.n_entries {
		e := br.entries[i]
		strings.write_string(builder, "\n")
		if e.has_suit {
			strings.write_string(builder, norn.suit_glyph(e.suit))
			strings.write_string(builder, " ")
		}
		fmt.sbprintf(builder, "%+.1f %s", e.value, opc_entry_phrase(e))
	}
	fmt.sbprintf(builder, "\n= %.1f", br.total)
}

// The reason phrase for a breakdown entry — norn's reason text, except a fit is narrated by its combined
// length (value 1/2/3 -> 8/9/10+ -card fit) which the flat reason label cannot carry.
@(private)
opc_entry_phrase :: proc(e: norn.Opc_Entry) -> string {
	if e.reason == .Fit {
		switch e.value {
		case 1:
			return "8-card fit"
		case 2:
			return "9-card fit"
		case:
			return "10+card fit"
		}
	}
	return norn.opc_reason_text(e.reason)
}

// The two partners declaring a par contract, from its seat field: a single declarer or a partnership
// both resolve to the N/S or E/W pair. ok=false should never happen (every contract has a side).
@(private)
declaring_pair :: proc(s: Seats) -> (pair: [2]norn.Seat, ok: bool) {
	switch s {
	case .N, .S, .NS:
		return {.North, .South}, true
	case .E, .W, .EW:
		return {.East, .West}, true
	}
	return {}, false
}

// The trump suit for `combined_opc` from a par contract's denomination: the matching norn suit, or nil
// for notrump (its shortage handling differs). NB `Denom` and norn.Suit are distinct enums.
@(private)
denom_trump :: proc(d: Denom) -> Maybe(norn.Suit) {
	#partial switch d {
	case .Spades:
		return norn.Suit.Spades
	case .Hearts:
		return norn.Suit.Hearts
	case .Diamonds:
		return norn.Suit.Diamonds
	case .Clubs:
		return norn.Suit.Clubs
	}
	return nil // NT
}

// Write one side's par: the NS-view score plus its par contract(s). `have` is false when the solver
// could not give one, in which case we emit "n/a" rather than garbage.
write_par :: proc(builder: ^strings.Builder, m: ^Par, have: bool, glyphs := false) {
	if !have {
		strings.write_string(builder, "n/a")
		return
	}
	fmt.sbprintf(builder, "NS %d", m.score)
	for i in 0 ..< m.number {
		if i == 0 {
			strings.write_string(builder, " [")
		} else {
			strings.write_string(builder, ", ")
		}
		write_contract(builder, m.contracts[i], glyphs)
	}
	if m.number > 0 {
		strings.write_string(builder, "]")
	}
}

// Write a structured par contract, e.g. "4S NS", "3NT NS+1", "5Cx EW-2". A doubled sacrifice (par
// only ever doubles a non-making contract) is flagged by `under_tricks > 0`: append "x" and the
// undertricks; a making contract shows its overtricks (if any) instead.
@(private)
write_contract :: proc(builder: ^strings.Builder, c: Contract, glyphs := false) {
	fmt.sbprintf(builder, "%d", c.level)
	write_strain(builder, denom_label(c.denom), glyphs)
	if c.under_tricks > 0 {
		strings.write_string(builder, "x") // doubled sacrifice
	}
	fmt.sbprintf(builder, " %s", seats_label(c.seats))
	if c.under_tricks > 0 {
		fmt.sbprintf(builder, "-%d", c.under_tricks)
	} else if c.over_tricks > 0 {
		fmt.sbprintf(builder, "+%d", c.over_tricks)
	}
}

// A strain as the caption writes it: the letter (S H D C NT) in text, and in a page a suit's GLYPH, in the
// card page's suit colour (`.ssym.s` etc.) - `4♠`, `3NT`.
@(private)
write_strain :: proc(builder: ^strings.Builder, letter: string, glyphs: bool) {
	if !glyphs || letter == "NT" {
		strings.write_string(builder, letter)
		return
	}
	entity := "&spades;"
	switch letter {
	case "H":
		entity = "&hearts;"
	case "D":
		entity = "&diams;"
	case "C":
		entity = "&clubs;"
	}
	fmt.sbprintf(builder, `<span class="ssym %s">%s</span>`, strings.to_lower(letter, context.temp_allocator), entity)
}

// `Denom` label. NB its ordering differs from `Strain` (NT is 0 here), hence a separate map.
@(private)
denom_label :: proc(d: Denom) -> string {
	switch d {
	case .NT:
		return "NT"
	case .Spades:
		return "S"
	case .Hearts:
		return "H"
	case .Diamonds:
		return "D"
	case .Clubs:
		return "C"
	}
	return "?"
}

// Declaring seat(s) of a par contract (a single hand or a partnership).
@(private)
seats_label :: proc(s: Seats) -> string {
	switch s {
	case .N:
		return "N"
	case .E:
		return "E"
	case .S:
		return "S"
	case .W:
		return "W"
	case .NS:
		return "NS"
	case .EW:
		return "EW"
	}
	return "?"
}

// A board's par as bytes, for a link (`share`) and the caption's `data-par`:
//
//	10 bytes   the trick table, 20 four-bit counts in `Strain` x `Hand` order, low nibble first
//	1 byte     bit 7 there is a par result, bits 0-3 how many contracts; if there is one:
//	2 bytes    the score (N/S's view), little-endian, signed
//	3 bytes    each contract: level | denom << 3, seats | overtricks << 3, undertricks
//
// About 16 bytes for the usual one-contract par.
pack :: proc(out: ^[dynamic]u8, board: Board_Par) {
	tricks: [10]u8
	i := 0
	for strain in Strain {
		for hand in Hand {
			tricks[i / 2] |= u8(board.tricks[strain][hand] & 15) << uint((i % 2) * 4)
			i += 1
		}
	}
	append(out, ..tricks[:])
	if !board.have {
		append(out, 0)
		return
	}
	number := clamp(board.par.number, 0, len(board.par.contracts))
	append(out, 0x80 | u8(number))
	score := u16(i16(board.par.score))
	append(out, u8(score & 0xFF), u8(score >> 8))
	contracts := board.par.contracts
	for c in contracts[:number] {
		append(
			out,
			u8(c.level & 7) | u8(c.denom) << 3,
			u8(c.seats) | u8(c.over_tricks & 15) << 3,
			u8(c.under_tricks & 15),
		)
	}
}

Unpack_Error :: enum {
	None,
	Truncated,
	Bad, // a value `pack` never writes
}

// One `pack`ed par from the front of `bytes`, and how many bytes it took.
unpack :: proc(bytes: []u8) -> (board: Board_Par, used: int, err: Unpack_Error) {
	if len(bytes) < 11 {
		return {}, 0, .Truncated
	}
	i := 0
	for strain in Strain {
		for hand in Hand {
			n := int(bytes[i / 2] >> uint((i % 2) * 4)) & 15
			if n > 13 {
				return {}, 0, .Bad
			}
			board.tricks[strain][hand] = n
			i += 1
		}
	}
	head := bytes[10]
	used = 11
	if head & 0x80 == 0 {
		if head != 0 {
			return {}, 0, .Bad
		}
		return board, used, .None
	}
	number := int(head & 0x0F)
	if head & 0x70 != 0 || number > len(board.par.contracts) {
		return {}, 0, .Bad
	}
	if len(bytes) < used + 2 + number * 3 {
		return {}, 0, .Truncated
	}
	board.have = true
	board.par.score = int(i16(u16(bytes[used]) | u16(bytes[used + 1]) << 8))
	board.par.number = number
	used += 2
	for k in 0 ..< number {
		a, b, c := bytes[used], bytes[used + 1], bytes[used + 2]
		denom, seats := int(a >> 3), int(b & 7)
		if denom >= len(Denom) || seats >= len(Seats) || a & 7 == 0 {
			return {}, 0, .Bad
		}
		board.par.contracts[k] = {
			level        = int(a & 7),
			denom        = Denom(denom),
			seats        = Seats(seats),
			over_tricks  = int(b >> 3),
			under_tricks = int(c),
		}
		used += 3
	}
	return board, used, .None
}
