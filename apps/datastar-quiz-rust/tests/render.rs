//! The renderer's two silent transforms.
//!
//! The datastar naming transform is the one thing in this app that is silent when wrong: a slug
//! that differs binds a signal the server never reads, so the checkbox ticks and nothing happens --
//! no error, no log line. There are now FOUR implementations of it (the python, the Go port, the
//! load harness's own copy, and this one), so the golden is the cheapest way to keep them in step.

use std::collections::HashMap;

use dsquiz::render::{
    datastar_camel, datastar_kebab, emoji_text_auction, escape_html, points_percent, suits,
    topic_signal_key, topic_slug,
};
use serde::Deserialize;

#[derive(Deserialize)]
struct Names {
    slug: String,
    key: String,
}

/// Every topic name in the corpus, against the slug and signal key the python derives.
#[test]
fn topic_signal_names_match_the_python() {
    let body = include_str!("testdata/topic_names.json");
    let want: HashMap<String, Names> = serde_json::from_str(body).expect("the goldens must parse");
    assert!(!want.is_empty(), "no goldens");
    for (name, expected) in &want {
        assert_eq!(topic_slug(name), expected.slug, "topic_slug({name:?})");
        assert_eq!(
            topic_signal_key(name),
            expected.key,
            "topic_signal_key({name:?})"
        );
    }
}

/// The trap: HTML lowercases attribute names, so datastar converts kebab attribute keys to camel
/// signals -- splitting letter/digit boundaries on the way.
#[test]
fn the_kebab_and_camel_transforms() {
    assert_eq!(datastar_kebab("filterText"), "filter-text");
    assert_eq!(datastar_camel("ladder-mode"), "ladderMode");
    assert_eq!(topic_slug("1C opening"), "1-c-opening");
    assert_eq!(topic_signal_key("1C opening"), "1COpening");
    // the slug drops anything that is not alphanumeric, whitespace, `_` or `-`
    assert_eq!(topic_slug("2/1 game force"), "2-1-game-force");
    assert_eq!(topic_signal_key("2/1 game force"), "21GameForce");
}

#[test]
fn the_auction_text() {
    let separator: String = {
        let mut out = String::new();
        for _ in 0..4 {
            out.push('\u{2063}');
        }
        out.push('‣');
        for _ in 0..4 {
            out.push('\u{2063}');
        }
        out
    };
    let cases = [
        ("1C", "1♣".to_owned()),
        // `N` becomes `NT`, but an already-spelled `1NT` is left alone -- the negative lookahead
        // the python's regex needs and this port hand-writes
        ("1N", "1NT".to_owned()),
        ("1NT", "1NT".to_owned()),
        ("2HS", "2♥♠".to_owned()),
        ("1D --> 1H", format!("1♦ {separator} 1♥")),
        ("1C (Pass) 1H", format!("1♣ {separator} 1♥")),
        ("[1D](#1C--1D)", "1♦".to_owned()),
        ("!c and !s", "♣ and ♠".to_owned()),
    ];
    for (input, want) in cases {
        assert_eq!(
            emoji_text_auction(input),
            want,
            "emoji_text_auction({input:?})"
        );
    }
}

#[test]
fn suits_are_coloured_and_markup_is_escaped() {
    let got = suits("1♠ <b>");
    assert!(
        got.contains(r#"<span class="scolor">♠</span>"#),
        "suit not coloured: {got}"
    );
    assert!(
        !got.contains("<b>"),
        "markup in the input was not escaped: {got}"
    );
    // the same entities the jinja and Go templates emit, so the three payloads can be diffed
    let mut escaped = String::new();
    escape_html("a<b&c\"d", &mut escaped);
    assert_eq!(escaped, "a&lt;b&amp;c&#34;d");
}

#[test]
fn the_points_gauge_is_capped_and_rounds_like_python() {
    let cases = [
        (0, 1000, 0),
        (125, 1000, 12), // 12.5 rounds to even, as python's round() does
        (175, 1000, 18), // 17.5 likewise
        (1000, 1000, 100),
        (2000, 1000, 100), // capped
    ];
    for (points, goal, want) in cases {
        assert_eq!(
            points_percent(points, goal),
            want,
            "points_percent({points}, {goal})"
        );
    }
}
