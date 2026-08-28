//! The compiled templates and the view models they render.

use std::collections::HashMap;
use std::sync::OnceLock;

use askama::Template;
use parking_lot::Mutex;

use crate::corpus::{FilterCheck, Status, System, Variant};
use crate::engine::{self, ChoiceType, Toast};
pub use crate::render::signals::points_percent;
use crate::render::{
    self, ACTIVATION_TARGETS, DEFAULT_CSS, DRAWER_OVERLAY_QUERY, Signals, THEME_COOKIE,
    TYPING_TARGETS, bound_signals, escape_html, local_ui_signals, server_signals, topic_signal_key,
    topic_slug,
};
use crate::session::{Session, Settings, State};

/// The deployment-shaped state the renderer needs and does not own.
#[derive(Clone, Debug)]
pub struct Config {
    /// Where the app is mounted, when it is not at the root of a host. Empty for a root mount.
    pub prefix: String,
    /// "client" or "stream" -- see the note in the web module.
    pub timer_mode: String,
}

impl Config {
    pub fn stream_timer(&self) -> bool {
        self.timer_mode == "stream"
    }
}

/// One row of the topics picker.
pub struct TopicChoice {
    pub name: String,
    pub slug: String,
    pub key: String,
    pub description: String,
}

/// The topics picker's rows: built once per system, not once per render.
///
/// The python memoises the four naming functions because a profile counted tens of thousands of
/// calls a minute for values that are pure functions of a topic name that never changes within a
/// process. The same fix applies here, one level up: the whole derived row set is computed once and
/// leaked, because it lives as long as the corpus does.
pub fn topic_choices(system: &'static System) -> &'static [TopicChoice] {
    static CHOICES: OnceLock<Mutex<HashMap<String, &'static [TopicChoice]>>> = OnceLock::new();
    let cache = CHOICES.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(found) = cache.lock().get(&system.variant.key) {
        return found;
    }
    let built: Vec<TopicChoice> = system
        .topics
        .list
        .iter()
        .map(|topic| TopicChoice {
            name: topic.name.clone(),
            slug: topic_slug(&topic.name),
            key: topic_signal_key(&topic.name),
            description: topic.description.clone(),
        })
        .collect();
    let leaked: &'static [TopicChoice] = Box::leak(built.into_boxed_slice());
    cache.lock().insert(system.variant.key.clone(), leaked);
    leaked
}

/// A short fingerprint of the templates, shown in the debug panel.
///
/// Not vanity. Three times in the python app a "this is broken again" turned out to be a process
/// serving code from before the fix. Rust cannot hot-reload at all, so here the stamp answers the
/// narrower question the same way: is the binary in front of me the one I just built?
pub fn build_stamp() -> &'static str {
    static STAMP: OnceLock<String> = OnceLock::new();
    STAMP.get_or_init(|| {
        // FNV-1a over the template sources, which the compiler has already inlined into the binary
        let mut hash: u64 = 0xcbf29ce484222325;
        for source in [
            include_str!("../../templates/shell.html"),
            include_str!("../../templates/app.html"),
            include_str!("../../templates/quiz.html"),
            include_str!("../../templates/reveal.html"),
            include_str!("../../templates/completed.html"),
            include_str!("../../templates/topics.html"),
        ] {
            for byte in source.bytes() {
                hash ^= u64::from(byte);
                hash = hash.wrapping_mul(0x100000001b3);
            }
        }
        let hex = format!("{hash:x}");
        hex[hex.len().saturating_sub(6)..].to_owned()
    })
}

/// The query every ACTION url carries, naming the system this page belongs to (`?swedish`).
///
/// The session cookie is one per browser, so it cannot say which quiz a given *page* is playing:
/// open `?swedish` and the squad tab, the back-history entry and the phone's other tab all still
/// hold the old markup while the cookie has moved on. The page's own URLs can say it.
pub fn variant_query(variant: &Variant) -> String {
    format!("?{}", variant.key)
}

/// Everything both the document and the fat-morph fragment need.
pub struct PageData {
    pub variant_title: String,
    pub system_notes_url: String,
    pub settings: Settings,
    pub playing: bool,
    pub quiz_body: String,
    pub min_difficulty: u8,
    pub max_difficulty: u8,
    pub milestone_ticks: Vec<i64>,
    pub points_goal: i64,
    pub debug: bool,
    pub qid: i64,
    pub stream_timer: bool,
    pub build_stamp: &'static str,
    pub css_href: String,
    pub theme_cookie: &'static str,
    pub cookie_path: String,
    pub topics: &'static [TopicChoice],
    pub topics_have_descriptions: bool,
    pub filter_text: String,
    pub filter_status: String,
    pub prefix: String,
    pub variant_query: String,
    pub drawer_overlay_query: &'static str,
    pub typing_targets: &'static str,
    pub activation_targets: &'static str,
}

#[derive(Template)]
#[template(path = "app.html")]
struct AppTemplate<'a> {
    page: &'a PageData,
}

#[derive(Template)]
#[template(path = "shell.html")]
struct ShellTemplate<'a> {
    page: &'a PageData,
    initial_signals: &'a str,
    /// The static `data-theme` on <html>, or empty. `auto` is the ABSENCE of the attribute, so this
    /// is the whole attribute rather than a value.
    theme_attr: &'a str,
    sfx_names: &'static [&'static str],
}

#[derive(Template)]
#[template(path = "quiz.html")]
struct QuizTemplate<'a> {
    intro: &'a str,
    answer: String,
    candidates: Vec<String>,
    qid: i64,
    prefix: &'a str,
    variant_query: &'a str,
    typing_targets: &'static str,
}

#[derive(Template)]
#[template(path = "reveal.html")]
struct RevealTemplate<'a> {
    intro: &'a str,
    answer: String,
    candidates: Vec<String>,
    /// `usize::MAX` when there is none -- a sentinel rather than an `Option`, because the template
    /// compares it against the loop index and askama hands that over as a reference.
    correct_index: usize,
    wrong_index: usize,
    prefix: &'a str,
    variant_query: &'a str,
    activation_targets: &'static str,
}

/// One piece of the finale burst: glyph, horizontal drift %, rotation, delay step.
struct ConfettiBit {
    glyph: &'static str,
    drift: i32,
    spin: i32,
    step: i32,
}

/// Fixed, not random, because the server renders it and a reload should not re-roll the party. The
/// numbers are spread by hand so the burst looks scattered rather than combed, which is the one
/// thing a formula (`i * 37 % 100`) visibly fails at.
const CONFETTI: [(&str, i32, i32, i32); 16] = [
    ("🎉", -42, -35, 0),
    ("🎊", -28, 24, 3),
    ("✨", -35, -12, 7),
    ("🥳", -14, 41, 1),
    ("🎉", -6, -28, 5),
    ("🎊", 9, 16, 2),
    ("✨", 18, -44, 8),
    ("🎉", 27, 31, 4),
    ("🥳", 36, -19, 6),
    ("🎊", 44, 38, 1),
    ("✨", -21, 9, 9),
    ("🎉", 3, -40, 7),
    ("🎊", 31, 12, 3),
    ("✨", -47, 27, 5),
    ("🥳", 22, -33, 8),
    ("🎉", -11, 44, 2),
];

#[derive(Template)]
#[template(path = "completed.html")]
struct CompletedTemplate<'a> {
    elapsed: i64,
    points: i64,
    correct: i64,
    attempted: i64,
    percentage: i64,
    goal: i64,
    confetti: Vec<ConfettiBit>,
    prefix: &'a str,
}

/// One span per character, numbered, so each digit can be sent in from somewhere different. The
/// unit lives INSIDE the figure: `.finale-stat` is a flex column, so a sibling `%` or `s` became its
/// own row under the number.
fn figure(value: i64, class: &str, unit: &str) -> String {
    let mut out = String::with_capacity(64);
    out.push_str("<span class=\"figure ");
    out.push_str(class);
    out.push_str("\">");
    for (index, ch) in value.to_string().chars().enumerate() {
        out.push_str("<span class=\"digit\" style=\"--i: ");
        out.push_str(&index.to_string());
        out.push_str("\">");
        out.push(ch);
        out.push_str("</span>");
    }
    if !unit.is_empty() {
        out.push_str("<span class=\"figure-unit\">");
        out.push_str(unit);
        out.push_str("</span>");
    }
    out.push_str("</span>");
    out
}

fn intro_for(choice_type: Option<ChoiceType>) -> &'static str {
    match choice_type {
        Some(ChoiceType::Descriptions) => {
            "Which description matches the final bid in this sequence:"
        }
        _ => "In which auction is the final bid best described by:",
    }
}

impl Config {
    /// Build everything both the document and the fat-morph fragment need.
    pub fn page_data(
        &self,
        session: &Session,
        state: &State,
    ) -> (PageData, std::sync::Arc<FilterCheck>) {
        let system = session.system;
        let check = system.check_filter(&state.filter_text, usize::from(engine::MAX_DIFFICULTY));
        let topics = topic_choices(system);
        let cookie_path = if self.prefix.is_empty() {
            "/".to_owned()
        } else {
            self.prefix.clone()
        };
        let page = PageData {
            variant_title: system.variant.title.clone(),
            system_notes_url: system.variant.system_notes_url.clone(),
            settings: state.settings,
            playing: state.still_playing(),
            quiz_body: self.quiz_body(session, state),
            min_difficulty: engine::MIN_DIFFICULTY,
            max_difficulty: engine::MAX_DIFFICULTY,
            milestone_ticks: engine::SCORE_MILESTONES
                .iter()
                .filter(|milestone| **milestone < 1.0)
                .map(|milestone| engine::py_round(milestone * 100.0))
                .collect(),
            points_goal: state.points_goal,
            debug: state.debug,
            qid: state.qid,
            stream_timer: self.stream_timer(),
            build_stamp: build_stamp(),
            css_href: render::stylesheet_href(DEFAULT_CSS, &self.prefix),
            theme_cookie: THEME_COOKIE,
            cookie_path,
            topics,
            topics_have_descriptions: topics.iter().any(|topic| !topic.description.is_empty()),
            filter_text: state.filter_text.clone(),
            filter_status: filter_status(&check, &state.filter_text, ""),
            prefix: self.prefix.clone(),
            variant_query: variant_query(&system.variant),
            drawer_overlay_query: DRAWER_OVERLAY_QUERY,
            typing_targets: TYPING_TARGETS,
            activation_targets: ACTIVATION_TARGETS,
        };
        (page, check)
    }

    /// The whole document: server-rendered current state, no client-side bootstrap, so view-source
    /// is the state of the quiz and a reload resumes it exactly.
    ///
    /// `theme` comes from the cookie the toggle wrote. It is rendered STATICALLY onto <html> as well
    /// as declared as a signal: the attribute is what makes the first paint right, and the signal is
    /// what keeps it right when the toggle is clicked.
    pub fn shell(&self, session: &Session, state: &State, theme: &str) -> String {
        let (page, check) = self.page_data(session, state);
        let mut signals = Signals::new();
        bound_signals(state, page.topics, &check.parsed.topic_names, &mut signals);
        server_signals(state, &mut signals);
        local_ui_signals(theme, &mut signals);
        let initial = signals.finish();

        let theme_attr = if theme == "auto" {
            String::new()
        } else {
            let mut attr = String::from(" data-theme=\"");
            escape_html(theme, &mut attr);
            attr.push('"');
            attr
        };
        ShellTemplate {
            page: &page,
            initial_signals: &initial,
            theme_attr: &theme_attr,
            sfx_names: crate::sfx::NAMES,
        }
        .render()
        .expect("the templates are compiled and their data cannot fail to format")
    }

    /// The whole page below <body>: the fat-morph unit.
    ///
    /// Sending this rather than a hand-picked fragment is what the Tao of Datastar asks for, and it
    /// removes a class of bug -- the server no longer has to remember which fragments a state change
    /// touches.
    pub fn app_body(&self, session: &Session, state: &State) -> String {
        let (page, _) = self.page_data(session, state);
        AppTemplate { page: &page }
            .render()
            .expect("compiled template")
    }

    /// The `#quiz` fragment: prompt, the thing to match, and the candidate buttons -- or the
    /// revealed answer after a wrong one, or the completion screen once the points goal is met.
    pub fn quiz_body(&self, session: &Session, state: &State) -> String {
        if !state.still_playing() {
            return CompletedTemplate {
                // rounded to whole seconds: the finale renders this at 2.4rem, one span per
                // character, and "137" assembles better than "137.4"
                elapsed: engine::py_round(state.elapsed_seconds()),
                points: state.score.total_points,
                correct: state.score.questions_correct,
                attempted: state.score.questions_attempted,
                percentage: state.score.percentage(),
                goal: state.points_goal,
                confetti: CONFETTI
                    .iter()
                    .map(|(glyph, drift, spin, step)| ConfettiBit {
                        glyph,
                        drift: *drift,
                        spin: spin * 12,
                        step: *step,
                    })
                    .collect(),
                prefix: &self.prefix,
            }
            .render()
            .expect("compiled template");
        }
        let question = &state.question;
        let mut answer = render::emoji_text_auction(&question.answer);
        if let Some(first) = answer.chars().next() {
            let upper: String = first.to_uppercase().collect();
            answer = upper + &answer[first.len_utf8()..];
        }
        let candidates: Vec<String> = question
            .candidates
            .iter()
            .map(|candidate| render::suits(&render::emoji_text_auction(candidate)))
            .collect();
        let intro = intro_for(question.choice_type);
        let variant_query = variant_query(&session.system.variant);

        if state.awaiting_next {
            return RevealTemplate {
                intro,
                answer: render::suits(&answer),
                candidates,
                correct_index: question.answer_index().unwrap_or(usize::MAX),
                wrong_index: state.wrong_index.unwrap_or(usize::MAX),
                prefix: &self.prefix,
                variant_query: &variant_query,
                activation_targets: ACTIVATION_TARGETS,
            }
            .render()
            .expect("compiled template");
        }
        QuizTemplate {
            intro,
            answer: render::suits(&answer),
            candidates,
            qid: state.qid,
            prefix: &self.prefix,
            variant_query: &variant_query,
            typing_targets: TYPING_TARGETS,
        }
        .render()
        .expect("compiled template")
    }
}

// --- the small fragments ----------------------------------------------------

/// The `#toasts` fragment. An empty text renders an empty container -- the panel handler's bare
/// one-second beat between the last toast and the next question.
pub fn toast(item: &Toast) -> String {
    if item.text.is_empty() {
        return String::new();
    }
    format!(
        "<div class=\"toast {kind} notification is-{kind}\">{text}</div>",
        kind = item.kind,
        text = render::suits(&item.text)
    )
}

/// The number that floats up off the card the player chose, or "" for a beat without one.
///
/// The floater says what you SCORED, so only the beats carrying a number get one -- "Correct!" and
/// "Not quite" are already said by the card's own tick or cross. `+1 SKIP!` earns one because it is
/// a reward the corner toast makes too easy to miss.
///
/// `final_beat` marks the answer that crossed the points goal: the same number, in gold, larger and
/// slower, because it is the last one the player will ever see on that card.
pub fn floater(item: &Toast, final_beat: bool) -> String {
    let text = item.text.trim();
    let label = if text.to_ascii_uppercase().contains("SKIP") {
        "+1 SKIP".to_owned()
    } else {
        match find_signed_number(text) {
            Some(number) => number.to_owned(),
            None => return String::new(),
        }
    };
    let mut kind = if label.starts_with('+') {
        "gain".to_owned()
    } else {
        "loss".to_owned()
    };
    if final_beat {
        kind.push_str(" final");
    }
    format!("<span class=\"floater {kind}\" aria-hidden=\"true\">{label}</span>")
}

/// The python's `[+-]\d+`.
fn find_signed_number(text: &str) -> Option<&str> {
    let bytes = text.as_bytes();
    for start in 0..bytes.len() {
        if bytes[start] != b'+' && bytes[start] != b'-' {
            continue;
        }
        let mut end = start + 1;
        while end < bytes.len() && bytes[end].is_ascii_digit() {
            end += 1;
        }
        if end > start + 1 {
            return Some(&text[start..end]);
        }
    }
    None
}

/// One sound beat: markup that plays `<audio id="sfx-<beat>">`, which is already in the page.
///
/// Appended to `#sfx`, which is the same trick as the floaters -- the server knows when the beat
/// happened, so the beat is a patch rather than something the browser has to work out. Two things
/// are deliberate: `$_sound &&` gates it client-side, because the preference is a LOCAL signal the
/// server cannot know; and `play()` alone, because an element that has ENDED rewinds itself on the
/// next call and one still playing ignores it, which is what makes `tick` self-spacing.
pub fn sfx_beat(beat: &str) -> String {
    format!(
        "<span aria-hidden=\"true\" data-init=\"$_sound && document.getElementById('sfx-{beat}')?.play()?.catch(() => {{}})\"></span>"
    )
}

/// The shine that crosses the points gauge when a milestone has just paid for a skip. Appended to
/// the gauge itself, so it needs no signal and no cleanup: the fat morph at the end of the answer
/// stream rewrites `#app` from markup that never contains it.
pub fn meter_sweep() -> &'static str {
    "<span class=\"meter-sweep\" aria-hidden=\"true\"></span>"
}

/// The `#filter-status` fragment: what the text in the box *would* select.
///
/// Asking never commits anything, so this is safe to render on every keystroke -- which is the
/// point: the validation lives with the matcher, on the server, and the browser needs to know
/// nothing about bidding.
pub fn filter_status(check: &FilterCheck, in_force: &str, pending_hint: &str) -> String {
    let parsed = &check.parsed;
    let mut lines: Vec<String> = Vec::new();
    if !parsed.errors.is_empty() {
        // the unrecognised entries are whatever the user typed, so they are escaped
        let mut line = String::from("⚠ not a topic or pattern: ");
        for (index, error) in parsed.errors.iter().enumerate() {
            if index > 0 {
                line.push_str(", ");
            }
            line.push_str("<code>");
            escape_html(error, &mut line);
            line.push_str("</code>");
        }
        lines.push(line);
    }
    match check.status {
        Status::TooFew => lines.push(format!(
            "⚠ only {} match, need {}+ — the whole system is used",
            check.hits.len(),
            engine::MAX_DIFFICULTY
        )),
        Status::Error => lines.push("⚠ nothing usable — the whole system is used".to_owned()),
        _ if parsed.entries.is_empty() => lines.push(format!(
            "the whole system, <strong>{}</strong> auctions",
            check.hits.len()
        )),
        _ => lines.push(format!(
            "<strong>{}</strong> auctions match",
            check.hits.len()
        )),
    }
    if !pending_hint.is_empty() && parsed.canonical_text != in_force {
        let mut line = String::from("<em>");
        escape_html(pending_hint, &mut line);
        line.push_str("</em>");
        lines.push(line);
    }
    let mut out = String::with_capacity(96);
    for line in lines {
        out.push_str("<div class=\"filter-line\">");
        out.push_str(&line);
        out.push_str("</div>\n");
    }
    out
}
