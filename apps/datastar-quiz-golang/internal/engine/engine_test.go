package engine

import (
	"strings"
	"testing"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
)

// Ported from `apps/datastar-quiz/tests/test_engine.py`, which is itself asserted against
// the panel app's own `points` function. The scoring is the one piece of this app where a
// silent one-off would look like a game-design decision rather than a bug.

func questionOf(candidates []string, answerCandidate string) Question {
	if answerCandidate == "" && len(candidates) > 0 {
		answerCandidate = candidates[0]
	}
	return Question{
		Candidates:      candidates,
		Answer:          "the description",
		AnswerCandidate: answerCandidate,
		ChoiceType:      Auctions,
	}
}

func TestSecondsForDifficultyMatchesThePanelTable(t *testing.T) {
	// difficulty * secondsPerLevel[difficulty]
	cases := map[int]float64{4: 32, 5: 35, 6: 36, 7: 35, 8: 32, 9: 36}
	for difficulty, want := range cases {
		if got := SecondsForDifficulty(difficulty); got != want {
			t.Errorf("SecondsForDifficulty(%d) = %v, want %v", difficulty, got, want)
		}
	}
}

func TestPercentTimeLeft(t *testing.T) {
	cases := []struct {
		elapsed, allowed float64
		want             int
	}{
		{0, 10, 100},
		{5, 10, 50},
		{12, 10, 0}, // never negative
		{1, 0, 0},   // no allowance is no bonus, not a division by zero
	}
	for _, c := range cases {
		if got := PercentTimeLeft(c.elapsed, c.allowed); got != c.want {
			t.Errorf("PercentTimeLeft(%v, %v) = %d, want %d", c.elapsed, c.allowed, got, c.want)
		}
	}
}

func TestClampDifficulty(t *testing.T) {
	cases := []struct {
		value any
		want  int
	}{
		{float64(6), 6},
		{"7", 7},
		{float64(99), MaxDifficulty},
		{float64(1), MinDifficulty},
		{nil, InitialDifficulty},
		{"nonsense", InitialDifficulty},
		{[]any{}, InitialDifficulty},
	}
	for _, c := range cases {
		if got := ClampDifficulty(c.value); got != c.want {
			t.Errorf("ClampDifficulty(%#v) = %d, want %d", c.value, got, c.want)
		}
	}
}

// TestPointsAreCandidateLengthsWithTwoMultipliers pins the panel formula: one point per
// token across every candidate, +10% per streak step (capped at doubling), + the time bonus
// as a proportion of the same base.
func TestPointsAreCandidateLengthsWithTwoMultipliers(t *testing.T) {
	question := questionOf([]string{"1C", "1H", "2N"}, "")
	base := 3
	cases := []struct {
		streak, percentLeft int
		want                Points
	}{
		{0, 0, Points{base, 0, 0}},
		{1, 0, Points{base, 0, 0}},          // a streak of one is not yet a bonus
		{2, 0, Points{base, 1, 0}},          // round(3 * 0.2) = 1
		{5, 0, Points{base, 2, 0}},          // round(3 * 0.5) = 2 (half to even)
		{12, 0, Points{base, 3, 0}},         // the multiplier caps at 1.0
		{0, 100, Points{base, 0, base}},     // a full clock doubles the base
		{0, 37, Points{base, 0, 1}},         // round(3 * 0.37) = 1
		{12, 100, Points{base, base, base}}, //
	}
	for _, c := range cases {
		if got := ScorePoints(question, c.streak, c.percentLeft); got != c.want {
			t.Errorf("ScorePoints(streak %d, %d%%) = %+v, want %+v", c.streak, c.percentLeft, got, c.want)
		}
	}
	// the `-->` joiner is not a token
	if got := ScorePoints(questionOf([]string{"1D --> 1S --> 3N", "1C"}, ""), 0, 0); got.FromCandidateLengths != 4 {
		t.Errorf("the auction separator was counted: %+v", got)
	}
	// no candidates, no points, no panic
	if got := ScorePoints(questionOf(nil, ""), 5, 100); got.Total() != 0 {
		t.Errorf("an empty question scored %+v", got)
	}
}

func TestCorrectAnswerScoresAndStreaks(t *testing.T) {
	score := NewScore()
	question := questionOf([]string{"1C 1H 2N", "1D 1S"}, "1C 1H 2N")

	outcome, lastPoints := Answer(&score, AnswerInput{
		Question: question, Candidate: "1C 1H 2N", PercentLeft: 100,
		LadderMode: true, TargetPct: 70, PointsGoal: PointsGoal,
	})

	if !outcome.Correct || score.Streak != 1 || score.QuestionsCorrect != 1 || score.QuestionsAttempted != 1 {
		t.Fatalf("outcome %+v, score %+v", outcome, score)
	}
	if score.TotalPoints != lastPoints || lastPoints <= 0 {
		t.Errorf("total %d, last correct %d", score.TotalPoints, lastPoints)
	}
	texts := toastTexts(outcome)
	if texts[0] != "Correct!" || !strings.HasPrefix(texts[1], "+") {
		t.Errorf("the first two beats were %q", texts[:2])
	}
	// the running total shown alongside each toast ends at the final score
	last := 0
	for _, toast := range outcome.Toasts {
		if toast.HasPointsAfter {
			last = toast.PointsAfter
		}
	}
	if last != score.TotalPoints {
		t.Errorf("the last instalment showed %d, the score is %d", last, score.TotalPoints)
	}
}

func TestWrongAnswerResetsStreakAndChargesLadderMode(t *testing.T) {
	score := NewScore()
	score.TotalPoints, score.Streak = 100, 4
	question := questionOf([]string{"1C", "1D"}, "1D")

	outcome, lastPoints := Answer(&score, AnswerInput{
		Question: question, Candidate: "1C", PercentLeft: 50,
		LadderMode: true, TargetPct: 70, LastCorrectPoints: 30, PointsGoal: PointsGoal,
	})

	if outcome.Correct || score.Streak != 0 {
		t.Fatalf("outcome %+v, streak %d", outcome, score.Streak)
	}
	if score.TotalPoints != 70 {
		t.Errorf("total = %d, want 70 (100 less the last correct answer's worth)", score.TotalPoints)
	}
	if lastPoints != 30 {
		t.Errorf("last correct points = %d, want 30 -- it is what the NEXT wrong answer costs", lastPoints)
	}
	texts := strings.Join(toastTexts(outcome), "|")
	if !strings.Contains(texts, "Not quite") || !strings.Contains(texts, "Ladder mode: -30 points") {
		t.Errorf("toasts = %q", texts)
	}
	// the answer itself is revealed in the card, not read out in a toast the player waits behind
	pause := 0.0
	for _, toast := range outcome.Toasts {
		pause += toast.Pause
	}
	if pause >= 2.0 {
		t.Errorf("a wrong answer blocks for %.1fs; it should be brief", pause)
	}
}

func TestNoLadderChargeWhenScoreAlreadyZero(t *testing.T) {
	score := NewScore()
	outcome, _ := Answer(&score, AnswerInput{
		Question: questionOf([]string{"1C", "1D"}, "1D"), Candidate: "1C",
		LadderMode: true, TargetPct: 70, LastCorrectPoints: 30, PointsGoal: PointsGoal,
	})
	if score.TotalPoints != 0 {
		t.Errorf("total = %d, want 0", score.TotalPoints)
	}
	if strings.Contains(strings.Join(toastTexts(outcome), "|"), "Ladder mode") {
		t.Error("a zero score should not be told it lost points")
	}
}

func TestMilestonesAwardSkipsOnceEach(t *testing.T) {
	score := NewScore()
	score.TotalPoints, score.QuestionsAttempted, score.QuestionsCorrect = PointsGoal-1, 9, 9
	question := questionOf([]string{"1C 1H 2N 3C 4D", "1D"}, "1C 1H 2N 3C 4D")

	outcome, _ := Answer(&score, AnswerInput{
		Question: question, Candidate: "1C 1H 2N 3C 4D", PercentLeft: 100,
		TargetPct: 70, PointsGoal: PointsGoal,
	})

	// crossing the goal collects every milestone still outstanding
	if outcome.AwardedSkips != len(ScoreMilestones) {
		t.Errorf("awarded %d skips, want %d", outcome.AwardedSkips, len(ScoreMilestones))
	}
	if len(score.AvailableMilestones) != 0 {
		t.Errorf("%d milestones left uncollected", len(score.AvailableMilestones))
	}
	if !outcome.Completed {
		t.Error("crossing the goal did not complete the quiz")
	}
	// every skip beat is flagged, so the gauge sweep and its sound cannot be lost to a
	// copy edit of the words
	flagged := 0
	for _, toast := range outcome.Toasts {
		if toast.AwardsSkip {
			flagged++
		}
	}
	if flagged != outcome.AwardedSkips {
		t.Errorf("%d beats flagged, %d skips awarded", flagged, outcome.AwardedSkips)
	}
}

func TestTargetPercentageGatesCompletion(t *testing.T) {
	// 1 of 2 correct so far = 50%, below a 70% target
	score := NewScore()
	score.TotalPoints, score.QuestionsAttempted, score.QuestionsCorrect = PointsGoal, 2, 1

	outcome, _ := Answer(&score, AnswerInput{
		Question: questionOf([]string{"1C", "1D"}, "1C"), Candidate: "1C",
		TargetOn: true, TargetPct: 70, PointsGoal: PointsGoal,
	})

	if outcome.Completed {
		t.Error("the target percentage did not gate completion")
	}
	if !strings.Contains(strings.Join(toastTexts(outcome), "|"), "target score 70%") {
		t.Error("the player was not told why the quiz did not finish")
	}
}

func TestNewQuestionDrawsDistinctDescriptions(t *testing.T) {
	if err := corpus.Load(); err != nil {
		t.Fatalf("corpus: %v", err)
	}
	auctions := corpus.Default().Auctions
	for difficulty := MinDifficulty; difficulty <= MaxDifficulty; difficulty++ {
		question := NewQuestion(auctions, difficulty)
		if len(question.Candidates) != difficulty {
			t.Fatalf("difficulty %d drew %d candidates", difficulty, len(question.Candidates))
		}
		if question.AnswerIndex() < 0 {
			t.Fatalf("the answer is not among the candidates: %+v", question)
		}
		seen := map[string]bool{}
		for _, candidate := range question.Candidates {
			if seen[candidate] {
				// only the DESCRIPTIONS are forced distinct; two auctions can repeat, but
				// then they carry different descriptions and the question is still fair
				if question.ChoiceType == Descriptions {
					t.Errorf("a description was offered twice: %q", candidate)
				}
			}
			seen[candidate] = true
		}
	}
}

func toastTexts(outcome Answered) []string {
	out := make([]string, 0, len(outcome.Toasts))
	for _, toast := range outcome.Toasts {
		out = append(out, toast.Text)
	}
	return out
}

// --- benchmarks -------------------------------------------------------------
//
// `engine` and `bidfilter` are free of net/http precisely so these can be run without a
// server in the way, and compared against the python microbenchmarks.

func BenchmarkScorePoints(b *testing.B) {
	question := questionOf([]string{"1C (Pass) 1H --> 2D", "1D --> 1S", "1N --> 2C", "2H", "3N"}, "")
	b.ReportAllocs()
	for b.Loop() {
		_ = ScorePoints(question, 5, 62)
	}
}

func BenchmarkNewQuestion(b *testing.B) {
	if err := corpus.Load(); err != nil {
		b.Fatalf("corpus: %v", err)
	}
	auctions := corpus.Default().Auctions
	b.ReportAllocs()
	for b.Loop() {
		_ = NewQuestion(auctions, InitialDifficulty)
	}
}

func BenchmarkAnswer(b *testing.B) {
	question := questionOf([]string{"1C 1H 2N", "1D 1S"}, "1C 1H 2N")
	b.ReportAllocs()
	for b.Loop() {
		score := NewScore()
		_, _ = Answer(&score, AnswerInput{
			Question: question, Candidate: "1C 1H 2N", PercentLeft: 100,
			LadderMode: true, TargetPct: 70, PointsGoal: PointsGoal,
		})
	}
}
