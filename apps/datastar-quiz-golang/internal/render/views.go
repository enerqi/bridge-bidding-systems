package render

import (
	"embed"
	"html/template"
	"math"
	"regexp"
	"strconv"
	"strings"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/engine"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/session"
)

//go:embed templates/*.gohtml
var templateFS embed.FS

// pyRound is python's `round()` on a float: half to EVEN. Used wherever the python rounds,
// so the two implementations agree at every .5 -- the gauge percentage and the question
// allowance both land on one.
func pyRound(value float64) int { return int(math.RoundToEven(value)) }

// PageContext builds everything both the document and the fat-morph fragment need. Call
// with the session lock held.
func (c Config) PageContext(s *session.Session) (PageData, corpus.FilterCheck) {
	check := s.System.CheckFilter(s.FilterText, engine.MaxDifficulty)
	ticks := make([]int, 0, len(engine.ScoreMilestones))
	for _, milestone := range engine.ScoreMilestones {
		if milestone < 1 {
			ticks = append(ticks, pyRound(milestone*100))
		}
	}
	topics := TopicChoices(s.System)
	described := false
	for _, topic := range topics {
		if topic.Description != "" {
			described = true
			break
		}
	}
	return PageData{
		Variant:                s.System.Variant,
		Settings:               s.Settings,
		Playing:                s.StillPlaying(),
		QuizBody:               template.HTML(c.QuizBody(s)),
		MinDifficulty:          engine.MinDifficulty,
		MaxDifficulty:          engine.MaxDifficulty,
		MilestoneTicks:         ticks,
		PointsGoal:             s.PointsGoal,
		Debug:                  s.Debug,
		QID:                    s.QID,
		TimerMode:              c.TimerMode,
		BuildStamp:             BuildStamp(),
		CSSHref:                StylesheetHref(DefaultCSS, c.Prefix),
		ThemeCookie:            ThemeCookie,
		Topics:                 topics,
		TopicsHaveDescriptions: described,
		FilterText:             s.FilterText,
		FilterStatus:           template.HTML(FilterStatus(check, s.FilterText, "")),
		VariantQuery:           VariantQuery(s.System.Variant),
		DrawerOverlayQuery:     DrawerOverlayQuery,
		TypingTargets:          TypingTargets,
		ActivationTargets:      ActivationTargets,
	}, check
}

// Shell is the whole document: server-rendered current state, no client-side bootstrap, so
// view-source is the state of the quiz and a reload resumes it exactly.
//
// `theme` comes from the cookie the toggle wrote. It is rendered STATICALLY onto <html> as
// well as declared as a signal: the attribute is what makes the first paint right, and the
// signal is what keeps it right when the toggle is clicked. Call with the session lock held.
func (c Config) Shell(s *session.Session, theme string) string {
	page, check := c.PageContext(s)
	initial := BoundSignals(s, check.Parsed.TopicNames)
	for key, value := range Signals(s) {
		initial[key] = value
	}
	for key, value := range LocalUISignals(theme) {
		initial[key] = value
	}
	var themeAttr template.HTMLAttr
	if theme != "auto" {
		themeAttr = template.HTMLAttr(` data-theme="` + template.HTMLEscapeString(theme) + `"`)
	}
	return c.render("shell.gohtml", ShellData{
		PageData:       page,
		InitialSignals: string(MarshalSignals(initial)),
		ThemeAttr:      themeAttr,
		SfxNames:       sfxNames,
	})
}

// sfxNames is the order the <audio> elements are rendered in. Held here rather than
// imported so the render package stays free of the synthesiser.
var sfxNames = []string{"correct", "wrong", "skip", "final", "tick"}

// AppBody is the whole page below <body>: the fat-morph unit.
//
// Sending this rather than a hand-picked fragment is what the Tao of Datastar asks for, and
// it removes a class of bug -- the server no longer has to remember which fragments a state
// change touches. Call with the session lock held.
func (c Config) AppBody(s *session.Session) string {
	page, _ := c.PageContext(s)
	return c.render("app.gohtml", page)
}

// QuizBody is the `#quiz` fragment: prompt, the thing to match, and the candidate buttons
// -- or the revealed answer after a wrong one, or the completion screen once the points
// goal is met. Call with the session lock held.
func (c Config) QuizBody(s *session.Session) string {
	if !s.StillPlaying() {
		return c.render("completed.gohtml", CompletedData{
			// rounded to whole seconds: the finale renders this at 2.4rem, one span per
			// character, and "137" assembles better than "137.4"
			Elapsed:      pyRound(s.ElapsedSeconds()),
			Points:       s.Score.TotalPoints,
			Correct:      s.Score.QuestionsCorrect,
			Attempted:    s.Score.QuestionsAttempted,
			Percentage:   s.Score.Percentage(),
			Goal:         s.PointsGoal,
			Confetti:     confetti,
			VariantQuery: VariantQuery(s.System.Variant),
		})
	}
	data := c.quizData(s)
	if s.AwaitingNext {
		data.CorrectIndex = s.Question.AnswerIndex()
		data.WrongIndex = s.WrongIndex
		return c.render("reveal.gohtml", data)
	}
	return c.render("quiz.gohtml", data)
}

func (c Config) quizData(s *session.Session) QuizData {
	answer := EmojiTextAuction(s.Question.Answer)
	if answer != "" {
		answer = strings.ToUpper(answer[:1]) + answer[1:]
	}
	candidates := make([]template.HTML, 0, len(s.Question.Candidates))
	for _, candidate := range s.Question.Candidates {
		candidates = append(candidates, Suits(EmojiTextAuction(candidate)))
	}
	return QuizData{
		Intro:             intros[s.Question.ChoiceType],
		Answer:            Suits(answer),
		Candidates:        candidates,
		QID:               s.QID,
		VariantQuery:      VariantQuery(s.System.Variant),
		TypingTargets:     TypingTargets,
		ActivationTargets: ActivationTargets,
		CorrectIndex:      -1,
		WrongIndex:        -1,
	}
}

// --- the small fragments ----------------------------------------------------

// Toast is the `#toasts` fragment. An empty text renders an empty container -- the panel
// handler's bare one-second beat between the last toast and the next question.
func Toast(item engine.Toast) string {
	if item.Text == "" {
		return ""
	}
	return `<div class="toast ` + item.Kind + ` notification is-` + item.Kind + `">` +
		string(Suits(item.Text)) + `</div>`
}

// The floater says what you SCORED, so only the beats carrying a number get one --
// "Correct!" and "Not quite" are already said by the card's own tick or cross, and
// repeating them over the card was noise. `+1 SKIP!` earns one because it is a reward the
// corner toast makes too easy to miss.
var floaterNumberRE = regexp.MustCompile(`[+-]\d+`)

// Floater is the number that floats up off the card the player chose, or "" for a beat
// without one.
//
// `final` marks the answer that crossed the points goal: the same number, in gold, larger
// and slower, because it is the last one the player will ever see on that card.
//
// The text is the toast's own -- trimmed to the part that is a score -- so the two can
// never disagree about what was awarded.
func Floater(item engine.Toast, final bool) string {
	text := strings.TrimSpace(item.Text)
	var label string
	if strings.Contains(strings.ToUpper(text), "SKIP") {
		label = "+1 SKIP"
	} else {
		number := floaterNumberRE.FindString(text)
		if number == "" {
			return ""
		}
		label = number
	}
	kind := "loss"
	if strings.HasPrefix(label, "+") {
		kind = "gain"
	}
	if final {
		kind += " final"
	}
	return `<span class="floater ` + kind + `" aria-hidden="true">` + label + `</span>`
}

// SfxBeat is one sound beat: markup that plays `<audio id="sfx-<beat>">`, which is already
// in the page. Appended to `#sfx`, which is the same trick as the floaters -- the server
// knows when the beat happened, so the beat is a patch rather than something the browser
// has to work out. Two things are deliberate:
//
//   - **`$_sound &&` first.** The preference is a LOCAL signal, so the server cannot know
//     it and streams the beat either way; the expression is the gate, exactly as
//     `body.juice` gates the floaters. ~90 bytes for a player who has sound off, and the
//     audio elements have no `src` in that case anyway, so nothing is fetched.
//   - **`play()` and nothing else.** An element that has ENDED rewinds itself on the next
//     `play()`, and one that is still playing ignores the call -- which is what makes
//     `tick` self-spacing. `.catch` because a play() the browser refuses rejects a promise,
//     and an unhandled rejection is a console error per beat.
func SfxBeat(beat string) string {
	return `<span aria-hidden="true" data-init="$_sound && document.getElementById('sfx-` + beat +
		`')?.play()?.catch(() => {})"></span>`
}

// MeterSweep is the shine that crosses the points gauge when a milestone has just paid for
// a skip. Appended to the gauge itself, so it needs no signal and no cleanup: the fat morph
// at the end of the answer stream rewrites `#app` from markup that never contains it.
func MeterSweep() string {
	return `<span class="meter-sweep" aria-hidden="true"></span>`
}

// FilterStatus is the `#filter-status` fragment: what the text in the box *would* select.
//
// Asking never commits anything, so this is safe to render on every keystroke -- which is
// the point: the validation lives with the matcher, on the server, and the browser needs to
// know nothing about bidding.
func FilterStatus(check corpus.FilterCheck, inForce, pendingHint string) string {
	parsed := check.Parsed
	var lines []string
	if len(parsed.Errors) > 0 {
		// the unrecognised entries are whatever the user typed, so they are escaped
		offenders := make([]string, 0, len(parsed.Errors))
		for _, e := range parsed.Errors {
			offenders = append(offenders, "<code>"+template.HTMLEscapeString(e)+"</code>")
		}
		lines = append(lines, "⚠ not a topic or pattern: "+strings.Join(offenders, ", "))
	}
	switch {
	case check.Status == "too_few":
		lines = append(lines, "⚠ only "+strconv.Itoa(len(check.Hits))+" match, need "+
			strconv.Itoa(engine.MaxDifficulty)+"+ — the whole system is used")
	case check.Status == "error":
		lines = append(lines, "⚠ nothing usable — the whole system is used")
	case len(parsed.Entries) == 0:
		lines = append(lines, "the whole system, <strong>"+strconv.Itoa(len(check.Hits))+"</strong> auctions")
	default:
		lines = append(lines, "<strong>"+strconv.Itoa(len(check.Hits))+"</strong> auctions match")
	}
	if pendingHint != "" && parsed.CanonicalText != inForce {
		lines = append(lines, "<em>"+template.HTMLEscapeString(pendingHint)+"</em>")
	}
	var out strings.Builder
	for _, line := range lines {
		out.WriteString(`<div class="filter-line">` + line + "</div>\n")
	}
	return out.String()
}
