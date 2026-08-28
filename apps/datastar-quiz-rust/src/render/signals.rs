//! The signal payloads.
//!
//! Written straight into a `String` rather than through a map and a serialiser. The keys are fixed
//! and the values are numbers, booleans and two strings, so the JSON is a handful of `write!` calls
//! and one allocation -- and the server-owned set goes out with EVERY view patch, which is the
//! hottest thing this app does after rendering.
//!
//! Keys are emitted in sorted order, which is what `encoding/json` does for a Go map and what
//! `json.dumps` does with `sort_keys`; keeping to it means the three ports' payloads can be diffed.

use std::fmt::Write as _;

use crate::engine;
use crate::render::{TopicChoice, topic_signal_key};
use crate::session::State;

/// A JSON object being built.
pub struct Signals {
    out: String,
    first: bool,
}

impl Default for Signals {
    fn default() -> Self {
        Signals::new()
    }
}

impl Signals {
    pub fn new() -> Signals {
        let mut out = String::with_capacity(320);
        out.push('{');
        Signals { out, first: true }
    }

    fn key(&mut self, key: &str) {
        if !self.first {
            self.out.push(',');
        }
        self.first = false;
        self.out.push('"');
        self.out.push_str(key);
        self.out.push_str("\":");
    }

    pub fn number(&mut self, key: &str, value: i64) -> &mut Self {
        self.key(key);
        let _ = write!(self.out, "{value}");
        self
    }

    pub fn boolean(&mut self, key: &str, value: bool) -> &mut Self {
        self.key(key);
        self.out.push_str(if value { "true" } else { "false" });
        self
    }

    pub fn string(&mut self, key: &str, value: &str) -> &mut Self {
        self.key(key);
        write_json_string(value, &mut self.out);
        self
    }

    /// A nested object of booleans -- the topic ticks.
    pub fn flags<'a>(
        &mut self,
        key: &str,
        entries: impl Iterator<Item = (&'a str, bool)>,
    ) -> &mut Self {
        self.key(key);
        self.out.push('{');
        let mut first = true;
        for (name, value) in entries {
            if !first {
                self.out.push(',');
            }
            first = false;
            write_json_string(name, &mut self.out);
            self.out.push(':');
            self.out.push_str(if value { "true" } else { "false" });
        }
        self.out.push('}');
        self
    }

    pub fn finish(mut self) -> String {
        self.out.push('}');
        self.out
    }
}

/// JSON string escaping, per RFC 8259.
fn write_json_string(value: &str, out: &mut String) {
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// The gauge's fill, capped at 100.
pub fn points_percent(points: i64, goal: i64) -> i64 {
    if goal <= 0 {
        return 0;
    }
    engine::py_round(points as f64 / goal as f64 * 100.0).min(100)
}

/// Every signal the server owns.
///
/// Local (`_`-prefixed) so they are never uploaded back. `_timeLeftPct` and `_questionMs` drive the
/// timer bar: the server states the allowance and resets the bar per question, and the browser's
/// 100ms interval walks it down. No clock is shared, because the bar is cosmetic -- the bonus that
/// actually scores is recomputed server-side when the answer arrives.
pub fn server_signals(state: &State, into: &mut Signals) {
    let time_left = if state.still_playing() {
        state.percent_time_left()
    } else {
        0
    };
    into.number("_attempted", state.score.questions_attempted)
        .number("_correct", state.score.questions_correct)
        .boolean("_playing", state.still_playing())
        .number("_points", state.score.total_points)
        .number(
            "_pointsPct",
            points_percent(state.score.total_points, state.points_goal),
        )
        .number(
            "_questionMs",
            engine::py_round(state.question_seconds * 1000.0),
        )
        .number("_scorePct", state.score.percentage())
        .number("_skipsLeft", state.skips_left)
        .number("_streak", state.score.streak)
        // Whether the countdown should be running at all. `_playing` is not the same question: a
        // scored answer parks on the reveal with the quiz very much still in play, and the bar kept
        // draining there -- time pressure on a question that had already been answered.
        .boolean("_ticking", state.on_the_clock())
        .number("_timeLeftPct", time_left);
}

/// The *effective* settings, to be echoed back after the server has adopted them.
///
/// The browser originates these, but the server clamps them, so after adopting a value the two can
/// disagree -- send `difficulty: 99` and the server uses 8 while the slider still reads 99 until the
/// next page load.
///
/// Note what is deliberately NOT here: `filterText` and the `topics` ticks. Those are drafts the
/// user may be in the middle of editing, and re-stating them on an unrelated patch (a Skip, say)
/// would wipe what they were typing.
pub fn settings_signals(state: &State, into: &mut Signals) {
    into.number("difficulty", i64::from(state.settings.difficulty))
        .boolean("ladderMode", state.settings.ladder_mode)
        .boolean("targetOn", state.settings.target_on)
        .number("targetPct", state.settings.target_pct);
}

/// The signals the *browser* owns: form inputs bound with `data-bind`.
///
/// These have no underscore, so datastar uploads them with every request -- that is how the server
/// learns the slider moved. `topics` is seeded from the filter in force, so the picker's ticks agree
/// with it even when the filter was typed rather than picked.
pub fn bound_signals(
    state: &State,
    choices: &[TopicChoice],
    active_topics: &[String],
    into: &mut Signals,
) {
    settings_signals(state, into);
    into.string("filterText", &state.filter_text);
    let ticked: Vec<String> = active_topics
        .iter()
        .map(|name| topic_signal_key(name))
        .collect();
    into.flags(
        "topics",
        choices
            .iter()
            .map(|choice| (choice.key.as_str(), ticked.contains(&choice.key))),
    );
}

/// View-local signals the server never sets, declared so they exist from the first paint.
///
/// They must be declared: an undefined signal reads as `''` in an expression, and `data-attr` treats
/// `''` as "set the attribute", so an undeclared `$_topicsOpen` leaves `<dialog open>` -- the picker
/// is stuck open. Declared in the `data-signals` OBJECT rather than as `data-signals:_topics-open`,
/// because attribute keys are kebab-then-camel converted, which eats a leading underscore -- and the
/// underscore is what keeps these out of every request.
pub fn local_ui_signals(theme: &str, into: &mut Signals) {
    into.boolean("_answering", false)
        .string("_css", crate::render::DEFAULT_CSS)
        .string("_font", "notes")
        // The "game feel" experiment: hit-stop and shake on the reveal, floating points on the card
        // you picked, and an escalating streak chip. Purely presentational, so purely local.
        .boolean("_juice", true)
        // closed at every width now that the drawer holds only settings
        .boolean("_navOpen", false)
        // Sound, OFF by default and the only appearance preference that is. Everything else here
        // changes how the page looks to the person who asked for it; audio arrives in a room. It
        // also gates the FETCH: the <audio> elements have no `src` until this is true.
        .boolean("_sound", false)
        // `auto` | `light` | `dark`, remembered across reloads in the theme cookie and seeded from
        // it here, so the signal and the server-rendered attribute agree from the first frame
        .string("_theme", theme)
        .boolean("_topicsOpen", false);
}
