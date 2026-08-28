// Package engine is the quiz rules: question generation, scoring, the time bonus,
// milestone skip awards, completion.
//
// No HTTP, no HTML, no signals -- this is the state machine the routes drive, ported from
// `apps/datastar-quiz/engine.py` (which is itself a port of the panel app's `points` /
// `on_answer_click` / `reset_time_bonus_by_difficulty`). Keeping it separate is what lets
// it be benchmarked with `go test -bench` and compared against the python microbenchmarks
// with no server in the way.
//
// Scoring applies the whole state change at once and *returns* the instalments as Toasts:
// the SSE handler replays them with the same delays, but a mid-stream reload sees final
// state rather than a half-scored session.
package engine

import (
	"fmt"
	"math"
	"math/rand/v2"
	"strconv"
	"strings"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
)

const (
	InitialDifficulty = 5
	MinDifficulty     = 4
	MaxDifficulty     = 8

	PointsGoal   = 1000
	InitialSkips = 3
)

// ScoreMilestones are the fractions of the goal that each pay for one skip.
var ScoreMilestones = []float64{0.1, 0.25, 0.45, 0.65, 0.8, 1}

// secondsPerLevel is the seconds allowed per question, by difficulty
// (the panel's `reset_time_bonus_by_difficulty`).
var secondsPerLevel = map[int]int{4: 8, 5: 7, 6: 6, 7: 5, 8: 4}

// SecondsForDifficulty is the allowance for one question.
func SecondsForDifficulty(difficulty int) float64 {
	seconds, ok := secondsPerLevel[difficulty]
	if !ok {
		seconds = 4
	}
	return float64(difficulty * seconds)
}

// pyRound is python's `round()` on a float: half to EVEN, not half away from zero.
// Used everywhere the python rounds, because the two disagree at every .5 -- and the
// percentages here land on one often enough for it to show (a 50% time bonus on an even
// candidate count, the gauge at exactly 12.5%).
func pyRound(value float64) int {
	return int(math.RoundToEven(value))
}

// PercentTimeLeft is the time bonus percentage, as the panel's `TimeBonus` progress bar
// computed it.
func PercentTimeLeft(elapsed, allowed float64) int {
	if allowed <= 0 {
		return 0
	}
	return pyRound(math.Max(allowed-elapsed, 0) / allowed * 100)
}

// ClampDifficulty turns a signal value from the browser into a difficulty. Anything
// unusable is the default.
//
// The shapes are what `encoding/json` produces for a datastar signal payload: a number, a
// string, a bool, or something else entirely. The python accepts int/float/str (and bool,
// which is an int there), truncates toward zero, and falls back on anything it cannot
// read; this does the same.
func ClampDifficulty(value any) int {
	var difficulty int
	switch v := value.(type) {
	case float64:
		difficulty = int(v) // truncates toward zero, as python's int()
	case int:
		difficulty = v
	case bool:
		if v {
			difficulty = 1
		}
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return InitialDifficulty
		}
		difficulty = parsed
	default:
		return InitialDifficulty
	}
	return max(MinDifficulty, min(MaxDifficulty, difficulty))
}

// --- questions --------------------------------------------------------------

// ChoiceType is which way round a question is asked.
type ChoiceType string

const (
	// Auctions: several auctions, one description -- pick the auction it describes.
	Auctions ChoiceType = "Auctions"
	// Descriptions: one auction, several descriptions -- pick the one that fits.
	Descriptions ChoiceType = "Descriptions"
)

// Question is one question as the browser will see it.
type Question struct {
	Candidates      []string
	Answer          string
	AnswerCandidate string
	ChoiceType      ChoiceType
}

// AnswerIndex is where the right answer sits among the candidates.
func (q Question) AnswerIndex() int {
	for i, candidate := range q.Candidates {
		if candidate == q.AnswerCandidate {
			return i
		}
	}
	return -1
}

// prettifyDescription is `quiz.prettify_description`: trim, and spell the suit shorthand
// out. The remaining `!x`-to-glyph work is presentation and happens in the renderer.
var descriptionReplacer = strings.NewReplacer("!c", "C", "!d", "D", "!h", "H", "!s", "S")

func prettifyDescription(text string) string {
	return descriptionReplacer.Replace(strings.TrimSpace(text))
}

// AuctionSeparator is how the parts of one auction are joined for display -- the same
// ` --> ` the panel app used, which `render.EmojiTextAuction` then turns into a glyph.
const AuctionSeparator = " --> "

// maxDraws bounds the "keep drawing until the descriptions are distinct" loop.
//
// The python spins forever if a working set holds fewer distinct non-blank descriptions
// than the question needs candidates, and it cannot happen in practice: a filter that
// selects fewer than MaxDifficulty auctions is rejected as `too_few` and the whole system
// is used instead. A goroutine that never returns is a worse failure than a repeated
// candidate, so the loop gives up rather than hanging -- on any corpus where the python
// terminates, this bound is never reached.
const maxDraws = 10000

// NewQuestion draws one question from a working set: `quiz.generate_question`, with the
// choice type picked at random as `random_multi_choice_type` does.
func NewQuestion(auctions []corpus.Auction, difficulty int) Question {
	choiceType := Auctions
	if rand.IntN(2) == 0 {
		choiceType = Descriptions
	}
	return NewQuestionOfType(auctions, difficulty, choiceType)
}

// NewQuestionOfType is NewQuestion with the choice type named, for tests.
func NewQuestionOfType(auctions []corpus.Auction, difficulty int, choiceType ChoiceType) Question {
	answerIndex := rand.IntN(difficulty)
	seen := make(map[string]bool, difficulty)
	question := Question{ChoiceType: choiceType, Candidates: make([]string, 0, difficulty)}
	if len(auctions) == 0 {
		return question
	}
	for i := 0; i < difficulty; i++ {
		var description, auction string
		for draw := 0; draw < maxDraws; draw++ {
			picked := auctions[rand.IntN(len(auctions))]
			description = prettifyDescription(picked.Description)
			// some auction sequences, some preludes do not have descriptions
			if strings.TrimSpace(description) != "" && !seen[description] {
				auction = strings.Join(picked.Sequence, AuctionSeparator)
				break
			}
			description = ""
		}
		if description == "" {
			break
		}
		seen[description] = true

		if choiceType == Auctions {
			if i == answerIndex {
				question.Answer = description
				question.AnswerCandidate = auction
			}
			question.Candidates = append(question.Candidates, auction)
		} else {
			if i == answerIndex {
				question.Answer = auction
				question.AnswerCandidate = description
			}
			question.Candidates = append(question.Candidates, description)
		}
	}
	return question
}

// --- scoring ----------------------------------------------------------------

// Points is one answer's score, broken into the instalments the toasts reveal.
type Points struct {
	FromCandidateLengths int
	FromStreakBonus      int
	FromTimeBonus        int
}

func (p Points) Total() int {
	return p.FromCandidateLengths + p.FromStreakBonus + p.FromTimeBonus
}

// ScorePoints is the verbatim port of `quiz_app.points` -- longer auctions are worth more,
// with a streak multiplier and a time multiplier on top.
func ScorePoints(question Question, streak, percentLeft int) Points {
	fromCandidateLengths := 0
	for _, candidate := range question.Candidates {
		fromCandidateLengths += len(strings.Fields(strings.ReplaceAll(candidate, "-->", "")))
	}
	streakBonus := 0
	if streak > 1 {
		percentBonus := math.Min(float64(streak)*10/100, 1.0)
		streakBonus = pyRound(float64(fromCandidateLengths) * percentBonus)
	}
	timeBonus := 0
	if percentLeft > 0 {
		timeBonus = pyRound(float64(fromCandidateLengths) * (float64(percentLeft) / 100))
	}
	return Points{fromCandidateLengths, streakBonus, timeBonus}
}

// Toast is one notification, and how long the stream should pause after showing it.
//
// Kind matches the panel notification methods (success / info / warning) so the CSS can
// keep the same colour language.
type Toast struct {
	Kind  string
	Text  string
	Pause float64 // seconds
	// The running points total *as at this toast*. The state change is applied in one go,
	// but the panel app revealed the points in instalments (candidate length, then streak
	// bonus, then time bonus), so each toast carries the number to show alongside it.
	PointsAfter    int
	HasPointsAfter bool
	// This beat is a milestone paying for a skip. A flag rather than a text match in the
	// renderer: the words are presentation and have been reworded once already, and
	// "+1 SKIP!" appearing in the stream handler would make an unrelated copy edit
	// silently drop the gauge sweep and the sound that go with it.
	AwardsSkip bool
}

// Answered is the outcome of scoring one answer.
type Answered struct {
	Correct      bool
	Toasts       []Toast
	Completed    bool
	AwardedSkips int
}

// Score is the part of a session the score panel renders.
type Score struct {
	QuestionsCorrect   int
	QuestionsAttempted int
	Streak             int
	TotalPoints        int
	// The milestones not yet collected, highest first -- popped from the back as the
	// points pass them, exactly as the python's reversed list is.
	AvailableMilestones []float64
}

// NewScore is a fresh ledger.
func NewScore() Score {
	score := Score{}
	score.Reset()
	return score
}

// Percentage is the proportion of attempts that were right.
func (s *Score) Percentage() int {
	if s.QuestionsAttempted > 0 {
		return pyRound(float64(s.QuestionsCorrect) / float64(s.QuestionsAttempted) * 100)
	}
	return 0
}

// Reset returns the ledger to the start of a quiz.
func (s *Score) Reset() {
	s.QuestionsCorrect = 0
	s.QuestionsAttempted = 0
	s.Streak = 0
	s.TotalPoints = 0
	s.AvailableMilestones = make([]float64, len(ScoreMilestones))
	for i, milestone := range ScoreMilestones {
		s.AvailableMilestones[len(ScoreMilestones)-1-i] = milestone
	}
}

// AnswerInput is everything scoring one answer needs beyond the ledger.
type AnswerInput struct {
	Question          Question
	Candidate         string
	PercentLeft       int
	LadderMode        bool
	TargetOn          bool
	TargetPct         int
	LastCorrectPoints int
	// PointsGoal is a parameter rather than the package constant so the debug panel can
	// shorten a quiz without a global mutation -- the goal decides both completion and
	// where the skip milestones fall, and two sessions in one process may disagree.
	PointsGoal int
}

// Answer scores one answer. It mutates `score` and returns the toast script plus the new
// "last correct points" (what a wrong answer costs in ladder mode).
//
// A wrong answer's toasts are deliberately brief: the answer itself is revealed in place in
// the question card, not spelled out in a notification the player must wait behind.
func Answer(score *Score, in AnswerInput) (Answered, int) {
	correct := in.Candidate == in.Question.AnswerCandidate
	var toasts []Toast

	if !correct {
		score.Streak = 0
		score.QuestionsAttempted++
		scoreWasNonZero := score.TotalPoints > 0
		if in.LadderMode {
			score.TotalPoints = max(score.TotalPoints-in.LastCorrectPoints, 0)
		}
		toasts = append(toasts, Toast{Kind: "warning", Text: "Not quite", Pause: 0.6})
		if in.LadderMode && in.LastCorrectPoints > 0 && scoreWasNonZero {
			toasts = append(toasts, Toast{
				Kind:           "warning",
				Text:           fmt.Sprintf("Ladder mode: -%d points", in.LastCorrectPoints),
				Pause:          0.6,
				PointsAfter:    score.TotalPoints,
				HasPointsAfter: true,
			})
		}
		return Answered{Correct: false, Toasts: toasts}, in.LastCorrectPoints
	}

	score.Streak++
	increase := ScorePoints(in.Question, score.Streak, in.PercentLeft)

	toasts = append(toasts, Toast{Kind: "success", Text: "Correct!", Pause: 0.5})
	score.TotalPoints += increase.FromCandidateLengths
	toasts = append(toasts, Toast{
		Kind: "info", Text: fmt.Sprintf("+%d!", increase.FromCandidateLengths), Pause: 0.5,
		PointsAfter: score.TotalPoints, HasPointsAfter: true,
	})
	if increase.FromStreakBonus > 0 {
		score.TotalPoints += increase.FromStreakBonus
		toasts = append(toasts, Toast{
			Kind:  "info",
			Text:  fmt.Sprintf("Streak %d, Bonus +%d", score.Streak, increase.FromStreakBonus),
			Pause: 0.5, PointsAfter: score.TotalPoints, HasPointsAfter: true,
		})
	}
	if increase.FromTimeBonus > 0 {
		score.TotalPoints += increase.FromTimeBonus
		toasts = append(toasts, Toast{
			Kind: "info", Text: fmt.Sprintf("Time Bonus +%d", increase.FromTimeBonus), Pause: 0.5,
			PointsAfter: score.TotalPoints, HasPointsAfter: true,
		})
	}

	score.QuestionsAttempted++
	score.QuestionsCorrect++

	awardedSkips := 0
	for len(score.AvailableMilestones) > 0 {
		last := score.AvailableMilestones[len(score.AvailableMilestones)-1]
		if last*float64(in.PointsGoal) > float64(score.TotalPoints) {
			break
		}
		score.AvailableMilestones = score.AvailableMilestones[:len(score.AvailableMilestones)-1]
		awardedSkips++
		toasts = append(toasts, Toast{Kind: "success", Text: "+1 SKIP!", Pause: 0.5, AwardsSkip: true})
	}

	completed := false
	if score.TotalPoints >= in.PointsGoal {
		percentage := score.Percentage()
		if !in.TargetOn || percentage >= in.TargetPct {
			completed = true
		} else {
			toasts = append(toasts, Toast{
				Kind:  "warning",
				Text:  fmt.Sprintf("Current score %d%%, target score %d%%", percentage, in.TargetPct),
				Pause: 0.5,
			})
		}
	}

	// the panel handler paused a further second before moving on when the answer was right
	toasts = append(toasts, Toast{Kind: "info", Text: "", Pause: 1.0})

	return Answered{Correct: true, Toasts: toasts, Completed: completed, AwardedSkips: awardedSkips}, increase.Total()
}
