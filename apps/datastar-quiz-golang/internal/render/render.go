// Package render is the HTML: the page shell, the patchable fragments, and the signal
// payloads. A port of `apps/datastar-quiz/render.py` and its jinja templates.
//
// Two things worth knowing about how the fragments are split:
//
//   - Only `#quiz` and `#toasts` are ever patched as *elements*. The score panel, the skip
//     counter and the timer bar are markup that never changes -- their values arrive as
//     signals and are applied by `data-text` / `data-style`. That is datastar's "backend
//     drives the frontend by patching elements *and* signals" with the cheap half used
//     where it fits.
//   - Those server-owned display signals are `_`-prefixed (`$_points`, `$_scorePct`, ...).
//     The underscore means datastar excludes them from every outgoing request, which is
//     exactly right: the server told the browser these values, so it must not have them
//     echoed back on the next click.
//
// The templates are `html/template` rather than the SDK's preferred `templ`. templ is the
// better pairing on paper -- compiled, type-checked, `sse.PatchElementTempl` -- but it
// costs a codegen step and a generator binary, and the handoff names stdlib templates as
// the fallback for exactly that reason. What is measured here is the runtime, and both
// compile the markup once; templ would move template execution off the request path
// entirely, which is worth revisiting if the profile ever points at it.
package render

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"html/template"
	"io/fs"
	"strconv"
	"strings"
	"sync"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/engine"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/session"
)

// DefaultCSS is the base stylesheet everyone gets. The A/B/C between the hand-rolled
// sheet, Pico and Bulma is over (COMPARISON.md): the three are near-indistinguishable to a
// player, so the picker is a DEBUG-only control and this is what a session starts with.
const DefaultCSS = "pico"

// The theme preference, remembered in a COOKIE rather than in localStorage: a cookie is on
// the request, so the server can render `data-theme` into the FIRST PAINT, and cookies are
// keyed by host and PATH rather than by origin, so one choice covers every instance on the
// machine. Written by the browser (`document.cookie` in the toggle's expression), read
// here -- the server has no opinion about the theme, it just relays what it was told.
const ThemeCookie = "dsq_theme"

var themes = map[string]bool{"auto": true, "light": true, "dark": true}

// ThemeFrom reads the theme cookie. A cookie is user input: anything unrecognised is
// `auto`, never interpolated into the page.
func ThemeFrom(raw string) string {
	if themes[raw] {
		return raw
	}
	return "auto"
}

// StylesheetHref is the naming contract, in Go: `hand` is `app.css`, anything else is
// `app-<value>.css`. The template builds the same string from `$_css` at runtime; this is
// for the two places the server has to state it -- the static href that paints before
// datastar runs, and the fallback that expression uses when the signal has not been
// declared yet (it is in <head>).
func StylesheetHref(value, prefix string) string {
	name := "app-" + value + ".css"
	if value == "hand" {
		name = "app.css"
	}
	return prefix + "/static/" + name
}

// What may swallow a keystroke aimed at the window. Every accelerator (1-9, `s`, Enter on
// the reveal) is a window keydown, so each one has to decide whether the focused control
// has a better claim on the key -- and the first version of this said "any form control",
// which is too many. Focus a RANGE input (the difficulty slider) or tick a CHECKBOX and the
// digits went dead for the rest of the session: a range has no use for `1`, a checkbox has
// no use for `s`.
const TypingTargets = "input:not([type=range]):not([type=checkbox]):not([type=radio]), select, textarea, [contenteditable]"

// Enter and Space are different: Space ACTIVATES a focused checkbox or radio, so those keep
// their claim here even though they have none on a digit.
const ActivationTargets = "input:not([type=range]), select, textarea, [contenteditable]"

// DrawerOverlayQuery is the width at which the drawer stops being a column beside the quiz
// and becomes an overlay ON TOP of it. Below this it hides the thing you are configuring,
// so the handlers that mean "done" close it; above it, closing the drawer would just take
// the settings away. Written once here because it has to agree with the `@media` block that
// does the repositioning.
const DrawerOverlayQuery = "(max-width: 900px)"

// --- suit glyph presentation (copied from the panel app) ---------------------
//
// The plain text glyphs, deliberately WITHOUT the U+FE0F variation selector the panel app
// used: VS16 asks for emoji presentation, so hearts and diamonds were drawn by the colour
// emoji font while spades and clubs stayed text glyphs inheriting the element's colour --
// which is why a spade went white on the dark card. All four are text glyphs now, and
// `suits` colours them with bml's own classes so the quiz matches the system notes.
const (
	Spade   = "♠"
	Heart   = "♥"
	Diamond = "♦"
	Club    = "♣"
)

// glyph -> bml css class. Same names and glyphs as `bml2html._SUIT`, so the colours defined
// in `bml.css` are the colours here.
var suitClasses = map[rune]string{
	'♣': "ccolor",
	'♦': "dcolor",
	'♥': "hcolor",
	'♠': "scolor",
}

// Suits colours the suit glyphs: `♠` -> `<span class="scolor">♠</span>`.
//
// The input is escaped first, so this is safe for anything -- including the bml
// descriptions, which are corpus text rather than user input, and the auctions inside toast
// messages. A separate step from EmojiTextAuction because that function's output also
// travels through the engine's toast strings, where markup would be escaped again.
func Suits(text string) template.HTML {
	escaped := template.HTMLEscapeString(text)
	var out strings.Builder
	out.Grow(len(escaped))
	for _, ch := range escaped {
		if class, ok := suitClasses[ch]; ok {
			out.WriteString(`<span class="` + class + `">`)
			out.WriteRune(ch)
			out.WriteString(`</span>`)
			continue
		}
		out.WriteRune(ch)
	}
	return template.HTML(out.String())
}

// --- templates --------------------------------------------------------------

var funcs = template.FuncMap{
	"suits":  Suits,
	"figure": figure,
	// `js` marks a value as already-safe inside a JavaScript STRING literal.
	//
	// html/template decides an attribute's content type from its name, and after stripping
	// the `data-` prefix every `data-on:*` attribute starts with "on" -- so datastar's event
	// expressions are treated as JavaScript, which is correct but has one visible
	// consequence: the default string escaper rewrites `/` as `\/`. Semantically that is the
	// same string, but the load harness reads the mount prefix back out of the raw HTML with
	// a regex (`apps/dsquiz-perf/common/datastar.py`), and `\/bridge-system-quiz` is not a
	// path. template.JSStr uses the NORMALISING table instead, which still escapes the HTML
	// specials (`<`, `>`, `&`, quotes) but leaves a slash alone.
	//
	// Used only on values that are the server's own -- the mount prefix and the cookie path.
	"js":  func(text string) template.JSStr { return template.JSStr(text) },
	"inc": func(i int) int { return i + 1 },
	"iterate": func(n int) []int {
		out := make([]int, n)
		for i := range out {
			out[i] = i
		}
		return out
	},
}

var (
	stampOnce  sync.Once
	buildStamp string
)

// BuildStamp is a short fingerprint of the templates, shown in the debug panel.
//
// Not vanity. Three times in the python app a "this is broken again" turned out to be a
// process serving code from before the fix. Go cannot hot-reload at all, so here the stamp
// answers the narrower question the same way: is the binary in front of me the one I just
// built? It changes whenever the markup does.
func BuildStamp() string {
	stampOnce.Do(func() {
		hash := fnv.New64a()
		_ = fs.WalkDir(templateFS, ".", func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.IsDir() {
				return err
			}
			body, err := templateFS.ReadFile(path)
			if err != nil {
				return err
			}
			hash.Write([]byte(path))
			hash.Write(body)
			return nil
		})
		buildStamp = fmt.Sprintf("%x", hash.Sum64())
		if len(buildStamp) > 6 {
			buildStamp = buildStamp[len(buildStamp)-6:]
		}
	})
	return buildStamp
}

// Config is the deployment-shaped state the renderer needs and does not own: where the app
// is mounted, which countdown model the shell should wire up.
type Config struct {
	// Prefix is where the app is mounted, when it is not at the root of a host. Empty for
	// a root mount, which is the default. The templates emit `@post('<prefix>/answer/...')`
	// and `<link href="<prefix>/static/app.css">`; without the prefix on those, the browser
	// asks the site's ROOT for them and everything 404s.
	Prefix string
	// TimerMode is "client" or "stream" -- see the note in the web package.
	TimerMode string
}

// TopicChoice is one row of the topics picker.
//
// Bind is the whole `data-bind:topics.<slug>` attribute, precomputed. It has to be one
// typed value rather than a slug interpolated after `data-bind:topics.` in the template,
// because html/template refuses to interpolate into an attribute NAME -- and this is a
// name: the signal path is written in the attribute key, which is the naming trap the
// kebab/camel transform above exists for.
type TopicChoice struct {
	Name        string
	Slug        string
	Key         string
	Description string
	Bind        template.HTMLAttr
}

// PageData is everything both the document and the fat-morph fragment need.
type PageData struct {
	Variant                corpus.Variant
	Settings               session.Settings
	Playing                bool
	QuizBody               template.HTML
	MinDifficulty          int
	MaxDifficulty          int
	MilestoneTicks         []int
	PointsGoal             int
	Debug                  bool
	QID                    int64
	TimerMode              string
	BuildStamp             string
	CSSHref                string
	ThemeCookie            string
	Topics                 []TopicChoice
	TopicsHaveDescriptions bool
	FilterText             string
	FilterStatus           template.HTML
	VariantQuery           string
	DrawerOverlayQuery     string
	TypingTargets          string
	ActivationTargets      string
}

// ShellData is PageData plus what only the whole document carries.
type ShellData struct {
	PageData
	InitialSignals string
	// The static `data-theme` on <html>, or empty. `auto` is the ABSENCE of the attribute
	// -- see the theme switch note in app.css -- so this is the whole attribute rather than
	// a value, and typed so html/template will place it in the tag.
	ThemeAttr template.HTMLAttr
	SfxNames  []string
}

// QuizData is the `#quiz` fragment's model: the live question, or the reveal.
type QuizData struct {
	Intro             string
	Answer            template.HTML
	Candidates        []template.HTML
	QID               int64
	VariantQuery      string
	TypingTargets     string
	ActivationTargets string
	CorrectIndex      int
	WrongIndex        int
}

// CompletedData is the finale.
type CompletedData struct {
	Elapsed      int
	Points       int
	Correct      int
	Attempted    int
	Percentage   int
	Goal         int
	Confetti     []ConfettiBit
	VariantQuery string
}

// ConfettiBit is one piece of the burst: glyph, horizontal drift %, rotation, delay step.
type ConfettiBit struct {
	Glyph string
	Drift int
	Spin  int
	Step  int
}

// The confetti burst on the completion screen: fixed, not random, because the server
// renders it and a reload should not re-roll the party. The numbers are spread by hand so
// the burst looks scattered rather than combed, which is the one thing a formula
// (`i * 37 % 100`) visibly fails at.
var confetti = []ConfettiBit{
	{"\U0001F389", -42, -35 * 12, 0},
	{"\U0001F38A", -28, 24 * 12, 3},
	{"✨", -35, -12 * 12, 7},
	{"\U0001F973", -14, 41 * 12, 1},
	{"\U0001F389", -6, -28 * 12, 5},
	{"\U0001F38A", 9, 16 * 12, 2},
	{"✨", 18, -44 * 12, 8},
	{"\U0001F389", 27, 31 * 12, 4},
	{"\U0001F973", 36, -19 * 12, 6},
	{"\U0001F38A", 44, 38 * 12, 1},
	{"✨", -21, 9 * 12, 9},
	{"\U0001F389", 3, -40 * 12, 7},
	{"\U0001F38A", 31, 12 * 12, 3},
	{"✨", -47, 27 * 12, 5},
	{"\U0001F973", 22, -33 * 12, 8},
	{"\U0001F389", -11, 44 * 12, 2},
}

var intros = map[engine.ChoiceType]string{
	engine.Auctions:     "In which auction is the final bid best described by:",
	engine.Descriptions: "Which description matches the final bid in this sequence:",
}

// figure is the completion screen's `number` macro: one span per character, numbered, so
// each can be sent in from somewhere different. The unit lives INSIDE the figure, not
// beside it: `.finale-stat` is a flex column, so a sibling `%` or `s` became its own row
// under the number.
func figure(value int, class, unit string) template.HTML {
	var out strings.Builder
	out.WriteString(`<span class="figure ` + template.HTMLEscapeString(class) + `">`)
	for i, ch := range strconv.Itoa(value) {
		out.WriteString(`<span class="digit" style="--i: ` + strconv.Itoa(i) + `">`)
		out.WriteRune(ch)
		out.WriteString(`</span>`)
	}
	if unit != "" {
		out.WriteString(`<span class="figure-unit">` + template.HTMLEscapeString(unit) + `</span>`)
	}
	out.WriteString(`</span>`)
	return template.HTML(out.String())
}

func (c Config) render(name string, data any) string {
	var out strings.Builder
	if err := templatesFor(c.Prefix).ExecuteTemplate(&out, name, data); err != nil {
		// A template that does not execute is a programming error, not a request error:
		// the data shapes are fixed at compile time and the templates are embedded. Panic
		// rather than serving half a page, so the failure is one stack trace at the first
		// request instead of a page that is subtly wrong for everybody.
		panic("render " + name + ": " + err.Error())
	}
	return out.String()
}

// VariantQuery is the query every ACTION url carries, naming the system this page belongs
// to (`?swedish`).
//
// The session cookie is one per browser, so it cannot say which quiz a given *page* is
// playing: open `?swedish` and the squad tab, the back-history entry and the phone's other
// tab all still hold the old markup while the cookie has moved on. The page's own URLs can
// say it, and they are written by the server that knows.
func VariantQuery(variant corpus.Variant) string { return "?" + variant.Key }

// --- signals ----------------------------------------------------------------

// Signals is every signal the server owns, as a patch payload.
//
// Local (`_`-prefixed) so they are never uploaded back. `_timeLeftPct` and `_questionMs`
// drive the timer bar: the server states the allowance and resets the bar to 100 per
// question, and the browser's 100ms interval walks it down. No clock is shared, because the
// bar is cosmetic -- the bonus that actually scores is recomputed server-side from
// QuestionStart when the answer arrives. Call with the session lock held.
func Signals(s *session.Session) map[string]any {
	timeLeft := 0
	if s.StillPlaying() {
		timeLeft = s.PercentTimeLeft()
	}
	return map[string]any{
		"_correct":   s.Score.QuestionsCorrect,
		"_attempted": s.Score.QuestionsAttempted,
		"_scorePct":  s.Score.Percentage(),
		"_points":    s.Score.TotalPoints,
		"_pointsPct": PointsPercent(s.Score.TotalPoints, s.PointsGoal),
		"_streak":    s.Score.Streak,
		"_skipsLeft": s.SkipsLeft,
		"_playing":   s.StillPlaying(),
		// Whether the countdown should be running at all. `_playing` is not the same
		// question: a scored answer parks on the reveal with the quiz very much still in
		// play, and the bar kept draining there -- time pressure on a question that had
		// already been answered. The client interval and the held stream both gate on it.
		"_ticking":     s.OnTheClock(),
		"_questionMs":  pyRound(s.QuestionSecs * 1000),
		"_timeLeftPct": timeLeft,
	}
}

// PointsPercent is the gauge's fill, capped at 100.
func PointsPercent(points, goal int) int {
	if goal <= 0 {
		return 0
	}
	return min(pyRound(float64(points)/float64(goal)*100), 100)
}

// SettingsSignals are the *effective* settings, to be echoed back after the server has
// adopted them.
//
// The browser originates these, but the server clamps them, so after adopting a value the
// two can disagree -- send `difficulty: 99` and the server uses 8 while the slider still
// reads 99 until the next page load.
//
// Note what is deliberately NOT here: `filterText` and the `topics` ticks. Those are drafts
// the user may be in the middle of editing, and re-stating them on an unrelated patch (a
// Skip, say) would wipe what they were typing. Call with the session lock held.
func SettingsSignals(s *session.Session) map[string]any {
	return map[string]any{
		"difficulty": s.Settings.Difficulty,
		"ladderMode": s.Settings.LadderMode,
		"targetOn":   s.Settings.TargetOn,
		"targetPct":  s.Settings.TargetPct,
	}
}

// BoundSignals are the signals the *browser* owns: form inputs bound with `data-bind`.
//
// These have no underscore, so datastar uploads them with every request -- that is how the
// server learns the slider moved. `topics` is seeded from the filter in force, so the
// picker's ticks agree with it even when the filter was typed rather than picked. Call with
// the session lock held.
func BoundSignals(s *session.Session, activeTopics []string) map[string]any {
	ticked := map[string]bool{}
	for _, name := range activeTopics {
		ticked[TopicSignalKey(name)] = true
	}
	topics := map[string]bool{}
	for _, choice := range TopicChoices(s.System) {
		topics[choice.Key] = ticked[choice.Key]
	}
	out := SettingsSignals(s)
	out["filterText"] = s.FilterText
	out["topics"] = topics
	return out
}

// LocalUISignals are view-local signals the server never sets, declared so they exist from
// the first paint.
//
// They must be declared: an undefined signal reads as `”` in an expression, and
// `data-attr` treats `”` as "set the attribute", so an undeclared `$_topicsOpen` leaves
// `<dialog open>` -- the picker is stuck open. Declared in the `data-signals` OBJECT rather
// than as `data-signals:_topics-open`, because attribute keys are kebab-then-camel
// converted, which eats a leading underscore -- and the underscore is what keeps these out
// of every request.
func LocalUISignals(theme string) map[string]any {
	return map[string]any{
		"_topicsOpen": false,
		"_answering":  false,
		"_font":       "notes",
		// `auto` | `light` | `dark`, remembered across reloads in ThemeCookie and seeded
		// from it here, so the signal and the server-rendered attribute agree from the
		// first frame.
		"_theme": theme,
		// closed at every width now that the drawer holds only settings
		"_navOpen": false,
		"_css":     DefaultCSS,
		// The "game feel" experiment: hit-stop and shake on the reveal, floating points on
		// the card you picked, and an escalating streak chip. Purely presentational, so
		// purely local -- the server streams the floaters either way and `body.juice`
		// decides whether they are visible.
		"_juice": true,
		// Sound, OFF by default and the only appearance preference that is. Everything else
		// here changes how the page looks to the person who asked for it; audio arrives in
		// a room, and a quiz played in a lesson or on a train should make no noise until
		// someone says so. It also gates the FETCH: the <audio> elements have no `src`
		// until this is true.
		"_sound": false,
	}
}

// MarshalSignals is the JSON a signal patch or the `data-signals` attribute carries.
func MarshalSignals(signals map[string]any) []byte {
	body, err := json.Marshal(signals)
	if err != nil {
		panic("signals: " + err.Error()) // map[string]any of scalars cannot fail
	}
	return body
}
