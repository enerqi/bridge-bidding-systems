//! The hypermedia surface of the quiz: axum routes over tokio.
//!
//! Every handler is the same shape -- mutate the authoritative session, then stream back the patches
//! that make the browser agree. There is no client-side model to keep in step, which is the whole
//! point of the experiment.
//!
//! The action lives in the URL (`/answer/<qid>/<index>`), not in a signal, so a stale or repeated
//! click is rejected by comparing the question nonce -- replacing panel's "clicks occurred too
//! quickly" guard with something a reload cannot defeat.

mod assets;
mod handlers;
pub mod sse;

use std::sync::Arc;

use axum::Router;
use axum::routing::{get, post};
use tower_http::compression::CompressionLayer;

use crate::corpus::Corpus;
use crate::render;
use crate::session::Store;

/// The deployment-shaped configuration, all of it from `DSQUIZ_*` environment variables with the
/// same names the python and Go apps use, so one environment drives all three.
#[derive(Clone, Debug)]
pub struct Config {
    /// Which push model drives the countdown bar. The whole point of the port is comparing these:
    ///
    /// - `"client"` (default): the browser walks `$_timeLeftPct` down with `data-on-interval`. No
    ///   held connection; the server states the allowance once per question and nothing else.
    /// - `"stream"`: `GET /timer` is held open and pushes a signal patch every tick, panel's model
    ///   exactly. On python that is the mode nobody would ship; here it is a task and an interval.
    pub timer_mode: String,
    /// How much DOM a state change sends back. The Tao's advice is "fat morph": send large chunks
    /// and let the morph work out what changed.
    ///
    /// - `"fat"` (default): patch `#app`, the whole page below `<body>`. The server never has to
    ///   remember which fragments a change touches.
    /// - `"fragment"`: patch `#quiz` only. Measured on the python at 1000 users: ~40% off the P99
    ///   tail and nothing on throughput.
    pub morph_mode: String,
    /// Where the app is mounted when it is not at the root of a host. Requests must arrive WITH the
    /// prefix still attached.
    pub prefix: String,
    /// `""` means `?debug` arms the panel for that session; `"1"` means on for every session; `"0"`
    /// means off and `?debug` cannot turn it on -- the one to set on a public deployment, because
    /// the panel can hand itself points and jump to the end.
    pub debug_mode: String,
}

impl Config {
    pub fn fragment_morph(&self) -> bool {
        self.morph_mode == "fragment"
    }
    pub fn stream_timer(&self) -> bool {
        self.timer_mode == "stream"
    }
}

/// Everything a handler needs, shared by every task.
pub struct AppState {
    pub config: Config,
    pub renderer: render::Config,
    pub corpus: &'static Corpus,
    pub store: Store,
}

pub type State = Arc<AppState>;

/// The element targets. Only `#quiz` and `#toasts` are ever patched as elements; everything else
/// the server owns arrives as `_`-prefixed signals.
pub const APP_SELECTOR: &str = "#app";
pub const QUIZ_SELECTOR: &str = "#quiz";
pub const TOASTS_SELECTOR: &str = "#toasts";
/// The sound sink lives OUTSIDE `#app`, with the `<audio>` elements, so a fat morph cannot disturb
/// a sound mid-play. The gauge is inside it, which is exactly what the milestone sweep wants: the
/// next view patch takes the shine away with no cleanup.
pub const SFX_SELECTOR: &str = "#sfx";
pub const METER_SELECTOR: &str = "#app .points-meter";
pub const FILTER_STATUS_SELECTOR: &str = "#filter-status";
pub const TOPICS_STATUS_SELECTOR: &str = "#topics-status";

/// Build the router, mounted at its prefix.
pub fn router(state: State) -> Router {
    let prefix = state.config.prefix.clone();
    let at = |path: &str| format!("{prefix}{path}");

    // The datastar routes are STREAMS and compress themselves (see `sse`); only the routes that
    // produce a whole response go through the middleware.
    let streams = Router::new()
        .route(&at("/answer/{qid}/{index}"), post(handlers::answer))
        .route(&at("/next"), post(handlers::next))
        .route(&at("/skip"), post(handlers::skip))
        .route(&at("/restart"), post(handlers::restart))
        .route(&at("/settings"), post(handlers::settings))
        .route(&at("/timer"), get(handlers::timer))
        .route(&at("/filter/preview"), get(handlers::filter_preview))
        .route(&at("/filter/preview-topics"), get(handlers::topics_preview))
        .route(&at("/filter/topics-reset"), get(handlers::topics_reset))
        .route(&at("/filter/apply"), post(handlers::filter_apply))
        .route(&at("/filter/apply-topics"), post(handlers::topics_apply))
        // The debug panel: the panel app's row of buttons for reaching a state that takes minutes
        // of honest play. Every route is a no-op unless the session is armed, so an unarmed
        // instance answers with a 204 rather than a 404 -- the same "nothing to do" answer a stale
        // qid gets, and it does not advertise whether the routes exist.
        .route(&at("/debug/points/{delta}"), post(handlers::debug_points))
        .route(&at("/debug/goal/{value}"), post(handlers::debug_goal))
        .route(&at("/debug/complete"), post(handlers::debug_complete))
        .route(&at("/debug/reveal"), post(handlers::debug_reveal));

    let documents = Router::new()
        // GET / is `no-store`, and not as a nicety: this page IS session state -- the current
        // question, the score, the reveal you are parked on -- rendered into HTML. A cached copy is
        // a different player's answer sheet at worst and a stale question at best.
        .route(&at("/"), get(handlers::index))
        .route(&at("/sfx/{name}"), get(handlers::sound))
        .route(&at("/static/{*path}"), get(assets::statics))
        .route(&at("/media/{*path}"), get(assets::media))
        // brotli quality 5 with a gzip fallback and a 256-byte minimum: what Litestar is pinned to.
        .layer(
            CompressionLayer::new()
                .br(true)
                .gzip(true)
                .quality(tower_http::CompressionLevel::Precise(5)),
        );

    streams.merge(documents).with_state(state)
}
