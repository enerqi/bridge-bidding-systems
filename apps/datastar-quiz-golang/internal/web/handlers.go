package web

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/starfederation/datastar-go/datastar"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/engine"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/render"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/session"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/sfx"
)

// --- session plumbing -------------------------------------------------------

// sessionFor is this browser's session for the variant this request belongs to, or a new
// one, plus whether the browser arrived with an identity we no longer have a quiz for.
//
// The variant is resolved FIRST, because it is half the key: sessions live under
// (browser, variant) so the two systems coexist. `wanted` is what the request names -- the
// query on a navigation, the query every action URL carries on an interaction. When it names
// none, the browser's last navigated-to variant stands in, and failing that the default.
//
// Switching systems is therefore not a replacement: `?swedish` parks the squad quiz and
// resumes (or starts) the swedish one, both keep their score, and a squad tab left open in
// the same browser goes on being about the squad session.
//
// The `replaced` flag records that the browser arrived with an identity we no longer have a
// quiz for -- a restart, a six-hour gap -- so the play routes can resync the page instead of
// quietly scoring against a question it has never shown.
func (s *Server) sessionFor(r *http.Request, wanted *corpus.System) (*session.Session, bool) {
	sid := ""
	if cookie, err := r.Cookie(session.Cookie); err == nil {
		sid = cookie.Value
	}
	system := wanted
	if system == nil {
		system = corpus.Get(s.store.CurrentVariant(sid))
	}
	if system == nil {
		system = corpus.Default()
	}
	if found := s.store.Get(sid, system.Variant.Key); found != nil {
		return found, false
	}
	return s.store.Create(system, sid), sid != ""
}

// playSession is sessionFor for an interaction: only an explicitly named variant switches
// it. Reading a *bare* path as "take me to the default" would throw a swedish player back to
// squad on their first click.
func (s *Server) playSession(r *http.Request) (*session.Session, bool) {
	return s.sessionFor(r, corpus.RequestedVariant(r.URL.RawQuery))
}

// stale reports whether the page this request came from is talking about a quiz that no
// longer exists. Two ways, and they used to be handled differently for no reason:
//
//   - the session itself is gone (`replaced`), so *nothing* the page says applies here;
//   - the question nonce has moved on -- a double click, a replayed request, a background
//     tab.
//
// Since qids are unique per process (see session.NextQID), the second test is exact: it can
// no longer pass by coincidence because two sessions both started counting at 1. Call with
// the session lock held.
func stale(replaced bool, sess *session.Session, qid int64, hasQID bool) bool {
	if replaced {
		return true
	}
	return hasQID && qid != sess.QID
}

// resync answers a stale interaction by making the page tell the truth again.
//
// The old answer was a bare 204: correct, in that nothing should be scored, but from the
// player's chair it is a dead button -- and the page stays wrong, so the next click is stale
// too. This re-renders the whole page from the session that actually exists, which is the one
// thing that ends the loop, and says so, because the question changing under your finger
// needs an explanation.
//
// The FAT patch even in fragment morph mode: what is stale here is not just the question.
// The title, the score, the drawer and the topics all belong to a quiz this browser is no
// longer in. Call with the session lock held.
func (s *Server) resync(sess *session.Session) []event {
	signals := render.Signals(sess)
	for key, value := range render.SettingsSignals(sess) {
		signals[key] = value
	}
	return []event{
		patchElements(s.renderer.AppBody(sess), appSelector, datastar.ElementPatchModeInner),
		patchSignals(signals),
		patchElements(
			render.Toast(engine.Toast{Kind: "warning", Text: "Quiz reloaded — this page has caught up"}),
			toastsSelector, datastar.ElementPatchModeInner),
	}
}

// viewPatches is the standard "make the browser agree with the session" set.
//
// Server-owned signals *and* the effective settings: the browser proposed those, but the
// server clamps them, so echoing them is what stops a rejected value sitting in the UI until
// a reload. Drafts (`filterText`, topic ticks) are excluded. Call with the session lock held.
func (s *Server) viewPatches(sess *session.Session) []event {
	var elements event
	if s.cfg.MorphMode == "fragment" {
		elements = patchElements(s.renderer.QuizBody(sess), quizSelector, datastar.ElementPatchModeInner)
	} else {
		elements = patchElements(s.renderer.AppBody(sess), appSelector, datastar.ElementPatchModeInner)
	}
	signals := render.Signals(sess)
	for key, value := range render.SettingsSignals(sess) {
		signals[key] = value
	}
	return []event{elements, patchSignals(signals)}
}

func clearToasts() event {
	return patchElements("", toastsSelector, datastar.ElementPatchModeInner)
}

// clearSfx empties the sound sink before an answer appends its beats to it.
//
// The markers are appended rather than morphed, so without this they would accumulate for
// the life of the page. Clearing at the START rather than the end also means a marker is
// never removed while the sound it started is still playing -- the <audio> element is what
// plays, and it lives outside the sink.
func clearSfx() event {
	return patchElements("", sfxSelector, datastar.ElementPatchModeInner)
}

// pickedCardSelector is the card the player just chose.
//
// `nth-child` rather than `nth-of-type`: every child of the group is a button, so they
// agree, and nth-child does not care if a future revision wraps them. The floaters need no
// cleanup -- both outcomes replace `#quiz` wholesale a moment later.
func pickedCardSelector(index int) string {
	return quizSelector + " .candidates > :nth-child(" + strconv.Itoa(index+1) + ")"
}

// syncSettings adopts the bound signals the browser just sent, and reports whether anything
// changed.
//
// The browser is the source of truth for these -- they originate there and are uploaded with
// every request -- so the session merely mirrors them. A change restarts the quiz, exactly as
// the panel watchers did. Call with the session lock held.
func syncSettings(sess *session.Session, signals map[string]any) bool {
	if signals == nil {
		return false
	}
	before := sess.Settings
	if value, ok := signals["difficulty"]; ok {
		sess.Settings.Difficulty = engine.ClampDifficulty(value)
	}
	if value, ok := signals["ladderMode"]; ok {
		sess.Settings.LadderMode = truthy(value)
	}
	if value, ok := signals["targetOn"]; ok {
		sess.Settings.TargetOn = truthy(value)
	}
	if value, ok := signals["targetPct"]; ok {
		if pct, ok := asInt(value); ok {
			sess.Settings.TargetPct = max(70, min(90, pct))
		}
	}
	return before != sess.Settings
}

// truthy is python's `bool(x)` over a decoded JSON value.
func truthy(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case float64:
		return v != 0
	case string:
		return v != ""
	case nil:
		return false
	case []any:
		return len(v) > 0
	case map[string]any:
		return len(v) > 0
	}
	return true
}

// asInt is python's `int(x)` with its TypeError/ValueError suppressed.
func asInt(value any) (int, bool) {
	switch v := value.(type) {
	case float64:
		return int(v), true
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(v))
		return parsed, err == nil
	case bool:
		if v {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

func filterTextFrom(signals map[string]any) string {
	if text, ok := signals["filterText"].(string); ok {
		return text
	}
	return ""
}

// topicsTextFrom turns ticked topic slugs back into the filter text they stand for.
//
// Signal paths cannot hold spaces, so the picker binds kebab-case slugs, which datastar
// stores camel-cased. The real topic names live here, on the server, so an unknown key
// simply does not select anything. Call with the session lock held.
func topicsTextFrom(sess *session.Session, signals map[string]any) string {
	ticked, _ := signals["topics"].(map[string]any)
	var names []string
	for _, choice := range render.TopicChoices(sess.System) {
		if truthy(ticked[choice.Key]) {
			names = append(names, choice.Name)
		}
	}
	return strings.Join(names, ", ")
}

// --- routes -----------------------------------------------------------------

// index is the full page. Everything the browser knows starts here, in view-source.
//
// Also where the debug flag is decided, and only here: the datastar interactions POST to
// bare paths with no query, so re-reading `?debug` per request would switch the panel off on
// the first click. Set on page load, sticky for the session.
func (s *Server) index(w http.ResponseWriter, r *http.Request) {
	// A bare URL additionally means the default variant, and only a real navigation can
	// carry that meaning -- see corpus.VariantSwitchForQuery.
	sess, _ := s.sessionFor(r, corpus.VariantSwitchForQuery(r.URL.RawQuery))
	// The theme is the browser's preference, not the session's: it is written by the toggle
	// into its own cookie and only relayed here, so it survives a new session, a restart and
	// a second tab.
	theme := "auto"
	if cookie, err := r.Cookie(render.ThemeCookie); err == nil {
		theme = render.ThemeFrom(cookie.Value)
	}
	var page string
	sess.With(func() {
		sess.Debug = s.debugAllowed(r.URL.RawQuery)
		page = s.renderer.Shell(sess, theme)
	})
	// A NAVIGATION is the only thing that moves the mark for "which system this browser is
	// on", which is what an ambiguous later page load (`?debug`, naming no variant) resolves
	// against. Doing it on interactions instead would let a background tab drag the answer
	// back to its own system.
	s.store.Remember(sess)
	s.setCookie(w, sess)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(page))
}

// debugAllowed reports whether the debug panel should be armed, given this page load's query.
func (s *Server) debugAllowed(query string) bool {
	switch s.cfg.DebugMode {
	case "0":
		return false
	case "1":
		return true
	}
	return strings.Contains(strings.ToLower(query), "debug")
}

// answer scores one answer, then streams the notifications the way panel showed them.
//
// A stale qid (double click, back button, replay, a page whose session was replaced) scores
// nothing and RESYNCS the page instead: the nonce moved on when the question did, and the
// browser is showing a quiz that no longer exists. A finished quiz is still a plain no-op --
// the completion screen is already what the page is showing.
func (s *Server) answer(w http.ResponseWriter, r *http.Request) {
	qid, err := strconv.ParseInt(r.PathValue("qid"), 10, 64)
	index, indexErr := strconv.Atoi(r.PathValue("index"))
	if err != nil || indexErr != nil {
		http.NotFound(w, r)
		return
	}
	sess, replaced := s.playSession(r)
	s.scoreAnswer(w, r, sess, replaced, qid, index, true)
}

func (s *Server) scoreAnswer(
	w http.ResponseWriter, r *http.Request,
	sess *session.Session, replaced bool, qid int64, index int, floaters bool,
) {
	signals := readSignals(r)

	var (
		refuse      []event
		outcome     engine.Answered
		percentLeft int
		scored      bool
	)
	sess.With(func() {
		if stale(replaced, sess, qid, true) {
			refuse = s.resync(sess)
			return
		}
		if !sess.StillPlaying() || index < 0 || index >= len(sess.Question.Candidates) {
			return
		}
		syncSettings(sess, signals)

		question := sess.Question
		candidate := question.Candidates[index]
		// the bonus that scores is measured here, from the server's own clock -- the
		// browser's countdown bar is only an animation
		percentLeft = sess.PercentTimeLeft()

		var lastCorrect int
		outcome, lastCorrect = engine.Answer(&sess.Score, engine.AnswerInput{
			Question:          question,
			Candidate:         candidate,
			PercentLeft:       percentLeft,
			LadderMode:        sess.Settings.LadderMode,
			TargetOn:          sess.Settings.TargetOn,
			TargetPct:         sess.Settings.TargetPct,
			LastCorrectPoints: sess.LastCorrectPoints,
			PointsGoal:        sess.PointsGoal,
		})
		sess.LastCorrectPoints = lastCorrect
		sess.SkipsLeft += outcome.AwardedSkips

		// the clock stops the moment the answer is scored -- percentLeft above is the last
		// thing that reads it, and everything after this point (the toast sequence, the
		// reveal, a reload while parked) should report what was left, not keep draining
		sess.FreezeQuestionClock()

		// state is settled before a single byte is streamed, so a reload mid-notification
		// shows the finished score and the next question rather than a half-applied answer
		switch {
		case outcome.Completed:
			sess.Complete()
		case outcome.Correct:
			sess.NextQuestion()
		default:
			// park on the reveal instead: the answer is shown in place, and the player advances
			sess.AwaitingNext = true
			sess.WrongIndex = index
		}
		scored = true
	})

	if refuse != nil {
		s.respond(w, r, sess, refuse)
		return
	}
	if !scored {
		s.respond(w, r, sess, nil)
		return
	}
	picked := index
	if !floaters {
		picked = -1
	}
	s.streamAnswer(w, r, sess, outcome, picked)
}

// streamAnswer is the panel notification chain, as one long SSE response.
//
// `on_answer_click` awaited `asyncio.sleep` between notification calls; the same pacing
// survives here, with each beat as an element patch instead of a websocket message -- and
// with a `time.Sleep` on a goroutine instead of an await on the one loop, which is one of
// the differences this port exists to measure.
//
// Each beat that carries points is *also* appended to the card the player chose, as a
// floating number. The server can do that because the choice is in the URL it was called on;
// the alternative was a client-side signal remembering the last click, which is state the
// browser would then own for no reason. The floaters are inert unless `body.juice` is set,
// which is why they are streamed unconditionally: `$_juice` is a local view signal and never
// reaches the server.
func (s *Server) streamAnswer(
	w http.ResponseWriter, r *http.Request, sess *session.Session, outcome engine.Answered, picked int,
) {
	s.setCookie(w, sess)
	sse, done := s.openSSE(w, r)
	defer done()

	var streak, goal int
	sess.With(func() { streak, goal = sess.Score.Streak, sess.PointsGoal })

	// The streak lands with the FIRST beat, not with the view patch at the end of the
	// stream: the chip is the reward for the answer that was just given, and arriving two or
	// three seconds late (after the toasts, with the next question) read as belonging to the
	// following question.
	if err := sse.PatchSignals(render.MarshalSignals(map[string]any{"_streak": streak})); err != nil {
		return
	}

	// Sound rides the same beats, gated client-side on `$_sound`. The verdict chime goes
	// FIRST, before the toast it belongs to, because a sound that arrives after the words
	// have appeared reads as a response to reading them.
	verdict := "wrong"
	if outcome.Correct {
		verdict = "correct"
	}
	if err := clearSfx()(sse); err != nil {
		return
	}
	if err := patchElements(render.SfxBeat(verdict), sfxSelector, datastar.ElementPatchModeAppend)(sse); err != nil {
		return
	}

	for _, toast := range outcome.Toasts {
		if err := patchElements(render.Toast(toast), toastsSelector, datastar.ElementPatchModeInner)(sse); err != nil {
			return
		}
		// A milestone has just paid for a skip: the gauge that measures milestones says so
		// itself, rather than leaving it to one toast among four. Both halves are one-shot
		// appends -- the shine is taken away by the view patch at the end of the stream, the
		// sound marker by the clearSfx of the next answer.
		if toast.AwardsSkip {
			if err := patchElements(render.MeterSweep(), meterSelector, datastar.ElementPatchModeAppend)(sse); err != nil {
				return
			}
			if err := patchElements(render.SfxBeat("skip"), sfxSelector, datastar.ElementPatchModeAppend)(sse); err != nil {
				return
			}
		}
		if toast.HasPointsAfter {
			// `sess.PointsGoal`, NOT the package constant: with a debug goal of 200 these
			// mid-stream percentages were computed against 1000 while the view patch used
			// 200, so the gauge jumped backwards when the final patch arrived
			if err := sse.PatchSignals(render.MarshalSignals(map[string]any{
				"_points":    toast.PointsAfter,
				"_pointsPct": render.PointsPercent(toast.PointsAfter, goal),
			})); err != nil {
				return
			}
		}
		if picked >= 0 {
			if floater := render.Floater(toast, outcome.Completed); floater != "" {
				if err := patchElements(floater, pickedCardSelector(picked), datastar.ElementPatchModeAppend)(sse); err != nil {
					return
				}
			}
		}
		if !sleep(sse, toast.Pause) {
			return
		}
	}

	// The finale's own sound, once per quiz, with the completion screen rather than with the
	// answer: the gold floater and the confetti are the same beat, and the fanfare is long
	// enough that firing it beside the "Correct!" chime would be two flourishes over each
	// other.
	if outcome.Completed {
		if err := patchElements(render.SfxBeat("final"), sfxSelector, datastar.ElementPatchModeAppend)(sse); err != nil {
			return
		}
	}

	if err := clearToasts()(sse); err != nil {
		return
	}
	var patches []event
	sess.With(func() {
		// the clock starts when the question reaches the player, not when it was drawn --
		// the notifications above took real seconds and they are not thinking time
		if sess.StillPlaying() && !sess.AwaitingNext {
			sess.StartQuestionClock()
		}
		patches = s.viewPatches(sess)
	})
	for _, send := range patches {
		if err := send(sse); err != nil {
			return
		}
	}
}

// sleep pauses for the toast's own beat, and reports whether the client is still there. A
// disconnected browser must not keep a goroutine parked for the rest of the choreography.
func sleep(sse *datastar.ServerSentEventGenerator, seconds float64) bool {
	if seconds <= 0 {
		return sse.Context().Err() == nil
	}
	timer := time.NewTimer(time.Duration(seconds * float64(time.Second)))
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-sse.Context().Done():
		return false
	}
}

// next leaves the revealed answer and draws the next question.
//
// Only valid while parked on a reveal, so a stray press cannot skip a live question -- that
// is what Skip is for, and it costs a skip.
func (s *Server) next(w http.ResponseWriter, r *http.Request) {
	sess, replaced := s.playSession(r)
	signals := readSignals(r)
	var events []event
	sess.With(func() {
		if stale(replaced, sess, 0, false) {
			events = s.resync(sess)
			return
		}
		syncSettings(sess, signals)
		if !sess.AwaitingNext || !sess.StillPlaying() {
			return
		}
		sess.NextQuestion()
		events = append([]event{clearToasts()}, s.viewPatches(sess)...)
	})
	s.respond(w, r, sess, events)
}

// skip spends a skip, if a milestone has paid for one.
func (s *Server) skip(w http.ResponseWriter, r *http.Request) {
	sess, replaced := s.playSession(r)
	signals := readSignals(r)
	var events []event
	sess.With(func() {
		if stale(replaced, sess, 0, false) {
			events = s.resync(sess)
			return
		}
		syncSettings(sess, signals)
		if sess.SkipsLeft <= 0 || !sess.StillPlaying() {
			return
		}
		sess.SkipsLeft--
		sess.NextQuestion()
		events = append([]event{clearToasts()}, s.viewPatches(sess)...)
	})
	s.respond(w, r, sess, events)
}

func (s *Server) restart(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	signals := readSignals(r)
	var events []event
	sess.With(func() {
		syncSettings(sess, signals)
		sess.Restart()
		events = append([]event{clearToasts()}, s.viewPatches(sess)...)
	})
	s.respond(w, r, sess, events)
}

// settings adopts difficulty / ladder mode / target percentage from the bound signals.
//
// Panel restarted the quiz on every such change, so this does too -- and only when a value
// actually moved, so a re-sent identical signal set is free.
func (s *Server) settings(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	signals := readSignals(r)
	var events []event
	sess.With(func() {
		if !syncSettings(sess, signals) {
			return
		}
		sess.Restart()
		events = append([]event{clearToasts()}, s.viewPatches(sess)...)
	})
	s.respond(w, r, sess, events)
}

// timerTick is how often the held stream pushes, matching the client interval exactly -- the
// two push models must agree about the bar's motion or the mode becomes visible to the
// player, which defeats the comparison.
const timerTick = 100 * time.Millisecond

// timerStreamMax bounds a held stream. Without it an abandoned tab keeps a connection and a
// session alive forever. Ten minutes is far longer than any question; the client reopens on
// the next page load.
const timerStreamMax = 10 * time.Minute

// timer is the held-connection countdown: panel's push model, for comparison with the client
// interval.
//
// Only reachable when DSQUIZ_TIMER=stream; the shell wires `data-init` to it in that mode
// and omits the `data-on-interval` attribute, so exactly one of the two is ever live.
//
// Note what this costs against the client-interval default: a tick per 100ms per connected
// tab, each one a signal patch over the wire, whether or not the value changed. On python
// that is the mode nobody would ship; here it is a goroutine and a ticker, which is the
// point of having it.
func (s *Server) timer(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	if s.cfg.TimerMode != "stream" {
		s.respond(w, r, sess, nil)
		return
	}
	s.setCookie(w, sess)
	sse, done := s.openSSE(w, r)
	defer done()

	ticker := time.NewTicker(timerTick)
	defer ticker.Stop()
	deadline := time.After(timerStreamMax)
	for {
		var (
			playing bool
			ticking bool
			left    int
		)
		sess.With(func() {
			playing, ticking = sess.StillPlaying(), sess.OnTheClock()
			left = sess.PercentTimeLeft()
		})
		if !playing {
			_ = sse.PatchSignals(render.MarshalSignals(map[string]any{"_timeLeftPct": 0}))
			return
		}
		// Nothing to push while parked on a reveal: the question has been answered, so the
		// clock is frozen and every tick would restate the same number. The client interval
		// gates on the same condition (`$_ticking`).
		if ticking {
			if err := sse.PatchSignals(render.MarshalSignals(map[string]any{"_timeLeftPct": left})); err != nil {
				return
			}
		}
		select {
		case <-ticker.C:
		case <-deadline:
			return
		case <-sse.Context().Done():
			return
		}
	}
}

// --- the bidding-tree filter ------------------------------------------------

const (
	filterStatusSelector = "#filter-status"
	topicsStatusSelector = "#topics-status"
)

func (s *Server) preview(w http.ResponseWriter, r *http.Request, sess *session.Session, text, selector, hint string) {
	var events []event
	sess.With(func() {
		check := sess.System.CheckFilter(text, engine.MaxDifficulty)
		events = []event{patchElements(
			render.FilterStatus(check, sess.FilterText, hint), selector, datastar.ElementPatchModeInner)}
	})
	s.respond(w, r, sess, events)
}

// filterPreview is what the text in the box *would* select. Commits nothing.
//
// This is the panel `value_input` watcher, except the validation never left the server.
// Cheap enough to run per keystroke because the corpus is pre-parsed and the check is
// memoised.
func (s *Server) filterPreview(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	s.preview(w, r, sess, filterTextFrom(readSignals(r)), filterStatusSelector, "press Enter to apply")
}

func (s *Server) topicsPreview(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	signals := readSignals(r)
	var text string
	sess.With(func() { text = topicsTextFrom(sess, signals) })
	s.preview(w, r, sess, text, topicsStatusSelector, "press Apply to use this")
}

// topicsReset: Close (and Escape) DISCARD the ticks, putting them back to the filter in
// force.
//
// The picker has an explicit Apply and says so in its own first line, which makes Close the
// cancel path -- and a cancel that quietly keeps your edits is the odd one out among dialogs.
// Keeping them also left the picker disagreeing with the app: reopening showed ticks that
// select nothing, under a status line reading "N auctions match, press Apply" while the
// drawer reported the real working set.
//
// Only the `topics` branch is patched. The bound signals also carry the difficulty and
// `filterText`, and `filterText` is a DRAFT the player may be part-way through typing in the
// drawer behind the dialog -- re-sending it here would wipe it.
func (s *Server) topicsReset(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	var events []event
	sess.With(func() {
		check := sess.System.CheckFilter(sess.FilterText, engine.MaxDifficulty)
		inForce := render.BoundSignals(sess, check.Parsed.TopicNames)["topics"]
		events = []event{
			patchSignals(map[string]any{"topics": inForce}),
			// ...and the picker's own status line, which was previewing a selection that no
			// longer exists. Empty rather than re-rendered: with nothing pending there is
			// nothing to say.
			patchElements("", topicsStatusSelector, datastar.ElementPatchModeInner),
		}
	})
	s.respond(w, r, sess, events)
}

// commitFilter is the one path that changes the filter in force.
func (s *Server) commitFilter(w http.ResponseWriter, r *http.Request, sess *session.Session, text string) {
	var events []event
	sess.With(func() {
		check, changed := sess.ApplyFilter(text, engine.MaxDifficulty)
		events = []event{
			patchElements(render.FilterStatus(check, sess.FilterText, ""), filterStatusSelector, datastar.ElementPatchModeInner),
			patchElements("", topicsStatusSelector, datastar.ElementPatchModeInner),
			// the box and the picker are brought into line with what was actually applied:
			// the canonical text has topic prefixes expanded and the whitespace tidied
			patchSignals(render.BoundSignals(sess, check.Parsed.TopicNames)),
		}
		if changed {
			sess.Restart()
			events = append(events, clearToasts())
			events = append(events, s.viewPatches(sess)...)
		}
	})
	s.respond(w, r, sess, events)
}

func (s *Server) filterApply(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	s.commitFilter(w, r, sess, filterTextFrom(readSignals(r)))
}

// topicsApply replaces whatever is in the filter box with the ticked topics, as panel did.
func (s *Server) topicsApply(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	signals := readSignals(r)
	var text string
	sess.With(func() { text = topicsTextFrom(sess, signals) })
	s.commitFilter(w, r, sess, text)
}

// --- debug panel ------------------------------------------------------------

// debugPoints adds or removes points without answering anything.
//
// Deliberately does NOT check the goal: crossing it by hand should not fake a completion,
// because then the finale would be reachable without the code path that produces it.
// `/debug/complete` is the honest way to see that screen.
func (s *Server) debugPoints(w http.ResponseWriter, r *http.Request) {
	delta, err := strconv.Atoi(r.PathValue("delta"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	sess, _ := s.playSession(r)
	var events []event
	sess.With(func() {
		if !sess.Debug {
			return
		}
		sess.Score.TotalPoints = max(0, sess.Score.TotalPoints+delta)
		events = s.viewPatches(sess)
	})
	s.respond(w, r, sess, events)
}

// debugGoal shortens (or lengthens) the quiz. Per session, so this is not a global mutation.
// The milestones that pay for skips are fractions of the goal, so lowering it also brings
// those forward -- which is the point: a 200-point goal exercises the whole ladder in a
// minute.
func (s *Server) debugGoal(w http.ResponseWriter, r *http.Request) {
	value, err := strconv.Atoi(r.PathValue("value"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	sess, _ := s.playSession(r)
	var events []event
	sess.With(func() {
		if !sess.Debug {
			return
		}
		sess.PointsGoal = max(10, min(value, 100_000))
		events = s.viewPatches(sess)
	})
	s.respond(w, r, sess, events)
}

// debugComplete jumps to the finale, through the real scoring path.
//
// Points are set one short of the goal and the current question is answered *correctly*, so
// this goes through engine.Answer -> Completed -> the toast chain -> the completion screen,
// including the gold goal-crossing floater. Faking the completion would show the screen while
// skipping everything that makes it happen.
func (s *Server) debugComplete(w http.ResponseWriter, r *http.Request) {
	sess, replaced := s.playSession(r)
	var (
		armed        bool
		qid          int64
		correctIndex int
	)
	sess.With(func() {
		if !sess.Debug {
			return
		}
		armed = true
		if !sess.StillPlaying() {
			sess.Restart()
		}
		sess.Score.TotalPoints = max(0, sess.PointsGoal-1)
		sess.AwaitingNext = false
		qid, correctIndex = sess.QID, sess.Question.AnswerIndex()
	})
	if !armed || correctIndex < 0 {
		s.respond(w, r, sess, nil)
		return
	}
	// No floaters on this path: the browser is showing whatever it was showing (often the
	// previous finale, since this restarts a finished quiz), so a patch aimed at
	// `.candidates > :nth-child(n)` finds no target and datastar logs
	// `PatchElementsNoTargetsFound` for every scoring beat.
	s.scoreAnswer(w, r, sess, replaced, qid, correctIndex, false)
}

// debugReveal parks on the reveal without getting one wrong, for looking at the shake and
// the marks.
func (s *Server) debugReveal(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.playSession(r)
	var events []event
	sess.With(func() {
		if !sess.Debug {
			return
		}
		if !sess.StillPlaying() {
			sess.Restart()
		}
		sess.AwaitingNext = true
		sess.FreezeQuestionClock()
		correct := sess.Question.AnswerIndex()
		if correct < 0 || len(sess.Question.Candidates) == 0 {
			return
		}
		sess.WrongIndex = (correct + 1) % len(sess.Question.Candidates)
		events = s.viewPatches(sess)
	})
	s.respond(w, r, sess, events)
}

// --- sound ------------------------------------------------------------------

// sound serves one synthesised WAV. There is no `static/sfx/` directory -- see internal/sfx.
//
// Cached HARD (a year, and immutable in effect) because the bytes for a given name never
// change within a build; the `?v=` the page appends is the build stamp, so an edited synth
// arrives as a different URL rather than waiting out a cache. `preload="auto"` means the
// browser asks for all five the moment sound is switched on, and never again.
func (s *Server) sound(w http.ResponseWriter, r *http.Request) {
	audio, ok := sfx.Sounds[r.PathValue("name")]
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "audio/wav")
	w.Header().Set("Cache-Control", "public, max-age=31536000")
	_, _ = w.Write(audio)
}
