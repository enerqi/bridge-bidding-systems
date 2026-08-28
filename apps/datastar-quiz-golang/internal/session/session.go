// Package session is the server-side session state -- the authoritative quiz.
//
// Datastar's doctrine: "Most state should live in the backend. Since the frontend is
// exposed to the user, the backend should be the source of truth for your application
// state." Everything here is state the browser must not own:
//
//   - the current Question, because it carries the answer -- signals are readable in
//     devtools and are uploaded with every request, so an answer in a signal is a cheat
//     code;
//   - the score, streak and milestone ledger, for the same reason;
//   - the working set of auctions, which is a slice of the process-wide corpus.
//
// Signals carry only what the browser originates: bound form inputs (difficulty, ladder
// mode, target %, filter draft) and `_`-prefixed local view state.
//
// ONE DIFFERENCE FROM THE PYTHON, AND IT IS THE INTERESTING ONE. The litestar app is a
// single asyncio loop: a handler runs to its next `await` with no other handler in the
// middle of touching the same session, so nothing there needs a lock. Here every request
// is a goroutine and several can hold the same session at once -- two tabs, a click
// arriving during an answer stream, the held timer connection ticking. So a session has a
// mutex, and the rule is: every read and every write of a Session's fields happens under
// it (see Session.With). The store has its own.
package session

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"sync/atomic"
	"time"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/engine"
)

// Cookie identifies the BROWSER, not the quiz: sessions are keyed by (browser, variant),
// so the squad quiz and the swedish one coexist instead of one replacing the other.
// Deliberately still one cookie under one name -- nginx pins a browser to a worker with
// `hash $cookie_dsq_sid consistent`, and a name that varied by variant would leave that
// directive hashing on a cookie half the requests do not carry.
const Cookie = "dsq_sid"

const (
	TTL         = 6 * time.Hour
	sweepPeriod = 10 * time.Minute
)

// THE QUESTION NONCE IS PROCESS-WIDE, and that is the whole point of it.
//
// Per session, starting at 1, a page whose session had been REPLACED -- and there are
// three ordinary ways for that to happen: `?swedish` used to discard the old session, a
// restart empties the store, and a session ages out after six hours -- posted qid=1 at a
// brand new session whose first question was *also* qid=1. The staleness guard then passed
// by coincidence and the answer was scored against a question that had never been on
// screen. That is the "I answered one question and it showed me another" report, and it is
// not a race -- it is two counters that both start at 1.
var qids atomic.Int64

// NextQID is the next question nonce. Unique per process, not per session.
func NextQID() int64 { return qids.Add(1) }

// Settings are the bound signals, as last seen from the browser. Mirrors of
// client-originated state: the browser is the source of truth for these, and every request
// re-states them.
type Settings struct {
	Difficulty int
	LadderMode bool
	TargetOn   bool
	TargetPct  int
}

// DefaultSettings is what a new quiz starts with.
func DefaultSettings() Settings {
	return Settings{Difficulty: engine.InitialDifficulty, LadderMode: true, TargetOn: false, TargetPct: 70}
}

// Session is one quiz in progress. Every field is guarded by mu; use With.
type Session struct {
	mu sync.Mutex

	SID      string
	System   *corpus.System
	Settings Settings
	Score    engine.Score
	// the working set questions are drawn from (filtered, or the whole system)
	Sequences []corpus.Auction
	Question  engine.Question
	// set from NextQID(); the answer route rejects a stale one. Never per-session.
	QID               int64
	SkipsLeft         int
	LastCorrectPoints int
	FilterText        string

	QuizStartWall  time.Time
	CompletionWall time.Time // zero while still playing
	QuestionStart  time.Time
	QuestionSecs   float64
	Touched        time.Time

	// Set when a wrong answer has been scored: the question stays on screen with the right
	// answer marked, and nothing moves on until the player asks (POST /next). Panel instead
	// blocked for 4.2s behind a centre-screen toast.
	AwaitingNext bool
	WrongIndex   int // -1 when none

	// Per-session so the debug panel can shorten a quiz without mutating a package
	// constant -- and so two browsers against one process can disagree about it.
	PointsGoal int
	// Set when the session was opened with `?debug` (or DSQUIZ_DEBUG=1). Sticky, like the
	// variant, because the query is gone after the first navigation.
	Debug bool

	// What was left on the clock when the question was answered. The allowance stops
	// mattering the moment an answer is scored, so it is frozen rather than left running
	// against QuestionStart: otherwise a reload while parked on the reveal reports a
	// smaller number than the one the answer was actually scored with, and GET /timer keeps
	// pushing a shrinking value at a bar that should be holding still.
	FrozenTimeLeft int
	HasFrozen      bool
}

// With runs fn holding the session lock. EVERY access to a Session's fields -- including
// rendering, which reads a dozen of them -- goes through this.
func (s *Session) With(fn func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn()
}

// StillPlaying reports that the quiz has not been completed. Call under the lock.
func (s *Session) StillPlaying() bool { return s.CompletionWall.IsZero() }

// OnTheClock reports whether a live, unanswered question is being timed.
//
// False while parked on a reveal and after completion -- the two states where the
// countdown must stop rather than keep draining. Call under the lock.
func (s *Session) OnTheClock() bool { return s.StillPlaying() && !s.AwaitingNext }

// ElapsedSeconds is how long the quiz took, to one decimal (the completion screen's
// number). Call under the lock.
func (s *Session) ElapsedSeconds() float64 {
	end := s.CompletionWall
	if end.IsZero() {
		end = time.Now()
	}
	return float64(int64(end.Sub(s.QuizStartWall).Seconds()*10+0.5)) / 10
}

// PercentTimeLeft is what is left of this question's allowance. Call under the lock.
func (s *Session) PercentTimeLeft() int {
	if s.HasFrozen {
		return s.FrozenTimeLeft
	}
	return engine.PercentTimeLeft(time.Since(s.QuestionStart).Seconds(), s.QuestionSecs)
}

// FreezeQuestionClock stops the countdown where it stands, because this question has been
// answered. Call under the lock.
func (s *Session) FreezeQuestionClock() {
	s.FrozenTimeLeft = s.PercentTimeLeft()
	s.HasFrozen = true
}

// NextQuestion draws a new question and restarts its clock. QID changes, which is what
// makes the previous question's answer buttons dead -- a double click cannot score twice.
// Call under the lock.
func (s *Session) NextQuestion() {
	s.AwaitingNext = false
	s.WrongIndex = -1
	s.Question = engine.NewQuestion(s.Sequences, s.Settings.Difficulty)
	s.QID = NextQID()
	s.QuestionSecs = engine.SecondsForDifficulty(s.Settings.Difficulty)
	s.StartQuestionClock()
}

// StartQuestionClock (re)starts the allowance for the current question.
//
// Called again when the question actually reaches the browser: the answer stream spends up
// to several seconds showing notifications after the next question has been drawn, and
// charging the player for that time would cost them a chunk of their bonus. Call under the
// lock.
func (s *Session) StartQuestionClock() {
	s.QuestionStart = time.Now()
	s.HasFrozen = false
}

// ApplyFilter commits a bidding-tree filter, narrowing the working set questions are drawn
// from, and reports whether the filter actually changed.
//
// Anything other than a usable filter falls back to the whole system, and the stored text
// is the *canonical* form (topic prefixes resolved, whitespace tidied) so the input box can
// show what is really in force. Call under the lock.
func (s *Session) ApplyFilter(text string, minHits int) (corpus.FilterCheck, bool) {
	check := s.System.CheckFilter(text, minHits)
	if check.Usable() {
		s.Sequences = check.Hits
	} else {
		s.Sequences = s.System.Auctions
	}
	canonical := check.Parsed.CanonicalText
	changed := canonical != s.FilterText
	s.FilterText = canonical
	return check, changed
}

// Restart is the port of the panel's `reset_skips_and_scoring_and_timer_and_question`.
// Every settings or filter change goes through here, as in the panel app. Call under the
// lock.
func (s *Session) Restart() {
	s.Score.Reset()
	s.SkipsLeft = engine.InitialSkips
	s.LastCorrectPoints = 0
	s.QuizStartWall = time.Now()
	s.CompletionWall = time.Time{}
	s.NextQuestion()
}

// Complete stops the quiz. Call under the lock.
func (s *Session) Complete() { s.CompletionWall = time.Now() }

// New builds a quiz for a system under the given browser id.
func New(system *corpus.System, sid string) *Session {
	if sid == "" {
		sid = newSID()
	}
	settings := DefaultSettings()
	now := time.Now()
	return &Session{
		SID:       sid,
		System:    system,
		Settings:  settings,
		Score:     engine.NewScore(),
		Sequences: system.Auctions,
		Question:  engine.NewQuestion(system.Auctions, settings.Difficulty),
		// from the process-wide counter, so this session's first question cannot share a
		// nonce with the first question of the session it replaced -- see NextQID
		QID:           NextQID(),
		SkipsLeft:     engine.InitialSkips,
		WrongIndex:    -1,
		PointsGoal:    engine.PointsGoal,
		QuestionSecs:  engine.SecondsForDifficulty(settings.Difficulty),
		QuestionStart: now,
		QuizStartWall: now,
		Touched:       now,
	}
}

func newSID() string {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		// crypto/rand does not fail on any supported platform; a session id that is not
		// unique is worse than a crash, so this is not papered over with a timestamp.
		panic("session id: " + err.Error())
	}
	return hex.EncodeToString(buf[:])
}
