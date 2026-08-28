//! Holding the ported matcher to the reference implementation over the REAL corpus.
//!
//! `tests/bidfilter.rs` covers the pattern language case by case. This covers the other half: that
//! the matcher selects the SAME auctions out of the same 1,652 and 7,627 auctions the python does.
//!
//! The goldens are produced by `apps/datastar-quiz/tools/export_filter_goldens.py` -- 132 probes
//! over both variants, every topic plus a spread of hand-written patterns, each recording the
//! status, the hit count and a **sha256 of the exact auction indices selected**. A single auction
//! moving in or out fails the test. The Go port asserts against the same file.

use std::collections::HashMap;
use std::sync::OnceLock;

use dsquiz::corpus::{Corpus, Status};
use serde::Deserialize;

#[derive(Deserialize)]
struct Golden {
    text: String,
    min_hits: usize,
    status: String,
    hits: usize,
    digest: String,
    canonical: String,
    errors: Vec<String>,
    topic_names: Vec<String>,
}

fn corpus() -> &'static Corpus {
    static CORPUS: OnceLock<Corpus> = OnceLock::new();
    CORPUS.get_or_init(|| Corpus::load().expect("the corpus is embedded and must parse"))
}

/// The python golden's sha256 over the selected auctions' indices, joined with commas.
///
/// A hand-rolled sha256 rather than a dependency: it is twenty lines of the published algorithm,
/// it runs once per probe in a test, and adding a crypto crate to a web app so that one test can
/// compare a digest is the wrong trade.
fn sha256_hex(message: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut padded = message.to_vec();
    let bit_length = (message.len() as u64) * 8;
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_length.to_be_bytes());

    for chunk in padded.chunks(64) {
        let mut w = [0u32; 64];
        for (index, word) in chunk.chunks(4).enumerate() {
            w[index] = u32::from_be_bytes(word.try_into().unwrap());
        }
        for index in 16..64 {
            let s0 = w[index - 15].rotate_right(7)
                ^ w[index - 15].rotate_right(18)
                ^ (w[index - 15] >> 3);
            let s1 = w[index - 2].rotate_right(17)
                ^ w[index - 2].rotate_right(19)
                ^ (w[index - 2] >> 10);
            w[index] = w[index - 16]
                .wrapping_add(s0)
                .wrapping_add(w[index - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for index in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[index])
                .wrapping_add(w[index]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        for (slot, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(value);
        }
    }
    state.iter().map(|word| format!("{word:08x}")).collect()
}

#[test]
fn the_filter_agrees_with_the_python_implementation() {
    let body = include_str!("testdata/filter_goldens.json");
    let goldens: HashMap<String, Vec<Golden>> =
        serde_json::from_str(body).expect("the goldens must parse");
    assert!(!goldens.is_empty(), "no goldens");

    let corpus = corpus();
    let mut probes = 0usize;
    for (key, cases) in &goldens {
        let system = corpus
            .get(key)
            .unwrap_or_else(|| panic!("no such variant: {key}"));
        for want in cases {
            let check = system.check_filter(&want.text, want.min_hits);
            let label = format!("{key} {:?}", want.text);

            assert_eq!(check.status.as_str(), want.status, "{label}: status");
            assert_eq!(check.hits.len(), want.hits, "{label}: hit count");

            let indices: Vec<String> = check.hits.iter().map(u32::to_string).collect();
            let digest = sha256_hex(indices.join(",").as_bytes());
            assert_eq!(
                digest, want.digest,
                "{label}: selected a different set of auctions"
            );

            assert_eq!(
                check.parsed.canonical_text, want.canonical,
                "{label}: canonical text"
            );
            assert_eq!(check.parsed.errors, want.errors, "{label}: errors");
            assert_eq!(
                check.parsed.topic_names, want.topic_names,
                "{label}: topics"
            );
            probes += 1;
        }
    }
    assert!(probes >= 100, "only {probes} probes ran");
}

#[test]
fn the_corpus_is_the_one_the_other_ports_embed() {
    let corpus = corpus();
    assert_eq!(corpus.get("squad").unwrap().auctions.len(), 1652);
    assert_eq!(corpus.get("swedish").unwrap().auctions.len(), 7627);
    assert_eq!(corpus.get("squad").unwrap().topics.len(), 18);
    assert_eq!(corpus.get("swedish").unwrap().topics.len(), 32);
    assert_eq!(corpus.default_system().variant.key, "squad");
}

#[test]
fn the_memo_remembers_and_does_not_fold_case() {
    // Its OWN corpus, not the shared one: cargo runs tests in parallel and the counters are
    // process-wide state, so a sibling test's keystroke would land in the middle of this arithmetic.
    let own = Corpus::load().expect("the corpus is embedded and must parse");
    let system = own.default_system();

    let first = system.check_filter("1C", 8);
    let second = system.check_filter(" 1C ", 8); // normalised to the same key
    assert_eq!(first.hits.len(), second.hits.len());
    assert!(
        std::sync::Arc::ptr_eq(&first, &second),
        "the second call should be the memo's answer"
    );

    let info = system.filter_cache_info();
    assert_eq!((info.hits, info.misses), (1, 1), "cache info = {info:?}");

    // `m` is the minors and `M` the majors: two entries that must not collapse into one
    let minors = system.check_filter("1m", 8);
    let majors = system.check_filter("1M", 8);
    assert!(!std::sync::Arc::ptr_eq(&minors, &majors));
    assert!(system.filter_cache_info().size >= 3);
}

#[test]
fn a_filter_that_selects_everything_shares_one_list() {
    let system = corpus().default_system();
    let all = system.check_filter("", 8);
    assert_eq!(all.status, Status::All);
    assert_eq!(all.hits.len(), system.auctions.len());
    // the same shared allocation, not a copy per session
    let again = system.check_filter("   ", 8);
    assert!(std::sync::Arc::ptr_eq(&all.hits, &again.hits));
}

/// The arena, reported so a change in the representation shows up as a number rather than as a
/// feeling. These are the figures the README quotes against the Go port's.
#[test]
fn the_prepared_corpus_is_small() {
    let swedish = corpus().get("swedish").unwrap();
    let bytes = swedish.prepared.heap_bytes();
    println!(
        "swedish: {} auctions, {} positions, {} calls, prepared heap {} bytes ({:.1} MB)",
        swedish.auctions.len(),
        swedish.prepared.position_count(),
        swedish.prepared.call_count(),
        bytes,
        bytes as f64 / 1_048_576.0
    );
    // The Go port holds the same data as `[]Variants` of `[]Position` of `[]Bid` at 40 bytes a
    // call: ~16 MB for this system. Four vectors of 6-byte calls is an order of magnitude less, and
    // this guards the representation rather than the exact figure.
    assert!(
        bytes < 4 * 1024 * 1024,
        "prepared corpus grew to {bytes} bytes"
    );
}
