//! The pattern language: `1D-1M-1N`, `1H-(X)-2H`, `1N-2D/2H`, `*-*-*`.
//!
//! Suit-class shortcuts expand -- `M` is the majors, `m` the minors -- so `1D-1M-1N` matches both
//! `1D-1H-1N` and `1D-1S-1N`. Opponent calls are written in brackets. A filter string may hold
//! several comma-separated entries, matched as an OR.

use crate::bids::{self, MAJORS, MINORS, NO_SUITS, Suits};
use crate::flat::Flat;

/// Whose call a pattern position asks for. The python writes this as `Optional[bool]`, where None
/// means "don't care"; the tri-state is the same thing said in a type.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
#[repr(u8)]
pub enum Side {
    /// None: don't care
    #[default]
    Either,
    /// False: one of ours
    Ours,
    /// True: the opponents'
    Theirs,
}

impl Side {
    pub const fn of(by_opponent: bool) -> Side {
        if by_opponent {
            Side::Theirs
        } else {
            Side::Ours
        }
    }
    /// Whether a call by this side satisfies the pattern.
    #[inline]
    pub const fn accepts(self, by_opponent: bool) -> bool {
        match self {
            Side::Either => true,
            Side::Ours => !by_opponent,
            Side::Theirs => by_opponent,
        }
    }
}

/// What a pattern position asks for, beyond the denominations.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
#[repr(u8)]
pub enum PatternKind {
    #[default]
    Bid,
    Pass,
    Double,
    Redouble,
    /// the bare `*` / `any`: any call at this position
    Wildcard,
}

/// One alternative at one position of a pattern. Six bytes, like a [`crate::bids::Bid`].
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct BidPattern {
    /// 0 = any level
    pub level: u8,
    /// allowed suits; empty = any suit
    pub suits: Suits,
    pub kind: PatternKind,
    pub side: Side,
}

/// A whole bid pattern: one group of alternatives per position.
///
/// Usually one alternative. `/` writes more than one -- `2D/2H`, `3S/4C` -- which is a single call
/// the author wrote as a choice, *not* two consecutive calls. Alternatives differing only in suit
/// could equally be written `2DH`; ones spanning levels (`3S/4C`) have no single-token form, which
/// is why a position is a set of patterns rather than one widened pattern.
pub type Pattern = Flat<BidPattern>;

/// A token (or a whole pattern) the language does not cover. The caller falls back to treating the
/// entry as a topic name, or records it as an error.
#[derive(Debug, PartialEq, Eq)]
pub struct BadPattern;

/// Tidy raw user input: strip ends, collapse whitespace runs, and remove whitespace that is
/// decorative rather than a token separator (inside brackets, around `--` and around the comma
/// entry separator).
///
/// Written by hand rather than with five regex passes: it runs on every keystroke, and it is the
/// key of the filter memo, so it is on the hot path twice.
pub fn normalize_filter_text(text: &str) -> String {
    // collapse whitespace runs, then dash runs (with any surrounding whitespace) to a single `-`
    let mut collapsed = String::with_capacity(text.len());
    let mut pending_space = false;
    let mut pending_dash = false;
    for ch in text.trim().chars() {
        if ch.is_whitespace() {
            pending_space = true;
            continue;
        }
        if ch == '-' {
            pending_dash = true;
            pending_space = false;
            continue;
        }
        if pending_dash {
            collapsed.push('-');
        } else if pending_space {
            collapsed.push(' ');
        }
        pending_dash = false;
        pending_space = false;
        collapsed.push(ch);
    }
    if pending_dash {
        collapsed.push('-');
    }
    // whitespace just inside brackets is decorative
    let mut tidied = String::with_capacity(collapsed.len());
    let bytes = collapsed.as_bytes();
    for (index, ch) in collapsed.char_indices() {
        if ch == ' ' {
            let before = tidied.as_bytes().last().copied();
            let after = bytes.get(index + 1).copied();
            if before == Some(b'(') || after == Some(b')') {
                continue;
            }
        }
        tidied.push(ch);
    }
    // rebuild from the entries so empty ones (`,,` or a trailing `,`) vanish
    let entries: Vec<&str> = tidied
        .split(',')
        .map(str::trim)
        .filter(|e| !e.is_empty())
        .collect();
    entries.join(", ")
}

/// Split normalised filter text on commas into non-empty entries.
pub fn split_entries(text: &str) -> Vec<String> {
    normalize_filter_text(text)
        .split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Split a pattern on `-` and whitespace, which are interchangeable separators.
fn split_tokens(text: &str) -> impl Iterator<Item = &str> {
    text.split(['-', ' ', '\t']).filter(|part| !part.is_empty())
}

/// Parse one position, which may be an alternation (`2D/2H`, `3S/4C`).
///
/// Brackets may wrap the whole alternation -- `(2D/2H)` is the opponents making either call -- or an
/// individual branch.
fn parse_pattern_token(token: &str, out: &mut Pattern) -> Result<(), BadPattern> {
    let (inner, opp) = bids::strip_brackets(token);
    let before = out.open_len();
    for part in inner.split(bids::ALT_SEP) {
        if part.trim().is_empty() {
            continue;
        }
        out.push_item(parse_alternative(part, opp)?);
    }
    if out.open_len() == before {
        return Err(BadPattern);
    }
    out.close_group();
    Ok(())
}

fn parse_alternative(token: &str, outer_opp: bool) -> Result<BidPattern, BadPattern> {
    let (inner, opp) = bids::strip_brackets(token);
    let opp = opp || outer_opp;
    // brackets are the notation for "the opponents did this", so a token without them is one of our
    // calls. (The bare `*` wildcard below opts back out to "either side" -- that is what makes it
    // useful for counting depth.)
    let side = Side::of(opp);
    let inner = bids::fold_call_case(&bids::expand_suit_shorthand(inner));
    let upper = inner.to_ascii_uppercase();

    match upper.as_str() {
        "P" | "PASS" => {
            return Ok(BidPattern {
                kind: PatternKind::Pass,
                side,
                ..Default::default()
            });
        }
        "X" | "DBL" => {
            return Ok(BidPattern {
                kind: PatternKind::Double,
                side,
                ..Default::default()
            });
        }
        "XX" | "RDBL" | "R" => {
            return Ok(BidPattern {
                kind: PatternKind::Redouble,
                side,
                ..Default::default()
            });
        }
        "*" | "ANY" => {
            // wildcard: any call at this position, by either side unless bracketed. `(*)` means
            // "the opponents did something here", since their passes are dropped.
            let side = if opp { Side::Theirs } else { Side::Either };
            return Ok(BidPattern {
                kind: PatternKind::Wildcard,
                side,
                ..Default::default()
            });
        }
        _ => {}
    }

    // `1*` / `1x` -- any suit at that level (an empty suit set means "any"). Bid tables spell this
    // `x`, section headers `*`; a bare `X` was caught above as a double, so the level makes them
    // unambiguous.
    let bytes = upper.as_bytes();
    if bytes.len() == 2 && (b'1'..=b'7').contains(&bytes[0]) && matches!(bytes[1], b'X' | b'*') {
        return Ok(BidPattern {
            level: bytes[0] - b'0',
            kind: PatternKind::Bid,
            side,
            ..Default::default()
        });
    }

    // `oM` in a *pattern* has no earlier call to be "other" than, so it asks for the class: an
    // auction whose oM resolved either way matches.
    let raw = inner.as_bytes();
    let (level, rest) = match raw.first() {
        Some(first) if (b'1'..=b'7').contains(first) => (first - b'0', &raw[1..]),
        _ => (0u8, raw),
    };
    if rest.len() == 2 && rest[0] == b'O' && matches!(rest[1], b'M' | b'm') {
        let suits = if rest[1] == b'M' { MAJORS } else { MINORS };
        return Ok(BidPattern {
            level,
            suits,
            kind: PatternKind::Bid,
            side,
        });
    }

    // Level + suit-class chars, `^([1-7])?([CDHSNMm]+)$`, case-sensitive because M/m are the class
    // shortcuts. Note what is NOT accepted: `T`. A pattern is not NT-normalised (only auctions
    // are), so `1NT` in the filter box is rejected and falls through to being read as a topic name
    // -- which is what the python and the Go port both do, and the tests pin.
    if rest.is_empty() {
        return Err(BadPattern);
    }
    let mut suits = NO_SUITS;
    for ch in rest.iter().copied() {
        suits = suits.union(match ch {
            b'M' => MAJORS,
            b'm' => MINORS,
            b'C' | b'D' | b'H' | b'S' | b'N' => Suits::from_char(ch),
            _ => return Err(BadPattern),
        });
    }
    Ok(BidPattern {
        level,
        suits,
        kind: PatternKind::Bid,
        side,
    })
}

/// Parse `1D-1M-1N` (dashes or spaces; bml's `--` also accepted).
/// A position may offer alternatives with `/`: `1M-3S/4C`.
pub fn parse_pattern(text: &str) -> Result<Pattern, BadPattern> {
    let normalised = normalize_filter_text(text);
    let mut pattern = Pattern::new();
    for token in split_tokens(&normalised) {
        parse_pattern_token(token, &mut pattern)?;
    }
    if pattern.is_empty() {
        return Err(BadPattern);
    }
    Ok(pattern)
}

/// Rewrite a pattern the way it was understood: `-`-joined, whitespace tidied, case folded
/// (`1d -- 1M 1n` -> `1D-1M-1N`).
pub fn canonical_pattern_text(text: &str) -> String {
    let normalised = normalize_filter_text(text);
    let mut out = String::with_capacity(normalised.len());
    for token in split_tokens(&normalised) {
        if !out.is_empty() {
            out.push('-');
        }
        let (inner, opp) = bids::strip_brackets(token);
        let inner = bids::fold_call_case(&bids::expand_suit_shorthand(inner));
        if opp {
            out.push('(');
            out.push_str(&inner);
            out.push(')');
        } else {
            out.push_str(&inner);
        }
    }
    out
}
