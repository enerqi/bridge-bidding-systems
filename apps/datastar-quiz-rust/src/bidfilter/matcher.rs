//! Matching an auction against a pattern, and turning a raw auction into the concrete auctions it
//! stands for.

use super::pattern::{BidPattern, Pattern, PatternKind, Side};
use super::relative;
use crate::bids::{self, Bid, Kind};
use crate::flat::{Flat, Groups};

/// A parsed auction: one group per POSITION, holding the calls that position allows. One for an
/// ordinary call, several for `2D/2H`.
pub type Auction = Flat<Bid>;

/// A borrowed auction: what the matcher actually walks. Produced by `Auction::view()` for a
/// standalone one and by the corpus for an auction packed into its arena.
pub type Positions<'a> = Groups<'a, Bid>;

/// The concrete auctions one written auction stands for -- one unless correlated suit classes bind
/// or a relative token like `next` resolves several ways.
pub type Variants = Vec<Auction>;

/// Does one call satisfy one alternative of a pattern position?
///
/// Both sides can name a *set* of calls -- the auction may record `1HS` or `2D/2H`, the pattern may
/// ask for `1M` or `3S/4C` -- so this is a test for overlap, not equality.
#[inline]
pub fn bid_matches(bid: Bid, pat: BidPattern) -> bool {
    match bid.kind {
        // a catch-all row -- "whatever is called here" -- so it answers to any pattern, subject to
        // whose call it was and to how much the word promised: `(overcall)` is a bid, `(bid)` is
        // anything but a pass, `any`/`other(s)` is anything at all
        Kind::Any | Kind::AnyBid | Kind::AnyCall => {
            if !pat.side.accepts(bid.by_opponent) {
                return false;
            }
            match bid.kind {
                Kind::AnyBid => matches!(pat.kind, PatternKind::Bid | PatternKind::Wildcard),
                Kind::AnyCall => matches!(
                    pat.kind,
                    PatternKind::Bid
                        | PatternKind::Double
                        | PatternKind::Redouble
                        | PatternKind::Wildcard
                ),
                _ => true,
            }
        }
        _ => {
            let kinds_agree = match pat.kind {
                PatternKind::Wildcard => true,
                PatternKind::Bid => bid.kind == Kind::Bid,
                PatternKind::Pass => bid.kind == Kind::Pass,
                PatternKind::Double => bid.kind == Kind::Double,
                PatternKind::Redouble => bid.kind == Kind::Redouble,
            };
            if !kinds_agree || !pat.side.accepts(bid.by_opponent) {
                return false;
            }
            if pat.kind == PatternKind::Bid {
                if pat.level != 0 && pat.level != bid.level {
                    return false;
                }
                if !pat.suits.is_empty() && !bid.suits.contains_any(pat.suits) {
                    return false;
                }
            }
            true
        }
    }
}

/// As [`bid_matches`], when the *auction* position is itself a set of calls.
///
/// `1HS--3S/4C` records a position no single Bid can express, so an auction position is a set of
/// alternatives. It matches when any of them does -- the recorded auction is one of these calls,
/// and the filter is asking whether it could be the one wanted.
#[inline]
pub fn position_matches(position: &[Bid], alternatives: &[BidPattern]) -> bool {
    position
        .iter()
        .any(|bid| alternatives.iter().any(|pat| bid_matches(*bid, *pat)))
}

/// Must this position line up with the very next call rather than skipping over opponent calls?
/// True for anything bracketed and for the bare `*`.
#[inline]
fn anchored(alternatives: &[BidPattern]) -> bool {
    alternatives
        .iter()
        .any(|alt| alt.side == Side::Theirs || alt.kind == PatternKind::Wildcard)
}

/// Does the auction begin with the pattern?
///
/// A pattern describes *our* auction. The opponents can slip a call in at any point, so opponent
/// calls the pattern does not ask about are stepped over rather than failing the match: `1D-1H`
/// matches 1D (Pass) 1H, 1D (1S) 1H and 1D (X) 1H alike.
///
/// Three kinds of token opt out of that skipping and line up with whatever call comes next:
/// - the *first* token, because this is a prefix match: it anchors to the opening call, so `2C`
///   means we opened 2C, not that we bid 2C at some point after an opponent's opening;
/// - a bracketed token -- `(X)`, `(2H)`, `(*)` -- which is *about* the opponents;
/// - the bare wildcard `*`, meaning "any call at all" including an opponent's, which is what makes
///   `*-*-*-*-*-*` mean "six calls deep" rather than "six calls by us".
pub fn matches_prefix(auction: Positions<'_>, pattern: &Pattern) -> bool {
    let mut index = 0usize;
    for position in 0..pattern.len() {
        let alternatives = pattern.group(position);
        if position > 0 && !anchored(alternatives) {
            while index < auction.len() && auction.group(index).iter().all(|b| b.by_opponent) {
                index += 1;
            }
        }
        if index >= auction.len() || !position_matches(auction.group(index), alternatives) {
            return false;
        }
        index += 1;
    }
    true
}

/// Does a pre-parsed auction match *any* of the patterns (comma = OR)?
pub fn bids_match_any(variants: &[Auction], patterns: &[Pattern]) -> bool {
    variants.iter().any(|auction| {
        patterns
            .iter()
            .any(|pattern| matches_prefix(auction.view(), pattern))
    })
}

/// Parse an auction into one entry per position, each the calls it allows.
///
/// Unlike a flat call parse this keeps `3S/4C` -- an alternation spanning levels, which has no
/// single-Bid form -- instead of degrading it to 'other'.
pub fn parse_sequence_positions<S: AsRef<str>>(sequence: &[S]) -> Auction {
    let mut auction = Auction::new();
    for element in sequence {
        for token in element.as_ref().split_whitespace() {
            let before = auction.open_len();
            for call in bids::parse_call_alternatives(token) {
                match call.kind {
                    // `2N+` names its own floor, so it needs no auction: expand it here into the
                    // calls it allows
                    Kind::AtLeast => {
                        let mut expanded = Vec::new();
                        bids::calls_at_or_above(call, &mut expanded);
                        for bid in expanded {
                            auction.push_item(bid);
                        }
                    }
                    // a game contract: 3N, 4H, 4S, 5C or 5D
                    Kind::Game => {
                        for bid in bids::game_calls(call.by_opponent) {
                            auction.push_item(bid);
                        }
                    }
                    _ => auction.push_item(call),
                }
            }
            if auction.open_len() > before {
                auction.close_group();
            }
        }
    }
    auction
}

/// Drop opponent passes. They are noise for filtering -- the auction notation omits them anyway --
/// and dropping them is what lets `(*)` mean "the opponents actually did something". Active
/// opponent calls like (X) or (1S) are kept, and [`matches_prefix`] decides whether to step over
/// them.
pub fn significant_positions(auction: &Auction) -> Auction {
    let mut out = Auction::with_capacity(auction.len(), auction.item_count());
    for position in auction.groups() {
        let all_opponent_passes = position
            .iter()
            .all(|bid| bid.by_opponent && bid.kind == Kind::Pass);
        if !all_opponent_passes {
            out.push_group(position.iter().copied());
        }
    }
    out
}

/// Turn one auction into the concrete auctions it stands for: parsed into positions, opponent
/// passes dropped, suit classes bound, `next` and its relatives resolved.
pub fn prepare_auction<S: AsRef<str>>(sequence: &[S]) -> Variants {
    let positions = significant_positions(&parse_sequence_positions(sequence));
    let mut out = Variants::new();
    for variant in relative::expand_correlated(&positions) {
        out.extend(relative::resolve_relative(&variant));
    }
    out
}

/// Parse a raw auction and prefix-match it against any of the patterns. Convenience for tests and
/// one-off checks; the app pre-parses instead.
pub fn sequence_matches_any<S: AsRef<str>>(sequence: &[S], patterns: &[Pattern]) -> bool {
    bids_match_any(&prepare_auction(sequence), patterns)
}
