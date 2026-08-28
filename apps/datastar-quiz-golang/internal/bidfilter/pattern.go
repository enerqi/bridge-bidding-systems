// Package bidfilter is the bidding-tree prefix filter: a Go port of the matching half of
// `apps/quiz/bidfilter.py`.
//
// It turns the quiz's messy auction strings (e.g. ["1C (Pass) 1H", "2D", "2S"], with
// opponents in parens, `!x` suit shorthand, and multi-suit bids like "2DHS") into
// canonical positions, and matches an auction prefix against a user pattern like
// `1D-1M-1N`, where suit-class shortcuts expand:
//
//	M -> majors  {H, S}      N -> notrump {N}
//	m -> minors  {C, D}
//
// So `1D-1M-1N` matches both `1D-1H-1N` and `1D-1S-1N`. Opponent bids are written in
// parens in a pattern too, e.g. `1H-(X)-2H`.
//
// A filter string may hold several comma-separated entries, matched as an OR. Each entry
// is either a bid pattern or the name of a *topic* -- a pre-composed collection of
// patterns, which in this port arrives with the exported corpus rather than from a toml.
//
// `oM`/`om` ("the other major/minor") and repeated class shortcuts are resolved against
// the auction itself: `1HS--2M` means one major named twice, and `1H--2oM` means spades.
// See ExpandCorrelated.
package bidfilter

import (
	"errors"
	"regexp"
	"strings"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/bids"
)

// Whose call a pattern position asks for. Python writes this as `Optional[bool]`, where
// None means "don't care"; the tri-state is the same thing said in a type Go can compare.
type Side int8

const (
	EitherSide Side = iota - 1 // None: don't care
	OurSide                    // False
	TheirSide                  // True
)

func sideOf(byOpponent bool) Side {
	if byOpponent {
		return TheirSide
	}
	return OurSide
}

// BidPattern is one alternative at one position of a pattern.
type BidPattern struct {
	Level     int          // 0 = any level
	SuitClass bids.SuitSet // allowed suits; empty = any suit
	Kind      string       // "bid" | "pass" | "double" | "redouble" | "*" (any call)
	Side      Side
}

// CallPattern is one position in an auction: the alternatives allowed there.
//
// Usually one. `/` writes more than one -- `2D/2H`, `3S/4C` -- which is a single call the
// author wrote as a choice, *not* two consecutive calls. Alternatives differing only in
// suit could equally be written `2DH`; ones spanning levels (`3S/4C`) have no single-token
// form, which is why a position is a set of patterns rather than one widened pattern.
type CallPattern struct {
	Alternatives []BidPattern
}

// Pattern is a whole bid pattern: one CallPattern per position.
type Pattern []CallPattern

var (
	wsRE   = regexp.MustCompile(`\s+`)
	dashRE = regexp.MustCompile(`\s*-+\s*`)
	// One dash is enough to separate calls -- bml's `--` is accepted too, and both
	// normalise to a single `-`.
	splitRE      = regexp.MustCompile(`-+|\s+`)
	openParenRE  = regexp.MustCompile(`\(\s+`)
	closeParenRE = regexp.MustCompile(`\s+\)`)

	levelWildcardPatternRE = regexp.MustCompile(`^([1-7])[X*]$`)
	otherClassPatternRE    = regexp.MustCompile(`^([1-7])?O([Mm])$`)
	levelSuitsPatternRE    = regexp.MustCompile(`^([1-7])?([CDHSNMm]+)$`)
)

// ErrBadPattern is returned for a token (or a whole pattern) the language does not cover.
// The caller falls back to treating the entry as a topic name, or records it as an error.
var ErrBadPattern = errors.New("cannot parse pattern")

// NormalizeFilterText tidies raw user input: strip ends, collapse whitespace runs, and
// remove whitespace that is decorative rather than a token separator (inside brackets,
// around `--` and around the comma entry separator).
func NormalizeFilterText(text string) string {
	s := wsRE.ReplaceAllString(strings.TrimSpace(text), " ")
	s = dashRE.ReplaceAllString(s, "-")
	s = openParenRE.ReplaceAllString(s, "(")
	s = closeParenRE.ReplaceAllString(s, ")")
	// rebuild from the entries so empty ones (`,,` or a trailing `,`) vanish
	var kept []string
	for _, part := range strings.Split(s, ",") {
		if e := strings.TrimSpace(part); e != "" {
			kept = append(kept, e)
		}
	}
	return strings.Join(kept, ", ")
}

// parsePatternToken parses one position, which may be an alternation (`2D/2H`, `3S/4C`).
// Brackets may wrap the whole alternation -- `(2D/2H)` is the opponents making either
// call -- or an individual branch.
func parsePatternToken(tok string) (CallPattern, error) {
	inner, opp := bids.StripBrackets(tok)
	var alternatives []BidPattern
	for _, part := range strings.Split(inner, bids.AltSep) {
		if strings.TrimSpace(part) == "" {
			continue
		}
		alt, err := parseAlternative(part, opp)
		if err != nil {
			return CallPattern{}, err
		}
		alternatives = append(alternatives, alt)
	}
	if len(alternatives) == 0 {
		return CallPattern{}, ErrBadPattern
	}
	return CallPattern{Alternatives: alternatives}, nil
}

func parseAlternative(tok string, outerOpp bool) (BidPattern, error) {
	inner, opp := bids.StripBrackets(tok)
	opp = opp || outerOpp
	// brackets are the notation for "the opponents did this", so a token without them is
	// one of our calls. (The bare `*` wildcard below opts back out to "either side" --
	// that is what makes it useful for counting depth.)
	side := sideOf(opp)
	inner = bids.FoldCallCase(bids.ExpandSuitShorthand(inner))
	upper := strings.ToUpper(inner)

	switch upper {
	case "P", "PASS":
		return BidPattern{Kind: "pass", Side: side}, nil
	case "X", "DBL":
		return BidPattern{Kind: "double", Side: side}, nil
	case "XX", "RDBL", "R":
		return BidPattern{Kind: "redouble", Side: side}, nil
	case "*", "ANY":
		// wildcard: any call at this position, by either side unless bracketed. `(*)`
		// means "the opponents did something here", since their passes are dropped by
		// significantPositions.
		wildSide := EitherSide
		if opp {
			wildSide = TheirSide
		}
		return BidPattern{Kind: "*", Side: wildSide}, nil
	}
	if m := levelWildcardPatternRE.FindStringSubmatch(upper); m != nil {
		// `1*` / `1x` -- any suit at that level (an empty suit class means "any"). Bid
		// tables spell this `x`, section headers `*`; a bare `X` was caught above as a
		// double, so the level makes them unambiguous.
		return BidPattern{Level: atoiLevel(m[1]), Kind: "bid", Side: side}, nil
	}
	if m := otherClassPatternRE.FindStringSubmatch(inner); m != nil {
		// `oM` in a *pattern* has no earlier call to be "other" than, so it asks for the
		// class: an auction whose oM resolved either way matches.
		suits := bids.Majors
		if m[2] == "m" {
			suits = bids.Minors
		}
		return BidPattern{Level: atoiLevel(m[1]), SuitClass: suits, Kind: "bid", Side: side}, nil
	}
	// level + suit-class chars (case-sensitive: M/m are class shortcuts)
	m := levelSuitsPatternRE.FindStringSubmatch(inner)
	if m == nil {
		return BidPattern{}, ErrBadPattern
	}
	var suitClass bids.SuitSet
	for i := 0; i < len(m[2]); i++ {
		switch m[2][i] {
		case 'M':
			suitClass |= bids.Majors
		case 'm':
			suitClass |= bids.Minors
		default:
			suitClass |= bids.SuitOf(m[2][i])
		}
	}
	return BidPattern{Level: atoiLevel(m[1]), SuitClass: suitClass, Kind: "bid", Side: side}, nil
}

func atoiLevel(text string) int {
	if text == "" {
		return 0
	}
	return int(text[0] - '0')
}

// ParsePattern parses `1D-1M-1N` (dashes or spaces; bml's `--` also accepted).
// A position may offer alternatives with `/`: `1M-3S/4C`.
func ParsePattern(patternStr string) (Pattern, error) {
	parts := splitRE.Split(NormalizeFilterText(patternStr), -1)
	var pattern Pattern
	for _, part := range parts {
		if part == "" {
			continue
		}
		call, err := parsePatternToken(part)
		if err != nil {
			return nil, err
		}
		pattern = append(pattern, call)
	}
	if len(pattern) == 0 {
		return nil, ErrBadPattern
	}
	return pattern, nil
}

// CanonicalPatternText rewrites a pattern the way it was understood: `-`-joined,
// whitespace tidied, case folded (`1d -- 1M 1n` -> `1D-1M-1N`).
func CanonicalPatternText(patternStr string) string {
	var out []string
	for _, part := range splitRE.Split(NormalizeFilterText(patternStr), -1) {
		if part == "" {
			continue
		}
		inner, opp := bids.StripBrackets(part)
		inner = bids.FoldCallCase(bids.ExpandSuitShorthand(inner))
		if opp {
			inner = "(" + inner + ")"
		}
		out = append(out, inner)
	}
	return strings.Join(out, "-")
}
