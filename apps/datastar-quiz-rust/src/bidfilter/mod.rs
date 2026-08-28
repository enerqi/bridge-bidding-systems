//! The bidding-tree prefix filter: a port of the matching half of `apps/quiz/bidfilter.py`.
//!
//! It turns the quiz's messy auction strings (e.g. `["1C (Pass) 1H", "2D", "2S"]`, with opponents
//! in parens, `!x` suit shorthand, and multi-suit bids like `2DHS`) into canonical positions, and
//! matches an auction prefix against a user pattern like `1D-1M-1N`.
//!
//! `oM`/`om` ("the other major/minor") and repeated class shortcuts are resolved against the
//! auction itself: `1HS--2M` means one major named twice, and `1H--2oM` means spades.

pub mod matcher;
pub mod pattern;
pub mod relative;

mod topics;

pub use matcher::{
    Auction, Variants, bid_matches, bids_match_any, matches_prefix, position_matches,
    prepare_auction, sequence_matches_any,
};
pub use pattern::{
    BadPattern, BidPattern, Pattern, PatternKind, Side, canonical_pattern_text,
    normalize_filter_text, parse_pattern, split_entries,
};
pub use topics::{ParsedFilter, Topic, Topics, parse_filter};

/// Pre-parse a corpus of auctions once, so that repeatedly re-filtering it (validating on every
/// keystroke) is only prefix comparisons.
pub fn prepare_sequence_bids<S: AsRef<str>>(sequences: &[Vec<S>]) -> Vec<Variants> {
    sequences
        .iter()
        .map(|sequence| prepare_auction(sequence))
        .collect()
}
