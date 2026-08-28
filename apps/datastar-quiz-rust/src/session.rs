//! Server-side session state -- the authoritative quiz.
//!
//! Datastar's doctrine: "Most state should live in the backend. Since the frontend is exposed to the
//! user, the backend should be the source of truth." Everything here is state the browser must not
//! own: the current question (it carries the answer), the score and milestone ledger, and the
//! working set of auctions.
//!
//! # Two shapes the language chose
//!
//! **The corpus is `&'static`.** It is loaded once and lives for the process, so it is leaked at
//! startup rather than wrapped in an `Arc` that every session would refcount. A session then holds a
//! plain shared reference to its system, which costs nothing to copy and nothing to drop.
//!
//! **The working set is `Arc<[u32]>`.** An unfiltered session shares the system's "everything" list;
//! a filtered one shares the memo's answer. Neither copies an auction, and two browsers that apply
//! the same filter hold the same allocation.

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{Duration, Instant, SystemTime};

use parking_lot::{Mutex, RwLock};
use rand::RngExt;
use std::collections::HashMap;

use crate::corpus::{FilterCheck, System};
use crate::engine::{self, Question, Score};

/// The cookie identifies the BROWSER, not the quiz: sessions live under (browser, variant), so the
/// squad quiz and the swedish one coexist instead of one replacing the other. Deliberately still one
/// cookie under one name -- nginx pins a browser to a worker with `hash $cookie_dsq_sid consistent`,
/// and a name that varied by variant would leave that directive hashing on a cookie half the
/// requests do not carry.
pub const COOKIE: &str = "dsq_sid";

pub const TTL: Duration = Duration::from_secs(6 * 60 * 60);
pub const SWEEP_PERIOD: Duration = Duration::from_secs(10 * 60);

/// THE QUESTION NONCE IS PROCESS-WIDE, and that is the whole point of it.
///
/// Per session, starting at 1, a page whose session had been REPLACED -- `?swedish` used to discard
/// the old session, a restart empties the store, a session ages out after six hours -- posted qid=1
/// at a brand new session whose first question was *also* qid=1. The staleness guard then passed by
/// coincidence and the answer was scored against a question that had never been on screen. That is
/// the "I answered one question and it showed me another" report, and it is not a race: it is two
/// counters that both start at 1.
static QIDS: AtomicI64 = AtomicI64::new(0);

/// The next question nonce. Unique per process, not per session.
pub fn next_qid() -> i64 {
    QIDS.fetch_add(1, Ordering::Relaxed) + 1
}

/// The bound signals, as last seen from the browser. Mirrors of client-originated state: the browser
/// is the source of truth for these, and every request re-states them.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Settings {
    pub difficulty: u8,
    pub ladder_mode: bool,
    pub target_on: bool,
    pub target_pct: i64,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            difficulty: engine::INITIAL_DIFFICULTY,
            ladder_mode: true,
            target_on: false,
            target_pct: 70,
        }
    }
}

/// One quiz in progress.
pub struct Session {
    pub sid: String,
    pub system: &'static System,
    /// Everything a request mutates, behind one lock.
    ///
    /// The litestar app is a single asyncio loop: a handler runs to its next `await` with no other
    /// handler inside the same session, so nothing there needs a lock. Here every request is a task
    /// and several can hold one session at once -- two tabs, a click arriving during an answer
    /// stream, the held timer connection ticking. Rust will not let that state be touched without
    /// the lock, which is the difference between "we remembered to guard it" and "it cannot be
    /// otherwise".
    pub state: Mutex<State>,
}

pub struct State {
    pub settings: Settings,
    pub score: Score,
    /// indices into `system.auctions`: the whole system, or a filter's hits, shared either way
    pub working_set: Arc<[u32]>,
    pub question: Question,
    /// set from [`next_qid`]; the answer route rejects a stale one. Never per-session.
    pub qid: i64,
    pub skips_left: i64,
    pub last_correct_points: i64,
    pub filter_text: String,

    pub quiz_start: SystemTime,
    pub completion: Option<SystemTime>,
    pub question_start: Instant,
    pub question_seconds: f64,
    pub touched: Instant,

    /// Set when a wrong answer has been scored: the question stays on screen with the right answer
    /// marked, and nothing moves on until the player asks. Panel instead blocked for 4.2s behind a
    /// centre-screen toast.
    pub awaiting_next: bool,
    pub wrong_index: Option<usize>,

    /// Per-session so the debug panel can shorten a quiz without mutating a constant.
    pub points_goal: i64,
    /// Set when the session was opened with `?debug` (or `DSQUIZ_DEBUG=1`). Sticky, like the
    /// variant, because the query is gone after the first navigation.
    pub debug: bool,

    /// What was left on the clock when the question was answered. The allowance stops mattering the
    /// moment an answer is scored, so it is frozen rather than left running: otherwise a reload
    /// while parked on the reveal reports a smaller number than the one the answer was scored with.
    pub frozen_time_left: Option<i64>,
}

impl State {
    pub fn still_playing(&self) -> bool {
        self.completion.is_none()
    }

    /// Whether a live, unanswered question is being timed.
    ///
    /// False while parked on a reveal and after completion -- the two states where the countdown
    /// must stop rather than keep draining.
    pub fn on_the_clock(&self) -> bool {
        self.still_playing() && !self.awaiting_next
    }

    /// How long the quiz took, to one decimal (the completion screen's number).
    pub fn elapsed_seconds(&self) -> f64 {
        let end = self.completion.unwrap_or_else(SystemTime::now);
        let seconds = end
            .duration_since(self.quiz_start)
            .unwrap_or_default()
            .as_secs_f64();
        (seconds * 10.0).round() / 10.0
    }

    /// What is left of this question's allowance.
    pub fn percent_time_left(&self) -> i64 {
        if let Some(frozen) = self.frozen_time_left {
            return frozen;
        }
        engine::percent_time_left(
            self.question_start.elapsed().as_secs_f64(),
            self.question_seconds,
        )
    }

    /// Stop the countdown where it stands, because this question has been answered.
    pub fn freeze_question_clock(&mut self) {
        self.frozen_time_left = Some(self.percent_time_left());
    }

    /// Draw a new question and restart its clock. The qid changes, which is what makes the previous
    /// question's answer buttons dead -- a double click cannot score twice.
    pub fn next_question(&mut self, system: &'static System) {
        self.awaiting_next = false;
        self.wrong_index = None;
        self.question = engine::new_question(
            &system.auctions,
            &self.working_set,
            self.settings.difficulty,
        );
        self.qid = next_qid();
        self.question_seconds = engine::seconds_for_difficulty(self.settings.difficulty);
        self.start_question_clock();
    }

    /// (Re)start the allowance for the current question.
    ///
    /// Called again when the question actually reaches the browser: the answer stream spends up to
    /// several seconds showing notifications after the next question has been drawn, and charging
    /// the player for that time would cost them a chunk of their bonus.
    pub fn start_question_clock(&mut self) {
        self.question_start = Instant::now();
        self.frozen_time_left = None;
    }

    /// Commit a bidding-tree filter, narrowing the working set, and report whether it changed.
    ///
    /// Anything other than a usable filter falls back to the whole system, and the stored text is
    /// the *canonical* form (topic prefixes resolved, whitespace tidied) so the input box can show
    /// what is really in force.
    pub fn apply_filter(
        &mut self,
        system: &'static System,
        text: &str,
        min_hits: usize,
    ) -> (Arc<FilterCheck>, bool) {
        let check = system.check_filter(text, min_hits);
        self.working_set = if check.usable() {
            Arc::clone(&check.hits)
        } else {
            Arc::clone(&system.check_filter("", min_hits).hits)
        };
        let changed = check.parsed.canonical_text != self.filter_text;
        self.filter_text = check.parsed.canonical_text.clone();
        (check, changed)
    }

    /// The port of the panel's `reset_skips_and_scoring_and_timer_and_question`. Every settings or
    /// filter change goes through here, as in the panel app.
    pub fn restart(&mut self, system: &'static System) {
        self.score.reset();
        self.skips_left = engine::INITIAL_SKIPS;
        self.last_correct_points = 0;
        self.quiz_start = SystemTime::now();
        self.completion = None;
        self.next_question(system);
    }

    pub fn complete(&mut self) {
        self.completion = Some(SystemTime::now());
    }
}

impl Session {
    /// Build a quiz for a system under the given browser id.
    pub fn new(system: &'static System, sid: Option<&str>) -> Session {
        let settings = Settings::default();
        let working_set = Arc::clone(
            &system
                .check_filter("", usize::from(engine::MAX_DIFFICULTY))
                .hits,
        );
        let question = engine::new_question(&system.auctions, &working_set, settings.difficulty);
        let now = Instant::now();
        Session {
            sid: sid.map(str::to_owned).unwrap_or_else(new_sid),
            system,
            state: Mutex::new(State {
                settings,
                score: Score::default(),
                working_set,
                question,
                // from the process-wide counter, so this session's first question cannot share a
                // nonce with the first question of the session it replaced -- see `next_qid`
                qid: next_qid(),
                skips_left: engine::INITIAL_SKIPS,
                last_correct_points: 0,
                filter_text: String::new(),
                quiz_start: SystemTime::now(),
                completion: None,
                question_start: now,
                question_seconds: engine::seconds_for_difficulty(settings.difficulty),
                touched: now,
                awaiting_next: false,
                wrong_index: None,
                points_goal: engine::POINTS_GOAL,
                debug: false,
                frozen_time_left: None,
            }),
        }
    }
}

/// A random browser id. 128 bits of `rand`'s thread generator, hex-encoded -- the same shape as the
/// Go port's `crypto/rand` value and the python's `uuid4().hex`.
fn new_sid() -> String {
    let mut rng = rand::rng();
    let bytes: [u8; 16] = rng.random();
    let mut out = String::with_capacity(32);
    for byte in bytes {
        out.push(char::from_digit(u32::from(byte >> 4), 16).expect("nibble"));
        out.push(char::from_digit(u32::from(byte & 0xf), 16).expect("nibble"));
    }
    out
}

/// The process-local session registry with TTL eviction, keyed by (browser, variant).
///
/// ONE QUIZ PER VARIANT PER BROWSER, which is what panel had for free by keying its sessions on the
/// variant. The single-session version replaced the whole quiz whenever `?swedish` was opened, and
/// with one cookie per browser that reached across tabs: the squad tab, the back-history entry and
/// the phone's first tab were all left holding a quiz that no longer existed, mid-score.
///
/// The `sid` still identifies the browser, so it stays a single cookie. `current` remembers which
/// variant a browser last *navigated* to, for the one request that cannot say: a page load with a
/// query that names no variant (`?debug`).
/// NESTED, not keyed by a `(String, String)` tuple.
///
/// A `HashMap<(String, String), _>` cannot be looked up with two `&str`s -- `Borrow` does not reach
/// inside a tuple -- so every request would allocate two `String`s just to ask a question. Nesting
/// the maps lets both levels be probed with a borrowed key, which takes the session lookup on the
/// hot path from two allocations to none.
pub struct Store {
    sessions: RwLock<HashMap<String, HashMap<String, Arc<Session>>>>,
    current: RwLock<HashMap<String, String>>,
    ttl: Duration,
}

impl Default for Store {
    fn default() -> Self {
        Store::with_ttl(TTL)
    }
}

impl Store {
    pub fn with_ttl(ttl: Duration) -> Store {
        Store {
            sessions: RwLock::new(HashMap::new()),
            current: RwLock::new(HashMap::new()),
            ttl,
        }
    }

    /// This browser's session for `variant_key`, or for whatever it is currently on when the key is
    /// empty.
    pub fn get(&self, sid: &str, variant_key: &str) -> Option<Arc<Session>> {
        if sid.is_empty() {
            return None;
        }
        let found = {
            let sessions = self.sessions.read();
            let by_variant = sessions.get(sid)?;
            if variant_key.is_empty() {
                // the only path that has to name the variant from elsewhere, so the only one that
                // touches the second map
                let current = self.current.read();
                by_variant.get(current.get(sid)?.as_str()).map(Arc::clone)?
            } else {
                by_variant.get(variant_key).map(Arc::clone)?
            }
        };
        found.state.lock().touched = Instant::now();
        Some(found)
    }

    /// The variant this browser last navigated to, if the store still has it.
    pub fn current_variant(&self, sid: &str) -> Option<String> {
        if sid.is_empty() {
            return None;
        }
        self.current.read().get(sid).cloned()
    }

    /// Build a quiz for a system under the given browser id (a new browser if there is none).
    pub fn create(&self, system: &'static System, sid: Option<&str>) -> Arc<Session> {
        let created = Arc::new(Session::new(system, sid));
        self.sessions
            .write()
            .entry(created.sid.clone())
            .or_default()
            .insert(system.variant.key.clone(), Arc::clone(&created));
        // Only if absent, not an assignment: a browser with NO mark has to get one from somewhere,
        // and the quiz it just had built is the only candidate. A browser that already has one keeps
        // it -- moving the mark is a navigation's job, so a rebuild triggered by a background tab's
        // click cannot decide what the next `?debug` page load resumes.
        self.current
            .write()
            .entry(created.sid.clone())
            .or_insert_with(|| system.variant.key.clone());
        created
    }

    /// Note which variant this browser is on. Page loads only: an interaction from a background tab
    /// must not move the mark, since that is the cross-tab bleed this store exists to end.
    pub fn remember(&self, session: &Session) {
        self.current
            .write()
            .insert(session.sid.clone(), session.system.variant.key.clone());
    }

    pub fn len(&self) -> usize {
        self.sessions.read().values().map(HashMap::len).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Drop sessions older than the TTL and forget browsers with none left.
    pub fn sweep(&self) -> usize {
        let now = Instant::now();
        let mut sessions = self.sessions.write();
        let count = |map: &HashMap<String, HashMap<String, Arc<Session>>>| -> usize {
            map.values().map(HashMap::len).sum()
        };
        let before = count(&sessions);
        for by_variant in sessions.values_mut() {
            by_variant
                .retain(|_, session| now.duration_since(session.state.lock().touched) <= self.ttl);
        }
        // a browser with no quizzes left is forgotten entirely, along with its variant mark
        sessions.retain(|_, by_variant| !by_variant.is_empty());
        let mut current = self.current.write();
        current.retain(|sid, _| sessions.contains_key(sid));
        before - count(&sessions)
    }
}
