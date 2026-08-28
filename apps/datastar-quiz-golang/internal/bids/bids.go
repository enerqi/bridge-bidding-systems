// Package bids is the canonical model of a bridge call: a Go port of the bml tools'
// `bmlbids.py` (~/dev/bml/bmlbids.py), which the python quiz, the html renderers and the
// Odin markup implementation all share.
//
// A call is written the way bml writes it:
//
//	1D 2H 3N      a bid: level 1-7 plus one or more suits, C D H S N
//	1HS           a multi-suit bid, meaning "1H or 1S"
//	2M 3m         suit classes: M = a major {H,S}, m = a minor {C,D}. These
//	              are the one place case is significant
//	3* 3x         any denomination at that level
//	oM 3oM        "the other major" -- a variable resolved against an earlier call
//	[1D](#1C--1D) a call written as a markdown link to its own section
//	1!h           `!x` suit shorthand, as used in .bml source
//	1NT           `NT` is accepted and normalised to `N`
//	Pass P        pass          X Dbl    double        XX Rdbl R   redouble
//	(1S) (X)      brackets mean the opponents made this call
//	2D/2H 3S/4C   alternatives at ONE position
//
// Anything else that appears in a bid table -- `any`, `cue`, `new`, `Game`, `others` --
// parses as its own kind rather than failing, so a sequence containing one can still be
// handled as a whole.
//
// Two deliberate differences from the python, neither of them semantic:
//
//   - `suits` is a bitset rather than a frozenset, which makes Bid a comparable struct
//     (usable as a map key, cheap to copy) and the set operations single instructions.
//     The corpus is ~7,600 auctions and every one of them is parsed at boot.
//   - `Level` is an int where python has `Optional[int]`, with 0 standing for None. No
//     real level is 0 (they run 1-7), and `step` -- the one kind that uses the field for
//     something else -- counts from 1 as well.
package bids

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// SuitSet is a set of denominations, one bit each.
type SuitSet uint8

// The denominations. Notrump is a denomination but not a suit -- several routines below
// care about the difference, and say so.
const (
	Clubs SuitSet = 1 << iota
	Diamonds
	Hearts
	Spades
	Notrump
)

const (
	Majors   = Hearts | Spades
	Minors   = Clubs | Diamonds
	AllSuits = Clubs | Diamonds | Hearts | Spades | Notrump
	// The four real suits: what `new`, `jump` and the cue tokens range over.
	RealSuits = Clubs | Diamonds | Hearts | Spades
)

// Ordering of the denominations within a level; notrump is highest.
var suitRank = map[byte]int{'C': 1, 'D': 2, 'H': 3, 'S': 4, 'N': 5}

var suitBit = map[byte]SuitSet{'C': Clubs, 'D': Diamonds, 'H': Hearts, 'S': Spades, 'N': Notrump}

// alphabetical, which is the order python's `sorted(frozenset)` produces -- kept so the
// generated variants come out in the same order as the reference implementation's
var suitChars = [...]byte{'C', 'D', 'H', 'N', 'S'}

var bitChar = map[SuitSet]byte{Clubs: 'C', Diamonds: 'D', Hearts: 'H', Spades: 'S', Notrump: 'N'}

// Rank of one denomination within a level (1..5). Zero for anything else.
func Rank(suit SuitSet) int { return suitRank[bitChar[suit]] }

// RankOfChar is Rank for a denomination letter.
func RankOfChar(ch byte) int { return suitRank[ch] }

func (s SuitSet) Has(other SuitSet) bool { return s&other != 0 }
func (s SuitSet) Empty() bool            { return s == 0 }

// Len counts the denominations in the set.
func (s SuitSet) Len() int {
	count := 0
	for bit := Clubs; bit <= Notrump; bit <<= 1 {
		if s&bit != 0 {
			count++
		}
	}
	return count
}

// Single returns the one denomination in the set, or 0 if it does not hold exactly one.
func (s SuitSet) Single() SuitSet {
	if s.Len() != 1 {
		return 0
	}
	return s
}

// SubsetOf reports whether every denomination here is also in other.
func (s SuitSet) SubsetOf(other SuitSet) bool { return s&^other == 0 }

// Each calls fn for every denomination in the set, in the order python's `sorted()` would
// produce (alphabetical: C, D, H, N, S).
func (s SuitSet) Each(fn func(SuitSet)) {
	for _, ch := range suitChars {
		bit := suitBit[ch]
		if s&bit != 0 {
			fn(bit)
		}
	}
}

// Chars renders the set as its letters, alphabetically.
func (s SuitSet) Chars() string {
	var out []byte
	s.Each(func(bit SuitSet) { out = append(out, bitChar[bit]) })
	return string(out)
}

// SuitOf is the bit for a denomination letter, or 0.
func SuitOf(ch byte) SuitSet { return suitBit[ch] }

// Bid is one call. Suits holds every denomination the token allows, so a plain `1H` is
// {H} and a multi-suit `1HS` is {H, S}.
type Bid struct {
	Level      int // 1..7, or 0 for pass/double/redouble/other
	Suits      SuitSet
	Kind       string // "bid"|"pass"|"double"|"redouble"|"any"|"anybid"|"anycall"|"other"|…
	ByOpponent bool
	// Which suit *class* the token named, when it named one rather than listing
	// denominations: "M"/"m" for a major/minor, "oM"/"om" for "the other" one. Suits
	// still holds the class's full membership, so a consumer that does not resolve
	// variables keeps matching as before; one that does (the quiz's filter) can tie
	// `1HS ... 2M` to the same major and `2oM` to the other.
	SuitClass string
	// For kind "jump": how many levels above the cheapest available bid.
	JumpLevels int
}

func (b Bid) IsBid() bool { return b.Kind == "bid" }

// IsOtherClass reports `oM`/`om`: the complement, within its class, of the bound suit.
func (b Bid) IsOtherClass() bool { return b.SuitClass == "oM" || b.SuitClass == "om" }

// ClassSuits is the denominations this token's class ranges over ({H,S} for any of M/oM),
// or its own suits when it named no class.
func (b Bid) ClassSuits() SuitSet {
	switch strings.TrimLeft(b.SuitClass, "o") {
	case "M":
		return Majors
	case "m":
		return Minors
	}
	return b.Suits
}

// Token kinds and their spellings. Kept as sets rather than a switch so the membership
// tests read like the python they came from.
var (
	passTokens     = map[string]bool{"P": true, "PASS": true}
	doubleTokens   = map[string]bool{"X": true, "DBL": true}
	redoubleTokens = map[string]bool{"XX": true, "RDBL": true, "R": true}
	anyTokens      = map[string]bool{"ANY": true}
	otherTokens    = map[string]bool{"OTHER": true, "OTHERS": true}
	// `(overcall)` / `(higher)` -- any *bid*, so not a pass and not a double
	anyBidTokens = map[string]bool{"OVERCALL": true, "HIGHER": true}
	// `(bid)` -- the same but doubles count too; anything except a pass
	anyCallTokens  = map[string]bool{"BID": true}
	gameTokens     = map[string]bool{"GAME": true}
	nextTokens     = map[string]bool{"NEXT": true}
	nextSuitTokens = map[string]bool{"NEXTSUIT": true}
	// `4thSuit` is fourth-suit-forcing -- the one suit still unbid
	fourthSuitTokens = map[string]bool{"4THSUIT": true, "FOURTHSUIT": true}
	// A jump in these tables is a jump *in a new suit*, one level above the cheapest bid
	// available in it. `doubleJump` is the same, one level higher again.
	jumpTokens = map[string]int{"JUMP": 1, "JUMPNEW": 1, "NEWJUMP": 1, "DOUBLEJUMP": 2}
)

// `game` is a game contract: 3N or a major game or a minor game.
var gameCallTexts = [...]string{"3N", "4H", "4S", "5C", "5D"}

// SlamLevels are the levels `slam` stands for when the token does not say.
var SlamLevels = [...]int{6, 7}

// StepLimit is how many step responses `xstep` stands for -- the corpus's own EKB rows
// describe five ("5th step = 2 KC + a void") before leaving the ladder with `6x`.
const StepLimit = 5

// AltSep separates alternatives at a single position: `2D/2H` is one call, not two.
const AltSep = "/"

var (
	// A bid is a level then one or more denominations. The multi-suit form (`1HS`,
	// `4CDHS`) is a real thing in bml tables and headers, not a typo.
	bidRE = regexp.MustCompile(`^\(?([1-7])([CDHSNMm*]+)\)?$`)
	// `3*` and `3x` both mean "any denomination at that level". A bare `X` is a double,
	// but a level-prefixed one cannot be.
	levelWildcardRE = regexp.MustCompile(`^([1-7])[X*]$`)
	// `oM` is "the other major" -- a variable, not a suit set.
	otherClassRE = regexp.MustCompile(`^([1-7])?O([Mm])$`)
	shorthandRE  = regexp.MustCompile(`!([cdhsCDHS])`)
	// A bid may be written as a markdown link, e.g. `[1D](#1C--1D) Negative 0--7`.
	linkRE = regexp.MustCompile(`^\[([^\]\s]+)\]\([^)]*\)$`)
	// `cue` is a bid in a suit the opponents bid; `CueOver` cues the player on your
	// immediate right; `cueLow`/`cueHi` name which of their two suits.
	cueRE     = regexp.MustCompile(`^([1-7])?CUE$`)
	cueOverRE = regexp.MustCompile(`^([1-7])?CUEOVER$`)
	cuePickRE = regexp.MustCompile(`^([1-7])?CUE(LOW|HI|HIGH)$`)
	// Step responses to an artificial ask. Both spellings occur: `1step` and `step1`.
	stepRE = regexp.MustCompile(`^(?:([1-7]|X)STEP|STEP([1-7]))$`)
	// `raise` supports the last suit partner bid; `jumpRaise` is one level higher.
	raiseRE = regexp.MustCompile(`^([1-7])?(JUMP)?RAISE$`)
	slamRE  = regexp.MustCompile(`^([1-7])?SLAM$`)
	// A denomination with no level is a *simple* bid in that strain; a trailing `+`
	// widens it to any level in that strain. A bare `D` is excluded: it is the double.
	strainRE = regexp.MustCompile(`^(?:MAJORS?|MINORS?|([CDHSNMm]+))(\+)?$`)
	// `suit`/`newSuit`/`2Y` are all the new-suit bid; `(otherSuit)` is the same rule
	// said from the opponents' side.
	newRE = regexp.MustCompile(`^(?:([1-7])?(?:NEW(?:SUIT)?|SUIT|OTHERSUIT)|([1-7])Y)$`)
	// `2N+` is "2N or anything higher". The bound is written out, so it needs nothing
	// from the auction.
	atLeastRE = regexp.MustCompile(`^([1-7])([CDHSNMm*X])\+$`)
)

// ExpandSuitShorthand turns `!h` / `!H` into `H`, the shorthand used in .bml source.
func ExpandSuitShorthand(text string) string {
	return shorthandRE.ReplaceAllStringFunc(text, func(match string) string {
		return strings.ToUpper(match[1:])
	})
}

// FoldCallCase uppercases a token, keeping a lowercase `m` (minors) distinct from `M`
// (majors). Everything else is a suit letter or a keyword, for which case carries no
// meaning.
func FoldCallCase(token string) string {
	var out strings.Builder
	out.Grow(len(token))
	for _, ch := range token {
		if ch == 'm' {
			out.WriteRune(ch)
		} else {
			out.WriteString(strings.ToUpper(string(ch)))
		}
	}
	return out.String()
}

// NormaliseCallToken case-folds a token and reduces `NT` to `N`, without touching brackets.
func NormaliseCallToken(token string) string {
	return strings.ReplaceAll(FoldCallCase(ExpandSuitShorthand(strings.TrimSpace(token))), "NT", "N")
}

// StripBrackets splits `(1S)` into its inner text and "was it the opponents'".
func StripBrackets(token string) (string, bool) {
	inner := strings.Trim(token, "()")
	return inner, strings.HasPrefix(strings.TrimSpace(token), "(")
}

// UnwrapLink turns `[1D](#1C--1D)` into `1D`.
func UnwrapLink(token string) string {
	if m := linkRE.FindStringSubmatch(strings.TrimSpace(token)); m != nil {
		return m[1]
	}
	return token
}

// expandDenominations: `HS` -> {H,S}; `M` -> majors; `m` -> minors; `*` -> everything.
func expandDenominations(text string) SuitSet {
	var suits SuitSet
	for i := 0; i < len(text); i++ {
		switch text[i] {
		case 'M':
			suits |= Majors
		case 'm':
			suits |= Minors
		case '*':
			suits |= AllSuits
		default:
			suits |= suitBit[text[i]]
		}
	}
	return suits
}

// ParseCallAlternatives parses one auction position into the calls it allows.
//
// `2D/2H` is *one* call written as two possibilities, and `(2D/2H)` is the opponents
// making it; the brackets may wrap the whole alternation or each alternative.
func ParseCallAlternatives(token string) []Bid {
	if strings.TrimSpace(token) == "" {
		return nil
	}
	outer, outerOpp := StripBrackets(UnwrapLink(strings.TrimSpace(token)))
	var calls []Bid
	for _, part := range strings.Split(outer, AltSep) {
		if strings.TrimSpace(part) == "" {
			continue
		}
		call, ok := ParseCall(part)
		if !ok {
			continue
		}
		// brackets around the whole alternation apply to every alternative
		call.ByOpponent = call.ByOpponent || outerOpp
		calls = append(calls, call)
	}
	return calls
}

// mergeAlternatives is one Bid covering every alternative, when they differ only in suit.
// `2D/2H` is exactly `2DH`. Alternatives spanning levels (`3S/4C`) or kinds cannot be one
// Bid, and the caller falls back to kind "other".
func mergeAlternatives(calls []Bid) (Bid, bool) {
	if len(calls) == 0 {
		return Bid{}, false
	}
	first := calls[0]
	suits := first.Suits
	for _, c := range calls[1:] {
		if c.Level != first.Level || c.Kind != first.Kind || c.ByOpponent != first.ByOpponent {
			return Bid{}, false
		}
		suits |= c.Suits
	}
	first.Suits = suits
	return first, true
}

// ParseCall parses a single call. The bool is false only for empty input; unrecognised
// tokens come back as kind "other" so they can be carried along rather than crashing a
// sequence.
func ParseCall(token string) (Bid, bool) {
	if strings.TrimSpace(token) == "" {
		return Bid{}, false
	}
	token = UnwrapLink(strings.TrimSpace(token))
	if strings.Contains(token, AltSep) {
		if merged, ok := mergeAlternatives(ParseCallAlternatives(token)); ok {
			return merged, true
		}
		_, opp := StripBrackets(token)
		return Bid{Kind: "other", ByOpponent: opp}, true
	}
	inner, opp := StripBrackets(NormaliseCallToken(token))
	upper := strings.ToUpper(inner)

	switch {
	case passTokens[inner]:
		return Bid{Kind: "pass", ByOpponent: opp}, true
	case doubleTokens[inner]:
		return Bid{Kind: "double", ByOpponent: opp}, true
	case redoubleTokens[inner]:
		return Bid{Kind: "redouble", ByOpponent: opp}, true
	case anyTokens[inner] || otherTokens[upper]:
		return Bid{Kind: "any", ByOpponent: opp}, true
	case anyBidTokens[upper]:
		return Bid{Kind: "anybid", ByOpponent: opp}, true
	case anyCallTokens[upper]:
		return Bid{Kind: "anycall", ByOpponent: opp}, true
	case gameTokens[upper]:
		return Bid{Kind: "game", ByOpponent: opp}, true
	case nextTokens[inner]:
		return Bid{Kind: "next", ByOpponent: opp}, true
	}
	if levels, ok := jumpTokens[upper]; ok {
		return Bid{Kind: "jump", ByOpponent: opp, JumpLevels: levels}, true
	}

	// `!d` is diamonds, but a bare `D` written on its own is the double, so the guard
	// looks at the token as written rather than after shorthand expansion
	rawInner, _ := StripBrackets(strings.TrimSpace(token))
	m := strainRE.FindStringSubmatch(inner)
	if m == nil {
		m = strainRE.FindStringSubmatch(upper)
	}
	if m != nil && strings.ToUpper(rawInner) != "D" {
		var suits SuitSet
		switch {
		case strings.HasPrefix(upper, "MAJOR"):
			suits = Majors
		case strings.HasPrefix(upper, "MINOR"):
			suits = Minors
		default:
			suits = expandDenominations(m[1])
		}
		kind := "strain"
		if m[2] != "" {
			// `!c+`: that strain at whatever level it takes, the pass/correct sense
			kind = "strainany"
		}
		return Bid{Suits: suits, Kind: kind, ByOpponent: opp}, true
	}

	if m := slamRE.FindStringSubmatch(upper); m != nil {
		return Bid{Level: optLevel(m[1]), Kind: "slam", ByOpponent: opp}, true
	}
	if nextSuitTokens[upper] {
		return Bid{Kind: "nextsuit", ByOpponent: opp}, true
	}
	if fourthSuitTokens[upper] {
		return Bid{Kind: "fourthsuit", ByOpponent: opp}, true
	}
	if m := raiseRE.FindStringSubmatch(upper); m != nil {
		jump := 0
		if m[2] != "" {
			jump = 1
		}
		return Bid{Level: optLevel(m[1]), Kind: "raise", ByOpponent: opp, JumpLevels: jump}, true
	}
	if m := stepRE.FindStringSubmatch(upper); m != nil {
		// level carries which step; 0 means "any of them"
		which := m[1]
		if which == "" {
			which = m[2]
		}
		step := 0
		if which != "X" {
			step = optLevel(which)
		}
		return Bid{Level: step, Kind: "step", ByOpponent: opp}, true
	}
	if m := cuePickRE.FindStringSubmatch(upper); m != nil {
		kind := "cuehigh"
		if m[2] == "LOW" {
			kind = "cuelow"
		}
		return Bid{Level: optLevel(m[1]), Kind: kind, ByOpponent: opp}, true
	}
	if m := cueOverRE.FindStringSubmatch(upper); m != nil {
		return Bid{Level: optLevel(m[1]), Kind: "cueover", ByOpponent: opp}, true
	}
	if m := cueRE.FindStringSubmatch(upper); m != nil {
		return Bid{Level: optLevel(m[1]), Kind: "cue", ByOpponent: opp}, true
	}
	if m := newRE.FindStringSubmatch(upper); m != nil {
		level := m[1]
		if level == "" {
			level = m[2]
		}
		return Bid{Level: optLevel(level), Kind: "new", ByOpponent: opp}, true
	}
	if m := atLeastRE.FindStringSubmatch(inner); m != nil {
		// `2N+` -- every call from 2N up. Enumerated by CallsAtOrAbove rather than
		// stored as a bound, so matching stays a plain set intersection.
		return Bid{
			Level:      optLevel(m[1]),
			Suits:      expandDenominations(strings.ReplaceAll(m[2], "X", "*")),
			Kind:       "at_least",
			ByOpponent: opp,
		}, true
	}
	if m := levelWildcardRE.FindStringSubmatch(inner); m != nil {
		return Bid{Level: optLevel(m[1]), Suits: AllSuits, Kind: "bid", ByOpponent: opp}, true
	}
	if m := otherClassRE.FindStringSubmatch(inner); m != nil {
		// `oM` with no level ("the other major, at whatever level") keeps level 0: it
		// still constrains the suit, which is what it is for.
		suits := Majors
		if m[2] == "m" {
			suits = Minors
		}
		return Bid{Level: optLevel(m[1]), Suits: suits, Kind: "bid", ByOpponent: opp, SuitClass: "o" + m[2]}, true
	}
	if m := bidRE.FindStringSubmatch(inner); m != nil {
		denominations := m[2]
		suitClass := ""
		if denominations == "M" || denominations == "m" {
			suitClass = denominations
		}
		return Bid{
			Level:      optLevel(m[1]),
			Suits:      expandDenominations(denominations),
			Kind:       "bid",
			ByOpponent: opp,
			SuitClass:  suitClass,
		}, true
	}
	return Bid{Kind: "other", ByOpponent: opp}, true
}

func optLevel(text string) int {
	if text == "" {
		return 0
	}
	level, err := strconv.Atoi(text)
	if err != nil {
		return 0
	}
	return level
}

// ParseCalls flattens strings that may each hold several space-separated calls
// (`'1C (Pass) 1H'`) into one list of calls.
func ParseCalls(sequence []string) []Bid {
	var calls []Bid
	for _, element := range sequence {
		for _, token := range strings.Fields(element) {
			if call, ok := ParseCall(token); ok {
				calls = append(calls, call)
			}
		}
	}
	return calls
}

// IsBidToken reports a real bid (not pass/double/prose). Multi-suit counts, and so does
// an alternation of bids -- including `3S/4C`, which spans levels and so has no
// single-Bid form to ask IsBid of.
func IsBidToken(token string) bool {
	calls := ParseCallAlternatives(token)
	if len(calls) == 0 {
		return false
	}
	for _, c := range calls {
		if !c.IsBid() {
			return false
		}
	}
	return true
}

// BidTokens are the bid tokens, as written, out of strings that may hold several calls.
// Non-bids (pass, double, prose) are dropped; multi-suit bids are kept -- dropping them
// is what loses section context like `1C--1HS`.
func BidTokens(strs []string) []string {
	var out []string
	for _, s := range strs {
		for _, tok := range strings.Fields(s) {
			if IsBidToken(tok) {
				out = append(out, tok)
			}
		}
	}
	return out
}

// NextCall is the cheapest bid above `bid` -- one denomination up, or the next level
// starting at clubs when `bid` was notrump.
//
// Only defined for a bid naming one denomination: after a token that could be several
// calls (`4HS`, `3x`, `any`) there is no single next step. Returns false at the ceiling
// (7N) and for non-bids.
func NextCall(bid Bid) (Bid, bool) {
	if !bid.IsBid() || bid.Level == 0 || bid.Suits.Len() != 1 {
		return Bid{}, false
	}
	rank := Rank(bid.Suits)
	out := bid
	out.SuitClass = ""
	if rank == suitRank['N'] {
		if bid.Level == 7 {
			return Bid{}, false
		}
		out.Level = bid.Level + 1
		out.Suits = Clubs
		return out, true
	}
	for ch, r := range suitRank {
		if r == rank+1 {
			out.Suits = suitBit[ch]
			return out, true
		}
	}
	return Bid{}, false
}

// StepCall is the `steps`-th call above `previous`, counting the cheapest as step 1.
// This is the ladder artificial asks answer on: over a 4N keycard ask, 5C is step 1.
func StepCall(previous Bid, steps int) (Bid, bool) {
	call := previous
	for i := 0; i < steps; i++ {
		next, ok := NextCall(call)
		if !ok {
			return Bid{}, false
		}
		call = next
	}
	return call, true
}

// CheapestCall is the lowest bid in `suit` that is legal over `previous`: the same level
// when `suit` outranks the previous denomination, one level up otherwise. False past 7,
// or when `previous` is not one specific bid (`4HS` could be either).
func CheapestCall(previous Bid, suit SuitSet) (Bid, bool) {
	if !previous.IsBid() || previous.Level == 0 || previous.Suits.Len() != 1 {
		return Bid{}, false
	}
	was := Rank(previous.Suits)
	level := previous.Level
	if Rank(suit) <= was {
		level++
	}
	if level > 7 {
		return Bid{}, false
	}
	out := previous
	out.Level = level
	out.Suits = suit
	out.SuitClass = ""
	out.JumpLevels = 0
	return out, true
}

// GameCalls are the game contracts: 3N, 4H, 4S, 5C, 5D.
func GameCalls(byOpponent bool) []Bid {
	out := make([]Bid, 0, len(gameCallTexts))
	for _, text := range gameCallTexts {
		call, _ := ParseCall(text)
		call.ByOpponent = byOpponent
		out = append(out, call)
	}
	return out
}

// CallsAtOrAbove is every bid from `bid` upwards, for an `at_least` token like `2N+`.
// Enumerating them keeps matching a set intersection instead of needing a comparison
// operator in the pattern language.
func CallsAtOrAbove(bid Bid) []Bid {
	if bid.Level == 0 || bid.Suits.Empty() {
		return nil
	}
	floor := 6
	bid.Suits.Each(func(s SuitSet) {
		if r := Rank(s); r < floor {
			floor = r
		}
	})
	var calls []Bid
	for level := bid.Level; level <= 7; level++ {
		for _, ch := range []byte{'C', 'D', 'H', 'S', 'N'} {
			if level == bid.Level && suitRank[ch] < floor {
				continue
			}
			calls = append(calls, Bid{Level: level, Suits: suitBit[ch], Kind: "bid", ByOpponent: bid.ByOpponent})
		}
	}
	return calls
}

func levelAndSuits(bid Bid) (int, SuitSet, bool) {
	if !bid.IsBid() || bid.Level == 0 {
		return 0, 0, false
	}
	return bid.Level, bid.Suits, true
}

func oneLessThan(b1, b2 Bid) bool {
	level1, suits1, ok1 := levelAndSuits(b1)
	level2, suits2, ok2 := levelAndSuits(b2)
	if !ok1 || !ok2 {
		return false
	}
	if level1 != level2 {
		return level1 < level2
	}
	// same level: every denomination b1 could be must rank below every one b2 could be,
	// so compare b1's highest against b2's lowest
	highest1, lowest2 := 0, 6
	suits1.Each(func(s SuitSet) {
		if r := Rank(s); r > highest1 {
			highest1 = r
		}
	})
	suits2.Each(func(s SuitSet) {
		if r := Rank(s); r < lowest2 {
			lowest2 = r
		}
	})
	return highest1 < lowest2
}

// BidLessThan reports whether `b1` ranks strictly below `b2` in the auction.
//
// Strict throughout, because the caller is asking "did this call have to come first?" and
// a wrong yes invents an auction. A multi-suit bid is below another call only when
// *every* denomination it allows is, and an alternation is below only when every branch
// is. Non-bids compare as false.
func BidLessThan(b1, b2 string) bool {
	left, right := ParseCallAlternatives(b1), ParseCallAlternatives(b2)
	if len(left) == 0 || len(right) == 0 {
		return false
	}
	for _, x := range left {
		for _, y := range right {
			if !oneLessThan(x, y) {
				return false
			}
		}
	}
	return true
}

// SortSuits returns the denominations of a set as single-bit sets, alphabetically -- the
// order python's `sorted(frozenset)` produces, kept so generated variants come out in the
// same order as the reference implementation's.
func SortSuits(s SuitSet) []SuitSet {
	var out []SuitSet
	s.Each(func(bit SuitSet) { out = append(out, bit) })
	return out
}

// sortByRank orders calls by (level, denomination rank) -- the key `min`/`max` use in the
// relative-call resolution.
func sortByRank(calls []Bid) {
	sort.SliceStable(calls, func(i, j int) bool {
		if calls[i].Level != calls[j].Level {
			return calls[i].Level < calls[j].Level
		}
		return Rank(calls[i].Suits) < Rank(calls[j].Suits)
	})
}

// LowestCall is python's `min(calls, key=lambda c: (c.level, SUIT_RANK[...]))`.
func LowestCall(calls []Bid) (Bid, bool) {
	if len(calls) == 0 {
		return Bid{}, false
	}
	sorted := append([]Bid(nil), calls...)
	sortByRank(sorted)
	return sorted[0], true
}
