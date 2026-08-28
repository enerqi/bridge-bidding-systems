//! The static files, embedded so the binary is the deployment.
//!
//! `include_bytes!` and a match rather than a crate: there are nine files, they never change at
//! runtime, and a directory-embedding dependency would earn its place only if there were many more.

use axum::extract::Path;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};

/// `static/` is copied verbatim from `apps/datastar-quiz/static/`: the three stylesheets, the
/// game-feel layer and the vendored datastar bundle plus its source map.
const STATIC_FILES: [(&str, &str, &[u8]); 8] = [
    (
        "app.css",
        "text/css; charset=utf-8",
        include_bytes!("../../assets/static/app.css"),
    ),
    (
        "app-pico.css",
        "text/css; charset=utf-8",
        include_bytes!("../../assets/static/app-pico.css"),
    ),
    (
        "app-bulma.css",
        "text/css; charset=utf-8",
        include_bytes!("../../assets/static/app-bulma.css"),
    ),
    (
        "juice.css",
        "text/css; charset=utf-8",
        include_bytes!("../../assets/static/juice.css"),
    ),
    (
        "pico.classless.min.css",
        "text/css; charset=utf-8",
        include_bytes!("../../assets/static/pico.classless.min.css"),
    ),
    (
        "bulma.min.css",
        "text/css; charset=utf-8",
        include_bytes!("../../assets/static/bulma.min.css"),
    ),
    (
        "datastar.js",
        "text/javascript; charset=utf-8",
        include_bytes!("../../assets/static/datastar.js"),
    ),
    // The MAP matters: the bundle ends with `//# sourceMappingURL=datastar.js.map`, so opening
    // devtools asks for it, and without it every such request is a 404 in the log.
    (
        "datastar.js.map",
        "application/json",
        include_bytes!("../../assets/static/datastar.js.map"),
    ),
];

/// The completion screen's image, which lives with the panel app and is served read-only.
const MEDIA_FILES: [(&str, &str, &[u8]); 1] = [(
    "completed.jpeg",
    "image/jpeg",
    include_bytes!("../../assets/media/completed.jpeg"),
)];

fn serve(files: &[(&str, &str, &'static [u8])], path: &str) -> Response {
    match files.iter().find(|(name, _, _)| *name == path) {
        Some((_, content_type, bytes)) => (
            [
                (header::CONTENT_TYPE, *content_type),
                // `no-cache` means REVALIDATE, not "do not cache": the browser keeps the file and
                // asks with its etag, so an unchanged sheet costs a 304 and a changed one arrives
                // immediately. Without it a browser is entitled to invent a freshness lifetime,
                // which is how an edited stylesheet kept not showing up until a hard reload.
                (header::CACHE_CONTROL, "no-cache"),
            ],
            *bytes,
        )
            .into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

pub async fn statics(Path(path): Path<String>) -> Response {
    serve(&STATIC_FILES, &path)
}

pub async fn media(Path(path): Path<String>) -> Response {
    serve(&MEDIA_FILES, &path)
}
