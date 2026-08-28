package bidfilter

import (
	"testing"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/bids"
)

// The cases are ported one for one from `apps/quiz/tests/test_bidfilter.py`, which is the
// specification of the pattern language: every behaviour asserted there has to hold here
// or the two implementations disagree about what a filter selects. Where the python asserts
// on a python-only detail (tomllib loading, `Path` handling for the topics file) the case
// is dropped rather than faked -- the topics arrive already parsed in this port.

func mustPattern(t *testing.T, text string) Pattern {
	t.Helper()
	pattern, err := ParsePattern(text)
	if err != nil {
		t.Fatalf("ParsePattern(%q): %v", text, err)
	}
	return pattern
}

// matches is the python `sequence_matches`: parse a raw auction and prefix-match it.
func matches(t *testing.T, seq []string, pattern string) bool {
	t.Helper()
	return SequenceMatchesAny(seq, []Pattern{mustPattern(t, pattern)})
}

// seqCase is one (auction, pattern, expected) row.
type seqCase struct {
	seq     []string
	pattern string
	want    bool
}

func runSeqCases(t *testing.T, cases []seqCase) {
	t.Helper()
	for _, c := range cases {
		if got := matches(t, c.seq, c.pattern); got != c.want {
			t.Errorf("matches(%q, %q) = %v, want %v", c.seq, c.pattern, got, c.want)
		}
	}
}

func TestParseBidToken(t *testing.T) {
	cases := []struct {
		token string
		want  bids.Bid
	}{
		{"1D", bids.Bid{Level: 1, Suits: bids.Diamonds, Kind: "bid"}},
		{"(1!h)", bids.Bid{Level: 1, Suits: bids.Hearts, Kind: "bid", ByOpponent: true}},
		{"2DHS", bids.Bid{Level: 2, Suits: bids.Diamonds | bids.Hearts | bids.Spades, Kind: "bid"}},
		{"(3CDHS)", bids.Bid{Level: 3, Suits: bids.RealSuits, Kind: "bid", ByOpponent: true}},
		{"(X)", bids.Bid{Kind: "double", ByOpponent: true}},
	}
	for _, c := range cases {
		got, ok := bids.ParseCall(c.token)
		if !ok || got != c.want {
			t.Errorf("ParseCall(%q) = %+v (%v), want %+v", c.token, got, ok, c.want)
		}
	}
	kinds := map[string]string{
		"Pass":    "pass",
		"any":     "any",
		"cue":     "cue",
		"others":  "any",   // a catch-all row
		"enquiry": "other", // prose, still unresolved
		"next":    "next",  // resolved against the auction
		"game":    "game",  //
		"jump":    "jump",  //
		"4thSuit": "fourthsuit",
	}
	for token, want := range kinds {
		got, _ := bids.ParseCall(token)
		if got.Kind != want {
			t.Errorf("ParseCall(%q).Kind = %q, want %q", token, got.Kind, want)
		}
	}
}

func TestParseSequencePositions(t *testing.T) {
	auction := ParseSequencePositions([]string{"1C (Pass) 1H", "2D", "2S"})
	wantKinds := []string{"bid", "pass", "bid", "bid", "bid"}
	if len(auction) != len(wantKinds) {
		t.Fatalf("got %d positions, want %d", len(auction), len(wantKinds))
	}
	for i, kind := range wantKinds {
		if auction[i][0].Kind != kind {
			t.Errorf("position %d kind = %q, want %q", i, auction[i][0].Kind, kind)
		}
	}
	if want := (bids.Bid{Level: 1, Suits: bids.Clubs, Kind: "bid"}); auction[0][0] != want {
		t.Errorf("first call = %+v, want %+v", auction[0][0], want)
	}
	if want := (bids.Bid{Kind: "pass", ByOpponent: true}); auction[1][0] != want {
		t.Errorf("second call = %+v, want %+v", auction[1][0], want)
	}
}

func TestMajorShortcutMatchesBoth(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1D (Pass) 1H", "1N"}, "1D--1M--1N", true},
		{[]string{"1D (Pass) 1S", "1N"}, "1D--1M--1N", true},
		{[]string{"1D (Pass) 2H", "1N"}, "1D--1M--1N", false}, // wrong level in the middle
		{[]string{"1D (Pass) 1C", "1N"}, "1D--1M--1N", false}, // minor where a major is required
	})
}

func TestPrefixShorterThanSequence(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1D (Pass) 1H", "1N", "2C"}, "1D--1H", true},
		{[]string{"1D"}, "1D--1H--1N", false}, // pattern longer than auction cannot match
	})
}

func TestMultiSuitAndOpponents(t *testing.T) {
	runSeqCases(t, []seqCase{
		// multi-suit bid 2DHS intersects a major-class pattern 2M
		{[]string{"1H (Pass) 2DHS"}, "1H--2M", true},
		{[]string{"1H (Pass) 2DHS"}, "1H--2C", false},
		{[]string{"1H (X)", "2H"}, "1H--(X)--2H", true},
		{[]string{"1H (Pass)", "2H"}, "1H--(X)--2H", false},
	})
}

func TestWildcardToken(t *testing.T) {
	runSeqCases(t, []seqCase{
		// `(*)` = opponents did something (implicit opponent passes are dropped)
		{[]string{"1H (X)"}, "1M--(*)", true},
		{[]string{"1S (2D)"}, "1M--(*)", true},
		{[]string{"1H (Pass)", "2H"}, "1M--(*)", false},
		{[]string{"1C (X)"}, "1M--(*)", false}, // 1C is not a major
		// bare `*` / `any` matches any call by either side
		{[]string{"1C (Pass) 1H"}, "*--*", true},
		{[]string{"1C (X)"}, "1C--any", true},
		// `1*` -- any suit, but that level and an actual bid
		{[]string{"1C (Pass) 1S"}, "1C--1*", true},
		{[]string{"1C (Pass) 2S"}, "1C--1*", false},
		{[]string{"1C (X)"}, "1C--1*", false},
	})
}

func TestNormalizeFilterText(t *testing.T) {
	cases := map[string]string{
		"  1D-1M-1N  ":     "1D-1M-1N",
		"1D  --  1M":       "1D-1M",
		"1H -- ( X ) - 2H": "1H-(X)-2H",
		"1C ,, 1D ,":       "1C, 1D",
		"":                 "",
	}
	for in, want := range cases {
		if got := NormalizeFilterText(in); got != want {
			t.Errorf("NormalizeFilterText(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestOpponentCallsCanBeSlippedInAnywhere(t *testing.T) {
	runSeqCases(t, []seqCase{
		// a pattern describes our auction; whatever the opponents do in between should
		// not stop it matching
		{[]string{"1D (Pass) 1H"}, "1D-1H", true},
		{[]string{"1D (1S) 1H"}, "1D-1H", true},
		{[]string{"1D (X) 1H"}, "1D-1H", true},
		{[]string{"1D (2C)", "1H"}, "1D-1H", true},
		{[]string{"1D (1S) 2C", "1H"}, "1D-1H", false}, // our own calls stay in order
		// naming the opponents pins them down: it must be the very next call
		{[]string{"1D (X) 1H"}, "1D-(X)-1H", true},
		{[]string{"1D (1S) 1H"}, "1D-(X)-1H", false},
		{[]string{"1D (Pass) 1H"}, "1D-(X)-1H", false},
		// a bare `*` is any call at all, opponents included, so it counts depth
		{[]string{"1D (1S) 1H"}, "*-*-*", true},
		{[]string{"1D (Pass) 1H"}, "*-*-*", false},
	})
}

func TestUnbracketedTokensAreOurCalls(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C (Pass) 1H"}, "1C", true},
		{[]string{"(1C) X"}, "1C", false},
		{[]string{"(1C) X"}, "(1C)", true},
		{[]string{"(1C) X"}, "*", true}, // the bare wildcard is the exception
	})
}

func TestFirstTokenAnchorsToTheOpeningCall(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"2C (Pass) 2D"}, "2C", true},
		{[]string{"(1H) 2C"}, "2C", false},
		{[]string{"(1H) 2C"}, "(1H)-2C", true},
		{[]string{"(1H) 2C"}, "(*)-2C", true},
	})
}

func TestSeparatorsAreInterchangeable(t *testing.T) {
	for _, text := range []string{"1D--1H--1N", "1D 1H 1N", "1D - 1H -- 1N", "1D-1H 1N", "1D  --1H-  1N"} {
		if got := CanonicalPatternText(text); got != "1D-1H-1N" {
			t.Errorf("CanonicalPatternText(%q) = %q", text, got)
		}
		if !matches(t, []string{"1D (Pass) 1H", "1N"}, text) {
			t.Errorf("pattern %q did not match the auction it describes", text)
		}
	}
	pf := ParseFilter("1D 1H, 2C-2D", nil)
	if pf.CanonicalText != "1D-1H, 2C-2D" || len(pf.Errors) != 0 {
		t.Errorf("ParseFilter canonical = %q errors = %v", pf.CanonicalText, pf.Errors)
	}
}

func TestCaseInsensitiveExceptMinors(t *testing.T) {
	same := [][2]string{
		{"1d--1h--1n", "1D--1H--1N"},
		{"1h--(x)--2h", "1H--(X)--2H"},
		{"1d--pass", "1D--PASS"},
		{"1d--(1!H)", "1D--(1!h)"},
		{"1M-3x", "1M-3*"},
	}
	for _, pair := range same {
		if !patternsEqual(mustPattern(t, pair[0]), mustPattern(t, pair[1])) {
			t.Errorf("%q and %q parsed differently", pair[0], pair[1])
		}
	}
	// ...but M (majors) and m (minors) stay distinct
	if got := mustPattern(t, "1d--1M")[1].Alternatives[0].SuitClass; got != bids.Majors {
		t.Errorf("1M suit class = %v", got)
	}
	if got := mustPattern(t, "1D--1m")[1].Alternatives[0].SuitClass; got != bids.Minors {
		t.Errorf("1m suit class = %v", got)
	}
	if patternsEqual(mustPattern(t, "1D--1M"), mustPattern(t, "1D--1m")) {
		t.Error("1M and 1m must not be the same pattern")
	}
}

func TestWhitespaceAndCaseDoNotChangeMatching(t *testing.T) {
	if !matches(t, []string{"1D (Pass) 1S", "1N"}, "  1d  --  1M  --  1n ") {
		t.Error("whitespace and case changed the match")
	}
}

func TestParseFilterCommaIsOr(t *testing.T) {
	pf := ParseFilter("1C, 1D--1M", nil)
	if len(pf.Patterns) != 2 || len(pf.Errors) != 0 {
		t.Fatalf("patterns = %d errors = %v", len(pf.Patterns), pf.Errors)
	}
	if !SequenceMatchesAny([]string{"1C (Pass) 1H"}, pf.Patterns) {
		t.Error("first alternative did not match")
	}
	if !SequenceMatchesAny([]string{"1D (Pass) 1S"}, pf.Patterns) {
		t.Error("second alternative did not match")
	}
	if SequenceMatchesAny([]string{"1H (Pass) 2H"}, pf.Patterns) {
		t.Error("an auction matching neither alternative matched")
	}
}

func TestParseFilterReportsBadEntryButKeepsTheRest(t *testing.T) {
	pf := ParseFilter("1C, nonsense!!, 1D", nil)
	if len(pf.Errors) != 1 || pf.Errors[0] != "nonsense!!" {
		t.Errorf("errors = %v", pf.Errors)
	}
	if len(pf.Patterns) != 2 || pf.CanonicalText != "1C, 1D" {
		t.Errorf("patterns = %d canonical = %q", len(pf.Patterns), pf.CanonicalText)
	}
}

func testTopics() *Topics {
	return NewTopics([]Topic{
		{Name: "Opening 1C", Patterns: []string{"1C"}},
		{Name: "Major raises", Patterns: []string{"1M--2M", "1M--3M"}},
		{Name: "Minor raises", Patterns: []string{"1m--2m"}},
	})
}

func TestTopicsResolution(t *testing.T) {
	topics := testTopics()
	cases := map[string]string{
		"  opening   1c ": "Opening 1C",   // exact, case- and whitespace-insensitive
		"major":           "Major raises", // unique prefix
		"1c":              "Opening 1C",   // unique substring
		"raises":          "",             // ambiguous: major and minor both
		"m":               "",             // prefix hits two topics
		"slam":            "",             // unknown
	}
	for text, want := range cases {
		index := topics.MatchName(text, true)
		got := ""
		if index >= 0 {
			got = topics.List[index].Name
		}
		if got != want {
			t.Errorf("MatchName(%q) = %q, want %q", text, got, want)
		}
	}
}

func TestParseFilterExpandsTopics(t *testing.T) {
	topics := NewTopics([]Topic{{Name: "Major raises", Patterns: []string{"1M--2M", "1M--3M"}}})
	pf := ParseFilter("major", topics)
	if len(pf.TopicNames) != 1 || pf.TopicNames[0] != "Major raises" {
		t.Fatalf("topic names = %v", pf.TopicNames)
	}
	if pf.CanonicalText != "Major raises" || len(pf.Patterns) != 2 {
		t.Errorf("canonical = %q patterns = %d", pf.CanonicalText, len(pf.Patterns))
	}
	if !SequenceMatchesAny([]string{"1H (Pass) 3H"}, pf.Patterns) {
		t.Error("3H raise did not match")
	}
	if SequenceMatchesAny([]string{"1H (Pass) 4H"}, pf.Patterns) {
		t.Error("4H is not one of the topic's patterns")
	}
}

func TestParseFilterMixesTopicsAndPatterns(t *testing.T) {
	topics := NewTopics([]Topic{{Name: "Opening 1C", Patterns: []string{"1C"}}})
	pf := ParseFilter("opening 1c, 1d -- 1M", topics)
	if len(pf.TopicNames) != 1 || pf.TopicNames[0] != "Opening 1C" {
		t.Fatalf("topic names = %v", pf.TopicNames)
	}
	if pf.CanonicalText != "Opening 1C, 1D-1M" {
		t.Errorf("canonical = %q", pf.CanonicalText)
	}
	if !SequenceMatchesAny([]string{"1C (Pass) 1H"}, pf.Patterns) ||
		!SequenceMatchesAny([]string{"1D (Pass) 1H"}, pf.Patterns) {
		t.Error("one of the two entries did not match")
	}
}

func TestValidPatternBeatsFuzzyTopicName(t *testing.T) {
	topics := NewTopics([]Topic{{Name: "Opening 1C strong", Patterns: []string{"1C--2N"}}})
	pf := ParseFilter("1C", topics)
	if len(pf.TopicNames) != 0 || pf.CanonicalText != "1C" {
		t.Errorf("topic names = %v canonical = %q", pf.TopicNames, pf.CanonicalText)
	}
	if !SequenceMatchesAny([]string{"1C (Pass) 1H"}, pf.Patterns) {
		t.Error("the pattern did not match")
	}
	// ...while a non-pattern prefix still resolves to the topic
	if names := ParseFilter("strong", topics).TopicNames; len(names) != 1 {
		t.Errorf("fuzzy topic names = %v", names)
	}
}

func TestPreparedBidsMatchTheUnpreparedPath(t *testing.T) {
	seqs := [][]string{{"1C (Pass) 1H", "2D"}, {"1D (X)", "2H"}, {"1H (Pass) 2H"}}
	pats := []Pattern{mustPattern(t, "1C"), mustPattern(t, "1D--(X)")}
	prepared := PrepareSequenceBids(seqs)
	want := []bool{true, true, false}
	for i, variants := range prepared {
		if got := BidsMatchAny(variants, pats); got != want[i] {
			t.Errorf("prepared[%d] = %v, want %v", i, got, want[i])
		}
		if got := SequenceMatchesAny(seqs[i], pats); got != want[i] {
			t.Errorf("unprepared[%d] = %v, want %v", i, got, want[i])
		}
	}
}

func TestEmptyFilterIsFalsey(t *testing.T) {
	pf := ParseFilter("   ", nil)
	if len(pf.Patterns) != 0 || len(pf.Errors) != 0 {
		t.Errorf("patterns = %v errors = %v", pf.Patterns, pf.Errors)
	}
}

func TestTopicsWithUnparseablePatternsAreSkipped(t *testing.T) {
	topics := NewTopics([]Topic{
		{Name: "Everywhere", Patterns: []string{"1C"}},
		{Name: "Broken", Patterns: []string{"not a bid"}},
		{Name: "Empty", Patterns: nil},
	})
	if topics.Len() != 1 || topics.List[0].Name != "Everywhere" {
		t.Errorf("topics = %+v", topics.List)
	}
}

// --- alternation (`/`) and the `*` wildcard ---------------------------------

func TestPatternAlternationSameLevel(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1N (Pass) 2D"}, "1N--2D/2H", true},
		{[]string{"1N (Pass) 2H"}, "1N--2D/2H", true},
		{[]string{"1N (Pass) 2S"}, "1N--2D/2H", false},
		// ...and it is not two positions: 1N-2D-2H must not be what it means
		{[]string{"1N (Pass) 2D", "3C"}, "1N--2D/2H", true},
	})
}

func TestPatternAlternationAcrossLevels(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1H (Pass) 3S"}, "1M--3S/4C", true},
		{[]string{"1S (Pass) 4C"}, "1M--3S/4C", true},
		{[]string{"1H (Pass) 4S"}, "1M--3S/4C", false}, // no cross-pairing
		{[]string{"1H (Pass) 3C"}, "1M--3S/4C", false},
	})
}

func TestPatternAlternationBracketsApplyToEveryBranch(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C (2D)"}, "1C--(2D/2H)", true},
		{[]string{"1C (2H)"}, "1C--(2D/2H)", true},
		{[]string{"1C (Pass) 2D"}, "1C--(2D/2H)", false}, // ours, not theirs
	})
}

func TestWildcardDenominationPattern(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1H (Pass) 3D"}, "1M--3*", true},
		{[]string{"1S (Pass) 3N"}, "1M--3*", true},
		{[]string{"1H (Pass) 4D"}, "1M--3*", false}, // level still binds
	})
}

func TestAlternationInTheRecordedAuction(t *testing.T) {
	seq := []string{"1C", "1D", "1N/2C", "2D"}
	runSeqCases(t, []seqCase{
		{seq, "1C-1D-1N-2D", true},
		{seq, "1C-1D-2C-2D", true},
		{seq, "1C-1D-1H-2D", false},
		// and it stays ONE position: 2D follows it, nothing was inserted
		{seq, "1C-1D-1N-2C", false},
	})
}

func TestCanonicalTextKeepsAlternation(t *testing.T) {
	cases := map[string]string{
		"1n -- 2d/2h": "1N-2D/2H",
		"1m--3*":      "1m-3*",
	}
	for in, want := range cases {
		if got := CanonicalPatternText(in); got != want {
			t.Errorf("CanonicalPatternText(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCallPatternAlternatives(t *testing.T) {
	pat := mustPattern(t, "1D--1M")
	if got := pat[1].Alternatives[0].SuitClass; got != bids.Majors {
		t.Errorf("suit class = %v", got)
	}
	if got := pat[1].Alternatives[0].Level; got != 1 {
		t.Errorf("level = %d", got)
	}
	if got := len(mustPattern(t, "1D--3S/4C")[1].Alternatives); got != 2 {
		t.Errorf("alternatives = %d", got)
	}
}

// --- suit-class variables ---------------------------------------------------

func TestRepeatedClassMeansTheSameSuit(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1HS", "2M"}, "1H-2H", true},
		{[]string{"1HS", "2M"}, "1S-2S", true},
		{[]string{"1HS", "2M"}, "1H-2S", false},
		{[]string{"1HS", "2M"}, "1S-2H", false},
		{[]string{"1HS", "2M"}, "1M-2M", true}, // the class-level question still answers yes
		{[]string{"1HS", "2M", "3M"}, "1S-2S-3S", true},
		{[]string{"1HS", "2M", "3M"}, "1S-2S-3H", false},
		{[]string{"2CD", "3m"}, "2C-3C", true}, // minors bind the same way
		{[]string{"2CD", "3m"}, "2C-3D", false},
	})
}

func TestOtherMajorResolvesAgainstTheAuction(t *testing.T) {
	long := []string{"1C", "1HS", "2C", "2D", "2oM"}
	runSeqCases(t, []seqCase{
		{[]string{"1H", "2oM"}, "1H-2S", true},
		{[]string{"1H", "2oM"}, "1H-2H", false},
		{long, "1C-1H-2C-2D-2S", true},
		{long, "1C-1S-2C-2D-2H", true},
		{long, "1C-1H-2C-2D-2H", false},
	})
}

func TestWhatDoesNotBind(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1HS", "3CD"}, "1H-3D", true}, // different classes are unrelated
		{[]string{"3x", "4x"}, "3H-4S", true},   // two wildcards are two unknown suits
		{[]string{"2M"}, "2S", true},            // a lone class is as permissive as before
		{[]string{"2M"}, "2H", true},            //
		{[]string{"1H", "1S"}, "1H-1S", true},   // two concrete majors are just themselves
	})
}

func TestXAndOMInPatterns(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1H (Pass) 3D"}, "1M-3x", true},
		// `oM` typed as a pattern has nothing to be other than, so it asks the class
		{[]string{"1C (Pass) 2H"}, "1C-2oM", true},
		{[]string{"1C (Pass) 2D"}, "1C-2oM", false},
	})
}

func TestLinkBidsInAnAuction(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C", "[1HS](#1C--1HS)"}, "1C-1H", true},
		{[]string{"1C", "[1HS](#1C--1HS)"}, "1C-2H", false},
	})
}

func TestAnyRowAnswersToAnyPattern(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C", "(any)"}, "1C-(X)", true},
		{[]string{"1C", "(any)"}, "1C-(2H)", true},
		{[]string{"1C", "(any)"}, "1C-(*)", true},
		{[]string{"1C", "(any)"}, "1C-2H", false}, // whose call it was still matters
		{[]string{"1C", "any"}, "1C-2H", true},
		{[]string{"1C", "any"}, "1C-(2H)", false},
		// and it does not swallow the rest of the auction
		{[]string{"1C", "(any)", "2D"}, "1C-(X)-2D", true},
		{[]string{"1C", "(any)", "2D"}, "1C-(X)-3D", false},
	})
}

func TestNextResolvesToTheStepAboveItsParent(t *testing.T) {
	seq := []string{"1C", "3C", "4HS", "next"}
	runSeqCases(t, []seqCase{
		{seq, "1C-3C-4H-4S", true},
		{seq, "1C-3C-4S-4N", true},
		{seq, "1C-3C-4H-4N", false}, // never the cross pairing
		{seq, "1C-3C-4S-4S", false},
		{[]string{"4H", "next"}, "4H-4S", true},
		{[]string{"4H", "next"}, "4H-5C", false},
		{[]string{"4N", "next"}, "4N-5C", true}, // notrump rolls to the next level
		{[]string{"4HS", "next", "5C"}, "4S-4N-5C", true},
		{[]string{"4HS", "next", "5C"}, "4H-4N-5C", false},
	})
}

func TestNextStaysUnresolvedWithoutAParentBid(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C", "any", "next"}, "1C-2H-2S", false},
		{[]string{"next"}, "2C", false},
		{[]string{"1C", "Pass", "next"}, "1C-P-2C", false},
	})
}

func TestNextAfterABoundClass(t *testing.T) {
	seq := []string{"1HS", "2M", "next"}
	runSeqCases(t, []seqCase{
		{seq, "1S-2S-2N", true},
		{seq, "1H-2H-2S", true},
		{seq, "1H-2S-2N", false},
		{seq, "1S-2S-3C", false},
	})
}

func TestJumpIsAJumpInANewSuit(t *testing.T) {
	seq := []string{"2H", "2S", "jump"}
	runSeqCases(t, []seqCase{
		{seq, "2H-2S-4C", true},
		{seq, "2H-2S-4D", true},
		{seq, "2H-2S-3C", false}, // that is no jump
		{seq, "2H-2S-4H", false}, // hearts were bid
		{seq, "2H-2S-4N", false}, // never notrump
		{seq, "2H-2S-3N", false},
	})
}

func TestJumpSkipsSuitsAlreadyBid(t *testing.T) {
	seq := []string{"1D", "1S", "jump"}
	runSeqCases(t, []seqCase{
		{seq, "1D-1S-3C", true},
		{seq, "1D-1S-3H", true},
		{seq, "1D-1S-3D", false},
		{seq, "1D-1S-3S", false},
		{seq, "1D-1S-2C", false}, // the cheapest bid
	})
}

func TestDoubleJumpIsOneHigher(t *testing.T) {
	seq := []string{"1D", "1S", "doubleJump"}
	runSeqCases(t, []seqCase{
		{seq, "1D-1S-4C", true},
		{seq, "1D-1S-4H", true},
		{seq, "1D-1S-3C", false},
	})
}

func TestJumpWithoutAResolvableParent(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C", "any", "jump"}, "1C-2H-3S", false},
		{[]string{"jump"}, "3S", false},
	})
}

func TestCueIsTheLowestAvailableBidInTheirSuit(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"(1H)", "1S", "cue"}, "(1H)-1S-2H", true},
		{[]string{"(1H)", "1S", "cue"}, "(1H)-1S-3H", false}, // not the lowest
		{[]string{"(1H)", "1S", "cue"}, "(1H)-1S-2C", false}, // not their suit
		// with two of their suits shown, only the cheaper cue counts
		{[]string{"(1H)", "(2D)", "2S", "cue"}, "(1H)-(2D)-2S-3D", true},
		{[]string{"(1H)", "(2D)", "2S", "cue"}, "(1H)-(2D)-2S-3H", false},
		// a level named on the token overrides "lowest"
		{[]string{"(1H)", "1S", "3cue"}, "(1H)-1S-3H", true},
		{[]string{"(1H)", "1S", "3cue"}, "(1H)-1S-2H", false},
		// nothing to cue: unresolved, so unmatched
		{[]string{"1C", "1H", "cue"}, "1C-1H-2H", false},
	})
}

func TestNewIsASuitNeitherSideHasBid(t *testing.T) {
	seq := []string{"1D", "1S", "new"}
	runSeqCases(t, []seqCase{
		{seq, "1D-1S-2C", true},
		{seq, "1D-1S-2H", true},
		{seq, "1D-1S-2D", false}, // ours
		{seq, "1D-1S-2S", false}, // ours
		{seq, "1D-1S-2N", false}, // not a suit
		{seq, "1D-1S-3C", false}, // that is a jump
		// the opponents' suit is not new either
		{[]string{"1D", "(1H)", "1S", "new"}, "1D-(1H)-1S-2H", false},
		// a level named on the token pins it
		{[]string{"1D", "1S", "3new"}, "1D-1S-3C", true},
		{[]string{"1D", "1S", "3new"}, "1D-1S-2C", false},
	})
}

func TestAtLeastTokenCoversEverythingAbove(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C", "(2N+)"}, "1C-(2N)", true},
		{[]string{"1C", "(2N+)"}, "1C-(3C)", true},
		{[]string{"1C", "(2N+)"}, "1C-(7N)", true},
		{[]string{"1C", "(2N+)"}, "1C-(2S)", false},
		{[]string{"1C", "(2N+)"}, "1C-(1N)", false},
		{[]string{"1C", "(2x+)"}, "1C-(2C)", true}, // `2x+` starts at the bottom of the level
		{[]string{"1C", "(2x+)"}, "1C-(1S)", false},
	})
}

func TestCatchAllRowsPromiseDifferentAmounts(t *testing.T) {
	over := []string{"1C", "1N", "(overcall)"}
	butPass := []string{"1C", "1N", "(bid)"}
	runSeqCases(t, []seqCase{
		{over, "1C-1N-(2H)", true},
		{over, "1C-1N-(X)", false}, // a bid, not a double
		{over, "1C-1N-2H", false},  // theirs, not ours
		{butPass, "1C-1N-(2H)", true},
		{butPass, "1C-1N-(X)", true},
		{butPass, "1C-1N-(XX)", true},
		// `other` is the same catch-all as `any`, not a statement about siblings
		{[]string{"1C", "1D", "other"}, "1C-1D-2D", true},
		{[]string{"1C", "1D", "other"}, "1C-1D-P", true},
	})
}

func TestGameIsAGameContract(t *testing.T) {
	for _, call := range []string{"3N", "4H", "4S", "5C", "5D"} {
		if !matches(t, []string{"1C", "game"}, "1C-"+call) {
			t.Errorf("game did not cover %s", call)
		}
	}
	runSeqCases(t, []seqCase{
		{[]string{"1C", "game"}, "1C-4N", false},
		{[]string{"1C", "game"}, "1C-3S", false},
	})
}

func TestSuitIsASimpleNewSuit(t *testing.T) {
	seq := []string{"1D", "1S", "suit"}
	runSeqCases(t, []seqCase{
		{seq, "1D-1S-2C", true},
		{seq, "1D-1S-2H", true},
		{seq, "1D-1S-2N", false}, // never notrump
		{seq, "1D-1S-3C", false}, // that is a jump
		{seq, "1D-1S-2D", false}, // already bid
	})
}

func TestLevelYIsANewSuit(t *testing.T) {
	seq := []string{"1D", "1S", "2Y"}
	runSeqCases(t, []seqCase{
		{seq, "1D-1S-2C", true},
		{seq, "1D-1S-2H", true},
		{seq, "1D-1S-2D", false}, // already bid
		{seq, "1D-1S-2N", false}, // not a suit
		{seq, "1D-1S-3C", false}, // wrong level
	})
}

func TestCueOverCuesThePlayerOnOurRight(t *testing.T) {
	seq := []string{"(1C)", "P", "(1HS)", "CueOver"}
	runSeqCases(t, []seqCase{
		{seq, "(1C)-P-(1H)-2H", true},
		{seq, "(1C)-P-(1S)-2S", true},
		{seq, "(1C)-P-(1H)-1S", false}, // their suit is what *they* bid
		{seq, "(1C)-P-(1H)-2C", false}, // not the first opponent's suit
		{[]string{"(1C)", "P", "(1HS)", "cue"}, "(1C)-P-(1H)-2C", true},
		// a wildcard opponent bid: whatever they bid is the suit to cue
		{[]string{"(1C)", "P", "(1x)", "CueOver"}, "(1C)-P-(1D)-2D", true},
		// nothing to cue over
		{[]string{"(1C)", "P", "(X)", "CueOver"}, "(1C)-P-(X)-2C", false},
	})
}

func TestStepResponsesToAnArtificialAsk(t *testing.T) {
	for _, call := range []string{"5C", "5D", "5H", "5S", "5N"} {
		if !matches(t, []string{"4N", "xstep"}, "4N-"+call) {
			t.Errorf("xstep did not cover %s", call)
		}
	}
	nested := []string{"4N", "xstep", "1step"}
	runSeqCases(t, []seqCase{
		{[]string{"4N", "xstep"}, "4N-6C", false}, // off the ladder
		{[]string{"4N", "1step"}, "4N-5C", true},  // a numbered step is one rung
		{[]string{"4N", "1step"}, "4N-5D", false},
		{nested, "4N-5C-5D", true},
		{nested, "4N-5H-5S", true},
		{nested, "4N-5C-5H", false},
		{[]string{"any", "xstep"}, "*-2C", false}, // nothing to answer
		{[]string{"7N", "xstep"}, "7N-7N", false}, // nowhere left to go
	})
}

func TestRaiseSupportsPartnersLastSuit(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"2HS", "raise"}, "2H-3H", true},
		{[]string{"2HS", "raise"}, "2S-3S", true},
		{[]string{"2HS", "raise"}, "2H-3S", false},
		// an opponent in between does not make their suit ours
		{[]string{"1H", "(2C)", "raise"}, "1H-(2C)-2H", true},
		{[]string{"1H", "(2C)", "raise"}, "1H-(2C)-3C", false},
		// opener raising responder's suit: partner's last is the 2C, not the 1H
		{[]string{"1H", "2C", "raise"}, "1H-2C-3C", true},
		{[]string{"1H", "2C", "raise"}, "1H-2C-2H", false},
		// bracketed, it is *their* partner's suit
		{[]string{"(1H)", "X", "(raise)"}, "(1H)-X-(2H)", true},
		{[]string{"(1H)", "X", "(raise)"}, "(1H)-X-(2S)", false},
		// nobody on our side has bid
		{[]string{"(1H)", "raise"}, "(1H)-2H", false},
	})
}

func TestJumpRaiseAndLevelledRaise(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1H", "(2C)", "jumpRaise"}, "1H-(2C)-3H", true},
		{[]string{"1H", "(2C)", "jumpRaise"}, "1H-(2C)-2H", false},
		{[]string{"1H", "2C", "3raise"}, "1H-2C-3C", true},
	})
}

func TestResolutionMeasuresFromTheLastBidNotTheLastCall(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1H", "X", "new"}, "1H-X-2C", true},
		{[]string{"(1H)", "X", "(raise)"}, "(1H)-X-(2H)", true},
	})
}

func TestCueLowAndCueHighPickBetweenTheirSuits(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"(1H)", "P", "(2S)", "cueLow"}, "(1H)-P-(2S)-3H", true},
		{[]string{"(1H)", "P", "(2S)", "cueLow"}, "(1H)-P-(2S)-3S", false},
		{[]string{"(1H)", "P", "(2S)", "cueHi"}, "(1H)-P-(2S)-3S", true},
		{[]string{"(1H)", "P", "(2S)", "cueHi"}, "(1H)-P-(2S)-3H", false},
		// over a *conventional* two-suiter only one call is on the table
		{[]string{"1C", "(2C)", "cueLow"}, "1C-(2C)-3C", false},
	})
}

func TestHigherIsACatchAllBid(t *testing.T) {
	seq := []string{"(1C)", "1HS", "(higher)"}
	runSeqCases(t, []seqCase{
		{seq, "(1C)-1H-(2C)", true},
		{seq, "(1C)-1H-(1N)", true},
		{seq, "(1C)-1H-(X)", false}, // a bid, not a double
		{seq, "(1C)-1H-(P)", false},
	})
}

func TestDenominationWithoutALevelIsASimpleBid(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C", "2C", "(2S)", "NT"}, "1C-2C-(2S)-2N", true},
		{[]string{"1C", "2C", "(2S)", "NT"}, "1C-2C-(2S)-3N", false},
		{[]string{"1C", "1D", "major"}, "1C-1D-1H", true},
		{[]string{"1C", "1D", "major"}, "1C-1D-1S", true},
		{[]string{"1C", "1D", "major"}, "1C-1D-2H", false},
		{[]string{"1C", "1D", "major"}, "1C-1D-1N", false},
		{[]string{"2S", "m"}, "2S-3C", true},
		{[]string{"2S", "m"}, "2S-3D", true},
		{[]string{"2S", "m"}, "2S-3H", false},
		{[]string{"2S", "m"}, "2S-2N", false},
		// both halves of an alternation of strains resolve
		{[]string{"1N", "(2H)", "!c/!d"}, "1N-(2H)-3C", true},
		{[]string{"1N", "(2H)", "!c/!d"}, "1N-(2H)-3D", true},
		{[]string{"1N", "(2H)", "!c/!d"}, "1N-(2H)-3H", false},
	})
}

func TestOtherSuitIsTheNewSuitRule(t *testing.T) {
	seq := []string{"(1H)", "1S", "(otherSuit)"}
	runSeqCases(t, []seqCase{
		{seq, "(1H)-1S-(2C)", true},
		{seq, "(1H)-1S-(2D)", true},
		{seq, "(1H)-1S-(2H)", false}, // partner's
		{seq, "(1H)-1S-(1N)", false}, // not a suit
	})
}

func TestStrainPlusIsAnyLevelInThatStrain(t *testing.T) {
	seq := []string{"1N", "(2H)", "!c+/!d+"}
	for _, call := range []string{"3C", "3D", "4C", "5D", "7C"} {
		if !matches(t, seq, "1N-(2H)-"+call) {
			t.Errorf("!c+/!d+ did not cover %s", call)
		}
	}
	runSeqCases(t, []seqCase{
		{seq, "1N-(2H)-3H", false}, // wrong strain
		{seq, "1N-(2H)-2C", false}, // not legal
		// the bare form stays the simple bid
		{[]string{"1N", "(2H)", "!c/!d"}, "1N-(2H)-3C", true},
		{[]string{"1N", "(2H)", "!c/!d"}, "1N-(2H)-4C", false},
	})
}

func TestSlamBidsTheAgreedSuitAtTheSlamLevel(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"4HS", "slam"}, "4H-6H", true},
		{[]string{"4HS", "slam"}, "4S-6S", true},
		{[]string{"4HS", "slam"}, "4H-7H", true},
		{[]string{"4HS", "slam"}, "4H-6S", false}, // pinned
		{[]string{"4HS", "slam"}, "4H-5H", false},
		{[]string{"1H", "2C", "6slam"}, "1H-2C-6C", true},
		{[]string{"1H", "2C", "6slam"}, "1H-2C-7C", false},
	})
}

func TestNextSuitSkipsNotrump(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C", "2H", "nextSuit"}, "1C-2H-2S", true},
		{[]string{"1C", "2H", "nextSuit"}, "1C-2H-2N", false},
		{[]string{"1C", "2S", "nextSuit"}, "1C-2S-3C", true},
		{[]string{"1C", "2S", "nextSuit"}, "1C-2S-2N", false},
	})
}

func TestFourthSuitIsTheOneLeft(t *testing.T) {
	runSeqCases(t, []seqCase{
		{[]string{"1C", "1D", "1H", "4thSuit"}, "1C-1D-1H-1S", true},
		{[]string{"1C", "1D", "1H", "4thSuit"}, "1C-1D-1H-2C", false},
		// with two suits still unbid it is not describing one call
		{[]string{"1C", "1D", "4thSuit"}, "1C-1D-1H", false},
	})
}

func patternsEqual(a, b Pattern) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if len(a[i].Alternatives) != len(b[i].Alternatives) {
			return false
		}
		for j := range a[i].Alternatives {
			if a[i].Alternatives[j] != b[i].Alternatives[j] {
				return false
			}
		}
	}
	return true
}
