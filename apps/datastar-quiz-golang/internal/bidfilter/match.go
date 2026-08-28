package bidfilter

import (
	"strings"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/bids"
)

// Position is one place in an auction: the calls it allows. One for an ordinary call,
// several for `2D/2H`.
type Position []bids.Bid

// Auction is a parsed auction: one Position per call.
type Auction []Position

// Variants are the concrete auctions one written auction stands for -- one unless
// correlated suit classes bind (see ExpandCorrelated) or a relative token like `next`
// resolves several ways.
type Variants []Auction

// BidMatches reports whether one call satisfies one position of a pattern.
//
// Both sides can name a *set* of calls -- the auction may record `1HS` or `2D/2H`, the
// pattern may ask for `1M` or `3S/4C` -- so this is a test for overlap, not equality: the
// position matches if any alternative it allows shares a denomination with any the call
// allows.
func BidMatches(bid bids.Bid, pat BidPattern) bool {
	switch bid.Kind {
	case "any", "anybid", "anycall":
		// a catch-all row -- "whatever is called here" -- so it answers to any pattern,
		// subject to whose call it was and to how much the word promised: `(overcall)`
		// is a bid, `(bid)` is anything but a pass, `any`/`other(s)` is anything at all
		if pat.Side != EitherSide && pat.Side != sideOf(bid.ByOpponent) {
			return false
		}
		switch bid.Kind {
		case "anybid":
			return pat.Kind == "bid" || pat.Kind == "*"
		case "anycall":
			return pat.Kind == "bid" || pat.Kind == "double" || pat.Kind == "redouble" || pat.Kind == "*"
		}
		return true
	}
	if pat.Kind != "*" && pat.Kind != bid.Kind {
		return false
	}
	if pat.Side != EitherSide && pat.Side != sideOf(bid.ByOpponent) {
		return false
	}
	if pat.Kind == "bid" {
		if pat.Level != 0 && pat.Level != bid.Level {
			return false
		}
		if !pat.SuitClass.Empty() && !bid.Suits.Has(pat.SuitClass) {
			return false
		}
	}
	return true
}

// callMatches is BidMatches over a whole position of the pattern (its alternatives).
func callMatches(bid bids.Bid, pat CallPattern) bool {
	for _, alt := range pat.Alternatives {
		if BidMatches(bid, alt) {
			return true
		}
	}
	return false
}

// PositionMatches is BidMatches when the *auction* position is itself a set of calls.
//
// `1HS--3S/4C` records a position no single Bid can express, so an auction position is a
// tuple of alternatives. It matches when any of them does -- the recorded auction is one
// of these calls, and the filter is asking whether it could be the one wanted.
func PositionMatches(position Position, pat CallPattern) bool {
	for _, bid := range position {
		if callMatches(bid, pat) {
			return true
		}
	}
	return false
}

// MatchesPrefix reports whether the auction begins with the pattern.
//
// A pattern describes *our* auction. The opponents can slip a call in at any point, so
// opponent calls the pattern does not ask about are stepped over rather than failing the
// match: `1D-1H` matches 1D (Pass) 1H, 1D (1S) 1H and 1D (X) 1H alike.
//
// Three kinds of token opt out of that skipping and line up with whatever call comes next:
//   - the *first* token, because this is a prefix match: it anchors to the opening call,
//     so `2C` means we opened 2C, not that we bid 2C at some point after an opponent's
//     opening;
//   - a bracketed token -- `(X)`, `(2H)`, `(*)` -- which is *about* the opponents, so it
//     must match the very next call;
//   - the bare wildcard `*`, meaning "any call at all" including an opponent's, which is
//     what makes `*-*-*-*-*-*` mean "six calls deep" rather than "six calls by us".
func MatchesPrefix(auction Auction, pattern Pattern) bool {
	i := 0
	for n, pat := range pattern {
		if n > 0 && !anchored(pat) {
			for i < len(auction) && allByOpponent(auction[i]) {
				i++
			}
		}
		if i >= len(auction) || !PositionMatches(auction[i], pat) {
			return false
		}
		i++
	}
	return true
}

func allByOpponent(position Position) bool {
	for _, b := range position {
		if !b.ByOpponent {
			return false
		}
	}
	return true
}

// anchored: must this position line up with the very next call rather than skipping over
// opponent calls? True for anything bracketed and for the bare `*`.
func anchored(pat CallPattern) bool {
	for _, a := range pat.Alternatives {
		if a.Side == TheirSide || a.Kind == "*" {
			return true
		}
	}
	return false
}

// ParseSequencePositions parses an auction into one entry per position, each the calls it
// allows.
//
// Unlike a flat call parse this keeps `3S/4C` -- an alternation spanning levels, which has
// no single-Bid form -- instead of degrading it to 'other'.
func ParseSequencePositions(sequence []string) Auction {
	var auction Auction
	for _, element := range sequence {
		for _, token := range strings.Fields(element) {
			var calls Position
			for _, call := range bids.ParseCallAlternatives(token) {
				switch call.Kind {
				case "at_least":
					// `2N+` names its own floor, so it needs no auction: expand it here
					// into the calls it allows
					calls = append(calls, bids.CallsAtOrAbove(call)...)
				case "game":
					// a game contract: 3N, 4H, 4S, 5C or 5D
					calls = append(calls, bids.GameCalls(call.ByOpponent)...)
				default:
					calls = append(calls, call)
				}
			}
			if len(calls) > 0 {
				auction = append(auction, calls)
			}
		}
	}
	return auction
}

// SignificantPositions drops opponent passes. They are noise for filtering -- the auction
// notation omits them anyway -- and dropping them is what lets `(*)` mean "the opponents
// actually did something". Active opponent calls like (X) or (1S) are kept, and
// MatchesPrefix decides whether to step over them.
func SignificantPositions(auction Auction) Auction {
	out := make(Auction, 0, len(auction))
	for _, p := range auction {
		allOppPass := true
		for _, b := range p {
			if !(b.ByOpponent && b.Kind == "pass") {
				allOppPass = false
				break
			}
		}
		if !allOppPass {
			out = append(out, p)
		}
	}
	return out
}

// PrepareAuction turns one auction into the concrete auctions it stands for: parsed into
// positions, opponent passes dropped, suit classes bound, `next` and its relatives
// resolved.
func PrepareAuction(sequence []string) Variants {
	positions := SignificantPositions(ParseSequencePositions(sequence))
	var out Variants
	for _, variant := range ExpandCorrelated(positions) {
		out = append(out, ResolveRelative(variant)...)
	}
	return out
}

// PrepareSequenceBids pre-parses a corpus of auctions once, so that repeatedly
// re-filtering it (validating on every keystroke) is only prefix comparisons.
func PrepareSequenceBids(sequences [][]string) []Variants {
	out := make([]Variants, len(sequences))
	for i, s := range sequences {
		out[i] = PrepareAuction(s)
	}
	return out
}

// BidsMatchAny reports whether a pre-parsed auction matches *any* of the patterns
// (comma = OR).
func BidsMatchAny(variants Variants, patterns []Pattern) bool {
	for _, v := range variants {
		for _, p := range patterns {
			if MatchesPrefix(v, p) {
				return true
			}
		}
	}
	return false
}

// SequenceMatchesAny parses a raw auction and prefix-matches it against any of the
// patterns. Convenience for tests and one-off checks; the app pre-parses instead.
func SequenceMatchesAny(sequence []string, patterns []Pattern) bool {
	return BidsMatchAny(PrepareAuction(sequence), patterns)
}
