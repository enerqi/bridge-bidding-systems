//! The routes.

use std::sync::Arc;
use std::time::Duration;

use async_stream::stream;
use axum::body::{Body, Bytes};

use axum::extract::{Path, State as AxumState};
use axum::http::{HeaderMap, HeaderValue, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use datastar::prelude::*;
use serde_json::{Map, Value};

use super::sse::{self, Encoding, Stream};
use super::{
    APP_SELECTOR, FILTER_STATUS_SELECTOR, METER_SELECTOR, QUIZ_SELECTOR, SFX_SELECTOR, State,
    TOASTS_SELECTOR, TOPICS_STATUS_SELECTOR,
};
use crate::corpus::System;
use crate::engine::{self, AnswerInput, Toast};
use crate::render::{self, Signals};
use crate::session::{self, Session, State as SessionState};
use crate::sfx;

/// The datastar signal payload on this request, or `None` if the body is not usable.
///
/// A map rather than a typed struct, which is what the python and Go both have: PRESENCE matters.
/// `difficulty` missing means "the browser did not say", and a struct's zero value cannot tell that
/// from "the browser said 0". The SDK's own `ReadSignals` extractor is deliberately not used
/// either -- it rejects a malformed payload with a 400, and a malformed payload here is a client
/// mistake that the app answers with a no-op 204, which is what the load harness expects.
fn read_signals(body: &str) -> Option<Map<String, Value>> {
    match serde_json::from_str::<Value>(body) {
        Ok(Value::Object(map)) => Some(map),
        _ => None,
    }
}

/// Signals on a GET arrive as `?datastar=<json>`.
///
/// Parsed out of the RAW query rather than through axum's `Query` extractor, which would deserialise
/// the whole string into owned pairs -- a second pass over the ~800 bytes of JSON this app already
/// has in hand, and one more allocation per keystroke on the route that runs per keystroke.
fn signals_from_query(query: &str) -> Option<Map<String, Value>> {
    let raw = query_param(query, "datastar")?;
    read_signals(&raw)
}

/// One query parameter, percent-decoded. `+` is a space, as in a form-encoded query.
fn query_param(query: &str, name: &str) -> Option<String> {
    let encoded = query.split('&').find_map(|pair| {
        pair.strip_prefix(name)
            .and_then(|rest| rest.strip_prefix('='))
    })?;
    let bytes = encoded.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'%' if index + 2 < bytes.len() => {
                match u8::from_str_radix(&encoded[index + 1..index + 3], 16) {
                    Ok(byte) => {
                        out.push(byte);
                        index += 3;
                    }
                    Err(_) => {
                        out.push(b'%');
                        index += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                index += 1;
            }
            byte => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// python's `bool(x)` over a decoded JSON value.
fn truthy(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64().is_some_and(|n| n != 0.0),
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::Object(map)) => !map.is_empty(),
        _ => false,
    }
}

/// python's `int(x)` with its TypeError/ValueError suppressed.
fn as_int(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => number.as_f64().map(|float| float as i64),
        Value::String(text) => text.trim().parse::<i64>().ok(),
        Value::Bool(flag) => Some(i64::from(*flag)),
        _ => None,
    }
}

/// Adopt the bound signals the browser just sent, and report whether anything changed.
///
/// The browser is the source of truth for these -- they originate there and are uploaded with every
/// request -- so the session merely mirrors them. A change restarts the quiz, exactly as the panel
/// watchers did.
fn sync_settings(state: &mut SessionState, signals: Option<&Map<String, Value>>) -> bool {
    let Some(signals) = signals else { return false };
    let before = state.settings;
    if signals.contains_key("difficulty") {
        state.settings.difficulty = engine::clamp_difficulty(signals.get("difficulty"));
    }
    if signals.contains_key("ladderMode") {
        state.settings.ladder_mode = truthy(signals.get("ladderMode"));
    }
    if signals.contains_key("targetOn") {
        state.settings.target_on = truthy(signals.get("targetOn"));
    }
    if let Some(value) = signals.get("targetPct")
        && let Some(pct) = as_int(value)
    {
        state.settings.target_pct = pct.clamp(70, 90);
    }
    before != state.settings
}

fn filter_text_from(signals: Option<&Map<String, Value>>) -> String {
    signals
        .and_then(|map| map.get("filterText"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// Ticked topic slugs back into the filter text they stand for.
///
/// Signal paths cannot hold spaces, so the picker binds kebab-case slugs, which datastar stores
/// camel-cased. The real topic names live here, on the server, so an unknown key simply does not
/// select anything.
fn topics_text_from(system: &'static System, signals: Option<&Map<String, Value>>) -> String {
    let ticked = signals
        .and_then(|map| map.get("topics"))
        .and_then(Value::as_object);
    let names: Vec<&str> = render::topic_choices(system)
        .iter()
        .filter(|choice| truthy(ticked.and_then(|map| map.get(&choice.key))))
        .map(|choice| choice.name.as_str())
        .collect();
    names.join(", ")
}

// --- session plumbing -------------------------------------------------------

/// Borrowed out of the header rather than copied: the session id is read on every single request
/// and only the `create` path ever needs to own it.
fn cookie_value<'a>(headers: &'a HeaderMap, name: &str) -> &'a str {
    let Some(raw) = headers
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
    else {
        return "";
    };
    for pair in raw.split(';') {
        let pair = pair.trim();
        if let Some(value) = pair
            .strip_prefix(name)
            .and_then(|rest| rest.strip_prefix('='))
        {
            return value;
        }
    }
    ""
}

/// This browser's session for the variant this request belongs to, or a new one, plus whether the
/// browser arrived with an identity we no longer have a quiz for.
///
/// The variant is resolved FIRST, because it is half the key: sessions live under (browser, variant)
/// so the two systems coexist. When the request names none, the browser's last navigated-to variant
/// stands in, and failing that the default.
///
/// The `replaced` flag records a browser arriving with an identity we no longer have a quiz for -- a
/// restart, a six-hour gap -- so the play routes can resync the page instead of quietly scoring
/// against a question it has never shown.
fn session_for(
    state: &State,
    headers: &HeaderMap,
    wanted: Option<&'static System>,
) -> (Arc<Session>, bool) {
    let sid = cookie_value(headers, session::COOKIE);
    let system = wanted
        .or_else(|| {
            state
                .store
                .current_variant(sid)
                .and_then(|key| state.corpus.get(&key))
        })
        .unwrap_or_else(|| state.corpus.default_system());
    if let Some(found) = state.store.get(sid, &system.variant.key) {
        return (found, false);
    }
    let replaced = !sid.is_empty();
    (
        state
            .store
            .create(system, if sid.is_empty() { None } else { Some(sid) }),
        replaced,
    )
}

/// [`session_for`] for an interaction: only an explicitly named variant switches it. Reading a
/// *bare* path as "take me to the default" would throw a swedish player back to squad on their first
/// click.
fn play_session(state: &State, headers: &HeaderMap, query: &str) -> (Arc<Session>, bool) {
    session_for(state, headers, state.corpus.requested_variant(query))
}

fn cookie_header(state: &State, session: &Session) -> (header::HeaderName, HeaderValue) {
    let path = if state.config.prefix.is_empty() {
        "/"
    } else {
        &state.config.prefix
    };
    (
        header::SET_COOKIE,
        HeaderValue::try_from(format!(
            "{}={}; Path={path}; HttpOnly; SameSite=Lax",
            session::COOKIE,
            session.sid
        ))
        .expect("session id is hex, so the cookie is always a valid header value"),
    )
}

/// Whether the page this request came from is talking about a quiz that no longer exists.
///
/// Two ways: the session itself is gone (`replaced`), so *nothing* the page says applies; or the
/// question nonce has moved on -- a double click, a replayed request, a background tab. Since qids
/// are unique per process, the second test is exact.
fn stale(replaced: bool, state: &SessionState, qid: Option<i64>) -> bool {
    replaced || qid.is_some_and(|qid| qid != state.qid)
}

// --- events -----------------------------------------------------------------

/// One thing to send. Held as the SDK's framework-agnostic event, whose `Display` is the exact SSE
/// frame -- which is what lets the compressed body be built without going through axum's own `Sse`.
type Event = DatastarEvent;

fn patch_elements(html: impl Into<String>, selector: &str, mode: ElementPatchMode) -> Event {
    PatchElements::new(html)
        .selector(selector)
        .mode(mode)
        .into()
}

fn patch_signals(signals: String) -> Event {
    PatchSignals::new(signals).into()
}

/// Write the session cookie and then the events.
///
/// A 204 IS A NO-OP, NOT AN ERROR. A datastar response with no events is `204 No Content`, and this
/// app returns one deliberately whenever a press no longer applies: Skip with none left, Next while
/// not on a reveal, a settings POST that changed nothing, an answer to a finished quiz, `/timer` in
/// client mode. The load harness treats 200 and 204 alike; a server that answered 200 with an empty
/// body would be lying about having done something.
fn respond(state: &State, session: &Session, headers: &HeaderMap, events: Vec<Event>) -> Response {
    let cookie = cookie_header(state, session);
    if events.is_empty() {
        return (StatusCode::NO_CONTENT, [cookie]).into_response();
    }
    let encoding = sse::negotiate(
        headers
            .get(header::ACCEPT_ENCODING)
            .and_then(|value| value.to_str().ok()),
    );
    let mut stream = Stream::new(encoding);
    let mut body = Vec::with_capacity(events.len() + 1);
    for event in &events {
        body.push(stream.push(&event.to_string()));
    }
    body.push(stream.finish());
    let total: usize = body.iter().map(Bytes::len).sum();
    let mut joined = Vec::with_capacity(total);
    for chunk in body {
        joined.extend_from_slice(&chunk);
    }
    sse_response(cookie, encoding, Body::from(joined))
}

fn sse_response(cookie: (header::HeaderName, HeaderValue), encoding: Encoding, body: Body) -> Response {
    let mut response = Response::builder()
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header(cookie.0, cookie.1);
    if let Some(value) = encoding.header_value() {
        response = response
            .header(header::CONTENT_ENCODING, value)
            .header(header::VARY, "Accept-Encoding");
    }
    response.body(body).expect("a valid response")
}

/// The standard "make the browser agree with the session" set.
///
/// Server-owned signals *and* the effective settings: the browser proposed those, but the server
/// clamps them, so echoing them is what stops a rejected value sitting in the UI until a reload.
/// Drafts (`filterText`, topic ticks) are excluded.
fn view_patches(state: &State, session: &Session, session_state: &SessionState) -> Vec<Event> {
    let elements = if state.config.fragment_morph() {
        patch_elements(
            state.renderer.quiz_body(session, session_state),
            QUIZ_SELECTOR,
            ElementPatchMode::Inner,
        )
    } else {
        patch_elements(
            state.renderer.app_body(session, session_state),
            APP_SELECTOR,
            ElementPatchMode::Inner,
        )
    };
    let mut signals = Signals::new();
    render::server_signals(session_state, &mut signals);
    render::settings_signals(session_state, &mut signals);
    vec![elements, patch_signals(signals.finish())]
}

/// Answer a stale interaction by making the page tell the truth again.
///
/// The old answer was a bare 204: correct, in that nothing should be scored, but from the player's
/// chair it is a dead button -- and the page stays wrong, so the next click is stale too. This
/// re-renders the whole page from the session that actually exists, which is the one thing that ends
/// the loop, and says so.
///
/// The FAT patch even in fragment morph mode: what is stale here is not just the question. The
/// title, the score, the drawer and the topics all belong to a quiz this browser is no longer in.
fn resync(state: &State, session: &Session, session_state: &SessionState) -> Vec<Event> {
    let mut signals = Signals::new();
    render::server_signals(session_state, &mut signals);
    render::settings_signals(session_state, &mut signals);
    vec![
        patch_elements(
            state.renderer.app_body(session, session_state),
            APP_SELECTOR,
            ElementPatchMode::Inner,
        ),
        patch_signals(signals.finish()),
        patch_elements(
            render::toast(&Toast {
                kind: "warning",
                text: "Quiz reloaded — this page has caught up".into(),
                ..Default::default()
            }),
            TOASTS_SELECTOR,
            ElementPatchMode::Inner,
        ),
    ]
}

fn clear_toasts() -> Event {
    patch_elements("", TOASTS_SELECTOR, ElementPatchMode::Inner)
}

/// Empty the sound sink before an answer appends its beats to it.
///
/// The markers are appended rather than morphed, so without this they would accumulate for the life
/// of the page. Clearing at the START rather than the end also means a marker is never removed while
/// the sound it started is still playing -- the `<audio>` element is what plays, and it lives
/// outside the sink.
fn clear_sfx() -> Event {
    patch_elements("", SFX_SELECTOR, ElementPatchMode::Inner)
}

/// The card the player just chose.
///
/// `nth-child` rather than `nth-of-type`: every child of the group is a button, so they agree, and
/// nth-child does not care if a future revision wraps them. The floaters need no cleanup -- both
/// outcomes replace `#quiz` wholesale a moment later.
fn picked_card_selector(index: usize) -> String {
    format!("{QUIZ_SELECTOR} .candidates > :nth-child({})", index + 1)
}

// --- routes -----------------------------------------------------------------

/// The full page. Everything the browser knows starts here, in view-source.
///
/// Also where the debug flag is decided, and only here: the datastar interactions POST to bare paths
/// with no query, so re-reading `?debug` per request would switch the panel off on the first click.
/// Set on page load, sticky for the session.
pub async fn index(AxumState(state): AxumState<State>, uri: Uri, headers: HeaderMap) -> Response {
    let query = uri.query().unwrap_or_default();
    // A bare URL additionally means the default variant, and only a real navigation can carry that
    // meaning.
    let (session, _) = session_for(
        &state,
        &headers,
        state.corpus.variant_switch_for_query(query),
    );
    // The theme is the browser's preference, not the session's: it is written by the toggle into its
    // own cookie and only relayed here, so it survives a new session, a restart and a second tab.
    let theme = render::theme_from(cookie_value(&headers, render::THEME_COOKIE));

    let page = {
        let mut session_state = session.state.lock();
        session_state.debug = debug_allowed(&state, query);
        state.renderer.shell(&session, &session_state, theme)
    };
    // A NAVIGATION is the only thing that moves the mark for "which system this browser is on",
    // which is what an ambiguous later page load (`?debug`, naming no variant) resolves against.
    state.store.remember(&session);

    // TWEAK 3 (experiment): constant header values are `HeaderValue::from_static`, which is a
    // borrow of a `&'static str` rather than a `String` allocated per response. The cookie is the
    // one genuinely dynamic value, and `HeaderValue::try_from(String)` takes ownership of the
    // `format!` buffer instead of copying it again.
    (
        [
            (
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/html; charset=utf-8"),
            ),
            (header::CACHE_CONTROL, HeaderValue::from_static("no-store")),
            cookie_header(&state, &session),
        ],
        page,
    )
        .into_response()
}

/// `haystack.contains(needle)`, ASCII-case-insensitively, without allocating. `needle` must be
/// lowercase.
fn contains_ignore_ascii_case(haystack: &str, needle: &str) -> bool {
    let (haystack, needle) = (haystack.as_bytes(), needle.as_bytes());
    if needle.is_empty() || haystack.len() < needle.len() {
        return needle.is_empty();
    }
    haystack
        .windows(needle.len())
        .any(|window| window.eq_ignore_ascii_case(needle))
}

fn debug_allowed(state: &State, query: &str) -> bool {
    match state.config.debug_mode.as_str() {
        "0" => false,
        "1" => true,
        // TWEAK 3 (experiment): a case-insensitive scan rather than `to_ascii_lowercase()`, which
        // allocated a copy of the whole query string on every page load to answer one substring
        // question.
        _ => contains_ignore_ascii_case(query, "debug"),
    }
}

/// Score one answer, then stream the notifications the way panel showed them.
///
/// A stale qid (double click, back button, replay, a page whose session was replaced) scores nothing
/// and RESYNCS the page instead: the nonce moved on when the question did, and the browser is
/// showing a quiz that no longer exists. A finished quiz is still a plain no-op.
pub async fn answer(
    AxumState(state): AxumState<State>,
    Path((qid, index)): Path<(i64, usize)>,
    uri: Uri,
    headers: HeaderMap,
    body: String,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, replaced) = play_session(&state, &headers, query);
    score_answer(
        state,
        session,
        replaced,
        qid,
        index,
        true,
        headers,
        read_signals(&body),
    )
}

#[allow(clippy::too_many_arguments)]
fn score_answer(
    state: State,
    session: Arc<Session>,
    replaced: bool,
    qid: i64,
    index: usize,
    floaters: bool,
    headers: HeaderMap,
    signals: Option<Map<String, Value>>,
) -> Response {
    let (outcome, goal, refuse) = {
        let mut session_state = session.state.lock();
        if stale(replaced, &session_state, Some(qid)) {
            let events = resync(&state, &session, &session_state);
            (None, 0, Some(events))
        } else if !session_state.still_playing() || index >= session_state.question.candidates.len()
        {
            (None, 0, Some(Vec::new()))
        } else {
            sync_settings(&mut session_state, signals.as_ref());

            let candidate = session_state.question.candidates[index].clone();
            // the bonus that scores is measured here, from the server's own clock -- the browser's
            // countdown bar is only an animation
            let percent_left = session_state.percent_time_left();
            let question = session_state.question.clone();
            // read out first: the ledger is borrowed mutably for the call, and the rest of the
            // session is what tells it how to score
            let settings = session_state.settings;
            let last_correct_points = session_state.last_correct_points;
            let points_goal = session_state.points_goal;
            let (outcome, last_correct) = engine::answer(
                &mut session_state.score,
                AnswerInput {
                    question: &question,
                    candidate: &candidate,
                    percent_left,
                    ladder_mode: settings.ladder_mode,
                    target_on: settings.target_on,
                    target_pct: settings.target_pct,
                    last_correct_points,
                    points_goal,
                },
            );
            session_state.last_correct_points = last_correct;
            session_state.skips_left += outcome.awarded_skips;

            // the clock stops the moment the answer is scored -- everything after this point should
            // report what was left, not keep draining
            session_state.freeze_question_clock();

            // state is settled before a single byte is streamed, so a reload mid-notification shows
            // the finished score and the next question rather than a half-applied answer
            if outcome.completed {
                session_state.complete();
            } else if outcome.correct {
                session_state.next_question(session.system);
            } else {
                // park on the reveal instead: the answer is shown in place, and the player advances
                session_state.awaiting_next = true;
                session_state.wrong_index = Some(index);
            }
            (Some(outcome), points_goal, None)
        }
    };

    if let Some(events) = refuse {
        return respond(&state, &session, &headers, events);
    }
    let outcome = outcome.expect("scored");
    stream_answer(
        state,
        session,
        headers,
        outcome,
        goal,
        if floaters { Some(index) } else { None },
    )
}

/// The panel notification chain, as one long SSE response.
///
/// `on_answer_click` awaited `asyncio.sleep` between notification calls; the same pacing survives
/// here, with each beat as an element patch -- and with a `tokio::time::sleep` in a task rather than
/// an await on the one loop, which is one of the differences this port exists to measure.
///
/// Each beat that carries points is *also* appended to the card the player chose, as a floating
/// number. The server can do that because the choice is in the URL it was called on. The floaters
/// are inert unless `body.juice` is set, which is why they are streamed unconditionally: `$_juice`
/// is a local view signal and never reaches the server.
fn stream_answer(
    state: State,
    session: Arc<Session>,
    headers: HeaderMap,
    outcome: engine::Answered,
    goal: i64,
    picked: Option<usize>,
) -> Response {
    let cookie = cookie_header(&state, &session);
    let encoding = sse::negotiate(
        headers
            .get(header::ACCEPT_ENCODING)
            .and_then(|value| value.to_str().ok()),
    );
    let streak = session.state.lock().score.streak;

    let body = stream! {
        let mut out = Stream::new(encoding);

        // The streak lands with the FIRST beat, not with the view patch at the end of the stream:
        // the chip is the reward for the answer that was just given, and arriving two or three
        // seconds late read as belonging to the following question.
        let mut signals = Signals::new();
        signals.number("_streak", streak);
        yield Ok::<Bytes, std::convert::Infallible>(
            out.push(&patch_signals(signals.finish()).to_string()));

        // Sound rides the same beats, gated client-side on `$_sound`. The verdict chime goes FIRST,
        // before the toast it belongs to, because a sound that arrives after the words have appeared
        // reads as a response to reading them.
        let verdict = if outcome.correct { "correct" } else { "wrong" };
        yield Ok(out.push(&clear_sfx().to_string()));
        yield Ok(out.push(&patch_elements(
            render::sfx_beat(verdict), SFX_SELECTOR, ElementPatchMode::Append).to_string()));

        for toast in &outcome.toasts {
            yield Ok(out.push(&patch_elements(
                render::toast(toast), TOASTS_SELECTOR, ElementPatchMode::Inner).to_string()));
            // A milestone has just paid for a skip: the gauge that measures milestones says so
            // itself, rather than leaving it to one toast among four. Both halves are one-shot
            // appends -- the shine is taken away by the view patch at the end of the stream, the
            // sound marker by the clear_sfx of the next answer.
            if toast.awards_skip {
                yield Ok(out.push(&patch_elements(
                    render::meter_sweep(), METER_SELECTOR, ElementPatchMode::Append).to_string()));
                yield Ok(out.push(&patch_elements(
                    render::sfx_beat("skip"), SFX_SELECTOR, ElementPatchMode::Append).to_string()));
            }
            if let Some(points) = toast.points_after {
                // the SESSION's goal, not the constant: with a debug goal of 200 these mid-stream
                // percentages were computed against 1000 while the view patch used 200, so the
                // gauge jumped backwards when the final patch arrived
                let mut signals = Signals::new();
                signals
                    .number("_points", points)
                    .number("_pointsPct", render::points_percent(points, goal));
                yield Ok(out.push(&patch_signals(signals.finish()).to_string()));
            }
            if let Some(index) = picked {
                let floater = render::floater(toast, outcome.completed);
                if !floater.is_empty() {
                    yield Ok(out.push(&patch_elements(
                        floater, &picked_card_selector(index), ElementPatchMode::Append)
                        .to_string()));
                }
            }
            if toast.pause > 0.0 {
                tokio::time::sleep(Duration::from_secs_f64(toast.pause)).await;
            }
        }

        // The finale's own sound, once per quiz, with the completion screen rather than with the
        // answer: the gold floater and the confetti are the same beat, and the fanfare is long
        // enough that firing it beside the "Correct!" chime would be two flourishes over each other.
        if outcome.completed {
            yield Ok(out.push(&patch_elements(
                render::sfx_beat("final"), SFX_SELECTOR, ElementPatchMode::Append).to_string()));
        }

        yield Ok(out.push(&clear_toasts().to_string()));
        let patches = {
            let mut session_state = session.state.lock();
            // the clock starts when the question reaches the player, not when it was drawn -- the
            // notifications above took real seconds and they are not thinking time
            if session_state.still_playing() && !session_state.awaiting_next {
                session_state.start_question_clock();
            }
            view_patches(&state, &session, &session_state)
        };
        for event in patches {
            yield Ok(out.push(&event.to_string()));
        }
        yield Ok(out.finish());
    };

    sse_response(cookie, encoding, Body::from_stream(body))
}

/// Leave the revealed answer and draw the next question.
///
/// Only valid while parked on a reveal, so a stray press cannot skip a live question -- that is what
/// Skip is for, and it costs a skip.
pub async fn next(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
    body: String,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, replaced) = play_session(&state, &headers, query);
    let signals = read_signals(&body);
    let events = {
        let mut session_state = session.state.lock();
        if stale(replaced, &session_state, None) {
            resync(&state, &session, &session_state)
        } else {
            sync_settings(&mut session_state, signals.as_ref());
            if !session_state.awaiting_next || !session_state.still_playing() {
                Vec::new()
            } else {
                session_state.next_question(session.system);
                let mut events = vec![clear_toasts()];
                events.extend(view_patches(&state, &session, &session_state));
                events
            }
        }
    };
    respond(&state, &session, &headers, events)
}

/// Spend a skip, if a milestone has paid for one.
pub async fn skip(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
    body: String,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, replaced) = play_session(&state, &headers, query);
    let signals = read_signals(&body);
    let events = {
        let mut session_state = session.state.lock();
        if stale(replaced, &session_state, None) {
            resync(&state, &session, &session_state)
        } else {
            sync_settings(&mut session_state, signals.as_ref());
            if session_state.skips_left <= 0 || !session_state.still_playing() {
                Vec::new()
            } else {
                session_state.skips_left -= 1;
                session_state.next_question(session.system);
                let mut events = vec![clear_toasts()];
                events.extend(view_patches(&state, &session, &session_state));
                events
            }
        }
    };
    respond(&state, &session, &headers, events)
}

pub async fn restart(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
    body: String,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, query);
    let signals = read_signals(&body);
    let events = {
        let mut session_state = session.state.lock();
        sync_settings(&mut session_state, signals.as_ref());
        session_state.restart(session.system);
        let mut events = vec![clear_toasts()];
        events.extend(view_patches(&state, &session, &session_state));
        events
    };
    respond(&state, &session, &headers, events)
}

/// Difficulty / ladder mode / target percentage arrive as bound signals.
///
/// Panel restarted the quiz on every such change, so this does too -- and only when a value actually
/// moved, so a re-sent identical signal set is free.
pub async fn settings(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
    body: String,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, query);
    let signals = read_signals(&body);
    let events = {
        let mut session_state = session.state.lock();
        if !sync_settings(&mut session_state, signals.as_ref()) {
            Vec::new()
        } else {
            session_state.restart(session.system);
            let mut events = vec![clear_toasts()];
            events.extend(view_patches(&state, &session, &session_state));
            events
        }
    };
    respond(&state, &session, &headers, events)
}

/// How often the held stream pushes, matching the client interval exactly -- the two push models
/// must agree about the bar's motion or the mode becomes visible to the player.
const TIMER_TICK: Duration = Duration::from_millis(100);
/// A held stream needs an upper bound, or an abandoned tab keeps a connection and a session alive
/// forever. Ten minutes is far longer than any question; the client reopens on the next page load.
const TIMER_STREAM_MAX: Duration = Duration::from_secs(600);

/// The held-connection countdown: panel's push model, for comparison with the client interval.
///
/// Only reachable when `DSQUIZ_TIMER=stream`; the shell wires `data-init` to it in that mode and
/// omits the `data-on-interval` attribute, so exactly one of the two is ever live.
///
/// Note what this costs against the client-interval default: a tick per 100ms per connected tab,
/// each one a signal patch over the wire, whether or not the value changed. On python that is the
/// mode nobody would ship; here it is a task and an interval.
pub async fn timer(AxumState(state): AxumState<State>, uri: Uri, headers: HeaderMap) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, query);
    if !state.config.stream_timer() {
        return respond(&state, &session, &headers, Vec::new());
    }
    let cookie = cookie_header(&state, &session);
    let encoding = sse::negotiate(
        headers
            .get(header::ACCEPT_ENCODING)
            .and_then(|value| value.to_str().ok()),
    );

    let body = stream! {
        let mut out = Stream::new(encoding);
        let mut ticker = tokio::time::interval(TIMER_TICK);
        let deadline = tokio::time::sleep(TIMER_STREAM_MAX);
        tokio::pin!(deadline);
        loop {
            let (playing, ticking, left) = {
                let session_state = session.state.lock();
                (session_state.still_playing(), session_state.on_the_clock(),
                 session_state.percent_time_left())
            };
            if !playing {
                let mut signals = Signals::new();
                signals.number("_timeLeftPct", 0);
                yield Ok::<Bytes, std::convert::Infallible>(
                    out.push(&patch_signals(signals.finish()).to_string()));
                break;
            }
            // Nothing to push while parked on a reveal: the question has been answered, so the clock
            // is frozen and every tick would restate the same number. The client interval gates on
            // the same condition (`$_ticking`).
            if ticking {
                let mut signals = Signals::new();
                signals.number("_timeLeftPct", left);
                yield Ok(out.push(&patch_signals(signals.finish()).to_string()));
            }
            tokio::select! {
                _ = ticker.tick() => {}
                _ = &mut deadline => break,
            }
        }
        yield Ok(out.finish());
    };

    sse_response(cookie, encoding, Body::from_stream(body))
}

// --- the bidding-tree filter ------------------------------------------------

fn preview(
    state: &State,
    session: &Session,
    headers: &HeaderMap,
    text: &str,
    selector: &str,
    hint: &str,
) -> Response {
    let events = {
        let session_state = session.state.lock();
        let check = session
            .system
            .check_filter(text, usize::from(engine::MAX_DIFFICULTY));
        vec![patch_elements(
            render::filter_status(&check, &session_state.filter_text, hint),
            selector,
            ElementPatchMode::Inner,
        )]
    };
    respond(state, session, headers, events)
}

/// What the text in the box *would* select. Commits nothing.
///
/// This is the panel `value_input` watcher, except the validation never left the server. Cheap
/// enough to run per keystroke because the corpus is pre-parsed and the check is memoised.
pub async fn filter_preview(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let raw = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, raw);
    let text = filter_text_from(signals_from_query(raw).as_ref());
    preview(
        &state,
        &session,
        &headers,
        &text,
        FILTER_STATUS_SELECTOR,
        "press Enter to apply",
    )
}

pub async fn topics_preview(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let raw = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, raw);
    let text = topics_text_from(session.system, signals_from_query(raw).as_ref());
    preview(
        &state,
        &session,
        &headers,
        &text,
        TOPICS_STATUS_SELECTOR,
        "press Apply to use this",
    )
}

/// Close (and Escape) DISCARD the ticks, putting them back to the filter in force.
///
/// The picker has an explicit Apply and says so in its own first line, which makes Close the cancel
/// path -- and a cancel that quietly keeps your edits is the odd one out among dialogs. Keeping them
/// also left the picker disagreeing with the app.
///
/// Only the `topics` branch is patched. The bound signals also carry the difficulty and
/// `filterText`, and `filterText` is a DRAFT the player may be part-way through typing in the drawer
/// behind the dialog -- re-sending it here would wipe it.
pub async fn topics_reset(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let raw = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, raw);
    let events = {
        let session_state = session.state.lock();
        let check = session.system.check_filter(
            &session_state.filter_text,
            usize::from(engine::MAX_DIFFICULTY),
        );
        let choices = render::topic_choices(session.system);
        let mut signals = Signals::new();
        let ticked: Vec<String> = check
            .parsed
            .topic_names
            .iter()
            .map(|name| render::topic_signal_key(name))
            .collect();
        signals.flags(
            "topics",
            choices
                .iter()
                .map(|choice| (choice.key.as_str(), ticked.contains(&choice.key))),
        );
        vec![
            patch_signals(signals.finish()),
            // ...and the picker's own status line, which was previewing a selection that no longer
            // exists. Empty rather than re-rendered: with nothing pending there is nothing to say.
            patch_elements("", TOPICS_STATUS_SELECTOR, ElementPatchMode::Inner),
        ]
    };
    respond(&state, &session, &headers, events)
}

/// The one path that changes the filter in force.
fn commit_filter(state: &State, session: &Session, headers: &HeaderMap, text: &str) -> Response {
    let events = {
        let mut session_state = session.state.lock();
        let (check, changed) =
            session_state.apply_filter(session.system, text, usize::from(engine::MAX_DIFFICULTY));
        let choices = render::topic_choices(session.system);
        let mut signals = Signals::new();
        render::bound_signals(
            &session_state,
            choices,
            &check.parsed.topic_names,
            &mut signals,
        );
        let mut events = vec![
            patch_elements(
                render::filter_status(&check, &session_state.filter_text, ""),
                FILTER_STATUS_SELECTOR,
                ElementPatchMode::Inner,
            ),
            patch_elements("", TOPICS_STATUS_SELECTOR, ElementPatchMode::Inner),
            // the box and the picker are brought into line with what was actually applied: the
            // canonical text has topic prefixes expanded and the whitespace tidied
            patch_signals(signals.finish()),
        ];
        if changed {
            session_state.restart(session.system);
            events.push(clear_toasts());
            events.extend(view_patches(state, session, &session_state));
        }
        events
    };
    respond(state, session, headers, events)
}

pub async fn filter_apply(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
    body: String,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, query);
    let text = filter_text_from(read_signals(&body).as_ref());
    commit_filter(&state, &session, &headers, &text)
}

/// Apply replaces whatever is in the filter box with the ticked topics, as panel did.
pub async fn topics_apply(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
    body: String,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, query);
    let text = topics_text_from(session.system, read_signals(&body).as_ref());
    commit_filter(&state, &session, &headers, &text)
}

// --- debug panel ------------------------------------------------------------

/// Add or remove points without answering anything.
///
/// Deliberately does NOT check the goal: crossing it by hand should not fake a completion, because
/// then the finale would be reachable without the code path that produces it. `/debug/complete` is
/// the honest way to see that screen.
pub async fn debug_points(
    AxumState(state): AxumState<State>,
    Path(delta): Path<i64>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, query);
    let events = {
        let mut session_state = session.state.lock();
        if !session_state.debug {
            Vec::new()
        } else {
            session_state.score.total_points = (session_state.score.total_points + delta).max(0);
            view_patches(&state, &session, &session_state)
        }
    };
    respond(&state, &session, &headers, events)
}

/// Shorten (or lengthen) the quiz. Per session, so this is not a global mutation. The milestones
/// that pay for skips are fractions of the goal, so lowering it also brings those forward -- which
/// is the point: a 200-point goal exercises the whole ladder in a minute.
pub async fn debug_goal(
    AxumState(state): AxumState<State>,
    Path(value): Path<i64>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, query);
    let events = {
        let mut session_state = session.state.lock();
        if !session_state.debug {
            Vec::new()
        } else {
            session_state.points_goal = value.clamp(10, 100_000);
            view_patches(&state, &session, &session_state)
        }
    };
    respond(&state, &session, &headers, events)
}

/// Jump to the finale, through the real scoring path.
///
/// Points are set one short of the goal and the current question is answered *correctly*, so this
/// goes through the engine -> completed -> the toast chain -> the completion screen, including the
/// gold goal-crossing floater. Faking the completion would show the screen while skipping everything
/// that makes it happen.
pub async fn debug_complete(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, replaced) = play_session(&state, &headers, query);
    let armed = {
        let mut session_state = session.state.lock();
        if !session_state.debug {
            None
        } else {
            if !session_state.still_playing() {
                session_state.restart(session.system);
            }
            session_state.score.total_points = (session_state.points_goal - 1).max(0);
            session_state.awaiting_next = false;
            session_state
                .question
                .answer_index()
                .map(|index| (session_state.qid, index))
        }
    };
    let Some((qid, correct_index)) = armed else {
        return respond(&state, &session, &headers, Vec::new());
    };
    // No floaters on this path: the browser is showing whatever it was showing (often the previous
    // finale, since this restarts a finished quiz), so a patch aimed at `.candidates >
    // :nth-child(n)` finds no target and datastar logs a warning for every scoring beat.
    score_answer(
        state,
        session,
        replaced,
        qid,
        correct_index,
        false,
        headers,
        None,
    )
}

/// Park on the reveal without getting one wrong, for looking at the shake and the marks.
pub async fn debug_reveal(
    AxumState(state): AxumState<State>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let query = uri.query().unwrap_or_default();
    let (session, _) = play_session(&state, &headers, query);
    let events = {
        let mut session_state = session.state.lock();
        if !session_state.debug {
            Vec::new()
        } else {
            if !session_state.still_playing() {
                session_state.restart(session.system);
            }
            session_state.awaiting_next = true;
            session_state.freeze_question_clock();
            let count = session_state.question.candidates.len();
            match session_state.question.answer_index() {
                Some(correct) if count > 0 => {
                    session_state.wrong_index = Some((correct + 1) % count);
                    view_patches(&state, &session, &session_state)
                }
                _ => Vec::new(),
            }
        }
    };
    respond(&state, &session, &headers, events)
}

// --- sound ------------------------------------------------------------------

/// One synthesised WAV. There is no `static/sfx/` directory -- see the `sfx` module.
///
/// Cached HARD (a year, and immutable in effect) because the bytes for a given name never change
/// within a build; the `?v=` the page appends is the build stamp, so an edited synth arrives as a
/// different URL rather than waiting out a cache.
pub async fn sound(Path(name): Path<String>) -> Response {
    match sfx::get(&name) {
        Some(bytes) => (
            [
                (header::CONTENT_TYPE, "audio/wav"),
                (header::CACHE_CONTROL, "public, max-age=31536000"),
            ],
            bytes,
        )
            .into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
