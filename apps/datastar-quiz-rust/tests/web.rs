//! The behaviours the load harness and the players depend on.
//!
//! Ported from the Go port's `internal/web/web_test.go`, which is itself the python suite's
//! `test_routes`, `test_stale_pages`, `test_morph_modes`, `test_variants`, `test_timer_modes` and
//! `test_url_prefix`. The handoff's warning is why they are here: "the python port's own history is
//! a list of behaviours that look optional until they are missing -- the 204 no-ops, the question
//! nonce, the per-variant session keying -- and each one silently corrupts a load run rather than
//! failing it."

use std::sync::{Arc, OnceLock};

use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use dsquiz::corpus::Corpus;
use dsquiz::render;
use dsquiz::session::Store;
use dsquiz::web::{AppState, Config, State, router};
use http_body_util::BodyExt;
use tower::ServiceExt;

const SIGNALS: &str = r#"{"difficulty":5,"ladderMode":false,"targetOn":false,"targetPct":80,"filterText":"","topics":{}}"#;

fn corpus() -> &'static Corpus {
    static CORPUS: OnceLock<Corpus> = OnceLock::new();
    CORPUS.get_or_init(|| Corpus::load().expect("the corpus is embedded and must parse"))
}

fn config() -> Config {
    Config {
        timer_mode: "client".into(),
        morph_mode: "fat".into(),
        prefix: String::new(),
        debug_mode: String::new(),
    }
}

/// A browser: one cookie jar against one server.
struct Client {
    state: State,
    /// just the `name=value` pair, which is what a browser sends back
    cookie: Option<String>,
    /// the whole `Set-Cookie` header, so the attributes can be asserted on
    last_set_cookie: Option<String>,
}

struct Reply {
    status: StatusCode,
    body: String,
    headers: axum::http::HeaderMap,
}

impl Reply {
    fn contains(&self, needle: &str) -> bool {
        self.body.contains(needle)
    }
}

impl Client {
    fn new(config: Config) -> Client {
        let state = Arc::new(AppState {
            renderer: render::Config {
                prefix: config.prefix.clone(),
                timer_mode: config.timer_mode.clone(),
            },
            config,
            corpus: corpus(),
            store: Store::default(),
        });
        Client {
            state,
            cookie: None,
            last_set_cookie: None,
        }
    }

    async fn send(&mut self, method: &str, path: &str, body: Option<&str>) -> Reply {
        let mut request = Request::builder().method(method).uri(path);
        if body.is_some() {
            request = request.header(header::CONTENT_TYPE, "application/json");
        }
        if let Some(cookie) = &self.cookie {
            request = request.header(header::COOKIE, cookie);
        }
        let request = request
            .body(body.map_or_else(Body::empty, |text| Body::from(text.to_owned())))
            .expect("a valid request");

        let response = router(Arc::clone(&self.state))
            .oneshot(request)
            .await
            .expect("infallible router");
        let status = response.status();
        let headers = response.headers().clone();
        if let Some(set) = headers
            .get(header::SET_COOKIE)
            .and_then(|v| v.to_str().ok())
            && let Some(pair) = set.split(';').next()
            && pair.starts_with("dsq_sid=")
        {
            self.cookie = Some(pair.to_owned());
            self.last_set_cookie = Some(set.to_owned());
        }
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("a body")
            .to_bytes();
        Reply {
            status,
            body: String::from_utf8_lossy(&bytes).into_owned(),
            headers,
        }
    }

    async fn get(&mut self, path: &str) -> Reply {
        self.send("GET", path, None).await
    }

    async fn post(&mut self, path: &str) -> Reply {
        self.send("POST", path, Some(SIGNALS)).await
    }
}

/// Read the nonce and candidate count out of whatever the page (or a fat patch) last said -- the
/// same thing the load harness does.
fn question(body: &str) -> (Option<i64>, usize) {
    let mut qid = None;
    let mut candidates = 0usize;
    let mut rest = body;
    while let Some(index) = rest.find("@post('") {
        rest = &rest[index + 7..];
        let Some(end) = rest.find('\'') else { break };
        let url = &rest[..end];
        let Some(after) = url.split("/answer/").nth(1) else {
            continue;
        };
        let mut parts = after.split('/');
        let Some(found_qid) = parts.next().and_then(|text| text.parse::<i64>().ok()) else {
            continue;
        };
        let Some(index_text) = parts.next() else {
            continue;
        };
        let index_text: String = index_text
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        let Ok(found_index) = index_text.parse::<usize>() else {
            continue;
        };
        if qid.is_none() {
            qid = Some(found_qid);
        }
        candidates = candidates.max(found_index + 1);
    }
    (qid, candidates)
}

#[tokio::test]
async fn the_page_carries_a_question() {
    let mut client = Client::new(config());
    let page = client.get("/").await;
    assert_eq!(page.status, StatusCode::OK);
    // this page IS session state rendered into HTML; a cached copy is a different player's answer
    // sheet at worst and a stale question at best
    assert_eq!(
        page.headers
            .get(header::CACHE_CONTROL)
            .and_then(|v| v.to_str().ok()),
        Some("no-store")
    );
    let (qid, candidates) = question(&page.body);
    assert!(qid.is_some(), "no question nonce on the page");
    assert_eq!(candidates, 5, "the initial difficulty is five candidates");

    let cookie = page
        .headers
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .expect("a session cookie");
    assert!(cookie.contains("HttpOnly"), "cookie = {cookie}");
    assert!(cookie.contains("SameSite=Lax"), "cookie = {cookie}");
}

#[tokio::test]
async fn answering_scores_and_advances() {
    let mut client = Client::new(config());
    let (qid, _) = question(&client.get("/").await.body);
    let qid = qid.expect("a question");

    let stream = client.post(&format!("/answer/{qid}/0")).await;
    assert_eq!(stream.status, StatusCode::OK);
    let body = &stream.body;
    // the streak lands with the FIRST beat, not with the view patch at the end
    assert!(
        body.starts_with("event: datastar-patch-signals\ndata: signals {\"_streak\":"),
        "the stream did not open with the streak patch:\n{}",
        &body[..body.len().min(120)]
    );
    // the verdict chime goes before the toast it belongs to
    let sfx = body
        .find("sfx-correct")
        .or_else(|| body.find("sfx-wrong"))
        .expect("a verdict sound");
    let toast = body.find("class=\"toast").expect("a toast");
    assert!(
        sfx < toast,
        "the verdict sound arrived after the first toast"
    );
    // and the stream ends with the view patch
    assert!(
        body.contains("selector #app"),
        "the stream did not end with a fat view patch"
    );
}

/// The trap that produced "I answered one question and it showed me another": qids used to restart
/// at 1 per session, so an answer from a page whose session had been replaced passed the staleness
/// guard by coincidence.
#[tokio::test]
async fn a_stale_qid_resyncs_rather_than_scoring() {
    let mut client = Client::new(config());
    let (qid, _) = question(&client.get("/").await.body);
    let qid = qid.expect("a question");

    let first = client.post(&format!("/answer/{qid}/0")).await;
    assert_eq!(first.status, StatusCode::OK);
    // A WRONG answer keeps its nonce -- the reveal is the same question, still on screen -- so
    // leave the reveal before replaying, or the replay is not stale at all. (Which is also why the
    // reveal has no buttons: there is nothing to double-click.)
    if first.contains("Next question") {
        client.post("/next").await;
    }
    let second = client.post(&format!("/answer/{qid}/0")).await;
    assert_eq!(second.status, StatusCode::OK);
    assert!(
        second.contains("caught up"),
        "a replayed answer should resync the page"
    );
    assert!(
        second.contains("selector #app"),
        "the resync must be a FAT patch -- the title, score, drawer and topics are all stale"
    );
}

/// The six-hour gap and the server restart: the browser still has a cookie, the store has no quiz
/// under it.
#[tokio::test]
async fn a_replaced_session_resyncs() {
    let mut client = Client::new(config());
    let (qid, _) = question(&client.get("/").await.body);
    let qid = qid.expect("a question");
    client.cookie = Some("dsq_sid=a-browser-from-before-the-restart".to_owned());

    let reply = client.post(&format!("/answer/{qid}/0")).await;
    assert_eq!(reply.status, StatusCode::OK);
    assert!(
        reply.contains("caught up"),
        "a replaced session should resync"
    );
}

/// The one the load harness cares about most: a 200 with an empty body would be a lie, and treating
/// these as failures is what made `/timer` read as 100% failed.
#[tokio::test]
async fn no_ops_are_204() {
    let mut client = Client::new(config());
    client.get("/").await;

    // Next while not on a reveal
    assert_eq!(client.post("/next").await.status, StatusCode::NO_CONTENT);
    // a settings POST that changed nothing
    let unchanged = r#"{"difficulty":5,"ladderMode":true,"targetOn":false,"targetPct":70}"#;
    client.send("POST", "/settings", Some(unchanged)).await;
    assert_eq!(
        client
            .send("POST", "/settings", Some(unchanged))
            .await
            .status,
        StatusCode::NO_CONTENT
    );
    // /timer in the default client mode
    assert_eq!(client.get("/timer").await.status, StatusCode::NO_CONTENT);
    // the debug routes on an unarmed session -- 204, not 404: it does not advertise whether they
    // exist
    for path in [
        "/debug/points/100",
        "/debug/goal/200",
        "/debug/reveal",
        "/debug/complete",
    ] {
        assert_eq!(
            client.post(path).await.status,
            StatusCode::NO_CONTENT,
            "POST {path}"
        );
    }
}

#[tokio::test]
async fn skips_run_out() {
    let mut client = Client::new(config());
    client.get("/").await;
    for round in 1..=3 {
        assert_eq!(
            client.post("/skip").await.status,
            StatusCode::OK,
            "skip {round}"
        );
    }
    assert_eq!(
        client.post("/skip").await.status,
        StatusCode::NO_CONTENT,
        "the fourth skip -- three is what a quiz starts with"
    );
}

/// The cross-tab bleed the store exists to end: one cookie, two systems, two quizzes.
#[tokio::test]
async fn sessions_are_keyed_by_browser_and_variant() {
    let mut client = Client::new(config());
    let squad = client.get("/").await;
    assert!(
        squad.contains("?squad')"),
        "the squad page's action URLs do not name the variant"
    );
    let (squad_qid, _) = question(&squad.body);

    let swedish = client.get("/?swedish").await;
    assert!(
        swedish.contains("?swedish')"),
        "?swedish did not switch the system"
    );
    let (swedish_qid, _) = question(&swedish.body);
    assert_ne!(
        squad_qid, swedish_qid,
        "the two systems share a nonce -- they are one session"
    );

    // the squad tab is still about the squad session
    let back = client.get("/?squad").await;
    assert_eq!(
        question(&back.body).0,
        squad_qid,
        "returning to squad drew a new question"
    );

    // ...and a BARE url means "take me home" to the default
    assert!(
        client.get("/").await.contains("?squad')"),
        "a bare URL should mean the default"
    );
    // while a query naming no variant keeps whatever the browser is on
    client.get("/?swedish").await;
    assert!(
        client.get("/?debug").await.contains("?swedish')"),
        "?debug must not be read as 'switch me back to the default'"
    );
}

#[tokio::test]
async fn morph_modes() {
    for (mode, selector) in [("fat", "selector #app"), ("fragment", "selector #quiz")] {
        let mut client = Client::new(Config {
            morph_mode: mode.into(),
            ..config()
        });
        client.get("/").await;
        let body = client.post("/skip").await.body;
        assert!(
            body.contains(selector),
            "{mode} morph did not patch {selector}"
        );
        if mode == "fragment" {
            assert!(
                !body.contains("selector #app"),
                "fragment morph patched the whole app"
            );
        }
    }
}

#[tokio::test]
async fn the_timer_stream_pushes_the_countdown() {
    let mut client = Client::new(Config {
        timer_mode: "stream".into(),
        ..config()
    });
    let page = client.get("/").await;
    assert!(
        !page.contains("data-on-interval"),
        "stream mode must not also wire the browser interval"
    );
    assert!(
        page.contains("@get('/timer?squad')"),
        "stream mode must open the held connection from data-init on <body>"
    );
    // The held stream never ends on its own, so this asserts on the wiring rather than reading it:
    // a `oneshot` against an endless body would hang the test suite. The live behaviour is covered
    // by `just dsperf timer-stream`.
}

#[tokio::test]
async fn filter_preview_commits_nothing_and_apply_restarts() {
    let mut client = Client::new(config());
    let (before, _) = question(&client.get("/").await.body);

    let preview = client
        .get("/filter/preview?datastar=%7B%22filterText%22%3A%221C%22%7D")
        .await;
    assert_eq!(preview.status, StatusCode::OK);
    assert!(
        preview.contains("auctions match"),
        "preview = {}",
        preview.body
    );
    // asking never commits: the question is the one it was
    assert_eq!(
        question(&client.get("/").await.body).0,
        before,
        "a preview restarted the quiz"
    );

    let apply = client
        .send("POST", "/filter/apply", Some(r#"{"filterText":"1C"}"#))
        .await;
    assert_eq!(apply.status, StatusCode::OK);
    assert_ne!(
        question(&apply.body).0,
        before,
        "applying a filter must restart the quiz"
    );
    // the canonical text comes back so the box shows what is really in force
    assert!(
        apply.contains(r#""filterText":"1C""#),
        "apply did not echo the canonical text"
    );

    // ...and re-applying the same filter changes nothing, so the quiz is not restarted
    let again = client
        .send("POST", "/filter/apply", Some(r#"{"filterText":" 1c "}"#))
        .await;
    assert!(
        !again.contains("selector #app"),
        "re-applying an unchanged filter restarted the quiz"
    );
}

#[tokio::test]
async fn the_debug_panel_is_armed_by_the_query_and_sticks() {
    let mut client = Client::new(config());
    assert!(
        !client.get("/").await.contains(r#"id="debug""#),
        "the panel is on unasked"
    );
    assert!(
        client.get("/?debug").await.contains(r#"id="debug""#),
        "?debug did not arm it"
    );
    // sticky: the interactions POST to bare paths with no query
    assert_eq!(
        client.post("/debug/points/100").await.status,
        StatusCode::OK
    );
    // a plain reload disarms it again, which is the lifetime panel's own flag had
    assert!(
        !client.get("/").await.contains(r#"id="debug""#),
        "a reload should disarm it"
    );
}

#[tokio::test]
async fn debug_mode_off_forbids_the_query() {
    let mut client = Client::new(Config {
        debug_mode: "0".into(),
        ..config()
    });
    assert!(
        !client.get("/?debug").await.contains(r#"id="debug""#),
        "DSQUIZ_DEBUG=0 must forbid ?debug -- the panel can hand itself points"
    );
    assert_eq!(
        client.post("/debug/points/100").await.status,
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn debug_complete_goes_through_the_real_scoring_path() {
    let mut client = Client::new(Config {
        debug_mode: "1".into(),
        ..config()
    });
    client.get("/").await;
    client.post("/debug/goal/200").await;
    let body = client.post("/debug/complete").await.body;
    assert!(
        body.contains(r#"class="finale""#),
        "the finale did not arrive"
    );
    assert!(
        body.contains("sfx-final"),
        "the finale's own sound is part of that beat"
    );
}

#[tokio::test]
async fn the_mount_prefix_reaches_every_url() {
    let mut client = Client::new(Config {
        prefix: "/bridge-system-quiz".into(),
        ..config()
    });
    let page = client.get("/bridge-system-quiz/").await;
    assert_eq!(page.status, StatusCode::OK);
    assert!(
        page.contains("@post('/bridge-system-quiz/answer/"),
        "the action URLs did not carry the mount prefix"
    );
    // html/template rewrites `/` as `\/` inside a `data-on:*` attribute and the Go port had to
    // splice its prefix into the template source to avoid it. Askama does not, and this is what
    // pins that.
    assert!(
        !page.contains(r"\/bridge"),
        "a URL was escaped as a JavaScript string literal"
    );
    let set_cookie = client.last_set_cookie.clone().unwrap_or_default();
    assert!(
        set_cookie.contains("Path=/bridge-system-quiz"),
        "the cookie is not scoped to the mount point: {set_cookie}"
    );
    assert_eq!(client.get("/").await.status, StatusCode::NOT_FOUND);
    assert_eq!(
        client
            .get("/bridge-system-quiz/static/app-pico.css")
            .await
            .status,
        StatusCode::OK
    );
}

#[tokio::test]
async fn sounds_are_synthesised_and_cached_hard() {
    let mut client = Client::new(config());
    for name in ["correct", "wrong", "skip", "final", "tick"] {
        let reply = client.get(&format!("/sfx/{name}")).await;
        assert_eq!(reply.status, StatusCode::OK, "/sfx/{name}");
        assert!(
            reply.body.len() > 100,
            "/sfx/{name} is {} bytes",
            reply.body.len()
        );
        assert_eq!(
            reply
                .headers
                .get(header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok()),
            Some("audio/wav")
        );
        assert!(
            reply
                .headers
                .get(header::CACHE_CONTROL)
                .and_then(|v| v.to_str().ok())
                .is_some_and(|value| value.contains("31536000")),
            "/sfx/{name} is not cached hard -- the ?v= build stamp is what busts it"
        );
    }
    assert_eq!(
        client.get("/sfx/nonesuch").await.status,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn settings_are_clamped_and_echoed_back() {
    let mut client = Client::new(config());
    client.get("/").await;
    // difficulty 99 is clamped to 8, and the effective value is echoed so the slider cannot sit
    // stale in the UI until a reload
    let body = client
        .send(
            "POST",
            "/settings",
            Some(r#"{"difficulty":99,"targetPct":500}"#),
        )
        .await
        .body;
    assert!(
        body.contains(r#""difficulty":8"#),
        "difficulty was not clamped and echoed"
    );
    assert!(
        body.contains(r#""targetPct":90"#),
        "targetPct was not clamped and echoed"
    );
    assert_eq!(
        question(&body).1,
        8,
        "the new difficulty is the new candidate count"
    );

    // junk falls back to the default rather than erroring
    let body = client
        .send("POST", "/settings", Some(r#"{"difficulty":"nonsense"}"#))
        .await
        .body;
    assert!(
        body.contains(r#""difficulty":5"#),
        "an unusable difficulty should fall back"
    );
}

#[tokio::test]
async fn malformed_signals_are_not_a_server_error() {
    let mut client = Client::new(config());
    client.get("/").await;
    assert_eq!(
        client
            .send("POST", "/settings", Some("{not json"))
            .await
            .status,
        StatusCode::NO_CONTENT,
        "a malformed body should be a no-op, not a 400 -- absent signals mean nothing to adopt"
    );
}

/// The markers `apps/dsquiz-perf/common/datastar.py` reads out of the HTML. Getting any of these
/// wrong does not fail a load run -- it makes every request in it a failure, or silently measures
/// the wrong route.
#[tokio::test]
async fn the_harness_can_drive_the_page() {
    let mut client = Client::new(config());
    let page = client.get("/").await.body;
    assert!(
        page.contains("@post('/answer/"),
        "no answer action on the page"
    );
    assert!(
        page.contains("?squad')"),
        "the action URLs do not carry the variant query"
    );
    assert!(
        page.contains("data-bind:topics."),
        "no topic bindings on the page"
    );
    assert!(
        page.contains("/static/datastar.js"),
        "no static assets on the page"
    );
    for signal in ["_playing", "_skipsLeft"] {
        assert!(
            page.contains(signal),
            "the signal payload is missing {signal}"
        );
    }
}
