package analyse

/*
	analyse_test.odin — the reader, the argument surface and the report, asserted.

	None of this could be tested before: it lived in a single-file `package main`, which `odin test`
	cannot build. These cover the parts that have no solver in them — the four input formats, the
	seat/suit/card specs, and that the text report actually reaches the writer it was handed. The
	DDS-backed paths (sampling, tax, exact grids) are covered in `deal_solve`'s own tests and by the
	`test-golden` recipe, which diffs the real program's `data-sim` bake.
*/

import "core:strings"
import "core:testing"

import "norn:norn"

// A two-hand advisor board: declarer + dummy known, both defenders written `-`. The same board the
// golden test and deal_solve's tax tests use, so a change in the reader shows up as one story.
TWO_HAND :: `[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`

@(test)
test_resolve_pbn_tag :: proc(t: ^testing.T) {
	boards, err := resolve_boards(TWO_HAND)
	defer delete(boards)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(boards), 1)
	testing.expect_value(t, boards[0].known, bit_set[norn.Seat]{.North, .South})
}

// No `[Deal "` tag at all: the whole input is one bare `N:...` value.
@(test)
test_resolve_bare_pbn_value :: proc(t: ^testing.T) {
	boards, err := resolve_boards("N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -")
	defer delete(boards)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(boards), 1)
	testing.expect_value(t, boards[0].known, bit_set[norn.Seat]{.North, .South})
}

// Several `[Deal]` tags — a hand-ocr session or a .pbn file — become several boards, and the OTHER PBN
// tags that share the `[Deal` prefix (`[Dealer]`, `[Declarer]`) must not be mistaken for deals.
@(test)
test_resolve_multiple_boards_ignores_dealer_tags :: proc(t: ^testing.T) {
	text := `[Dealer "N"]
[Declarer "S"]
[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]
[Dealer "E"]
[Deal "N:AJ54.AK2.A32.AK3 Q98.QJT.KQJ.QJT7 KT32.543.654.542 76.9876.T987.986"]`
	boards, err := resolve_boards(text)
	defer delete(boards)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(boards), 2)
	testing.expect(t, !board_fully_known(boards[0]))
	testing.expect(t, board_fully_known(boards[1]))
}

// A bare LIN record (an `md|` token, no `[Deal "` tag) routes to the LIN reader, and yields ONE board.
@(test)
test_resolve_bare_lin_record :: proc(t: ^testing.T) {
	lin := "pn|South,West,North,East|st||md|1SAJ54HAK2DA32CAK3,SQ98HQJTDKQJCQJT7,SKT32H543D654C542|sv|o|"
	boards, err := resolve_boards(lin)
	defer delete(boards)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(boards), 1)
	testing.expect(t, board_fully_known(boards[0])) // LIN's fourth hand is the remainder
}

// A pasted bridge-site hand URL: the `lin=` query parameter is extracted and percent-decoded. `%2C` is a
// comma and `%7C` a pipe — LIN's own separators, which arrive encoded from a real URL.
@(test)
test_resolve_hand_url_percent_decoded :: proc(t: ^testing.T) {
	url := "https://play.intobridge.com/hand?lin=pn%7CSouth%2CWest%2CNorth%2CEast%7Cst%7C%7Cmd%7C1SAJ54HAK2DA32CAK3%2CSQ98HQJTDKQJCQJT7%2CSKT32H543D654C542%7Csv%7Co%7C&other=1"
	boards, err := resolve_boards(url)
	defer delete(boards)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(boards), 1)
	testing.expect(t, board_fully_known(boards[0]))
}

// The `&` ends the value (the next query parameter is not part of the LIN), and `+` decodes to a space.
@(test)
test_lin_query_param_stops_at_ampersand :: proc(t: ^testing.T) {
	got := lin_query_param("x?lin=a%7Cb+c&next=zzz", context.temp_allocator)
	testing.expect_value(t, got, "a|b c")
}

// A malformed `%` (not followed by two hex digits) passes through literally rather than eating bytes.
@(test)
test_url_decode_tolerates_bad_escape :: proc(t: ^testing.T) {
	got := url_decode("a%zzb%", context.temp_allocator)
	testing.expect_value(t, got, "a%zzb%")
}

@(test)
test_resolve_rejects_nonsense :: proc(t: ^testing.T) {
	boards, err := resolve_boards("this is not a deal at all")
	defer delete(boards)
	testing.expect(t, err != "")
	testing.expect_value(t, len(boards), 0)
}

// --void / --len / --lead specs, including the three length forms and a bad one.
@(test)
test_spec_parsers :: proc(t: ^testing.T) {
	v, v_ok := parse_void_spec("E:S")
	testing.expect(t, v_ok)
	testing.expect_value(t, v.seat, norn.Seat.East)
	testing.expect_value(t, v.suit, norn.Suit.Spades)
	testing.expect_value(t, v.min, 0)
	testing.expect_value(t, v.max, 0)

	exact, e_ok := parse_len_spec("W:H:6")
	testing.expect(t, e_ok)
	testing.expect_value(t, exact.min, 6)
	testing.expect_value(t, exact.max, 6)

	rng, r_ok := parse_len_spec("E:C:0-1")
	testing.expect(t, r_ok)
	testing.expect_value(t, rng.min, 0)
	testing.expect_value(t, rng.max, 1)

	plus, p_ok := parse_len_spec("W:D:5+")
	testing.expect(t, p_ok)
	testing.expect_value(t, plus.min, 5)
	testing.expect_value(t, plus.max, 13)

	_, bad_ok := parse_len_spec("W:D:9-2") // reversed bounds
	testing.expect(t, !bad_ok)

	lead, l_ok := parse_lead_spec("W:KH") // rank-first, norn convention
	testing.expect(t, l_ok)
	testing.expect_value(t, lead.seat, norn.Seat.West)
	testing.expect_value(t, norn.card_suit(lead.card), norn.Suit.Hearts)

	_, ls_ok := parse_lead_spec("W:HK") // suit-first is not the convention
	testing.expect(t, !ls_ok)
}

// The flag surface the GUI composes against: long forms, short aliases, and the unquoted `-` hands that
// would otherwise read as flags.
@(test)
test_parse_args_flags_and_void_hands :: proc(t: ^testing.T) {
	argv := []string {
		"--sample",
		"200",
		"-c",
		"3NT",
		"-t",
		"9",
		"--seed",
		"7",
		"--lead",
		"W:KH",
		"N:AJ54.AK2.A32.AK3",
		"-", // an UNQUOTED two-hand deal: these lone dashes are hands, not flags
		"KT32.543.654.542",
		"-",
	}
	args, err := parse_args(argv, allow_stdin = false)
	defer args_free(&args)
	testing.expect_value(t, err, "")
	testing.expect_value(t, args.sample, 200)
	testing.expect_value(t, args.contract, "3NT")
	testing.expect_value(t, args.target, 9)
	testing.expect_value(t, args.seed, u64(7))
	testing.expect_value(t, len(args.held), 1)
	testing.expect_value(t, args.text, "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -")

	// And that text really does resolve to the two-hand board.
	boards, berr := resolve_boards(args.text)
	defer delete(boards)
	testing.expect_value(t, berr, "")
	testing.expect_value(t, len(boards), 1)
}

// `allow_stdin = false` is what keeps a windowed process from blocking on a stdin nobody can type into:
// with no deal in argv, `text` must come back EMPTY rather than the parser waiting for EOF.
@(test)
test_parse_args_without_stdin_leaves_text_empty :: proc(t: ^testing.T) {
	args, err := parse_args([]string{"--sample", "100"}, allow_stdin = false)
	defer args_free(&args)
	testing.expect_value(t, err, "")
	testing.expect_value(t, args.text, "")
}

@(test)
test_parse_args_rejects_negative_sample :: proc(t: ^testing.T) {
	args, err := parse_args([]string{"--sample", "-5"}, allow_stdin = false)
	defer args_free(&args)
	testing.expect(t, err != "")
}

@(test)
test_parse_args_help_does_not_read_stdin :: proc(t: ^testing.T) {
	args, err := parse_args([]string{"-h"}, allow_stdin = false)
	defer args_free(&args)
	testing.expect_value(t, err, "")
	testing.expect(t, args.help)
}

// The report reaches the writer it was handed — the property the GUI depends on, and the reason these
// procs take an `io.Writer` at all. No solver: `--sample` is off, so this is combo only.
@(test)
test_report_board_writes_to_the_sink :: proc(t: ^testing.T) {
	boards, err := resolve_boards(TWO_HAND)
	defer delete(boards)
	testing.expect_value(t, err, "")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	args := Args {
		target = 9,
	}
	report_board(builder_sink(&b), boards[0], &args, {}, false)

	out := strings.to_string(b)
	testing.expect(t, len(out) > 0, "the report must not be empty")
	testing.expect(t, strings.contains(out, "Card-combination analysis for N/S"))
	testing.expect(t, strings.contains(out, "Double-dummy census"))
	testing.expect(t, strings.contains(out, "Top tricks (guaranteed)"))
	// Sampling was off, so the caveat must take its no-DDS branch, not name a simulated cross-check.
	testing.expect(t, strings.contains(out, "there is no DDS par to"))
	testing.expect(t, !strings.contains(out, "Whole-hand (simulated)"))
}

// A board that is neither a 2-hand advisor input nor a complete deal: the diagnostic goes to `err`, and
// no report is written. With a builder_sink both streams are one string, so assert on the message.
@(test)
test_report_board_rejects_a_three_hand_board :: proc(t: ^testing.T) {
	boards, err := resolve_boards(`[Deal "N:AJ54.AK2.A32.AK3 Q98.QJT.KQJ.QJT7 KT32.543.654.542 -"]`)
	defer delete(boards)
	testing.expect_value(t, err, "")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	args := Args{}
	report_board(builder_sink(&b), boards[0], &args, {}, false)

	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "not a 2-hand advisor board"))
	testing.expect(t, !strings.contains(out, "Double-dummy census"))
}

// `run` must report empty input as a USAGE error, and say so, rather than reading a stdin that is not
// there. This is the path a GUI hits when the deal box is empty.
@(test)
test_run_rejects_empty_input :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	args := Args{}
	res := run(builder_sink(&b), &args)
	testing.expect_value(t, res, Result.Usage_Error)
	testing.expect(t, strings.contains(strings.to_string(b), "no deal input"))
}

// The synthesised deal the card page feeds `combo.annotate`: the known pair duplicated into BOTH
// partnerships, so the page's N/S <-> E/W toggle shows the same (only known) analysis either way.
@(test)
test_synth_deal_duplicates_the_known_pair :: proc(t: ^testing.T) {
	boards, err := resolve_boards(TWO_HAND)
	defer delete(boards)
	testing.expect_value(t, err, "")

	synth := synth_deal(boards[0], {.North, .South})
	testing.expect_value(t, len(synth[.East]), len(synth[.North]))
	testing.expect_value(t, len(synth[.West]), len(synth[.South]))
	for card, i in synth[.North] {
		testing.expect_value(t, synth[.East][i], card)
	}
}
