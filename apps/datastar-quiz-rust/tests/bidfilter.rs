//! The pattern language, case by case.
//!
//! Ported from `apps/quiz/tests/test_bidfilter.py` by way of the Go port's
//! `internal/bidfilter/bidfilter_test.go`. That python file is the SPECIFICATION of the language:
//! every behaviour asserted there has to hold here or the implementations disagree about what a
//! filter selects. Where the python asserts on a python-only detail (tomllib loading, `Path`
//! handling for the topics file) the case is dropped rather than faked -- the topics arrive already
//! parsed in this port.

use dsquiz::bidfilter::{
    self, Pattern, Side, Topic, Topics, canonical_pattern_text, normalize_filter_text,
    parse_filter, parse_pattern, prepare_auction, sequence_matches_any,
};
use dsquiz::bids::{
    self, Bid, CLUBS, DIAMONDS, HEARTS, Kind, MAJORS, MINORS, REAL_SUITS, SPADES, SuitClass,
};

fn pattern(text: &str) -> Pattern {
    parse_pattern(text).unwrap_or_else(|_| panic!("parse_pattern({text:?}) failed"))
}

/// The python's `sequence_matches`: parse a raw auction and prefix-match it.
fn matches(seq: &[&str], text: &str) -> bool {
    sequence_matches_any(seq, &[pattern(text)])
}

/// One (auction, pattern, expected) row.
fn check(cases: &[(&[&str], &str, bool)]) {
    for (seq, text, want) in cases {
        let got = matches(seq, text);
        assert_eq!(
            got, *want,
            "matches({seq:?}, {text:?}) = {got}, want {want}"
        );
    }
}

#[test]
fn parse_bid_token() {
    let cases: [(&str, Bid); 5] = [
        (
            "1D",
            Bid {
                level: 1,
                suits: DIAMONDS,
                kind: Kind::Bid,
                ..Default::default()
            },
        ),
        (
            "(1!h)",
            Bid {
                level: 1,
                suits: HEARTS,
                kind: Kind::Bid,
                by_opponent: true,
                ..Default::default()
            },
        ),
        (
            "2DHS",
            Bid {
                level: 2,
                suits: DIAMONDS.union(HEARTS).union(SPADES),
                kind: Kind::Bid,
                ..Default::default()
            },
        ),
        (
            "(3CDHS)",
            Bid {
                level: 3,
                suits: REAL_SUITS,
                kind: Kind::Bid,
                by_opponent: true,
                ..Default::default()
            },
        ),
        (
            "(X)",
            Bid {
                kind: Kind::Double,
                by_opponent: true,
                ..Default::default()
            },
        ),
    ];
    for (token, want) in cases {
        assert_eq!(bids::parse_call(token), Some(want), "parse_call({token:?})");
    }
    let kinds = [
        ("Pass", Kind::Pass),
        ("any", Kind::Any),
        ("cue", Kind::Cue),
        ("others", Kind::Any),    // a catch-all row
        ("enquiry", Kind::Other), // prose, still unresolved
        ("next", Kind::Next),     // resolved against the auction
        ("game", Kind::Game),
        ("jump", Kind::Jump),
        ("4thSuit", Kind::FourthSuit),
    ];
    for (token, want) in kinds {
        assert_eq!(
            bids::parse_call(token).unwrap().kind,
            want,
            "parse_call({token:?}).kind"
        );
    }
    // `1C` is a class-free bid; `2M` names the majors class, which is what lets `1HS ... 2M` bind
    assert_eq!(bids::parse_call("1C").unwrap().suit_class, SuitClass::None);
    assert_eq!(bids::parse_call("2M").unwrap().suit_class, SuitClass::Major);
    assert_eq!(
        bids::parse_call("2oM").unwrap().suit_class,
        SuitClass::OtherMajor
    );
}

#[test]
fn parse_sequence_positions() {
    let auction = bidfilter::matcher::parse_sequence_positions(&["1C (Pass) 1H", "2D", "2S"]);
    let want_kinds = [Kind::Bid, Kind::Pass, Kind::Bid, Kind::Bid, Kind::Bid];
    assert_eq!(auction.len(), want_kinds.len());
    for (index, kind) in want_kinds.iter().enumerate() {
        assert_eq!(auction.group(index)[0].kind, *kind, "position {index}");
    }
    assert_eq!(
        auction.group(0)[0],
        Bid {
            level: 1,
            suits: CLUBS,
            kind: Kind::Bid,
            ..Default::default()
        }
    );
    assert_eq!(
        auction.group(1)[0],
        Bid {
            kind: Kind::Pass,
            by_opponent: true,
            ..Default::default()
        }
    );
}

#[test]
fn major_shortcut_matches_both() {
    check(&[
        (&["1D (Pass) 1H", "1N"], "1D--1M--1N", true),
        (&["1D (Pass) 1S", "1N"], "1D--1M--1N", true),
        (&["1D (Pass) 2H", "1N"], "1D--1M--1N", false), // wrong level in the middle
        (&["1D (Pass) 1C", "1N"], "1D--1M--1N", false), // minor where a major is required
    ]);
}

#[test]
fn prefix_shorter_than_sequence() {
    check(&[
        (&["1D (Pass) 1H", "1N", "2C"], "1D--1H", true),
        (&["1D"], "1D--1H--1N", false), // pattern longer than auction cannot match
    ]);
}

#[test]
fn multi_suit_and_opponents() {
    check(&[
        // multi-suit bid 2DHS intersects a major-class pattern 2M
        (&["1H (Pass) 2DHS"], "1H--2M", true),
        (&["1H (Pass) 2DHS"], "1H--2C", false),
        (&["1H (X)", "2H"], "1H--(X)--2H", true),
        (&["1H (Pass)", "2H"], "1H--(X)--2H", false),
    ]);
}

#[test]
fn wildcard_token() {
    check(&[
        // `(*)` = opponents did something (implicit opponent passes are dropped)
        (&["1H (X)"], "1M--(*)", true),
        (&["1S (2D)"], "1M--(*)", true),
        (&["1H (Pass)", "2H"], "1M--(*)", false),
        (&["1C (X)"], "1M--(*)", false), // 1C is not a major
        // bare `*` / `any` matches any call by either side
        (&["1C (Pass) 1H"], "*--*", true),
        (&["1C (X)"], "1C--any", true),
        // `1*` -- any suit, but that level and an actual bid
        (&["1C (Pass) 1S"], "1C--1*", true),
        (&["1C (Pass) 2S"], "1C--1*", false),
        (&["1C (X)"], "1C--1*", false),
    ]);
}

#[test]
fn normalize_text() {
    let cases = [
        ("  1D-1M-1N  ", "1D-1M-1N"),
        ("1D  --  1M", "1D-1M"),
        ("1H -- ( X ) - 2H", "1H-(X)-2H"),
        ("1C ,, 1D ,", "1C, 1D"),
        ("", ""),
    ];
    for (input, want) in cases {
        assert_eq!(
            normalize_filter_text(input),
            want,
            "normalize_filter_text({input:?})"
        );
    }
}

#[test]
fn opponent_calls_can_be_slipped_in_anywhere() {
    check(&[
        // a pattern describes our auction; whatever the opponents do in between should not stop it
        (&["1D (Pass) 1H"], "1D-1H", true),
        (&["1D (1S) 1H"], "1D-1H", true),
        (&["1D (X) 1H"], "1D-1H", true),
        (&["1D (2C)", "1H"], "1D-1H", true),
        (&["1D (1S) 2C", "1H"], "1D-1H", false), // our own calls stay in order
        // naming the opponents pins them down: it must be the very next call
        (&["1D (X) 1H"], "1D-(X)-1H", true),
        (&["1D (1S) 1H"], "1D-(X)-1H", false),
        (&["1D (Pass) 1H"], "1D-(X)-1H", false),
        // a bare `*` is any call at all, opponents included, so it counts depth
        (&["1D (1S) 1H"], "*-*-*", true),
        (&["1D (Pass) 1H"], "*-*-*", false),
    ]);
}

#[test]
fn unbracketed_tokens_are_our_calls() {
    check(&[
        (&["1C (Pass) 1H"], "1C", true),
        (&["(1C) X"], "1C", false),
        (&["(1C) X"], "(1C)", true),
        (&["(1C) X"], "*", true), // the bare wildcard is the exception
    ]);
}

#[test]
fn first_token_anchors_to_the_opening_call() {
    check(&[
        (&["2C (Pass) 2D"], "2C", true),
        (&["(1H) 2C"], "2C", false),
        (&["(1H) 2C"], "(1H)-2C", true),
        (&["(1H) 2C"], "(*)-2C", true),
    ]);
}

#[test]
fn separators_are_interchangeable() {
    for text in [
        "1D--1H--1N",
        "1D 1H 1N",
        "1D - 1H -- 1N",
        "1D-1H 1N",
        "1D  --1H-  1N",
    ] {
        assert_eq!(
            canonical_pattern_text(text),
            "1D-1H-1N",
            "canonical({text:?})"
        );
        assert!(
            matches(&["1D (Pass) 1H", "1N"], text),
            "pattern {text:?} did not match"
        );
    }
    let parsed = parse_filter("1D 1H, 2C-2D", None);
    assert_eq!(parsed.canonical_text, "1D-1H, 2C-2D");
    assert!(parsed.errors.is_empty());
}

#[test]
fn case_insensitive_except_minors() {
    let same = [
        ("1d--1h--1n", "1D--1H--1N"),
        ("1h--(x)--2h", "1H--(X)--2H"),
        ("1d--pass", "1D--PASS"),
        ("1d--(1!H)", "1D--(1!h)"),
        ("1M-3x", "1M-3*"),
    ];
    for (left, right) in same {
        assert_eq!(
            pattern(left),
            pattern(right),
            "{left:?} and {right:?} parsed differently"
        );
    }
    // ...but M (majors) and m (minors) stay distinct
    assert_eq!(pattern("1d--1M").group(1)[0].suits, MAJORS);
    assert_eq!(pattern("1D--1m").group(1)[0].suits, MINORS);
    assert_ne!(pattern("1D--1M"), pattern("1D--1m"));
}

#[test]
fn whitespace_and_case_do_not_change_matching() {
    assert!(matches(&["1D (Pass) 1S", "1N"], "  1d  --  1M  --  1n "));
}

#[test]
fn comma_is_or() {
    let parsed = parse_filter("1C, 1D--1M", None);
    assert_eq!(parsed.patterns.len(), 2);
    assert!(parsed.errors.is_empty());
    assert!(sequence_matches_any(&["1C (Pass) 1H"], &parsed.patterns));
    assert!(sequence_matches_any(&["1D (Pass) 1S"], &parsed.patterns));
    assert!(!sequence_matches_any(&["1H (Pass) 2H"], &parsed.patterns));
}

#[test]
fn a_bad_entry_does_not_discard_the_rest() {
    let parsed = parse_filter("1C, nonsense!!, 1D", None);
    assert_eq!(parsed.errors, vec!["nonsense!!".to_string()]);
    assert_eq!(parsed.patterns.len(), 2);
    assert_eq!(parsed.canonical_text, "1C, 1D");
}

fn test_topics() -> Topics {
    Topics::new(vec![
        Topic {
            name: "Opening 1C".into(),
            patterns: vec!["1C".into()],
            description: String::new(),
        },
        Topic {
            name: "Major raises".into(),
            patterns: vec!["1M--2M".into(), "1M--3M".into()],
            description: String::new(),
        },
        Topic {
            name: "Minor raises".into(),
            patterns: vec!["1m--2m".into()],
            description: String::new(),
        },
    ])
}

#[test]
fn topic_name_resolution() {
    let topics = test_topics();
    let cases = [
        ("  opening   1c ", Some("Opening 1C")), // exact, case- and whitespace-insensitive
        ("major", Some("Major raises")),         // unique prefix
        ("1c", Some("Opening 1C")),              // unique substring
        ("raises", None),                        // ambiguous: major and minor both
        ("m", None),                             // prefix hits two topics
        ("slam", None),                          // unknown
    ];
    for (text, want) in cases {
        let got = topics
            .match_name(text, true)
            .map(|index| topics.list[index].name.as_str());
        assert_eq!(got, want, "match_name({text:?})");
    }
}

#[test]
fn filter_expands_topics() {
    let topics = Topics::new(vec![Topic {
        name: "Major raises".into(),
        patterns: vec!["1M--2M".into(), "1M--3M".into()],
        description: String::new(),
    }]);
    let parsed = parse_filter("major", Some(&topics));
    assert_eq!(parsed.topic_names, vec!["Major raises".to_string()]);
    assert_eq!(parsed.canonical_text, "Major raises");
    assert_eq!(parsed.patterns.len(), 2);
    assert!(sequence_matches_any(&["1H (Pass) 3H"], &parsed.patterns));
    assert!(!sequence_matches_any(&["1H (Pass) 4H"], &parsed.patterns));
}

#[test]
fn filter_mixes_topics_and_patterns() {
    let topics = Topics::new(vec![Topic {
        name: "Opening 1C".into(),
        patterns: vec!["1C".into()],
        description: String::new(),
    }]);
    let parsed = parse_filter("opening 1c, 1d -- 1M", Some(&topics));
    assert_eq!(parsed.topic_names, vec!["Opening 1C".to_string()]);
    assert_eq!(parsed.canonical_text, "Opening 1C, 1D-1M");
    assert!(sequence_matches_any(&["1C (Pass) 1H"], &parsed.patterns));
    assert!(sequence_matches_any(&["1D (Pass) 1H"], &parsed.patterns));
}

#[test]
fn a_valid_pattern_beats_a_fuzzy_topic_name() {
    let topics = Topics::new(vec![Topic {
        name: "Opening 1C strong".into(),
        patterns: vec!["1C--2N".into()],
        description: String::new(),
    }]);
    let parsed = parse_filter("1C", Some(&topics));
    assert!(parsed.topic_names.is_empty());
    assert_eq!(parsed.canonical_text, "1C");
    assert!(sequence_matches_any(&["1C (Pass) 1H"], &parsed.patterns));
    // ...while a non-pattern prefix still resolves to the topic
    assert_eq!(parse_filter("strong", Some(&topics)).topic_names.len(), 1);
}

#[test]
fn prepared_bids_match_the_unprepared_path() {
    let seqs: [&[&str]; 3] = [
        &["1C (Pass) 1H", "2D"],
        &["1D (X)", "2H"],
        &["1H (Pass) 2H"],
    ];
    let pats = [pattern("1C"), pattern("1D--(X)")];
    let want = [true, true, false];
    for (index, seq) in seqs.iter().enumerate() {
        let prepared = prepare_auction(seq);
        assert_eq!(
            bidfilter::bids_match_any(&prepared, &pats),
            want[index],
            "prepared[{index}]"
        );
        assert_eq!(
            sequence_matches_any(seq, &pats),
            want[index],
            "unprepared[{index}]"
        );
    }
}

#[test]
fn empty_filter_is_empty() {
    let parsed = parse_filter("   ", None);
    assert!(parsed.patterns.is_empty());
    assert!(parsed.errors.is_empty());
}

#[test]
fn topics_with_unparseable_patterns_are_skipped() {
    let topics = Topics::new(vec![
        Topic {
            name: "Everywhere".into(),
            patterns: vec!["1C".into()],
            description: String::new(),
        },
        Topic {
            name: "Broken".into(),
            patterns: vec!["not a bid".into()],
            description: String::new(),
        },
        Topic {
            name: "Empty".into(),
            patterns: vec![],
            description: String::new(),
        },
    ]);
    assert_eq!(topics.len(), 1);
    assert_eq!(topics.list[0].name, "Everywhere");
}

// --- alternation (`/`) and the `*` wildcard ---------------------------------

#[test]
fn pattern_alternation_same_level() {
    check(&[
        (&["1N (Pass) 2D"], "1N--2D/2H", true),
        (&["1N (Pass) 2H"], "1N--2D/2H", true),
        (&["1N (Pass) 2S"], "1N--2D/2H", false),
        // ...and it is not two positions: 1N-2D-2H must not be what it means
        (&["1N (Pass) 2D", "3C"], "1N--2D/2H", true),
    ]);
}

#[test]
fn pattern_alternation_across_levels() {
    check(&[
        (&["1H (Pass) 3S"], "1M--3S/4C", true),
        (&["1S (Pass) 4C"], "1M--3S/4C", true),
        (&["1H (Pass) 4S"], "1M--3S/4C", false), // no cross-pairing
        (&["1H (Pass) 3C"], "1M--3S/4C", false),
    ]);
}

#[test]
fn pattern_alternation_brackets_apply_to_every_branch() {
    check(&[
        (&["1C (2D)"], "1C--(2D/2H)", true),
        (&["1C (2H)"], "1C--(2D/2H)", true),
        (&["1C (Pass) 2D"], "1C--(2D/2H)", false), // ours, not theirs
    ]);
}

#[test]
fn wildcard_denomination_pattern() {
    check(&[
        (&["1H (Pass) 3D"], "1M--3*", true),
        (&["1S (Pass) 3N"], "1M--3*", true),
        (&["1H (Pass) 4D"], "1M--3*", false), // level still binds
    ]);
}

#[test]
fn alternation_in_the_recorded_auction() {
    let seq: &[&str] = &["1C", "1D", "1N/2C", "2D"];
    check(&[
        (seq, "1C-1D-1N-2D", true),
        (seq, "1C-1D-2C-2D", true),
        (seq, "1C-1D-1H-2D", false),
        // and it stays ONE position: 2D follows it, nothing was inserted
        (seq, "1C-1D-1N-2C", false),
    ]);
}

#[test]
fn canonical_text_keeps_alternation() {
    assert_eq!(canonical_pattern_text("1n -- 2d/2h"), "1N-2D/2H");
    assert_eq!(canonical_pattern_text("1m--3*"), "1m-3*");
}

#[test]
fn call_pattern_alternatives() {
    let pat = pattern("1D--1M");
    assert_eq!(pat.group(1)[0].suits, MAJORS);
    assert_eq!(pat.group(1)[0].level, 1);
    assert_eq!(pat.group(1)[0].side, Side::Ours);
    assert_eq!(pattern("1D--3S/4C").group(1).len(), 2);
}

// --- suit-class variables ---------------------------------------------------

#[test]
fn repeated_class_means_the_same_suit() {
    check(&[
        (&["1HS", "2M"], "1H-2H", true),
        (&["1HS", "2M"], "1S-2S", true),
        (&["1HS", "2M"], "1H-2S", false),
        (&["1HS", "2M"], "1S-2H", false),
        (&["1HS", "2M"], "1M-2M", true), // the class-level question still answers yes
        (&["1HS", "2M", "3M"], "1S-2S-3S", true),
        (&["1HS", "2M", "3M"], "1S-2S-3H", false),
        (&["2CD", "3m"], "2C-3C", true), // minors bind the same way
        (&["2CD", "3m"], "2C-3D", false),
    ]);
}

#[test]
fn other_major_resolves_against_the_auction() {
    let long: &[&str] = &["1C", "1HS", "2C", "2D", "2oM"];
    check(&[
        (&["1H", "2oM"], "1H-2S", true),
        (&["1H", "2oM"], "1H-2H", false),
        (long, "1C-1H-2C-2D-2S", true),
        (long, "1C-1S-2C-2D-2H", true),
        (long, "1C-1H-2C-2D-2H", false),
    ]);
}

#[test]
fn what_does_not_bind() {
    check(&[
        (&["1HS", "3CD"], "1H-3D", true), // different classes are unrelated
        (&["3x", "4x"], "3H-4S", true),   // two wildcards are two unknown suits
        (&["2M"], "2S", true),            // a lone class is as permissive as before
        (&["2M"], "2H", true),
        (&["1H", "1S"], "1H-1S", true), // two concrete majors are just themselves
    ]);
}

#[test]
fn x_and_om_in_patterns() {
    check(&[
        (&["1H (Pass) 3D"], "1M-3x", true),
        // `oM` typed as a pattern has nothing to be other than, so it asks the class
        (&["1C (Pass) 2H"], "1C-2oM", true),
        (&["1C (Pass) 2D"], "1C-2oM", false),
    ]);
}

#[test]
fn link_bids_in_an_auction() {
    check(&[
        (&["1C", "[1HS](#1C--1HS)"], "1C-1H", true),
        (&["1C", "[1HS](#1C--1HS)"], "1C-2H", false),
    ]);
}

#[test]
fn any_row_answers_to_any_pattern() {
    check(&[
        (&["1C", "(any)"], "1C-(X)", true),
        (&["1C", "(any)"], "1C-(2H)", true),
        (&["1C", "(any)"], "1C-(*)", true),
        (&["1C", "(any)"], "1C-2H", false), // whose call it was still matters
        (&["1C", "any"], "1C-2H", true),
        (&["1C", "any"], "1C-(2H)", false),
        // and it does not swallow the rest of the auction
        (&["1C", "(any)", "2D"], "1C-(X)-2D", true),
        (&["1C", "(any)", "2D"], "1C-(X)-3D", false),
    ]);
}

#[test]
fn next_resolves_to_the_step_above_its_parent() {
    let seq: &[&str] = &["1C", "3C", "4HS", "next"];
    check(&[
        (seq, "1C-3C-4H-4S", true),
        (seq, "1C-3C-4S-4N", true),
        (seq, "1C-3C-4H-4N", false), // never the cross pairing
        (seq, "1C-3C-4S-4S", false),
        (&["4H", "next"], "4H-4S", true),
        (&["4H", "next"], "4H-5C", false),
        (&["4N", "next"], "4N-5C", true), // notrump rolls to the next level
        (&["4HS", "next", "5C"], "4S-4N-5C", true),
        (&["4HS", "next", "5C"], "4H-4N-5C", false),
    ]);
}

#[test]
fn next_stays_unresolved_without_a_parent_bid() {
    check(&[
        (&["1C", "any", "next"], "1C-2H-2S", false),
        (&["next"], "2C", false),
        (&["1C", "Pass", "next"], "1C-P-2C", false),
    ]);
}

#[test]
fn next_after_a_bound_class() {
    let seq: &[&str] = &["1HS", "2M", "next"];
    check(&[
        (seq, "1S-2S-2N", true),
        (seq, "1H-2H-2S", true),
        (seq, "1H-2S-2N", false),
        (seq, "1S-2S-3C", false),
    ]);
}

#[test]
fn jump_is_a_jump_in_a_new_suit() {
    let seq: &[&str] = &["2H", "2S", "jump"];
    check(&[
        (seq, "2H-2S-4C", true),
        (seq, "2H-2S-4D", true),
        (seq, "2H-2S-3C", false), // that is no jump
        (seq, "2H-2S-4H", false), // hearts were bid
        (seq, "2H-2S-4N", false), // never notrump
        (seq, "2H-2S-3N", false),
    ]);
}

#[test]
fn jump_skips_suits_already_bid() {
    let seq: &[&str] = &["1D", "1S", "jump"];
    check(&[
        (seq, "1D-1S-3C", true),
        (seq, "1D-1S-3H", true),
        (seq, "1D-1S-3D", false),
        (seq, "1D-1S-3S", false),
        (seq, "1D-1S-2C", false), // the cheapest bid
    ]);
}

#[test]
fn double_jump_is_one_higher() {
    let seq: &[&str] = &["1D", "1S", "doubleJump"];
    check(&[
        (seq, "1D-1S-4C", true),
        (seq, "1D-1S-4H", true),
        (seq, "1D-1S-3C", false),
    ]);
}

#[test]
fn jump_without_a_resolvable_parent() {
    check(&[
        (&["1C", "any", "jump"], "1C-2H-3S", false),
        (&["jump"], "3S", false),
    ]);
}

#[test]
fn cue_is_the_lowest_available_bid_in_their_suit() {
    check(&[
        (&["(1H)", "1S", "cue"], "(1H)-1S-2H", true),
        (&["(1H)", "1S", "cue"], "(1H)-1S-3H", false), // not the lowest
        (&["(1H)", "1S", "cue"], "(1H)-1S-2C", false), // not their suit
        // with two of their suits shown, only the cheaper cue counts
        (&["(1H)", "(2D)", "2S", "cue"], "(1H)-(2D)-2S-3D", true),
        (&["(1H)", "(2D)", "2S", "cue"], "(1H)-(2D)-2S-3H", false),
        // a level named on the token overrides "lowest"
        (&["(1H)", "1S", "3cue"], "(1H)-1S-3H", true),
        (&["(1H)", "1S", "3cue"], "(1H)-1S-2H", false),
        // nothing to cue: unresolved, so unmatched
        (&["1C", "1H", "cue"], "1C-1H-2H", false),
    ]);
}

#[test]
fn new_is_a_suit_neither_side_has_bid() {
    let seq: &[&str] = &["1D", "1S", "new"];
    check(&[
        (seq, "1D-1S-2C", true),
        (seq, "1D-1S-2H", true),
        (seq, "1D-1S-2D", false), // ours
        (seq, "1D-1S-2S", false), // ours
        (seq, "1D-1S-2N", false), // not a suit
        (seq, "1D-1S-3C", false), // that is a jump
        // the opponents' suit is not new either
        (&["1D", "(1H)", "1S", "new"], "1D-(1H)-1S-2H", false),
        // a level named on the token pins it
        (&["1D", "1S", "3new"], "1D-1S-3C", true),
        (&["1D", "1S", "3new"], "1D-1S-2C", false),
    ]);
}

#[test]
fn at_least_covers_everything_above() {
    check(&[
        (&["1C", "(2N+)"], "1C-(2N)", true),
        (&["1C", "(2N+)"], "1C-(3C)", true),
        (&["1C", "(2N+)"], "1C-(7N)", true),
        (&["1C", "(2N+)"], "1C-(2S)", false),
        (&["1C", "(2N+)"], "1C-(1N)", false),
        (&["1C", "(2x+)"], "1C-(2C)", true), // `2x+` starts at the bottom of the level
        (&["1C", "(2x+)"], "1C-(1S)", false),
    ]);
}

#[test]
fn catch_all_rows_promise_different_amounts() {
    let over: &[&str] = &["1C", "1N", "(overcall)"];
    let but_pass: &[&str] = &["1C", "1N", "(bid)"];
    check(&[
        (over, "1C-1N-(2H)", true),
        (over, "1C-1N-(X)", false), // a bid, not a double
        (over, "1C-1N-2H", false),  // theirs, not ours
        (but_pass, "1C-1N-(2H)", true),
        (but_pass, "1C-1N-(X)", true),
        (but_pass, "1C-1N-(XX)", true),
        // `other` is the same catch-all as `any`, not a statement about sibling rows
        (&["1C", "1D", "other"], "1C-1D-2D", true),
        (&["1C", "1D", "other"], "1C-1D-P", true),
    ]);
}

#[test]
fn game_is_a_game_contract() {
    for call in ["3N", "4H", "4S", "5C", "5D"] {
        assert!(
            matches(&["1C", "game"], &format!("1C-{call}")),
            "game did not cover {call}"
        );
    }
    check(&[
        (&["1C", "game"], "1C-4N", false),
        (&["1C", "game"], "1C-3S", false),
    ]);
}

#[test]
fn suit_is_a_simple_new_suit() {
    let seq: &[&str] = &["1D", "1S", "suit"];
    check(&[
        (seq, "1D-1S-2C", true),
        (seq, "1D-1S-2H", true),
        (seq, "1D-1S-2N", false), // never notrump
        (seq, "1D-1S-3C", false), // that is a jump
        (seq, "1D-1S-2D", false), // already bid
    ]);
}

#[test]
fn level_y_is_a_new_suit() {
    let seq: &[&str] = &["1D", "1S", "2Y"];
    check(&[
        (seq, "1D-1S-2C", true),
        (seq, "1D-1S-2H", true),
        (seq, "1D-1S-2D", false), // already bid
        (seq, "1D-1S-2N", false), // not a suit
        (seq, "1D-1S-3C", false), // wrong level
    ]);
}

#[test]
fn cue_over_cues_the_player_on_our_right() {
    let seq: &[&str] = &["(1C)", "P", "(1HS)", "CueOver"];
    check(&[
        (seq, "(1C)-P-(1H)-2H", true),
        (seq, "(1C)-P-(1S)-2S", true),
        (seq, "(1C)-P-(1H)-1S", false), // their suit is what *they* bid
        (seq, "(1C)-P-(1H)-2C", false), // not the first opponent's suit
        (&["(1C)", "P", "(1HS)", "cue"], "(1C)-P-(1H)-2C", true),
        // a wildcard opponent bid: whatever they bid is the suit to cue
        (&["(1C)", "P", "(1x)", "CueOver"], "(1C)-P-(1D)-2D", true),
        // nothing to cue over
        (&["(1C)", "P", "(X)", "CueOver"], "(1C)-P-(X)-2C", false),
    ]);
}

#[test]
fn step_responses_to_an_artificial_ask() {
    for call in ["5C", "5D", "5H", "5S", "5N"] {
        assert!(
            matches(&["4N", "xstep"], &format!("4N-{call}")),
            "xstep did not cover {call}"
        );
    }
    let nested: &[&str] = &["4N", "xstep", "1step"];
    check(&[
        (&["4N", "xstep"], "4N-6C", false), // off the ladder
        (&["4N", "1step"], "4N-5C", true),  // a numbered step is one rung
        (&["4N", "1step"], "4N-5D", false),
        (nested, "4N-5C-5D", true),
        (nested, "4N-5H-5S", true),
        (nested, "4N-5C-5H", false),
        (&["any", "xstep"], "*-2C", false), // nothing to answer
        (&["7N", "xstep"], "7N-7N", false), // nowhere left to go
    ]);
}

#[test]
fn raise_supports_partners_last_suit() {
    check(&[
        (&["2HS", "raise"], "2H-3H", true),
        (&["2HS", "raise"], "2S-3S", true),
        (&["2HS", "raise"], "2H-3S", false),
        // an opponent in between does not make their suit ours
        (&["1H", "(2C)", "raise"], "1H-(2C)-2H", true),
        (&["1H", "(2C)", "raise"], "1H-(2C)-3C", false),
        // opener raising responder's suit: partner's last is the 2C, not the 1H
        (&["1H", "2C", "raise"], "1H-2C-3C", true),
        (&["1H", "2C", "raise"], "1H-2C-2H", false),
        // bracketed, it is *their* partner's suit
        (&["(1H)", "X", "(raise)"], "(1H)-X-(2H)", true),
        (&["(1H)", "X", "(raise)"], "(1H)-X-(2S)", false),
        // nobody on our side has bid
        (&["(1H)", "raise"], "(1H)-2H", false),
    ]);
}

#[test]
fn jump_raise_and_levelled_raise() {
    check(&[
        (&["1H", "(2C)", "jumpRaise"], "1H-(2C)-3H", true),
        (&["1H", "(2C)", "jumpRaise"], "1H-(2C)-2H", false),
        (&["1H", "2C", "3raise"], "1H-2C-3C", true),
    ]);
}

#[test]
fn resolution_measures_from_the_last_bid_not_the_last_call() {
    check(&[
        (&["1H", "X", "new"], "1H-X-2C", true),
        (&["(1H)", "X", "(raise)"], "(1H)-X-(2H)", true),
    ]);
}

#[test]
fn cue_low_and_cue_high_pick_between_their_suits() {
    check(&[
        (&["(1H)", "P", "(2S)", "cueLow"], "(1H)-P-(2S)-3H", true),
        (&["(1H)", "P", "(2S)", "cueLow"], "(1H)-P-(2S)-3S", false),
        (&["(1H)", "P", "(2S)", "cueHi"], "(1H)-P-(2S)-3S", true),
        (&["(1H)", "P", "(2S)", "cueHi"], "(1H)-P-(2S)-3H", false),
        // over a *conventional* two-suiter only one call is on the table
        (&["1C", "(2C)", "cueLow"], "1C-(2C)-3C", false),
    ]);
}

#[test]
fn higher_is_a_catch_all_bid() {
    let seq: &[&str] = &["(1C)", "1HS", "(higher)"];
    check(&[
        (seq, "(1C)-1H-(2C)", true),
        (seq, "(1C)-1H-(1N)", true),
        (seq, "(1C)-1H-(X)", false), // a bid, not a double
        (seq, "(1C)-1H-(P)", false),
    ]);
}

#[test]
fn denomination_without_a_level_is_a_simple_bid() {
    check(&[
        (&["1C", "2C", "(2S)", "NT"], "1C-2C-(2S)-2N", true),
        (&["1C", "2C", "(2S)", "NT"], "1C-2C-(2S)-3N", false),
        (&["1C", "1D", "major"], "1C-1D-1H", true),
        (&["1C", "1D", "major"], "1C-1D-1S", true),
        (&["1C", "1D", "major"], "1C-1D-2H", false),
        (&["1C", "1D", "major"], "1C-1D-1N", false),
        (&["2S", "m"], "2S-3C", true),
        (&["2S", "m"], "2S-3D", true),
        (&["2S", "m"], "2S-3H", false),
        (&["2S", "m"], "2S-2N", false),
        // both halves of an alternation of strains resolve
        (&["1N", "(2H)", "!c/!d"], "1N-(2H)-3C", true),
        (&["1N", "(2H)", "!c/!d"], "1N-(2H)-3D", true),
        (&["1N", "(2H)", "!c/!d"], "1N-(2H)-3H", false),
    ]);
}

#[test]
fn other_suit_is_the_new_suit_rule() {
    let seq: &[&str] = &["(1H)", "1S", "(otherSuit)"];
    check(&[
        (seq, "(1H)-1S-(2C)", true),
        (seq, "(1H)-1S-(2D)", true),
        (seq, "(1H)-1S-(2H)", false), // partner's
        (seq, "(1H)-1S-(1N)", false), // not a suit
    ]);
}

#[test]
fn strain_plus_is_any_level_in_that_strain() {
    let seq: &[&str] = &["1N", "(2H)", "!c+/!d+"];
    for call in ["3C", "3D", "4C", "5D", "7C"] {
        assert!(
            matches(seq, &format!("1N-(2H)-{call}")),
            "!c+/!d+ did not cover {call}"
        );
    }
    check(&[
        (seq, "1N-(2H)-3H", false), // wrong strain
        (seq, "1N-(2H)-2C", false), // not legal
        // the bare form stays the simple bid
        (&["1N", "(2H)", "!c/!d"], "1N-(2H)-3C", true),
        (&["1N", "(2H)", "!c/!d"], "1N-(2H)-4C", false),
    ]);
}

#[test]
fn slam_bids_the_agreed_suit_at_the_slam_level() {
    check(&[
        (&["4HS", "slam"], "4H-6H", true),
        (&["4HS", "slam"], "4S-6S", true),
        (&["4HS", "slam"], "4H-7H", true),
        (&["4HS", "slam"], "4H-6S", false), // pinned
        (&["4HS", "slam"], "4H-5H", false),
        (&["1H", "2C", "6slam"], "1H-2C-6C", true),
        (&["1H", "2C", "6slam"], "1H-2C-7C", false),
    ]);
}

#[test]
fn next_suit_skips_notrump() {
    check(&[
        (&["1C", "2H", "nextSuit"], "1C-2H-2S", true),
        (&["1C", "2H", "nextSuit"], "1C-2H-2N", false),
        (&["1C", "2S", "nextSuit"], "1C-2S-3C", true),
        (&["1C", "2S", "nextSuit"], "1C-2S-2N", false),
    ]);
}

#[test]
fn fourth_suit_is_the_one_left() {
    check(&[
        (&["1C", "1D", "1H", "4thSuit"], "1C-1D-1H-1S", true),
        (&["1C", "1D", "1H", "4thSuit"], "1C-1D-1H-2C", false),
        // with two suits still unbid it is not describing one call
        (&["1C", "1D", "4thSuit"], "1C-1D-1H", false),
    ]);
}

/// A pattern is not NT-normalised (only auctions are), so `1NT` in the filter box does not parse
/// and falls through to being read as a topic name. Both the python and the Go port do this.
#[test]
fn nt_is_not_a_pattern_token() {
    assert!(parse_pattern("1NT").is_err());
    assert!(parse_pattern("1N").is_ok());
}
