//! The microbenchmarks: the filter (where the CPU goes), scoring, and question generation.
//!
//! `harness = false` and no criterion. What is wanted here is one wall-clock number per routine to
//! set beside the python's (`check_filter("1C")` 15.8 ms warm, a topic 43 ms, over 7,627 auctions)
//! and the Go port's, and criterion's statistics would not change any of those conclusions -- they
//! differ by one to two orders of magnitude. A dependency that only a benchmark uses is also a
//! dependency somebody has to build.
//!
//!     cargo bench            # or: just dsrs bench
//!
//! Run under `--release`, which cargo does for benches: a debug build of this app is roughly an
//! order of magnitude slower, because the matcher is generic iterator code that depends on inlining.

use std::hint::black_box;
use std::time::Instant;

use dsquiz::bidfilter;
use dsquiz::corpus::Corpus;
use dsquiz::engine::{self, AnswerInput, ChoiceType, POINTS_GOAL, Question, Score};

fn time(label: &str, iterations: u32, mut body: impl FnMut()) {
    // one untimed pass, so a first-call cost does not land in the average
    body();
    let started = Instant::now();
    for _ in 0..iterations {
        body();
    }
    let each = started.elapsed().as_secs_f64() / f64::from(iterations);
    let shown = if each >= 1e-3 {
        format!("{:>9.3} ms", each * 1e3)
    } else if each >= 1e-6 {
        format!("{:>9.3} us", each * 1e6)
    } else {
        format!("{:>9.1} ns", each * 1e9)
    };
    println!("{label:<44}{shown}   ({iterations} iterations)");
}

fn main() {
    let started = Instant::now();
    let corpus = Corpus::load().expect("the corpus is embedded");
    println!(
        "\ncorpus: parse + prepare both systems           {:>9.1} ms\n",
        started.elapsed().as_secs_f64() * 1e3
    );

    let swedish = corpus.get("swedish").expect("the swedish system");
    let squad = corpus.default_system();
    println!(
        "swedish: {} auctions, {} positions, {} calls, prepared heap {:.2} MB",
        swedish.auctions.len(),
        swedish.prepared.position_count(),
        swedish.prepared.call_count(),
        swedish.prepared.heap_bytes() as f64 / 1_048_576.0
    );
    println!("one Bid is {} bytes\n", size_of::<dsquiz::bids::Bid>());

    // --- the filter: cold (the memo cleared each time) and warm (the memo hit) ---
    time("check_filter(\"1C\") cold, 7,627 auctions", 200, || {
        swedish.clear_filter_cache();
        black_box(swedish.check_filter("1C", 8));
    });
    time("a topic cold, 7,627 auctions", 200, || {
        swedish.clear_filter_cache();
        black_box(swedish.check_filter("1C opening", 8));
    });
    time("check_filter(\"1C\") warm (memo hit)", 20_000, || {
        black_box(swedish.check_filter("1C", 8));
    });
    time("check_filter(\"1C\") cold, 1,652 auctions", 500, || {
        squad.clear_filter_cache();
        black_box(squad.check_filter("1C", 8));
    });
    // Every request that types a distinct filter pays this: the memo never helps, so it is the
    // worst case the per-keystroke validation can produce.
    let mut n = 0u32;
    time("a distinct valid pattern each time (squad)", 2_000, || {
        n += 1;
        let denominations = *b"CDHSN";
        let text = format!(
            "{}{}-{}{}",
            1 + (n / 35) % 7,
            denominations[((n / 5) % 5) as usize] as char,
            1 + (n / 5) % 7,
            denominations[(n % 5) as usize] as char
        );
        black_box(squad.check_filter(&text, 8));
    });

    // --- preparing the corpus, which is the boot cost ---
    let sequences: Vec<Vec<String>> = swedish
        .auctions
        .iter()
        .map(|auction| auction.sequence.clone())
        .collect();
    time("prepare the swedish corpus for filtering", 5, || {
        black_box(bidfilter::prepare_sequence_bids(&sequences));
    });

    // --- the rules ---
    let question = Question {
        candidates: ["1C (Pass) 1H --> 2D", "1D --> 1S", "1N --> 2C", "2H", "3N"]
            .iter()
            .map(|c| (*c).to_owned())
            .collect(),
        answer: "the description".into(),
        answer_candidate: "2H".into(),
        choice_type: Some(ChoiceType::Auctions),
    };
    time("score_points", 200_000, || {
        black_box(engine::score_points(&question, 5, 62));
    });
    time("answer (state change + toast script)", 100_000, || {
        let mut score = Score::default();
        black_box(engine::answer(
            &mut score,
            AnswerInput {
                question: &question,
                candidate: "2H",
                percent_left: 100,
                ladder_mode: true,
                target_on: false,
                target_pct: 70,
                last_correct_points: 0,
                points_goal: POINTS_GOAL,
            },
        ));
    });
    let working: Vec<u32> = (0..squad.auctions.len() as u32).collect();
    time("new_question (5 of 1,652)", 100_000, || {
        black_box(engine::new_question(&squad.auctions, &working, 5));
    });
    println!();
}
