//! Serves the Rust port of the bidding quiz.
//!
//! The point of this program is the COMPARISON with `apps/quiz/` (Panel), `apps/datastar-quiz/`
//! (Datastar + Litestar) and `apps/datastar-quiz-golang/`: the same hypermedia architecture, the
//! same corpus, the same routes, driven by the same load harness, so that what differs is the
//! runtime and the language rather than the design.
//!
//! TWO CORE BUDGETS, BOTH REPORTED. The python app is one asyncio loop in one process: one core,
//! whatever the machine has. Tokio's multi-threaded runtime will use all of them by default, so a
//! naive comparison says "Rust is 20x faster" when it means "Rust used 20 cores".
//!
//! ```text
//! --threads 1   the honest like-for-like: same work, same core budget, and the number that
//!               says what the runtime costs
//! --threads 0   unrestricted (the default) -- what the language actually buys you on this box
//! ```
//!
//! There is no GC to pin down, which is half the reason this port exists: the Go one needs `GOGC`
//! and `GOMEMLIMIT` held still so a collection landing mid-percentile is a deliberate effect, and
//! here there is nothing to hold still. Every setting a run used is logged at startup.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use axum::serve::ListenerExt;
use dsquiz::corpus::Corpus;
use dsquiz::session::{self, Store};
use dsquiz::web::{self, AppState, Config};
use dsquiz::{render, sfx};

// TWEAK 2 (experiment): see the note in Cargo.toml.
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    // THE CORPUS IS LOADED AT STARTUP, and there is deliberately no lazy path to fall back to -- so
    // `DSQUIZ_PREWARM` has no counterpart here, exactly as in the Go port. The python has one
    // because its corpus work happened inside a REQUEST until recently, and the yappi profile
    // caught it: 1.3s of `load_bid_tables` plus 4.3s of `prepare_sequence_bids` landing on the
    // first visitor to open the second system.
    let started = Instant::now();
    // Leaked rather than `Arc`ed: it is loaded once and lives for the process, so every session
    // holding a plain `&'static` costs nothing to copy and nothing to drop.
    let corpus: &'static Corpus = Box::leak(Box::new(Corpus::load()?));
    sfx::warm();
    let warm = started.elapsed();

    // TWEAK 1 (experiment): a single worker gets the CURRENT-THREAD scheduler rather than the
    // multi-thread one with `worker_threads(1)`. The multi-thread scheduler pays for work-stealing
    // queues, a remote-queue check per tick and cross-thread wakers whether or not a second worker
    // exists, and `--threads 1` is the like-for-like configuration the comparison is measured in.
    let mut runtime = if args.threads == 1 {
        tokio::runtime::Builder::new_current_thread()
    } else {
        tokio::runtime::Builder::new_multi_thread()
    };
    runtime.enable_all();
    if args.threads > 1 {
        runtime.worker_threads(args.threads);
    }
    let runtime = runtime.build()?;
    let workers = if args.threads > 0 {
        args.threads
    } else {
        std::thread::available_parallelism()?.get()
    };

    runtime.block_on(async move {
        let state = Arc::new(AppState {
            config: Config {
                timer_mode: args.timer_mode.clone(),
                morph_mode: args.morph_mode.clone(),
                prefix: args.prefix.clone(),
                debug_mode: args.debug_mode.clone(),
            },
            renderer: render::Config {
                prefix: args.prefix.clone(),
                timer_mode: args.timer_mode.clone(),
            },
            corpus,
            store: Store::default(),
        });

        // A background sweep rather than the python's lazy "sweep if it has been ten minutes since
        // the last request": an idle server should actually release the memory rather than hold it
        // until somebody knocks.
        let sweeper = Arc::clone(&state);
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(session::SWEEP_PERIOD);
            ticker.tick().await; // the first tick is immediate
            loop {
                ticker.tick().await;
                sweeper.store.sweep();
            }
        });

        let address: SocketAddr = format!("{}:{}", args.addr, args.port).parse()?;
        // TCP_NODELAY, WHICH AXUM DOES NOT SET FOR YOU.
        //
        // `axum::serve` hands the accepted socket straight to hyper; `set_nodelay` appears in
        // axum's own source only inside its tests. Go's `net/http` sets it on every accepted
        // connection, and so do uvicorn and granian, so leaving it alone here is not a level
        // playing field -- it is a handicap unique to this port.
        //
        // Measured: without it, locust (which keeps connections alive) saw 10-11 ms for `/next`,
        // `/skip`, `/restart` and `/settings` against the Go port's 2-3 ms, while `curl` -- a fresh
        // connection per request -- reported 1.0-1.7 ms for the same work. That gap is Nagle
        // waiting on a delayed ACK, not the server, and it would have cost this column a factor of
        // five in every interaction number.
        let listener = tokio::net::TcpListener::bind(address)
            .await?
            .tap_io(|stream| {
                if let Err(err) = stream.set_nodelay(true) {
                    eprintln!("could not set TCP_NODELAY: {err}");
                }
            });
        println!(
            "quizd listening addr={address} prefix={:?} timer={} morph={} debug={:?} \
             worker_threads={workers} available={} corpus_ms={}",
            args.prefix,
            args.timer_mode,
            args.morph_mode,
            args.debug_mode,
            std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(0),
            warm.as_millis(),
        );

        axum::serve(listener, web::router(state))
            .with_graceful_shutdown(shutdown())
            .await?;
        Ok::<(), Box<dyn std::error::Error>>(())
    })?;
    Ok(())
}

/// A load run is stopped with ctrl-c; that should not lose the connections mid-flight.
async fn shutdown() {
    let _ = tokio::signal::ctrl_c().await;
    println!("quizd stopping");
}

struct Args {
    addr: String,
    port: u16,
    threads: usize,
    timer_mode: String,
    morph_mode: String,
    prefix: String,
    debug_mode: String,
}

impl Args {
    /// Hand-parsed: seven flags, all with environment defaults using the same `DSQUIZ_*` names the
    /// other two ports read, so one environment drives all three. A CLI crate would be a dependency
    /// for `--help`.
    fn parse() -> Args {
        let mut args = Args {
            addr: env_or("DSQUIZ_ADDR", "127.0.0.1"),
            // 5070, not 5060 or 5008: running all three side by side is the point
            port: env_or("DSQUIZ_PORT", "5070").parse().unwrap_or(5070),
            threads: env_or("DSQUIZ_THREADS", "0").parse().unwrap_or(0),
            timer_mode: env_or("DSQUIZ_TIMER", "client"),
            morph_mode: env_or("DSQUIZ_MORPH", "fat"),
            prefix: normalise_prefix(&env_or("DSQUIZ_PREFIX", "")),
            debug_mode: env_or("DSQUIZ_DEBUG", ""),
        };
        let mut argv = std::env::args().skip(1);
        while let Some(flag) = argv.next() {
            let mut value = || argv.next().unwrap_or_default();
            match flag.as_str() {
                "--addr" => args.addr = value(),
                "--port" => args.port = value().parse().unwrap_or(args.port),
                "--threads" => args.threads = value().parse().unwrap_or(0),
                "--timer" => args.timer_mode = value(),
                "--morph" => args.morph_mode = value(),
                "--prefix" => args.prefix = normalise_prefix(&value()),
                "--debug" => args.debug_mode = value(),
                "--help" | "-h" => {
                    println!(
                        "quizd [--addr HOST] [--port N] [--threads N] [--timer client|stream]\n\
                         \x20      [--morph fat|fragment] [--prefix /path] [--debug ''|0|1]\n\n\
                         --threads 1 is the like-for-like run against the python's single event loop;\n\
                         0 (the default) uses every core. Every flag also reads a DSQUIZ_* env var."
                    );
                    std::process::exit(0);
                }
                other => eprintln!("ignoring unknown flag {other}"),
            }
        }
        args
    }
}

fn env_or(name: &str, fallback: &str) -> String {
    match std::env::var(name) {
        Ok(value) if !value.is_empty() => value,
        _ => fallback.to_owned(),
    }
}

/// `DSQUIZ_PREFIX=bridge-quiz` and `/bridge-quiz/` both mean `/bridge-quiz`; unset means the root.
fn normalise_prefix(prefix: &str) -> String {
    let trimmed = prefix.trim_matches('/');
    if trimmed.is_empty() {
        String::new()
    } else {
        format!("/{trimmed}")
    }
}
