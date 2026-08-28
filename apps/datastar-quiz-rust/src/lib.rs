//! The bidding quiz, again: the fourth implementation, in Rust.
//!
//! The point is the COMPARISON with `apps/quiz/` (Panel), `apps/datastar-quiz/` (Datastar +
//! Litestar) and `apps/datastar-quiz-golang/` -- the same hypermedia architecture, the same corpus,
//! the same routes, driven by the same load harness, so what differs is the runtime and the
//! language rather than the design. `README.md` is the write-up; `RESULTS.md` has the numbers.
//!
//! Everything except `web` is free of the HTTP stack, which is what lets the rules, the matcher and
//! the renderer be tested and benchmarked with no server in the way.

pub mod bidfilter;
pub mod bids;
pub mod corpus;
pub mod engine;
pub mod flat;
pub mod render;
pub mod session;
pub mod sfx;
pub mod web;
