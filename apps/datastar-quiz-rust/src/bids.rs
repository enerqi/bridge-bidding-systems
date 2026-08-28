//! The canonical model of a bridge call: a port of the bml tools' `bmlbids.py`, which the python
//! quiz, the html renderers and the Odin markup implementation all share.
//!
//! A call is written the way bml writes it:
//!
//! ```text
//! 1D 2H 3N      a bid: level 1-7 plus one or more suits, C D H S N
//! 1HS           a multi-suit bid, meaning "1H or 1S"
//! 2M 3m         suit classes: M = a major {H,S}, m = a minor {C,D}. These are the one
//!               place case is significant
//! 3* 3x         any denomination at that level
//! oM 3oM        "the other major" -- a variable, resolved against an earlier call
//! [1D](#1C--1D) a call written as a markdown link to its own section
//! 1!h           `!x` suit shorthand, as used in .bml source
//! 1NT           `NT` is accepted and normalised to `N`
//! Pass P        pass          X Dbl    double        XX Rdbl R   redouble
//! (1S) (X)      brackets mean the opponents made this call
//! 2D/2H 3S/4C   alternatives at ONE position
//! ```
//!
//! # THIS IS WHERE THE ALLOCATION STORY STARTS
//!
//! [`Bid`] is a six-byte `Copy` struct with no heap in it at all. The python holds a frozen
//! dataclass with two `frozenset`s and two `str`s; the Go port already shrank the sets to a
//! bitmask but kept `Kind` and `SuitClass` as `string`, which is 32 of its 40 bytes -- two pointers
//! and two lengths to carry what is really a pair of small enums.
//!
//! That matters because of how many there are. Preparing the swedish system for filtering produces
//! roughly 400,000 of these, held for the life of the process: 16 MB in Go, and 2.4 MB here. It is
//! also the difference between a comparison that chases pointers and one that walks an array.

use std::fmt::Write as _;

/// A set of denominations, one bit each.
///
/// Notrump is a denomination but not a suit -- several routines below care about the difference,
/// and say so.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Default)]
pub struct Suits(pub u8);

pub const CLUBS: Suits = Suits(1);
pub const DIAMONDS: Suits = Suits(2);
pub const HEARTS: Suits = Suits(4);
pub const SPADES: Suits = Suits(8);
pub const NOTRUMP: Suits = Suits(16);

pub const MAJORS: Suits = Suits(HEARTS.0 | SPADES.0);
pub const MINORS: Suits = Suits(CLUBS.0 | DIAMONDS.0);
pub const ALL_SUITS: Suits = Suits(0b11111);
/// The four real suits: what `new`, `jump` and the cue tokens range over.
pub const REAL_SUITS: Suits = Suits(0b01111);
pub const NO_SUITS: Suits = Suits(0);

/// Alphabetical, which is the order python's `sorted(frozenset)` produces -- kept so the generated
/// variants come out in the same order as the reference implementation's.
const ALPHABETICAL: [Suits; 5] = [CLUBS, DIAMONDS, HEARTS, NOTRUMP, SPADES];

impl Suits {
    #[inline]
    pub const fn contains_any(self, other: Suits) -> bool {
        self.0 & other.0 != 0
    }
    #[inline]
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }
    #[inline]
    pub const fn len(self) -> u32 {
        self.0.count_ones()
    }
    #[inline]
    pub const fn subset_of(self, other: Suits) -> bool {
        self.0 & !other.0 == 0
    }
    #[inline]
    pub const fn union(self, other: Suits) -> Suits {
        Suits(self.0 | other.0)
    }
    #[inline]
    pub const fn intersect(self, other: Suits) -> Suits {
        Suits(self.0 & other.0)
    }
    #[inline]
    pub const fn without(self, other: Suits) -> Suits {
        Suits(self.0 & !other.0)
    }

    /// The denominations, alphabetically -- the order `sorted()` produces in the python.
    pub fn iter(self) -> impl Iterator<Item = Suits> {
        ALPHABETICAL
            .into_iter()
            .filter(move |bit| self.contains_any(*bit))
    }

    /// Ordering of the denominations within a level; notrump is highest. Zero for a set that is
    /// not exactly one denomination.
    pub const fn rank(self) -> u8 {
        match self.0 {
            1 => 1,  // C
            2 => 2,  // D
            4 => 3,  // H
            8 => 4,  // S
            16 => 5, // N
            _ => 0,
        }
    }

    pub const fn from_char(ch: u8) -> Suits {
        match ch {
            b'C' => CLUBS,
            b'D' => DIAMONDS,
            b'H' => HEARTS,
            b'S' => SPADES,
            b'N' => NOTRUMP,
            _ => NO_SUITS,
        }
    }

    pub const fn from_rank(rank: u8) -> Suits {
        match rank {
            1 => CLUBS,
            2 => DIAMONDS,
            3 => HEARTS,
            4 => SPADES,
            5 => NOTRUMP,
            _ => NO_SUITS,
        }
    }

    pub const fn to_char(self) -> u8 {
        match self.0 {
            1 => b'C',
            2 => b'D',
            4 => b'H',
            8 => b'S',
            16 => b'N',
            _ => b'?',
        }
    }
}

/// What a token is. The python and the Go both carry this as a string; here it is one byte, which
/// is most of why a [`Bid`] fits in six.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
#[repr(u8)]
pub enum Kind {
    Bid,
    Pass,
    Double,
    Redouble,
    /// `any` / `other(s)`: whatever is called here, constraining nothing at all
    Any,
    /// `(overcall)` / `(higher)`: any *bid*, so not a pass and not a double
    AnyBid,
    /// `(bid)`: the same but doubles count too -- anything except a pass
    AnyCall,
    /// prose, or a token this model does not cover
    #[default]
    Other,
    /// `game`: 3N or a major game or a minor game
    Game,
    /// `2N+`: that call or anything above it
    AtLeast,
    // --- the relative kinds, whose call has to be worked out from the auction so far ---
    Next,
    Jump,
    Cue,
    CueOver,
    CueLow,
    CueHigh,
    New,
    Step,
    Raise,
    /// a denomination with no level: the simple (non-jump) bid in that strain
    Strain,
    /// `!c+`: that strain at whatever level it takes
    StrainAny,
    Slam,
    NextSuit,
    FourthSuit,
}

impl Kind {
    /// Whether this token's call has to be resolved against the auction so far.
    pub const fn is_relative(self) -> bool {
        matches!(
            self,
            Kind::Next
                | Kind::Jump
                | Kind::Cue
                | Kind::CueOver
                | Kind::CueLow
                | Kind::CueHigh
                | Kind::New
                | Kind::Step
                | Kind::Raise
                | Kind::Strain
                | Kind::StrainAny
                | Kind::Slam
                | Kind::NextSuit
                | Kind::FourthSuit
        )
    }
}

/// Which suit *class* a token named, when it named one rather than listing denominations.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
#[repr(u8)]
pub enum SuitClass {
    #[default]
    None,
    /// `M` -- a major
    Major,
    /// `m` -- a minor
    Minor,
    /// `oM` -- the other major
    OtherMajor,
    /// `om` -- the other minor
    OtherMinor,
}

impl SuitClass {
    /// `oM`/`om`: the complement, within its class, of the bound suit.
    pub const fn is_other(self) -> bool {
        matches!(self, SuitClass::OtherMajor | SuitClass::OtherMinor)
    }
    /// The denominations this class ranges over, or none when the token named no class.
    pub const fn suits(self) -> Suits {
        match self {
            SuitClass::Major | SuitClass::OtherMajor => MAJORS,
            SuitClass::Minor | SuitClass::OtherMinor => MINORS,
            SuitClass::None => NO_SUITS,
        }
    }
}

/// One call. `suits` holds every denomination the token allows, so a plain `1H` is {H} and a
/// multi-suit `1HS` is {H, S}.
///
/// Six bytes, `Copy`, no heap. See the module note.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct Bid {
    /// 1..=7, or 0 for pass/double/redouble/other. `Step` uses it for which step, counting from 1.
    pub level: u8,
    pub suits: Suits,
    pub kind: Kind,
    pub by_opponent: bool,
    pub suit_class: SuitClass,
    /// For `Jump`/`Raise`: how many levels above the cheapest available bid.
    pub jump_levels: u8,
}

impl Bid {
    pub const fn is_bid(&self) -> bool {
        matches!(self.kind, Kind::Bid)
    }
    pub const fn is_other_class(&self) -> bool {
        self.suit_class.is_other()
    }
    /// The denominations this token's class ranges over ({H,S} for any of M/oM), or its own suits
    /// when it named no class.
    pub const fn class_suits(&self) -> Suits {
        match self.suit_class {
            SuitClass::None => self.suits,
            other => other.suits(),
        }
    }
    const fn plain(kind: Kind, by_opponent: bool) -> Bid {
        Bid {
            level: 0,
            suits: NO_SUITS,
            kind,
            by_opponent,
            suit_class: SuitClass::None,
            jump_levels: 0,
        }
    }
}

/// How many step responses `xstep` stands for -- the corpus's own EKB rows describe five ("5th step
/// = 2 KC + a void") before leaving the ladder with `6x`.
pub const STEP_LIMIT: u8 = 5;

/// The levels `slam` stands for when the token does not say.
pub const SLAM_LEVELS: [u8; 2] = [6, 7];

/// `/` separates alternatives at a single position: `2D/2H` is one call, not two.
pub const ALT_SEP: char = '/';

/// `game` is a game contract: 3N or a major game or a minor game.
const GAME_CALLS: [(u8, Suits); 5] = [
    (3, NOTRUMP),
    (4, HEARTS),
    (4, SPADES),
    (5, CLUBS),
    (5, DIAMONDS),
];

// --- token normalisation ----------------------------------------------------

/// `!h` / `!H` -> `H`, the shorthand used in .bml source.
pub fn expand_suit_shorthand(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'!'
            && i + 1 < bytes.len()
            && matches!(
                bytes[i + 1],
                b'c' | b'd' | b'h' | b's' | b'C' | b'D' | b'H' | b'S'
            )
        {
            out.push(bytes[i + 1].to_ascii_uppercase() as char);
            i += 2;
            continue;
        }
        // not necessarily ascii: descriptions carry prose
        let ch = text[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// Uppercase a token, keeping a lowercase `m` (minors) distinct from `M` (majors). Everything else
/// is a suit letter or a keyword, for which case carries no meaning.
pub fn fold_call_case(token: &str) -> String {
    token
        .chars()
        .map(|ch| {
            if ch == 'm' {
                ch
            } else {
                ch.to_ascii_uppercase()
            }
        })
        .collect()
}

/// Case-fold a token and reduce `NT` to `N`, without touching brackets.
fn normalise_call_token(token: &str) -> String {
    fold_call_case(&expand_suit_shorthand(token.trim())).replace("NT", "N")
}

/// Split `(1S)` into its inner text and "was it the opponents'".
pub fn strip_brackets(token: &str) -> (&str, bool) {
    (
        token.trim_matches(|c| c == '(' || c == ')'),
        token.trim_start().starts_with('('),
    )
}

/// `[1D](#1C--1D)` -> `1D`. Bid tables may write a call as a markdown link to the section that
/// explains it; the label is the call.
pub fn unwrap_link(token: &str) -> &str {
    let trimmed = token.trim();
    let Some(rest) = trimmed.strip_prefix('[') else {
        return token;
    };
    let Some(close) = rest.find(']') else {
        return token;
    };
    let label = &rest[..close];
    if label.is_empty() || label.contains(char::is_whitespace) {
        return token;
    }
    let after = &rest[close + 1..];
    if !after.starts_with('(') || !after.ends_with(')') || after[1..after.len() - 1].contains(')') {
        return token;
    }
    label
}

/// `HS` -> {H,S}; `M` -> majors; `m` -> minors; `*` -> every denomination.
fn expand_denominations(text: &str) -> Suits {
    let mut suits = NO_SUITS;
    for ch in text.bytes() {
        suits = suits.union(match ch {
            b'M' => MAJORS,
            b'm' => MINORS,
            b'*' => ALL_SUITS,
            other => Suits::from_char(other),
        });
    }
    suits
}

// --- parsing ----------------------------------------------------------------

/// Parse one auction position into the calls it allows.
///
/// `2D/2H` is *one* call written as two possibilities, and `(2D/2H)` is the opponents making it;
/// the brackets may wrap the whole alternation or each alternative.
pub fn parse_call_alternatives(token: &str) -> Vec<Bid> {
    if token.trim().is_empty() {
        return Vec::new();
    }
    let (outer, outer_opp) = strip_brackets(unwrap_link(token.trim()));
    let mut calls = Vec::new();
    for part in outer.split(ALT_SEP) {
        if part.trim().is_empty() {
            continue;
        }
        if let Some(mut call) = parse_call(part) {
            // brackets around the whole alternation apply to every alternative
            call.by_opponent = call.by_opponent || outer_opp;
            calls.push(call);
        }
    }
    calls
}

/// One Bid covering every alternative, when they differ only in suit.
///
/// `2D/2H` is exactly `2DH`. Alternatives spanning levels (`3S/4C`) or kinds cannot be one Bid, and
/// the caller falls back to `Kind::Other`.
fn merge_alternatives(calls: &[Bid]) -> Option<Bid> {
    let first = *calls.first()?;
    let mut suits = first.suits;
    for call in &calls[1..] {
        if call.level != first.level
            || call.kind != first.kind
            || call.by_opponent != first.by_opponent
        {
            return None;
        }
        suits = suits.union(call.suits);
    }
    Some(Bid { suits, ..first })
}

fn level_of(text: &str) -> u8 {
    text.as_bytes().first().map_or(0, |b| b - b'0')
}

/// Parse a single call. `None` only for empty input; unrecognised tokens come back as
/// [`Kind::Other`] so they can be carried along rather than crashing a sequence.
pub fn parse_call(token: &str) -> Option<Bid> {
    if token.trim().is_empty() {
        return None;
    }
    let token = unwrap_link(token.trim());
    if token.contains(ALT_SEP) {
        if let Some(merged) = merge_alternatives(&parse_call_alternatives(token)) {
            return Some(merged);
        }
        let (_, opp) = strip_brackets(token);
        return Some(Bid::plain(Kind::Other, opp));
    }
    let normalised = normalise_call_token(token);
    let (inner, opp) = strip_brackets(&normalised);
    let upper = inner.to_ascii_uppercase();

    match inner {
        "P" | "PASS" => return Some(Bid::plain(Kind::Pass, opp)),
        "X" | "DBL" => return Some(Bid::plain(Kind::Double, opp)),
        "XX" | "RDBL" | "R" => return Some(Bid::plain(Kind::Redouble, opp)),
        "ANY" => return Some(Bid::plain(Kind::Any, opp)),
        "NEXT" => return Some(Bid::plain(Kind::Next, opp)),
        _ => {}
    }
    match upper.as_str() {
        "OTHER" | "OTHERS" => return Some(Bid::plain(Kind::Any, opp)),
        "OVERCALL" | "HIGHER" => return Some(Bid::plain(Kind::AnyBid, opp)),
        "BID" => return Some(Bid::plain(Kind::AnyCall, opp)),
        "GAME" => return Some(Bid::plain(Kind::Game, opp)),
        "JUMP" | "JUMPNEW" | "NEWJUMP" => {
            return Some(Bid {
                jump_levels: 1,
                ..Bid::plain(Kind::Jump, opp)
            });
        }
        "DOUBLEJUMP" => {
            return Some(Bid {
                jump_levels: 2,
                ..Bid::plain(Kind::Jump, opp)
            });
        }
        _ => {}
    }

    // `!d` is diamonds, but a bare `D` written on its own is the double, so the guard looks at the
    // token as written rather than after shorthand expansion
    let (raw_inner, _) = strip_brackets(token.trim());
    if !raw_inner.eq_ignore_ascii_case("D")
        && let Some((suits, plus)) = match_strain(inner, &upper)
    {
        let kind = if plus { Kind::StrainAny } else { Kind::Strain };
        return Some(Bid {
            suits,
            ..Bid::plain(kind, opp)
        });
    }

    if let Some(level) = match_suffixed(&upper, "SLAM") {
        return Some(Bid {
            level,
            ..Bid::plain(Kind::Slam, opp)
        });
    }
    if upper == "NEXTSUIT" {
        return Some(Bid::plain(Kind::NextSuit, opp));
    }
    if upper == "4THSUIT" || upper == "FOURTHSUIT" {
        return Some(Bid::plain(Kind::FourthSuit, opp));
    }
    if let Some((level, jump)) = match_raise(&upper) {
        return Some(Bid {
            level,
            jump_levels: jump,
            ..Bid::plain(Kind::Raise, opp)
        });
    }
    if let Some(step) = match_step(&upper) {
        // level carries which step; 0 means "any of them"
        return Some(Bid {
            level: step,
            ..Bid::plain(Kind::Step, opp)
        });
    }
    if let Some((level, kind)) = match_cue_pick(&upper) {
        return Some(Bid {
            level,
            ..Bid::plain(kind, opp)
        });
    }
    if let Some(level) = match_suffixed(&upper, "CUEOVER") {
        return Some(Bid {
            level,
            ..Bid::plain(Kind::CueOver, opp)
        });
    }
    if let Some(level) = match_suffixed(&upper, "CUE") {
        return Some(Bid {
            level,
            ..Bid::plain(Kind::Cue, opp)
        });
    }
    if let Some(level) = match_new(&upper) {
        return Some(Bid {
            level,
            ..Bid::plain(Kind::New, opp)
        });
    }
    if let Some((level, suits)) = match_at_least(inner) {
        // `2N+` -- every call from 2N up. Enumerated by `calls_at_or_above` rather than stored as a
        // bound, so matching stays a plain set intersection.
        return Some(Bid {
            level,
            suits,
            ..Bid::plain(Kind::AtLeast, opp)
        });
    }
    if let Some(level) = match_level_wildcard(inner) {
        return Some(Bid {
            level,
            suits: ALL_SUITS,
            ..Bid::plain(Kind::Bid, opp)
        });
    }
    if let Some((level, class)) = match_other_class(inner) {
        // `oM` with no level ("the other major, at whatever level") keeps level 0: it still
        // constrains the suit, which is what it is for.
        return Some(Bid {
            level,
            suits: class.suits(),
            suit_class: class,
            ..Bid::plain(Kind::Bid, opp)
        });
    }
    if let Some((level, denominations)) = match_bid(inner) {
        let suit_class = match denominations {
            "M" => SuitClass::Major,
            "m" => SuitClass::Minor,
            _ => SuitClass::None,
        };
        return Some(Bid {
            level,
            suits: expand_denominations(denominations),
            suit_class,
            ..Bid::plain(Kind::Bid, opp)
        });
    }
    Some(Bid::plain(Kind::Other, opp))
}

// The regexes of the python, written out. RE2 and `regex` would both do, but these run on every
// token of a 7,600-auction corpus at boot and each one is a handful of byte comparisons.

/// `^(?:MAJORS?|MINORS?|([CDHSNMm]+))(\+)?$` -- a denomination with no level.
fn match_strain(inner: &str, upper: &str) -> Option<(Suits, bool)> {
    let (body, plus) = match inner.strip_suffix('+') {
        Some(body) => (body, true),
        None => (inner, false),
    };
    let (upper_body, _) = match upper.strip_suffix('+') {
        Some(body) => (body, true),
        None => (upper, false),
    };
    if upper_body == "MAJOR" || upper_body == "MAJORS" {
        return Some((MAJORS, plus));
    }
    if upper_body == "MINOR" || upper_body == "MINORS" {
        return Some((MINORS, plus));
    }
    if body.is_empty()
        || !body
            .bytes()
            .all(|b| matches!(b, b'C' | b'D' | b'H' | b'S' | b'N' | b'M' | b'm'))
    {
        return None;
    }
    Some((expand_denominations(body), plus))
}

/// `^([1-7])?<WORD>$`
fn match_suffixed(upper: &str, word: &str) -> Option<u8> {
    if let Some(rest) = upper.strip_suffix(word) {
        return match rest.len() {
            0 => Some(0),
            1 if rest.as_bytes()[0].is_ascii_digit()
                && rest.as_bytes()[0] != b'0'
                && rest.as_bytes()[0] <= b'7' =>
            {
                Some(level_of(rest))
            }
            _ => None,
        };
    }
    None
}

/// `^([1-7])?(JUMP)?RAISE$`
fn match_raise(upper: &str) -> Option<(u8, u8)> {
    let rest = upper.strip_suffix("RAISE")?;
    let (rest, jump) = match rest.strip_suffix("JUMP") {
        Some(head) => (head, 1),
        None => (rest, 0),
    };
    match rest.len() {
        0 => Some((0, jump)),
        1 if (b'1'..=b'7').contains(&rest.as_bytes()[0]) => Some((level_of(rest), jump)),
        _ => None,
    }
}

/// `^(?:([1-7]|X)STEP|STEP([1-7]))$` -- both spellings occur. 0 means "any of them".
fn match_step(upper: &str) -> Option<u8> {
    if let Some(rest) = upper.strip_suffix("STEP") {
        return match rest {
            "X" => Some(0),
            _ if rest.len() == 1 && (b'1'..=b'7').contains(&rest.as_bytes()[0]) => {
                Some(level_of(rest))
            }
            _ => None,
        };
    }
    if let Some(rest) = upper.strip_prefix("STEP")
        && rest.len() == 1
        && (b'1'..=b'7').contains(&rest.as_bytes()[0])
    {
        return Some(level_of(rest));
    }
    None
}

/// `^([1-7])?CUE(LOW|HI|HIGH)$`
fn match_cue_pick(upper: &str) -> Option<(u8, Kind)> {
    for (suffix, kind) in [
        ("CUELOW", Kind::CueLow),
        ("CUEHIGH", Kind::CueHigh),
        ("CUEHI", Kind::CueHigh),
    ] {
        if let Some(level) = match_suffixed(upper, suffix) {
            return Some((level, kind));
        }
    }
    None
}

/// `^(?:([1-7])?(?:NEW(?:SUIT)?|SUIT|OTHERSUIT)|([1-7])Y)$`
fn match_new(upper: &str) -> Option<u8> {
    for suffix in ["NEWSUIT", "NEW", "OTHERSUIT", "SUIT"] {
        if let Some(level) = match_suffixed(upper, suffix) {
            return Some(level);
        }
    }
    // `2Y` is `2new` -- the `y` spelling exists to pin the level
    if upper.len() == 2
        && (b'1'..=b'7').contains(&upper.as_bytes()[0])
        && upper.as_bytes()[1] == b'Y'
    {
        return Some(level_of(upper));
    }
    None
}

/// `^([1-7])([CDHSNMm*X])\+$` -- `2N+` is 2N or higher.
fn match_at_least(inner: &str) -> Option<(u8, Suits)> {
    let body = inner.strip_suffix('+')?;
    let bytes = body.as_bytes();
    if bytes.len() != 2 || !(b'1'..=b'7').contains(&bytes[0]) {
        return None;
    }
    let denomination = match bytes[1] {
        b'X' | b'*' => "*",
        b'C' => "C",
        b'D' => "D",
        b'H' => "H",
        b'S' => "S",
        b'N' => "N",
        b'M' => "M",
        b'm' => "m",
        _ => return None,
    };
    Some((level_of(body), expand_denominations(denomination)))
}

/// `^([1-7])[X*]$` -- any denomination at that level.
fn match_level_wildcard(inner: &str) -> Option<u8> {
    let bytes = inner.as_bytes();
    if bytes.len() == 2 && (b'1'..=b'7').contains(&bytes[0]) && matches!(bytes[1], b'X' | b'*') {
        return Some(level_of(inner));
    }
    None
}

/// `^([1-7])?O([Mm])$`
fn match_other_class(inner: &str) -> Option<(u8, SuitClass)> {
    let bytes = inner.as_bytes();
    let (level, rest) = match bytes.len() {
        2 => (0, bytes),
        3 if (b'1'..=b'7').contains(&bytes[0]) => (level_of(inner), &bytes[1..]),
        _ => return None,
    };
    if rest[0] != b'O' {
        return None;
    }
    match rest[1] {
        b'M' => Some((level, SuitClass::OtherMajor)),
        b'm' => Some((level, SuitClass::OtherMinor)),
        _ => None,
    }
}

/// `^\(?([1-7])([CDHSNMm*]+)\)?$`
fn match_bid(inner: &str) -> Option<(u8, &str)> {
    let bytes = inner.as_bytes();
    if bytes.len() < 2 || !(b'1'..=b'7').contains(&bytes[0]) {
        return None;
    }
    let denominations = &inner[1..];
    if !denominations
        .bytes()
        .all(|b| matches!(b, b'C' | b'D' | b'H' | b'S' | b'N' | b'M' | b'm' | b'*'))
    {
        return None;
    }
    Some((level_of(inner), denominations))
}

// --- the calls a token can stand for ----------------------------------------

/// The cheapest bid above `bid` -- one denomination up, or the next level starting at clubs when
/// `bid` was notrump.
///
/// Only defined for a bid naming one denomination: after a token that could be several calls
/// (`4HS`, `3x`, `any`) there is no single next step. `None` at the ceiling (7N) and for non-bids.
pub fn next_call(bid: Bid) -> Option<Bid> {
    if !bid.is_bid() || bid.level == 0 || bid.suits.len() != 1 {
        return None;
    }
    let rank = bid.suits.rank();
    let mut out = Bid {
        suit_class: SuitClass::None,
        ..bid
    };
    if rank == 5 {
        if bid.level == 7 {
            return None;
        }
        out.level = bid.level + 1;
        out.suits = CLUBS;
        return Some(out);
    }
    out.suits = Suits::from_rank(rank + 1);
    Some(out)
}

/// The `steps`-th call above `previous`, counting the cheapest as step 1. This is the ladder
/// artificial asks answer on: over a 4N keycard ask, 5C is step 1.
pub fn step_call(previous: Bid, steps: u8) -> Option<Bid> {
    let mut call = previous;
    for _ in 0..steps {
        call = next_call(call)?;
    }
    Some(call)
}

/// The lowest bid in `suit` that is legal over `previous`: the same level when `suit` outranks the
/// previous denomination, one level up otherwise. `None` past 7, or when `previous` is not one
/// specific bid (`4HS` could be either, and each answer differs).
pub fn cheapest_call(previous: Bid, suit: Suits) -> Option<Bid> {
    if !previous.is_bid() || previous.level == 0 || previous.suits.len() != 1 {
        return None;
    }
    let was = previous.suits.rank();
    let level = if suit.rank() > was {
        previous.level
    } else {
        previous.level + 1
    };
    if level > 7 {
        return None;
    }
    Some(Bid {
        level,
        suits: suit,
        suit_class: SuitClass::None,
        jump_levels: 0,
        ..previous
    })
}

/// The game contracts: 3N, 4H, 4S, 5C, 5D.
pub fn game_calls(by_opponent: bool) -> impl Iterator<Item = Bid> {
    GAME_CALLS.into_iter().map(move |(level, suits)| Bid {
        level,
        suits,
        by_opponent,
        ..Bid::plain(Kind::Bid, by_opponent)
    })
}

/// Every bid from `bid` upwards, for an `at_least` token like `2N+`. Enumerating them keeps
/// matching a set intersection instead of needing a comparison operator in the pattern language.
pub fn calls_at_or_above(bid: Bid, out: &mut Vec<Bid>) {
    if bid.level == 0 || bid.suits.is_empty() {
        return;
    }
    let floor = bid.suits.iter().map(|s| s.rank()).min().unwrap_or(6);
    for level in bid.level..=7 {
        for rank in 1..=5u8 {
            if level == bid.level && rank < floor {
                continue;
            }
            out.push(Bid {
                level,
                suits: Suits::from_rank(rank),
                by_opponent: bid.by_opponent,
                ..Bid::plain(Kind::Bid, bid.by_opponent)
            });
        }
    }
}

/// python's `min(calls, key=lambda c: (c.level, SUIT_RANK[...]))`.
pub fn lowest_call(calls: &[Bid]) -> Option<Bid> {
    calls
        .iter()
        .copied()
        .min_by_key(|call| (call.level, call.suits.rank()))
}

// --- comparisons, for the corpus loader -------------------------------------

/// True for a real bid (not pass/double/prose). Multi-suit counts, and so does an alternation of
/// bids -- including `3S/4C`, which spans levels and so has no single-Bid form to ask about.
pub fn is_bid_token(token: &str) -> bool {
    let calls = parse_call_alternatives(token);
    !calls.is_empty() && calls.iter().all(Bid::is_bid)
}

fn one_less_than(left: Bid, right: Bid) -> bool {
    if !left.is_bid() || left.level == 0 || !right.is_bid() || right.level == 0 {
        return false;
    }
    if left.level != right.level {
        return left.level < right.level;
    }
    // same level: every denomination the left could be must rank below every one the right could
    // be, so compare the left's highest against the right's lowest
    let highest = left.suits.iter().map(|s| s.rank()).max().unwrap_or(0);
    let lowest = right.suits.iter().map(|s| s.rank()).min().unwrap_or(6);
    highest < lowest
}

/// Does `left` rank strictly below `right` in the auction?
///
/// Strict throughout, because the caller is asking "did this call have to come first?" and a wrong
/// yes invents an auction.
pub fn bid_less_than(left: &str, right: &str) -> bool {
    let (lefts, rights) = (
        parse_call_alternatives(left),
        parse_call_alternatives(right),
    );
    if lefts.is_empty() || rights.is_empty() {
        return false;
    }
    lefts
        .iter()
        .all(|l| rights.iter().all(|r| one_less_than(*l, *r)))
}

/// Render a call the way bml writes it. For diagnostics and test failure messages.
pub fn write_call(bid: Bid, out: &mut String) {
    if bid.by_opponent {
        out.push('(');
    }
    match bid.kind {
        Kind::Bid => {
            if bid.level > 0 {
                let _ = write!(out, "{}", bid.level);
            }
            for suit in bid.suits.iter() {
                out.push(suit.to_char() as char);
            }
        }
        Kind::Pass => out.push_str("Pass"),
        Kind::Double => out.push('X'),
        Kind::Redouble => out.push_str("XX"),
        other => {
            let _ = write!(out, "{other:?}");
        }
    }
    if bid.by_opponent {
        out.push(')');
    }
}
