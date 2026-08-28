//! The `.bml` corpus and the bidding-tree filter over it.
//!
//! The python app imports `apps/quiz/quiz.py` and parses the notes itself. This port does not:
//! writing a fourth BML parser (after the python one, the Odin `bridge-markup` and -- no, the Go
//! port did not write one either) is weeks of work and is not what the comparison is about. The
//! parsed corpus is EXPORTED from the python app by `apps/datastar-quiz/tools/export_corpus.py` and
//! embedded here, byte-identical to the copy the Go port embeds, so all three provably draw
//! questions from the same auctions.
//!
//! What is NOT exported is the filter: the matcher is ported (see [`crate::bidfilter`]), because
//! that is where the CPU goes and a comparison that skips it is not a comparison.
//!
//! # Two allocation decisions, both visible in the numbers
//!
//! **The prepared corpus is one arena.** Preparing the swedish system produces ~380,000 positions
//! across ~400,000 calls. Held as `Vec<Vec<Vec<Bid>>>` that is hundreds of thousands of separate
//! allocations; here it is four `Vec`s for the whole system and the matcher walks contiguous
//! memory. See [`Prepared`].
//!
//! **A filter's hits are indices, not auctions.** The memo keeps up to 256 answers, and the Go port
//! stores each as a `[]Auction` -- 40 bytes per hit, measured at 14.6 MB of live heap under load.
//! Here a hit is a `u32` into the auction list and the list is an `Arc<[u32]>`, so the same memo is
//! four bytes per hit and shared rather than cloned.

use std::sync::Arc;

use lru::LruCache;
use parking_lot::Mutex;
use serde::Deserialize;

use crate::bidfilter::{self, Pattern, Topic, Topics, Variants};
use crate::bids::Bid;
use crate::flat::Groups;

/// A quiz flavour: which bml system it draws on, and how it is presented.
#[derive(Clone, Debug)]
pub struct Variant {
    pub key: String,
    pub title: String,
    pub bml_file: String,
    pub system_notes_url: String,
}

/// One bidding sequence and what it means -- exactly the public fields of the python
/// `quiz.BidSequenceMeaning`.
#[derive(Clone, Debug, Deserialize)]
pub struct Auction {
    pub sequence: Vec<String>,
    pub description: String,
}

#[derive(Deserialize)]
struct ExportedTopic {
    name: String,
    patterns: Vec<String>,
    #[serde(default)]
    description: String,
}

#[derive(Deserialize)]
struct Exported {
    variant: String,
    title: String,
    bml_file: String,
    system_notes_url: String,
    auctions: Vec<Auction>,
    topics: Vec<ExportedTopic>,
}

/// Every prepared auction of one system, in four allocations.
///
/// `bids` holds every call of every variant of every auction, end to end. The three offset tables
/// index into each other: `positions[p]` is where position `p` stops in `bids`, `variants[v]` is
/// where variant `v` stops in `positions`, and `auctions[a]` is where auction `a` stops in
/// `variants`.
#[derive(Default)]
pub struct Prepared {
    bids: Vec<Bid>,
    positions: Vec<u32>,
    variants: Vec<u32>,
    auctions: Vec<u32>,
}

impl Prepared {
    fn push(&mut self, variants: &Variants) {
        for variant in variants {
            for position in variant.groups() {
                self.bids.extend_from_slice(position);
                self.positions.push(self.bids.len() as u32);
            }
            self.variants.push(self.positions.len() as u32);
        }
        self.auctions.push(self.variants.len() as u32);
    }

    fn range(ends: &[u32], index: usize) -> (usize, usize) {
        let end = ends[index] as usize;
        let start = if index == 0 {
            0
        } else {
            ends[index - 1] as usize
        };
        (start, end)
    }

    /// Does auction `index` match any of the patterns? Walks its variants without allocating.
    pub fn matches_any(&self, index: usize, patterns: &[Pattern]) -> bool {
        let (first_variant, last_variant) = Self::range(&self.auctions, index);
        for variant in first_variant..last_variant {
            let (first_position, last_position) = Self::range(&self.variants, variant);
            let base = if first_position == 0 {
                0
            } else {
                self.positions[first_position - 1]
            };
            let view = Groups::new(
                &self.bids,
                &self.positions[first_position..last_position],
                base,
            );
            if patterns
                .iter()
                .any(|pattern| bidfilter::matches_prefix(view, pattern))
            {
                return true;
            }
        }
        false
    }

    /// Bytes of heap held, for the memory write-up.
    pub fn heap_bytes(&self) -> usize {
        self.bids.capacity() * size_of::<Bid>()
            + (self.positions.capacity() + self.variants.capacity() + self.auctions.capacity())
                * size_of::<u32>()
    }

    pub fn call_count(&self) -> usize {
        self.bids.len()
    }
    pub fn position_count(&self) -> usize {
        self.positions.len()
    }
}

/// What a filter string *would* select. Asking never commits it.
///
/// `hits` are INDICES into the system's auction list, shared rather than cloned -- see the module
/// note.
#[derive(Debug)]
pub struct FilterCheck {
    pub status: Status,
    pub hits: Arc<[u32]>,
    pub parsed: bidfilter::ParsedFilter,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Status {
    /// no filter: the whole system
    All,
    /// a usable filter
    Ok,
    /// nothing in the text resolved
    Error,
    /// fewer matches than a question needs
    TooFew,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::All => "all",
            Status::Ok => "ok",
            Status::Error => "error",
            Status::TooFew => "too_few",
        }
    }
}

impl FilterCheck {
    /// Should the caller adopt the hits, or fall back to the whole system?
    pub fn usable(&self) -> bool {
        self.status == Status::Ok
    }
}

/// How many distinct filters to remember.
///
/// 256, as in the python and the Go: comfortably larger than the topic list plus the prefixes a
/// typist produces, and small enough that it cannot become a memory leak -- the text is user input,
/// so an unbounded cache would be a way to grow the process without limit.
pub const FILTER_CACHE_SIZE: usize = 256;

/// The memo's counters, for the debug panel and for reporting the hit rate under load.
#[derive(Clone, Copy, Debug, Default)]
pub struct CacheInfo {
    pub hits: u64,
    pub misses: u64,
    pub size: usize,
    pub max_size: usize,
}

/// One loaded variant: its auctions, the same auctions pre-parsed for filtering, and its topics.
pub struct System {
    pub variant: Variant,
    pub auctions: Vec<Auction>,
    pub prepared: Prepared,
    pub topics: Topics,
    cache: Mutex<FilterCache>,
    /// the "everything matches" answer, built once: the one filter that returns every auction
    all: Arc<[u32]>,
}

struct FilterCache {
    entries: LruCache<(String, usize), Arc<FilterCheck>>,
    hits: u64,
    misses: u64,
}

impl System {
    /// The port of the python `corpus.check_filter`.
    ///
    /// Used both to validate as the user types and to apply on commit, so the preview can never
    /// disagree with the result. Statuses other than `Ok` mean the caller should fall back to the
    /// whole system -- question generation needs `min_hits` distinct auctions to build the hardest
    /// question.
    ///
    /// MEMOISED, because this is the app's most expensive routine and it is called per keystroke.
    /// The KEY is the NORMALISED text, which costs nothing extra and is exact rather than
    /// approximate. Case is deliberately NOT folded in on top of that: `m` is the minors and `M`
    /// the majors, so a case-insensitive key would answer `1m` with the majors.
    pub fn check_filter(&self, text: &str, min_hits: usize) -> Arc<FilterCheck> {
        let key = (bidfilter::normalize_filter_text(text), min_hits);
        {
            let mut cache = self.cache.lock();
            if let Some(found) = cache.entries.get(&key).map(Arc::clone) {
                cache.hits += 1;
                return found;
            }
            cache.misses += 1;
        }
        // computed OUTSIDE the lock: a cold topic check is the most expensive thing this server
        // does, and holding the memo across it would serialise every other session's keystrokes
        // behind it
        let check = Arc::new(self.check_uncached(&key.0, min_hits));
        self.cache.lock().entries.put(key, Arc::clone(&check));
        check
    }

    fn check_uncached(&self, normalised: &str, min_hits: usize) -> FilterCheck {
        let parsed = bidfilter::parse_filter(normalised, Some(&self.topics));
        if parsed.patterns.is_empty() {
            let status = if parsed.errors.is_empty() {
                Status::All
            } else {
                Status::Error
            };
            return FilterCheck {
                status,
                hits: Arc::clone(&self.all),
                parsed,
            };
        }
        let hits: Arc<[u32]> = (0..self.auctions.len())
            .filter(|index| self.prepared.matches_any(*index, &parsed.patterns))
            .map(|index| index as u32)
            .collect();
        let status = if hits.len() < min_hits {
            Status::TooFew
        } else {
            Status::Ok
        };
        FilterCheck {
            status,
            hits,
            parsed,
        }
    }

    /// The auction at one of a [`FilterCheck`]'s hit indices.
    pub fn auction(&self, index: u32) -> &Auction {
        &self.auctions[index as usize]
    }

    pub fn filter_cache_info(&self) -> CacheInfo {
        let cache = self.cache.lock();
        CacheInfo {
            hits: cache.hits,
            misses: cache.misses,
            size: cache.entries.len(),
            max_size: FILTER_CACHE_SIZE,
        }
    }

    /// Empty the memo. For tests and for a clean measurement window.
    pub fn clear_filter_cache(&self) {
        let mut cache = self.cache.lock();
        cache.entries.clear();
        cache.hits = 0;
        cache.misses = 0;
    }
}

/// The exported corpus, checked in and regenerated with `just dsrs export-corpus`.
///
/// Embedded rather than read from disk so the binary is the deployment. The same two files are
/// embedded by the Go port; the goldens in `tests/` prove the two agree about what they select.
const SQUAD_JSON: &str = include_str!("../corpus/squad.json");
const SWEDISH_JSON: &str = include_str!("../corpus/swedish.json");

/// The order the variants are declared in, which is the order [`Corpus::load`] walks them. `squad`
/// is the default -- `?swedish` picks the other.
pub const VARIANT_KEYS: [&str; 2] = ["squad", "swedish"];
pub const DEFAULT_VARIANT_KEY: &str = "squad";

/// Every loaded system.
pub struct Corpus {
    systems: Vec<System>,
}

impl Corpus {
    /// Parse every variant's corpus and pre-parse its auctions for filtering.
    ///
    /// Called at startup, not on whoever asks first. The python app learned this the expensive way:
    /// the yappi profile caught `load_bid_tables` (1.3 s) plus `prepare_sequence_bids` (4.3 s)
    /// landing inside a REQUEST, on the first visitor to open the second system.
    pub fn load() -> Result<Corpus, String> {
        let mut systems = Vec::with_capacity(VARIANT_KEYS.len());
        for (key, json) in VARIANT_KEYS.iter().zip([SQUAD_JSON, SWEDISH_JSON]) {
            let exported: Exported =
                serde_json::from_str(json).map_err(|err| format!("corpus {key}.json: {err}"))?;
            if exported.auctions.is_empty() {
                return Err(format!("corpus {key}.json: no auctions"));
            }
            let mut prepared = Prepared::default();
            for auction in &exported.auctions {
                prepared.push(&bidfilter::prepare_auction(&auction.sequence));
            }
            let all: Arc<[u32]> = (0..exported.auctions.len() as u32).collect();
            let topics = Topics::new(
                exported
                    .topics
                    .into_iter()
                    .map(|topic| Topic {
                        name: topic.name,
                        patterns: topic.patterns,
                        description: topic.description,
                    })
                    .collect(),
            );
            systems.push(System {
                variant: Variant {
                    key: exported.variant,
                    title: exported.title,
                    bml_file: exported.bml_file,
                    system_notes_url: exported.system_notes_url,
                },
                auctions: exported.auctions,
                prepared,
                topics,
                cache: Mutex::new(FilterCache {
                    entries: LruCache::new(FILTER_CACHE_SIZE.try_into().expect("non-zero")),
                    hits: 0,
                    misses: 0,
                }),
                all,
            });
        }
        Ok(Corpus { systems })
    }

    /// The loaded system for a variant key, or `None` for a key this build does not have.
    ///
    /// Tolerant on purpose: the key may have come from a browser's stored "which system was I on",
    /// and a renamed variant should hand the player the default rather than an error.
    pub fn get(&self, key: &str) -> Option<&System> {
        self.systems.iter().find(|system| system.variant.key == key)
    }

    /// The system a bare URL means.
    pub fn default_system(&self) -> &System {
        self.get(DEFAULT_VARIANT_KEY)
            .expect("the default variant is always loaded")
    }

    pub fn systems(&self) -> &[System] {
        &self.systems
    }

    /// The variant a query string explicitly asks for, or `None` if it names none.
    ///
    /// Distinct from [`Self::variant_switch_for_query`] on purpose: an unrelated query (`?debug`)
    /// must not be read as "switch me back to the default", or a swedish session would flip to
    /// squad on the next odd link.
    pub fn requested_variant(&self, query: &str) -> Option<&System> {
        // Scanned case-insensitively in place rather than lowercasing the query first: the query
        // carries the whole ~800-byte signal payload on a GET, and this runs on every request.
        for key in ["swedish", "squad"] {
            if contains_ignore_ascii_case(query, key) {
                return self.get(key);
            }
        }
        None
    }

    /// What an *existing* session should switch to, or `None` to keep the variant it has.
    ///
    /// Three cases, and the middle one is the whole point:
    /// - names a variant (`?swedish`, `?squad`) -> that variant;
    /// - **no query at all** -> the default. The bare URL is the one people share and link to, so
    ///   it has to mean "take me home"; without this a `?swedish` session is stuck forever;
    /// - a non-empty query naming no variant (`?debug`) -> `None`, keep what the session has.
    pub fn variant_switch_for_query(&self, query: &str) -> Option<&System> {
        if query.is_empty() {
            return Some(self.default_system());
        }
        self.requested_variant(query)
    }
}

/// `haystack.to_lowercase().contains(needle)` without the allocation. `needle` must already be
/// lowercase ASCII.
fn contains_ignore_ascii_case(haystack: &str, needle: &str) -> bool {
    let (haystack, needle) = (haystack.as_bytes(), needle.as_bytes());
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    haystack
        .windows(needle.len())
        .any(|window| window.eq_ignore_ascii_case(needle))
}
