//! Correlated suit classes and relative calls -- the two things that make an auction stand for
//! more than one concrete auction.

use super::matcher::{Auction, Variants};
use crate::bids::{
    self, ALL_SUITS, Bid, Kind, MAJORS, MINORS, NO_SUITS, REAL_SUITS, SLAM_LEVELS, STEP_LIMIT,
    SuitClass, Suits,
};

// --- correlated suit classes ------------------------------------------------
//
// `1HS--2M` is "1H then 2H, or 1S then 2S" -- one major, named twice. Matching each position
// independently also accepts 1H then 2S, an auction the section never described. The corpus proves
// the intent: it writes `oM` when it means *the other* major, which would be pointless if a
// repeated `M` did not mean the same one.
//
// Rather than binding variables inside the matcher (which would make it stateful and need
// backtracking), an auction is expanded into the concrete auctions it stands for, and matches if
// any of them does. For a single set-valued position this is identical to the plain overlap test;
// it only tightens where two positions share a class.

/// A suit class is a proper subset of the denominations: {H,S} and {C,D} bind, the
/// five-denomination wildcard (`3*`) does not -- two wildcards in an auction are unrelated, not
/// "the same unknown suit".
const BINDABLE: [Suits; 2] = [MAJORS, MINORS];

/// The class this call's suit is drawn from, if it is one that binds, or none.
///
/// A concrete call counts: `1H` is a use of the majors class, which is what lets a later `2oM` mean
/// spades.
fn binding_class(bid: Bid) -> Suits {
    if !bid.is_bid() || bid.suits.is_empty() {
        return NO_SUITS;
    }
    if bid.suit_class != SuitClass::None {
        let class = bid.class_suits();
        return if BINDABLE.contains(&class) {
            class
        } else {
            NO_SUITS
        };
    }
    for class in BINDABLE {
        if bid.suits.subset_of(class) {
            return class;
        }
    }
    NO_SUITS
}

/// Which classes this auction uses as a variable.
///
/// A class binds when the auction leaves it open more than once (`1HS ... 2M`), or names "the
/// other" one alongside any call of that class (`1H ... 2oM` -- the concrete 1H is what fixes it).
fn bound_classes(auction: &Auction) -> Vec<Suits> {
    let mut open_uses = [0u32; 2];
    let mut any_uses = [0u32; 2];
    let mut other = [false; 2];
    for position in auction.groups() {
        for bid in position {
            let class = binding_class(*bid);
            let Some(slot) = BINDABLE.iter().position(|c| *c == class) else {
                continue;
            };
            any_uses[slot] += 1;
            if bid.is_other_class() {
                other[slot] = true;
            } else if bid.suits.len() > 1 {
                open_uses[slot] += 1;
            }
        }
    }
    // Fixed order rather than a hash map's: there are only two classes, and a deterministic list
    // keeps the generated variants in a stable order run to run.
    (0..2)
        .filter(|&slot| {
            any_uses[slot] > 0 && (open_uses[slot] > 1 || (other[slot] && any_uses[slot] > 1))
        })
        .map(|slot| BINDABLE[slot])
        .collect()
}

/// The one denomination of `class` the auction states outright, if any.
///
/// Two different concrete calls of the same class (`1H` then `1S`) leave the variable genuinely
/// ambiguous; returning none makes the caller fall back to the untightened auction rather than
/// guess.
fn fixed_suit(auction: &Auction, class: Suits) -> Suits {
    let mut concrete = NO_SUITS;
    for position in auction.groups() {
        for bid in position {
            if binding_class(*bid) == class && bid.suits.len() == 1 {
                concrete = concrete.union(bid.suits);
            }
        }
    }
    if concrete.len() == 1 {
        concrete
    } else {
        NO_SUITS
    }
}

fn resolve_bid(bid: Bid, assignment: &[(Suits, Suits)]) -> Bid {
    let class = binding_class(bid);
    let Some((_, chosen)) = assignment.iter().find(|(klass, _)| *klass == class) else {
        return bid;
    };
    if class == NO_SUITS || bid.suits.len() == 1 {
        return bid;
    }
    let suits = if bid.is_other_class() {
        class.without(*chosen)
    } else {
        *chosen
    };
    Bid { suits, ..bid }
}

/// The concrete auctions an auction with correlated suit classes stands for -- the auction
/// unchanged when nothing binds, which is the common case.
pub fn expand_correlated(auction: &Auction) -> Variants {
    let classes = bound_classes(auction);
    if classes.is_empty() {
        return vec![auction.clone()];
    }
    // one domain per bound class: the class's denominations, or the single one a spelled-out call
    // pinned it to
    let domains: Vec<Vec<Suits>> = classes
        .iter()
        .map(|class| {
            let fixed = fixed_suit(auction, *class);
            let has_other = auction
                .groups()
                .flatten()
                .any(|bid| binding_class(*bid) == *class && bid.is_other_class());
            if fixed != NO_SUITS && has_other {
                vec![fixed] // a spelled-out call pins the variable
            } else {
                class.iter().collect()
            }
        })
        .collect();

    let mut variants = Variants::new();
    let mut assignment: Vec<(Suits, Suits)> = classes.iter().map(|c| (*c, NO_SUITS)).collect();
    product(&domains, 0, &mut assignment, &mut |assignment| {
        let mut variant = Auction::with_capacity(auction.len(), auction.item_count());
        for position in auction.groups() {
            variant.push_group(position.iter().map(|bid| resolve_bid(*bid, assignment)));
        }
        variants.push(variant);
    });
    if variants.is_empty() {
        vec![auction.clone()]
    } else {
        variants
    }
}

/// `itertools.product` over the domains, in the same order, without materialising the cartesian
/// product.
fn product(
    domains: &[Vec<Suits>],
    depth: usize,
    assignment: &mut Vec<(Suits, Suits)>,
    emit: &mut impl FnMut(&[(Suits, Suits)]),
) {
    if depth == domains.len() {
        emit(assignment);
        return;
    }
    for value in &domains[depth] {
        assignment[depth].1 = *value;
        product(domains, depth + 1, assignment, emit);
    }
}

// --- relative calls ---------------------------------------------------------

/// One way a relative token could resolve: the call it becomes, plus the previous position pinned
/// to the single call it was measured from (when that position is the one immediately before,
/// which is the position [`resolve_relative`] rewrites).
struct Resolution {
    parent: Option<Bid>,
    call: Bid,
}

/// Replace `next` with the call it stands for: the cheapest bid above the position before it
/// (`4HS = splinter` then `next = RKB` is 4S over 4H).
///
/// Returns the auctions that produces. A parent naming several calls gives one auction per call,
/// *with the parent pinned* -- 4H then 4S, or 4S then 4N, and never 4H then 4N, which no line of
/// the table describes. A `next` whose parent is not a bid at all (`any`, prose) stays unresolved
/// and so matches nothing: the auction never said which call it was.
///
/// Run *after* [`expand_correlated`], so a parent whose suit class was bound is already concrete.
pub fn resolve_relative(auction: &Auction) -> Variants {
    let mut built: Variants = vec![Auction::new()];
    let mut scratch = Vec::new();

    for index in 0..auction.len() {
        let position = auction.group(index);
        scratch.clear();
        scratch.extend(
            position
                .iter()
                .copied()
                .filter(|bid| bid.kind.is_relative()),
        );

        if !scratch.is_empty() && !built[0].is_empty() {
            let mut grown = Variants::new();
            for partial in &built {
                let mut resolved_any = false;
                // `!c/!d` is two relative tokens at one position, so every one of them contributes
                // its resolutions
                for relative in &scratch {
                    for resolution in resolutions_of(*relative, partial) {
                        resolved_any = true;
                        let call = Bid {
                            by_opponent: relative.by_opponent,
                            ..resolution.call
                        };
                        match resolution.parent {
                            // the call we measured from is further back than the previous position,
                            // so there is nothing to pin here
                            None => {
                                let mut next = partial.clone();
                                next.push_group([call]);
                                grown.push(next);
                            }
                            Some(parent) => {
                                let mut next = Auction::with_capacity(
                                    partial.len() + 1,
                                    partial.item_count() + 2,
                                );
                                next.extend_prefix(partial, partial.len() - 1);
                                next.push_group([parent]);
                                next.push_group([call]);
                                grown.push(next);
                            }
                        }
                    }
                }
                if !resolved_any {
                    let mut next = partial.clone();
                    next.push_group(position.iter().copied()); // unresolvable, keep as is
                    grown.push(next);
                }
            }
            built = grown;
        } else {
            for partial in &mut built {
                partial.push_group(position.iter().copied());
            }
        }
    }
    built
}

/// Index of the last position holding an actual bid.
///
/// Everything here measures "cheapest above" from a *bid*: a raise or a cue over partner's double
/// is still legal, it just has to clear the last bid. `None` when the auction holds no bid at all.
fn last_bid_position(auction: &Auction) -> Option<usize> {
    (0..auction.len()).rev().find(|index| {
        auction
            .group(*index)
            .iter()
            .any(|bid| bid.is_bid() && !bid.suits.is_empty())
    })
}

/// (pinned previous call, the call the token resolves to) for each call the previous position could
/// have been.
fn resolutions_of(relative: Bid, auction: &Auction) -> Vec<Resolution> {
    let Some(source) = last_bid_position(auction) else {
        return Vec::new();
    };
    let pin = source == auction.len() - 1;
    let mut out = Vec::new();
    let mut calls = Vec::new();
    for previous in auction.group(source).to_vec() {
        for suit in previous.suits.iter() {
            let parent = Bid {
                suits: suit,
                suit_class: SuitClass::None,
                ..previous
            };
            let pinned = if pin { Some(parent) } else { None };

            if relative.kind == Kind::Next {
                if let Some(call) = bids::next_call(parent) {
                    out.push(Resolution {
                        parent: pinned,
                        call,
                    });
                }
                continue;
            }
            calls.clear();
            match relative.kind {
                Kind::Jump => jumps_from(parent, relative.jump_levels, auction, &mut calls),
                Kind::New => in_suits(parent, unbid_suits(auction), relative.level, &mut calls),
                // a denomination with no level: the simple (non-jump) bid in it
                Kind::Strain => in_suits(parent, relative.suits, 0, &mut calls),
                // `!c+`: that strain at whatever level it takes, so every legal bid in it from the
                // cheapest upward
                Kind::StrainAny => {
                    let mut cheapest = Vec::new();
                    in_suits(parent, relative.suits, 0, &mut cheapest);
                    for call in cheapest {
                        for level in call.level..=7 {
                            calls.push(Bid { level, ..call });
                        }
                    }
                }
                Kind::Raise => raises_from(parent, auction, relative, &mut calls),
                Kind::Slam => slams_from(parent, auction, relative, &mut calls),
                Kind::NextSuit => next_suit_from(parent, &mut calls),
                Kind::FourthSuit => fourth_suit_from(parent, auction, &mut calls),
                Kind::Step => steps_from(parent, relative.level, &mut calls),
                Kind::CueOver => in_suits(
                    parent,
                    rho_suits(parent, auction),
                    relative.level,
                    &mut calls,
                ),
                Kind::CueLow | Kind::CueHigh => picked_cue(parent, auction, relative, &mut calls),
                _ => cues_from(parent, auction, relative.level, &mut calls),
            }
            out.extend(calls.iter().map(|call| Resolution {
                parent: pinned,
                call: *call,
            }));
        }
    }
    out
}

/// The denominations the auction pinned down to one suit, optionally only the opponents'. An
/// unresolved `2M` names no single suit, so it neither counts as bid nor rules a suit out.
fn spoken_suits(auction: &Auction, by_opponent: Option<bool>) -> Suits {
    let mut suits = NO_SUITS;
    for position in auction.groups() {
        for bid in position {
            if !bid.is_bid() || bid.suits.len() != 1 {
                continue;
            }
            if by_opponent.is_some_and(|side| side != bid.by_opponent) {
                continue;
            }
            suits = suits.union(bid.suits);
        }
    }
    suits
}

/// Suits nobody has bid -- neither side. Notrump is not a suit.
fn unbid_suits(auction: &Auction) -> Suits {
    REAL_SUITS.without(spoken_suits(auction, None))
}

/// The call in each of `suits`: at `level` when the token named one (`3new`), otherwise the
/// cheapest available (a simple bid, not a jump).
fn in_suits(parent: Bid, suits: Suits, level: u8, out: &mut Vec<Bid>) {
    for suit in suits.iter() {
        if level == 0 {
            if let Some(call) = bids::cheapest_call(parent, suit) {
                out.push(call);
            }
            continue;
        }
        out.push(Bid {
            level,
            suits: suit,
            suit_class: SuitClass::None,
            jump_levels: 0,
            ..parent
        });
    }
}

/// Support for the last suit partner bid.
///
/// Partner's suit is the last bid on our own side of the table -- usually the call right before
/// ours, but an opponent may have come in between. `jumpRaise` is one level above the simple raise,
/// and `3raise` names the level outright.
fn raises_from(parent: Bid, auction: &Auction, token: Bid, out: &mut Vec<Bid>) {
    let suits = partner_suits(auction, token.by_opponent, parent);
    if suits.is_empty() {
        return;
    }
    let before = out.len();
    in_suits(parent, suits, token.level, out);
    if token.jump_levels == 0 {
        return;
    }
    let raised: Vec<Bid> = out[before..]
        .iter()
        .filter(|call| call.level + token.jump_levels <= 7)
        .map(|call| Bid {
            level: call.level + token.jump_levels,
            ..*call
        })
        .collect();
    out.truncate(before);
    out.extend(raised);
}

/// `slam`: the agreed suit -- the last one our side named -- at the slam level, 6 or 7. `6slam`
/// says which.
fn slams_from(parent: Bid, auction: &Auction, token: Bid, out: &mut Vec<Bid>) {
    let suits = partner_suits(auction, token.by_opponent, parent);
    for suit in suits.iter() {
        let Some(cheapest) = bids::cheapest_call(parent, suit) else {
            continue;
        };
        if token.level != 0 {
            if token.level >= cheapest.level {
                out.push(Bid {
                    level: token.level,
                    ..cheapest
                });
            }
            continue;
        }
        for level in SLAM_LEVELS {
            if level >= cheapest.level {
                out.push(Bid { level, ..cheapest });
            }
        }
    }
}

/// `nextSuit`: the next bid up that is a suit -- the cheapest call above, skipping notrump (a
/// `next` that lands on 3N is not one).
fn next_suit_from(parent: Bid, out: &mut Vec<Bid>) {
    let mut candidates = Vec::new();
    for suit in REAL_SUITS.iter() {
        if let Some(call) = bids::cheapest_call(parent, suit) {
            candidates.push(call);
        }
    }
    if let Some(lowest) = bids::lowest_call(&candidates) {
        out.push(lowest);
    }
}

/// `4thSuit`: fourth-suit-forcing -- the one suit still unbid.
///
/// Only resolvable when exactly one is left; with two or more the token is not describing anything
/// the auction has pinned down.
fn fourth_suit_from(parent: Bid, auction: &Auction, out: &mut Vec<Bid>) {
    let unbid = unbid_suits(auction);
    if unbid.len() != 1 {
        return;
    }
    in_suits(parent, unbid, 0, out);
}

/// The suits of the last bid on the given side -- partner's, for our own tokens.
///
/// When that bid is the one we are measuring from it has already been pinned to a single suit, so
/// use it: `4HS` then `slam` is 6H over 4H or 6S over 4S, never 6S over 4H.
fn partner_suits(auction: &Auction, by_opponent: bool, parent: Bid) -> Suits {
    for index in (0..auction.len()).rev() {
        let mut found = NO_SUITS;
        for bid in auction.group(index) {
            if bid.is_bid() && bid.by_opponent == by_opponent {
                found = found.union(bid.suits);
            }
        }
        if found.is_empty() {
            continue;
        }
        if parent.by_opponent == by_opponent && Some(index) == last_bid_position(auction) {
            return parent.suits.intersect(ALL_SUITS);
        }
        return found.intersect(ALL_SUITS);
    }
    NO_SUITS
}

/// The step response(s) to an artificial ask.
///
/// `1step` is one rung up the ladder, `2step` two. `xstep` is "a step response, however many the
/// scheme has" -- the author's reading -- so it stands for the first [`STEP_LIMIT`] of them.
fn steps_from(parent: Bid, step: u8, out: &mut Vec<Bid>) {
    let range = if step != 0 {
        step..=step
    } else {
        1..=STEP_LIMIT
    };
    for n in range {
        if let Some(call) = bids::step_call(parent, n) {
            out.push(call);
        }
    }
}

/// The suit of the last call by the player on our immediate right, the one `CueOver` cues -- as
/// opposed to `cue`, which is any of their suits.
///
/// It is their *last call* that matters, not their last bid: if they doubled, there is nothing to
/// cue over and the token stays unresolved. Notrump is dropped, there being no such thing as cueing
/// notrump.
fn rho_suits(parent: Bid, auction: &Auction) -> Suits {
    let Some(last) = (0..auction.len())
        .rev()
        .find(|index| auction.group(*index).iter().any(|bid| bid.by_opponent))
    else {
        return NO_SUITS;
    };
    if parent.by_opponent && Some(last) == last_bid_position(auction) {
        // their last call *is* the bid we are measuring from, already pinned
        return parent.suits.intersect(REAL_SUITS);
    }
    let mut suits = NO_SUITS;
    for bid in auction.group(last) {
        if bid.is_bid() {
            suits = suits.union(bid.suits);
        }
    }
    suits.intersect(REAL_SUITS)
}

/// `cueLow` / `cueHi`: a cue of the lower- or higher-ranking of *their two suits*. Only resolvable
/// when the auction shows two opponent suits.
fn picked_cue(parent: Bid, auction: &Auction, token: Bid, out: &mut Vec<Bid>) {
    let theirs = spoken_suits(auction, Some(true));
    if theirs.len() < 2 {
        return;
    }
    let picked = if token.kind == Kind::CueLow {
        theirs.iter().min_by_key(|s| s.rank())
    } else {
        theirs.iter().max_by_key(|s| s.rank())
    };
    if let Some(suit) = picked {
        in_suits(parent, suit, token.level, out);
    }
}

/// A cue bid: their suit. Unqualified it is the *lowest* cue available, so with two opponent suits
/// shown only the cheaper one counts.
fn cues_from(parent: Bid, auction: &Auction, level: u8, out: &mut Vec<Bid>) {
    let theirs = spoken_suits(auction, Some(true));
    let before = out.len();
    in_suits(parent, theirs, level, out);
    if level == 0
        && out.len() > before
        && let Some(lowest) = bids::lowest_call(&out[before..])
    {
        out.truncate(before);
        out.push(lowest);
    }
}

/// Every call `jump` could be over `parent`: a jump in a *new suit*.
///
/// A jump is `levels` above the cheapest bid available in that suit, never in notrump (a jump to 3N
/// is a different animal), and never in a suit already bid. "Already bid" counts only calls the
/// auction pinned down to one denomination, so an unresolved `2M` does not silently rule both
/// majors out.
fn jumps_from(parent: Bid, levels: u8, auction: &Auction, out: &mut Vec<Bid>) {
    let spoken = spoken_suits(auction, None).union(parent.suits);
    for suit in REAL_SUITS.without(spoken).iter() {
        let Some(cheapest) = bids::cheapest_call(parent, suit) else {
            continue;
        };
        if cheapest.level + levels > 7 {
            continue;
        }
        out.push(Bid {
            level: cheapest.level + levels,
            ..cheapest
        });
    }
}
