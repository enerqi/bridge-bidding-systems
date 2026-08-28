package bidfilter

import (
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/bids"
)

// --- correlated suit classes ------------------------------------------------
//
// `1HS--2M` is "1H then 2H, or 1S then 2S" -- one major, named twice. Matching each
// position independently also accepts 1H then 2S, an auction the section never described.
// The corpus proves the intent: it writes `oM` when it means *the other* major, which
// would be pointless if a repeated `M` did not mean the same one.
//
// Rather than binding variables inside the matcher (which would make it stateful and need
// backtracking), an auction is expanded into the concrete auctions it stands for, and
// matches if any of them does. For a single set-valued position this is identical to the
// plain overlap test; it only tightens where two positions share a class.

// A suit class is a proper subset of the denominations: {H,S} and {C,D} bind, the
// five-denomination wildcard (`3*`) does not -- two wildcards in an auction are
// unrelated, not "the same unknown suit".
var bindable = [...]bids.SuitSet{bids.Majors, bids.Minors}

// bindingClass is the class this call's suit is drawn from, if it is one that binds, or 0.
// A concrete call counts: `1H` is a use of the majors class, which is what lets a later
// `2oM` mean spades.
func bindingClass(bid bids.Bid) bids.SuitSet {
	if !bid.IsBid() || bid.Suits.Empty() {
		return 0
	}
	if bid.SuitClass != "" {
		klass := bid.ClassSuits()
		for _, b := range bindable {
			if klass == b {
				return klass
			}
		}
		return 0
	}
	for _, klass := range bindable {
		if bid.Suits.SubsetOf(klass) {
			return klass
		}
	}
	return 0
}

// boundClasses are the classes this auction uses as a variable.
//
// A class binds when the auction leaves it open more than once (`1HS ... 2M`), or names
// "the other" one alongside any call of that class (`1H ... 2oM` -- the concrete 1H is
// what fixes it).
func boundClasses(auction Auction) []bids.SuitSet {
	openUses := map[bids.SuitSet]int{}
	anyUses := map[bids.SuitSet]int{}
	other := map[bids.SuitSet]bool{}
	for _, position := range auction {
		for _, bid := range position {
			klass := bindingClass(bid)
			if klass == 0 {
				continue
			}
			anyUses[klass]++
			if bid.IsOtherClass() {
				other[klass] = true
			} else if bid.Suits.Len() > 1 {
				openUses[klass]++
			}
		}
	}
	// Fixed order rather than map order: there are only two classes, and a deterministic
	// list keeps the generated variants in a stable order run to run.
	var out []bids.SuitSet
	for _, k := range bindable {
		if anyUses[k] == 0 {
			continue
		}
		if openUses[k] > 1 || (other[k] && anyUses[k] > 1) {
			out = append(out, k)
		}
	}
	return out
}

// fixedSuit is the one denomination of `klass` the auction states outright, if any.
//
// Two different concrete calls of the same class (`1H` then `1S`) leave the variable
// genuinely ambiguous; returning 0 makes the caller fall back to the untightened auction
// rather than guess.
func fixedSuit(auction Auction, klass bids.SuitSet) bids.SuitSet {
	var concrete bids.SuitSet
	for _, position := range auction {
		for _, bid := range position {
			if bindingClass(bid) == klass && bid.Suits.Len() == 1 {
				concrete |= bid.Suits
			}
		}
	}
	if concrete.Len() == 1 {
		return concrete
	}
	return 0
}

func resolveBid(bid bids.Bid, assignment map[bids.SuitSet]bids.SuitSet) bids.Bid {
	klass := bindingClass(bid)
	chosen, ok := assignment[klass]
	if klass == 0 || !ok || bid.Suits.Len() == 1 {
		return bid
	}
	if bid.IsOtherClass() {
		bid.Suits = klass &^ chosen
	} else {
		bid.Suits = chosen
	}
	return bid
}

// ExpandCorrelated returns the concrete auctions an auction with correlated suit classes
// stands for -- the auction unchanged when nothing binds, which is the common case.
func ExpandCorrelated(auction Auction) []Auction {
	classes := boundClasses(auction)
	if len(classes) == 0 {
		return []Auction{auction}
	}
	domains := make([][]bids.SuitSet, 0, len(classes))
	for _, klass := range classes {
		fixed := fixedSuit(auction, klass)
		hasOther := false
		for _, position := range auction {
			for _, bid := range position {
				if bindingClass(bid) == klass && bid.IsOtherClass() {
					hasOther = true
				}
			}
		}
		if fixed != 0 && hasOther {
			domains = append(domains, []bids.SuitSet{fixed}) // a spelled-out call pins the variable
		} else {
			domains = append(domains, bids.SortSuits(klass))
		}
	}
	var variants []Auction
	for _, choice := range product(domains) {
		assignment := make(map[bids.SuitSet]bids.SuitSet, len(classes))
		for i, klass := range classes {
			assignment[klass] = choice[i]
		}
		variant := make(Auction, len(auction))
		for i, position := range auction {
			resolved := make(Position, len(position))
			for j, bid := range position {
				resolved[j] = resolveBid(bid, assignment)
			}
			variant[i] = resolved
		}
		variants = append(variants, variant)
	}
	if len(variants) == 0 {
		return []Auction{auction}
	}
	return variants
}

// product is itertools.product over the domains, in the same order.
func product(domains [][]bids.SuitSet) [][]bids.SuitSet {
	out := [][]bids.SuitSet{{}}
	for _, domain := range domains {
		var grown [][]bids.SuitSet
		for _, prefix := range out {
			for _, value := range domain {
				next := make([]bids.SuitSet, len(prefix), len(prefix)+1)
				copy(next, prefix)
				grown = append(grown, append(next, value))
			}
		}
		out = grown
	}
	return out
}

// --- relative calls ---------------------------------------------------------

// relativeKinds are the token kinds whose call has to be worked out from the auction so
// far.
var relativeKinds = map[string]bool{
	"next": true, "jump": true, "cue": true, "cueover": true, "cuelow": true,
	"cuehigh": true, "new": true, "step": true, "raise": true, "strain": true,
	"strainany": true, "slam": true, "nextsuit": true, "fourthsuit": true,
}

// resolution is one way a relative token could resolve: the call it becomes, plus the
// previous position pinned to the single call it was measured from (when that position is
// the one immediately before, which is the position ResolveRelative rewrites).
type resolution struct {
	Parent    bids.Bid
	HasParent bool
	Call      bids.Bid
}

// ResolveRelative replaces `next` with the call it stands for: the cheapest bid above the
// position before it (`4HS = splinter` then `next = RKB` is 4S over 4H).
//
// Returns the auctions that produces. A parent naming several calls gives one auction per
// call, *with the parent pinned* -- 4H then 4S, or 4S then 4N, and never 4H then 4N, which
// no line of the table describes. A `next` whose parent is not a bid at all (`any`, prose)
// stays unresolved and so matches nothing: the auction never said which call it was.
//
// Run *after* ExpandCorrelated, so a parent whose suit class was bound is already concrete.
func ResolveRelative(auction Auction) []Auction {
	auctions := []Auction{{}}
	for _, position := range auction {
		var relatives []bids.Bid
		for _, b := range position {
			if relativeKinds[b.Kind] {
				relatives = append(relatives, b)
			}
		}
		if len(relatives) > 0 && len(auctions[0]) > 0 {
			var grown []Auction
			for _, built := range auctions {
				resolvedAny := false
				for _, relative := range relatives {
					// `!c/!d` is two relative tokens at one position, so every one of
					// them contributes its resolutions
					for _, r := range resolutionsOf(relative, built) {
						resolvedAny = true
						call := r.Call
						call.ByOpponent = relative.ByOpponent
						if !r.HasParent {
							// the call we measured from is further back than the
							// previous position, so there is nothing to pin here
							grown = append(grown, appendPosition(built, Position{call}))
						} else {
							pinned := make(Auction, len(built))
							copy(pinned, built)
							pinned[len(pinned)-1] = Position{r.Parent}
							grown = append(grown, appendPosition(pinned, Position{call}))
						}
					}
				}
				if !resolvedAny {
					grown = append(grown, appendPosition(built, position)) // unresolvable, keep as is
				}
			}
			auctions = grown
		} else {
			for i, built := range auctions {
				auctions[i] = appendPosition(built, position)
			}
		}
	}
	return auctions
}

func appendPosition(auction Auction, position Position) Auction {
	out := make(Auction, len(auction), len(auction)+1)
	copy(out, auction)
	return append(out, position)
}

// lastBidPosition is the index of the last position holding an actual bid.
//
// Everything here measures "cheapest above" from a *bid*: a raise or a cue over partner's
// double is still legal, it just has to clear the last bid. -1 when the auction holds no
// bid at all.
func lastBidPosition(auction Auction) int {
	for i := len(auction) - 1; i >= 0; i-- {
		for _, bid := range auction[i] {
			if bid.IsBid() && !bid.Suits.Empty() {
				return i
			}
		}
	}
	return -1
}

// resolutionsOf is (pinned previous call, the call the token resolves to) for each call
// the previous position could have been.
func resolutionsOf(relative bids.Bid, auction Auction) []resolution {
	source := lastBidPosition(auction)
	if source < 0 {
		return nil
	}
	pin := source == len(auction)-1
	var out []resolution
	for _, previous := range auction[source] {
		for _, suit := range bids.SortSuits(previous.Suits) {
			parent := previous
			parent.Suits = suit
			parent.SuitClass = ""

			if relative.Kind == "next" {
				if call, ok := bids.NextCall(parent); ok {
					out = append(out, resolution{Parent: parent, HasParent: pin, Call: call})
				}
				continue
			}
			var calls []bids.Bid
			switch relative.Kind {
			case "jump":
				calls = jumpsFrom(parent, relative.JumpLevels, auction)
			case "new":
				calls = inSuits(parent, unbidSuits(auction), relative.Level)
			case "strain":
				// a denomination with no level: the simple (non-jump) bid in it
				calls = inSuits(parent, relative.Suits, 0)
			case "strainany":
				// `!c+`: that strain at whatever level it takes, so every legal bid in
				// it from the cheapest upward
				for _, cheapest := range inSuits(parent, relative.Suits, 0) {
					for level := cheapest.Level; level <= 7; level++ {
						raised := cheapest
						raised.Level = level
						calls = append(calls, raised)
					}
				}
			case "raise":
				calls = raisesFrom(parent, auction, relative)
			case "slam":
				calls = slamsFrom(parent, auction, relative)
			case "nextsuit":
				calls = nextSuitFrom(parent)
			case "fourthsuit":
				calls = fourthSuitFrom(parent, auction)
			case "step":
				calls = stepsFrom(parent, relative.Level)
			case "cueover":
				calls = inSuits(parent, rhoSuits(parent, auction), relative.Level)
			case "cuelow", "cuehigh":
				calls = pickedCue(parent, auction, relative)
			default: // cue
				calls = cuesFrom(parent, auction, relative.Level)
			}
			for _, call := range calls {
				out = append(out, resolution{Parent: parent, HasParent: pin, Call: call})
			}
		}
	}
	return out
}

// spokenSuits are the denominations the auction pinned down to one suit, optionally only
// the opponents'. An unresolved `2M` names no single suit, so it neither counts as bid nor
// rules a suit out.
func spokenSuits(auction Auction, side Side) bids.SuitSet {
	var suits bids.SuitSet
	for _, position := range auction {
		for _, bid := range position {
			if !bid.IsBid() || bid.Suits.Len() != 1 {
				continue
			}
			if side != EitherSide && sideOf(bid.ByOpponent) != side {
				continue
			}
			suits |= bid.Suits
		}
	}
	return suits
}

// unbidSuits are the suits nobody has bid -- neither side. Notrump is not a suit.
func unbidSuits(auction Auction) bids.SuitSet {
	return bids.RealSuits &^ spokenSuits(auction, EitherSide)
}

// inSuits is the call in each of `suits`: at `level` when the token named one (`3new`),
// otherwise the cheapest available (a simple bid, not a jump).
func inSuits(parent bids.Bid, suits bids.SuitSet, level int) []bids.Bid {
	var calls []bids.Bid
	for _, suit := range bids.SortSuits(suits) {
		if level == 0 {
			if call, ok := bids.CheapestCall(parent, suit); ok {
				calls = append(calls, call)
			}
			continue
		}
		call := parent
		call.Level = level
		call.Suits = suit
		call.SuitClass = ""
		call.JumpLevels = 0
		calls = append(calls, call)
	}
	return calls
}

// raisesFrom is support for the last suit partner bid.
//
// Partner's suit is the last bid on our own side of the table -- usually the call right
// before ours, but an opponent may have come in between (`2D--(P)--2N--(any)--raise`).
// `jumpRaise` is one level above the simple raise, and `3raise` names the level outright.
//
// Caveat: when partner's bid was itself several calls (`2HS`) *and* it is not the call
// immediately before ours, both raises are offered rather than one per pinned variant --
// only the previous position is pinned.
func raisesFrom(parent bids.Bid, auction Auction, token bids.Bid) []bids.Bid {
	suits := partnerSuits(auction, token.ByOpponent, parent, true)
	if suits.Empty() {
		return nil
	}
	calls := inSuits(parent, suits, token.Level)
	if token.JumpLevels == 0 {
		return calls
	}
	var raised []bids.Bid
	for _, c := range calls {
		if c.Level+token.JumpLevels <= 7 {
			c.Level += token.JumpLevels
			raised = append(raised, c)
		}
	}
	return raised
}

// slamsFrom is `slam`: the agreed suit -- the last one our side named -- at the slam
// level, 6 or 7. `6slam` says which.
func slamsFrom(parent bids.Bid, auction Auction, token bids.Bid) []bids.Bid {
	suits := partnerSuits(auction, token.ByOpponent, parent, true)
	levels := bids.SlamLevels[:]
	if token.Level != 0 {
		levels = []int{token.Level}
	}
	var calls []bids.Bid
	for _, suit := range bids.SortSuits(suits) {
		cheapest, ok := bids.CheapestCall(parent, suit)
		if !ok {
			continue
		}
		for _, level := range levels {
			if level >= cheapest.Level {
				call := cheapest
				call.Level = level
				calls = append(calls, call)
			}
		}
	}
	return calls
}

// nextSuitFrom is `nextSuit`: the next bid up that is a suit -- the cheapest call above,
// skipping notrump (a `next` that lands on 3N is not one).
func nextSuitFrom(parent bids.Bid) []bids.Bid {
	var candidates []bids.Bid
	for _, suit := range bids.SortSuits(bids.RealSuits) {
		if call, ok := bids.CheapestCall(parent, suit); ok {
			candidates = append(candidates, call)
		}
	}
	if lowest, ok := bids.LowestCall(candidates); ok {
		return []bids.Bid{lowest}
	}
	return nil
}

// fourthSuitFrom is `4thSuit`: fourth-suit-forcing -- the one suit still unbid.
//
// Only resolvable when exactly one is left; with two or more the token is not describing
// anything the auction has pinned down.
func fourthSuitFrom(parent bids.Bid, auction Auction) []bids.Bid {
	unbid := unbidSuits(auction)
	if unbid.Len() != 1 {
		return nil
	}
	return inSuits(parent, unbid, 0)
}

// partnerSuits are the suits of the last bid on the given side -- partner's, for our own
// tokens.
//
// When that bid is the one we are measuring from it has already been pinned to a single
// suit, so use it: `4HS` then `slam` is 6H over 4H or 6S over 4S, never 6S over 4H.
func partnerSuits(auction Auction, byOpponent bool, parent bids.Bid, hasParent bool) bids.SuitSet {
	for index := len(auction) - 1; index >= 0; index-- {
		var found bids.SuitSet
		for _, bid := range auction[index] {
			if bid.IsBid() && bid.ByOpponent == byOpponent {
				found |= bid.Suits
			}
		}
		if found.Empty() {
			continue
		}
		if hasParent && parent.ByOpponent == byOpponent && index == lastBidPosition(auction) {
			return parent.Suits & bids.AllSuits
		}
		return found & bids.AllSuits
	}
	return 0
}

// stepsFrom is the step response(s) to an artificial ask.
//
// `1step` is one rung up the ladder, `2step` two. `xstep` is "a step response, however
// many the scheme has" -- the author's reading -- so it stands for the first
// bids.StepLimit of them rather than for one known call.
func stepsFrom(parent bids.Bid, step int) []bids.Bid {
	var wanted []int
	if step != 0 {
		wanted = []int{step}
	} else {
		for n := 1; n <= bids.StepLimit; n++ {
			wanted = append(wanted, n)
		}
	}
	var calls []bids.Bid
	for _, n := range wanted {
		if call, ok := bids.StepCall(parent, n); ok {
			calls = append(calls, call)
		}
	}
	return calls
}

// rhoSuits is the suit of the last call by the player on our immediate right, the one
// `CueOver` cues -- as opposed to `cue`, which is any of their suits.
//
// It is their *last call* that matters, not their last bid: if they doubled, there is
// nothing to cue over and the token stays unresolved, even though an earlier opponent bid
// is sitting there. Notrump is dropped, there being no such thing as cueing notrump.
func rhoSuits(parent bids.Bid, auction Auction) bids.SuitSet {
	last := lastOpponentPosition(auction)
	if last < 0 {
		return 0
	}
	if parent.ByOpponent && last == lastBidPosition(auction) {
		// their last call *is* the bid we are measuring from, already pinned
		return parent.Suits & bids.RealSuits
	}
	var suits bids.SuitSet
	for _, bid := range auction[last] {
		if bid.IsBid() {
			suits |= bid.Suits
		}
	}
	return suits & bids.RealSuits
}

// lastOpponentPosition is the index of the opponents' most recent *call*, of any kind.
func lastOpponentPosition(auction Auction) int {
	for i := len(auction) - 1; i >= 0; i-- {
		for _, bid := range auction[i] {
			if bid.ByOpponent {
				return i
			}
		}
	}
	return -1
}

// pickedCue is `cueLow` / `cueHi`: a cue of the lower- or higher-ranking of *their two
// suits*. Only resolvable when the auction shows two opponent suits.
func pickedCue(parent bids.Bid, auction Auction, token bids.Bid) []bids.Bid {
	theirs := spokenSuits(auction, TheirSide)
	if theirs.Len() < 2 {
		return nil
	}
	var picked bids.SuitSet
	best := 0
	theirs.Each(func(s bids.SuitSet) {
		rank := bids.Rank(s)
		if picked == 0 || (token.Kind == "cuelow" && rank < best) || (token.Kind != "cuelow" && rank > best) {
			picked, best = s, rank
		}
	})
	return inSuits(parent, picked, token.Level)
}

// cuesFrom is a cue bid: their suit. Unqualified it is the *lowest* cue available, so with
// two opponent suits shown only the cheaper one counts.
func cuesFrom(parent bids.Bid, auction Auction, level int) []bids.Bid {
	theirs := spokenSuits(auction, TheirSide)
	calls := inSuits(parent, theirs, level)
	if level == 0 && len(calls) > 0 {
		if lowest, ok := bids.LowestCall(calls); ok {
			return []bids.Bid{lowest}
		}
	}
	return calls
}

// jumpsFrom is every call `jump` could be over `parent`: a jump in a *new suit*.
//
// A jump is `levels` above the cheapest bid available in that suit, never in notrump (a
// jump to 3N is a different animal), and never in a suit already bid. "Already bid" counts
// only calls the auction pinned down to one denomination, so an unresolved `2M` does not
// silently rule both majors out.
func jumpsFrom(parent bids.Bid, levels int, auction Auction) []bids.Bid {
	spoken := spokenSuits(auction, EitherSide) | parent.Suits
	var calls []bids.Bid
	for _, suit := range bids.SortSuits(bids.RealSuits &^ spoken) {
		cheapest, ok := bids.CheapestCall(parent, suit)
		if !ok || cheapest.Level+levels > 7 {
			continue
		}
		cheapest.Level += levels
		calls = append(calls, cheapest)
	}
	return calls
}
