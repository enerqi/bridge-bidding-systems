//! HTML: the page shell, the patchable fragments, and the signal payloads.
//!
//! Two things worth knowing about how the fragments are split:
//!
//! * Only `#quiz` and `#toasts` are ever patched as *elements*. The score panel, the skip counter
//!   and the timer bar are markup that never changes -- their values arrive as signals and are
//!   applied by `data-text` / `data-style`.
//! * Those server-owned display signals are `_`-prefixed (`$_points`, `$_scorePct`, ...). The
//!   underscore means datastar excludes them from every outgoing request, which is exactly right:
//!   the server told the browser these values, so it must not have them echoed back.
//!
//! # Askama, and one problem this port does not have
//!
//! The templates are [`askama`]: checked and compiled at build time into `write!` calls against one
//! buffer, so a render is one growing allocation rather than a tree walk. That is the same trade
//! `templ` offers the Go port -- which did not take it, because it costs a codegen step there; here
//! it is a derive.
//!
//! The Go port also had to splice its mount prefix into the template SOURCE, because
//! `html/template` reads every `data-on:*` attribute as JavaScript (they begin with "on" once
//! `data-` is stripped) and its JS escaper rewrites `/` as `\/` -- which the load harness cannot
//! parse back out of the markup. Askama escapes for HTML and nothing else, so `{{ prefix }}` inside
//! a datastar expression is simply the prefix, and this port interpolates it like any other value.

mod names;
mod signals;
mod templates;

pub use names::{datastar_camel, datastar_kebab, topic_signal_key, topic_slug};
pub use signals::{Signals, bound_signals, local_ui_signals, server_signals, settings_signals};
pub use templates::{
    Config, PageData, TopicChoice, build_stamp, filter_status, floater, meter_sweep,
    points_percent, sfx_beat, toast, topic_choices, variant_query,
};

use std::fmt::Write as _;

/// The base stylesheet everyone gets. The A/B/C between the hand-rolled sheet, Pico and Bulma is
/// over: the three are near-indistinguishable to a player, so the picker is a DEBUG-only control.
pub const DEFAULT_CSS: &str = "pico";

/// The theme preference, remembered in a COOKIE rather than in localStorage: a cookie is on the
/// request, so the server can render `data-theme` into the FIRST PAINT, and cookies are keyed by
/// host and PATH rather than by origin, so one choice covers every instance on the machine.
pub const THEME_COOKIE: &str = "dsq_theme";

/// A cookie is user input: anything unrecognised is `auto`, never interpolated into the page.
pub fn theme_from(raw: &str) -> &'static str {
    match raw {
        "light" => "light",
        "dark" => "dark",
        _ => "auto",
    }
}

/// The naming contract: `hand` is `app.css`, anything else is `app-<value>.css`.
pub fn stylesheet_href(value: &str, prefix: &str) -> String {
    if value == "hand" {
        format!("{prefix}/static/app.css")
    } else {
        format!("{prefix}/static/app-{value}.css")
    }
}

/// What may swallow a keystroke aimed at the window. Every accelerator (1-9, `s`, Enter on the
/// reveal) is a window keydown, so each has to decide whether the focused control has a better claim
/// on the key -- and the first version of this said "any form control", which is too many. Focus a
/// RANGE input (the difficulty slider) or tick a CHECKBOX and the digits went dead for the rest of
/// the session.
pub const TYPING_TARGETS: &str = "input:not([type=range]):not([type=checkbox]):not([type=radio]), select, textarea, [contenteditable]";

/// Enter and Space are different: Space ACTIVATES a focused checkbox or radio, so those keep their
/// claim here even though they have none on a digit.
pub const ACTIVATION_TARGETS: &str = "input:not([type=range]), select, textarea, [contenteditable]";

/// The width at which the drawer stops being a column beside the quiz and becomes an overlay ON TOP
/// of it. Written once here because it has to agree with the `@media` block that repositions it.
pub const DRAWER_OVERLAY_QUERY: &str = "(max-width: 900px)";

// --- suit glyph presentation (copied from the panel app) ---------------------
//
// The plain text glyphs, deliberately WITHOUT the U+FE0F variation selector the panel app used:
// VS16 asks for emoji presentation, so hearts and diamonds were drawn by the colour emoji font while
// spades and clubs stayed text glyphs inheriting the element's colour -- which is why a spade went
// white on the dark card.

pub const SPADE: char = '♠';
pub const HEART: char = '♥';
pub const DIAMOND: char = '♦';
pub const CLUB: char = '♣';

/// glyph -> bml css class. Same names and glyphs as `bml2html._SUIT`, so the colours defined in
/// `bml.css` are the colours here.
fn suit_class(ch: char) -> Option<&'static str> {
    match ch {
        CLUB => Some("ccolor"),
        DIAMOND => Some("dcolor"),
        HEART => Some("hcolor"),
        SPADE => Some("scolor"),
        _ => None,
    }
}

/// HTML-escape, using the same entities the jinja and Go templates emit.
///
/// Askama's own escaper writes `&#60;` where those write `&lt;`; both are correct, but this text is
/// compared against the other ports' output byte for byte often enough that matching is worth five
/// lines.
pub fn escape_html(text: &str, out: &mut String) {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&#34;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
}

/// Colour the suit glyphs: `♠` -> `<span class="scolor">♠</span>`.
///
/// The input is escaped first, so this is safe for anything -- including the bml descriptions, which
/// are corpus text rather than user input, and the auctions inside toast messages. A separate step
/// from [`emoji_text_auction`] because that function's output also travels through the engine's
/// toast strings, where markup would be escaped again.
pub fn suits(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len() + 16);
    escape_html(text, &mut escaped);
    let mut out = String::with_capacity(escaped.len());
    for ch in escaped.chars() {
        match suit_class(ch) {
            Some(class) => {
                let _ = write!(out, "<span class=\"{class}\">{ch}</span>");
            }
            None => out.push(ch),
        }
    }
    out
}

// --- the auction text -------------------------------------------------------
//
// `emoji_text_auction` and its rules are copied from `apps/quiz/quiz_app.py` rather than shared --
// that module imports panel. It is presentation-only, and the copy is the one piece of deliberate
// duplication in this port, as it is in the other two.

/// silly, but a button strips excess internal whitespace, so the separator carries its own
const INVISIBLE_SEPARATOR: char = '\u{2063}';

fn bid_separator() -> String {
    let mut out = String::new();
    for _ in 0..4 {
        out.push(INVISIBLE_SEPARATOR);
    }
    out.push('‣');
    for _ in 0..4 {
        out.push(INVISIBLE_SEPARATOR);
    }
    out
}

/// The python's `_suit_replace_regex` pass: `\d([CDHS]|N(?!T))+`, a digit followed by one or more
/// denominations, with the suit letters becoming glyphs and a bare `N` becoming `NT`.
///
/// Hand-written rather than a regex because of the negative lookahead, which is what keeps an
/// already-spelled `1NT` from becoming `1NTT`.
fn suit_replace_in_bids(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < bytes.len() {
        let ch = bytes[index];
        if ch.is_ascii_digit() {
            let mut end = index + 1;
            while end < bytes.len() {
                match bytes[end] {
                    b'C' | b'D' | b'H' | b'S' => end += 1,
                    b'N' if end + 1 >= bytes.len() || bytes[end + 1] != b'T' => end += 1,
                    _ => break,
                }
            }
            if end > index + 1 {
                out.push(ch as char);
                for letter in &bytes[index + 1..end] {
                    match letter {
                        b'C' => out.push(CLUB),
                        b'D' => out.push(DIAMOND),
                        b'H' => out.push(HEART),
                        b'S' => out.push(SPADE),
                        _ => out.push_str("NT"),
                    }
                }
                index = end;
                continue;
            }
        }
        // not necessarily ascii: descriptions carry prose
        let ch = text[index..]
            .chars()
            .next()
            .expect("index is a char boundary");
        out.push(ch);
        index += ch.len_utf8();
    }
    out
}

/// Replace `C `/`D `/`H `/`S ` at a word boundary with the glyph, the python's four `\b` regexes.
fn word_suits(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < bytes.len() {
        let ch = bytes[index];
        let is_letter = matches!(ch, b'C' | b'D' | b'H' | b'S');
        let at_boundary =
            index == 0 || !(bytes[index - 1].is_ascii_alphanumeric() || bytes[index - 1] == b'_');
        if is_letter && at_boundary && bytes.get(index + 1) == Some(&b' ') {
            out.push(match ch {
                b'C' => CLUB,
                b'D' => DIAMOND,
                b'H' => HEART,
                _ => SPADE,
            });
            out.push(' ');
            index += 2;
            continue;
        }
        let ch = text[index..]
            .chars()
            .next()
            .expect("index is a char boundary");
        out.push(ch);
        index += ch.len_utf8();
    }
    out
}

/// Turn one auction (or one description) into the text the card shows: suit letters become glyphs,
/// the `-->` joiner becomes the arrow separator, and markdown link targets are dropped.
pub fn emoji_text_auction(auction: &str) -> String {
    let separator = bid_separator();
    let mut text = auction.to_owned();

    if auction.matches('(').count() == 1
        && auction.matches(')').count() == 1
        && auction.contains("(Pass)")
    {
        // superfluous (pass); better fixed in the data source, or by making all opposition bids
        // explicit
        text = text.replace("(Pass)", &separator);
    }

    text = suit_replace_in_bids(&text);
    text = replace_each(&text, &[("!c", "♣"), ("!d", "♦"), ("!h", "♥"), ("!s", "♠")]);
    text = replace_each(
        &text,
        &[
            (" C ", " ♣ "),
            (" D ", " ♦ "),
            (" H ", " ♥ "),
            (" S ", " ♠ "),
        ],
    );
    text = word_suits(&text);
    text = replace_each(
        &text,
        &[("Cs", "♣s"), ("Ds", "♦s"), ("Hs", "♥s"), ("Ss", "♠s")],
    );
    text = text.replace("-->", &separator).replace("--", "-");
    text = text.replace(['[', ']'], "");
    strip_link_targets(&text)
}

/// One pass over the text applying whichever of the pairs matches at each position.
///
/// The python chains `str.replace` calls, which is one pass over the whole string each; one pass
/// with a small table is the same answer for a fraction of the copying, and this runs on every
/// candidate of every question.
fn replace_each(text: &str, pairs: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    'outer: while index < text.len() {
        for (from, to) in pairs {
            if text[index..].starts_with(from) {
                out.push_str(to);
                index += from.len();
                continue 'outer;
            }
        }
        let ch = text[index..]
            .chars()
            .next()
            .expect("index is a char boundary");
        out.push(ch);
        index += ch.len_utf8();
    }
    out
}

/// The python's `\(#.*\)`: from the first `(#` to the LAST `)`, greedily, every time.
fn strip_link_targets(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        let Some(start) = rest.find("(#") else {
            out.push_str(rest);
            return out;
        };
        let Some(end) = rest.rfind(')') else {
            out.push_str(rest);
            return out;
        };
        if end < start {
            out.push_str(rest);
            return out;
        }
        out.push_str(&rest[..start]);
        rest = &rest[end + 1..];
    }
}
