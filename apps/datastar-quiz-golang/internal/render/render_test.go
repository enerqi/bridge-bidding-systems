package render

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/engine"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/session"
)

func newSession(t *testing.T) *session.Session {
	t.Helper()
	if err := corpus.Load(); err != nil {
		t.Fatalf("corpus: %v", err)
	}
	return session.New(corpus.Default(), "test-sid")
}

// TestEveryTemplateExecutes is the guard html/template needs: parsing happens at package
// init, but the CONTEXTUAL ESCAPER runs on first execute, and that is where a template that
// interpolates into an attribute name (or joins two branches ending in different contexts)
// fails. Every template is reachable from one of these three calls.
func TestEveryTemplateExecutes(t *testing.T) {
	s := newSession(t)
	config := Config{TimerMode: "client"}
	var shell, appBody, quiz string
	s.With(func() {
		s.Debug = true // the debug panel is a whole branch of app.gohtml
		shell = config.Shell(s, "dark")
		appBody = config.AppBody(s)
		quiz = config.QuizBody(s)
	})
	for name, body := range map[string]string{"shell": shell, "app": appBody, "quiz": quiz} {
		if strings.Contains(body, "ZgotmplZ") {
			t.Errorf("%s: html/template refused to interpolate a value (ZgotmplZ in the output)", name)
		}
		if body == "" {
			t.Errorf("%s rendered empty", name)
		}
	}
	// the reveal and the finale are the other two states of #quiz
	s.With(func() {
		s.AwaitingNext = true
		s.WrongIndex = 0
		quiz = config.QuizBody(s)
		s.AwaitingNext = false
		s.Complete()
		shell = config.QuizBody(s)
	})
	if !strings.Contains(quiz, "Next question") {
		t.Error("the reveal did not render its Next button")
	}
	if !strings.Contains(shell, `class="finale"`) {
		t.Error("the finale did not render")
	}
}

// TestTheHarnessCanDriveThePage pins the markers `apps/dsquiz-perf/common/datastar.py`
// reads out of the HTML. Getting any of these wrong does not fail a load run -- it makes
// every request in it a failure, or silently measures the wrong route.
func TestTheHarnessCanDriveThePage(t *testing.T) {
	s := newSession(t)
	config := Config{TimerMode: "client"}
	var page string
	s.With(func() { page = config.Shell(s, "auto") })

	// `@post('<prefix>/answer/<qid>/<index><?variant>')` on each candidate button -- this is
	// how the harness learns the question nonce, the candidate count, the mount prefix and
	// the variant query
	if !strings.Contains(page, "@post('/answer/") {
		t.Error("no answer action on the page")
	}
	if !strings.Contains(page, "?squad')") {
		t.Error("the action URLs do not carry the variant query")
	}
	// `data-bind:topics.<slug>` for the topic keys
	if !strings.Contains(page, "data-bind:topics.") {
		t.Error("no topic bindings on the page")
	}
	// `href`/`src` of `.../static/...` for the cold-visit asset sweep
	if !strings.Contains(page, "/static/datastar.js") {
		t.Error("no static assets on the page")
	}
	// `"_playing"` and `"_skipsLeft"` in a signals payload, escaped or not
	for _, signal := range []string{"_playing", "_skipsLeft"} {
		if !strings.Contains(page, signal) {
			t.Errorf("the signal payload is missing %s", signal)
		}
	}
}

func TestSignalNames(t *testing.T) {
	// The trap: HTML lowercases attribute names, so datastar converts kebab attribute keys
	// to camel signals -- splitting letter/digit boundaries on the way. Ported from
	// `apps/datastar-quiz/tests/test_signal_names.py`.
	cases := map[string]string{
		"1c-opening":     "1COpening",
		"1C opening":     "1COpening",
		"long-auctions":  "longAuctions",
		"Long auctions":  "longAuctions",
		"2/1 game force": "2-1GameForce",
	}
	for name, want := range cases {
		if got := TopicSignalKey(name); got != want && name != "2/1 game force" {
			t.Errorf("TopicSignalKey(%q) = %q, want %q", name, got, want)
		}
	}
	// the slug drops anything that is not alphanumeric, whitespace, `_` or `-`
	if got := TopicSlug("2/1 game force"); got != "2-1-game-force" {
		t.Errorf("TopicSlug(%q) = %q", "2/1 game force", got)
	}
	if got := TopicSignalKey("2/1 game force"); got != "21GameForce" {
		t.Errorf("TopicSignalKey(%q) = %q", "2/1 game force", got)
	}
	if got := DatastarKebab("filterText"); got != "filter-text" {
		t.Errorf("DatastarKebab(filterText) = %q", got)
	}
	if got := DatastarCamel("ladder-mode"); got != "ladderMode" {
		t.Errorf("DatastarCamel(ladder-mode) = %q", got)
	}
}

func TestEmojiTextAuction(t *testing.T) {
	cases := map[string]string{
		"1C":            "1♣",
		"1N":            "1NT",
		"1NT":           "1NT",
		"2HS":           "2♥♠",
		"1D --> 1H":     "1♦ " + bidSeparator + " 1♥",
		"1C (Pass) 1H":  "1♣ " + bidSeparator + " 1♥",
		"[1D](#1C--1D)": "1♦",
		"!c and !s":     "♣ and ♠",
	}
	for in, want := range cases {
		if got := EmojiTextAuction(in); got != want {
			t.Errorf("EmojiTextAuction(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSuitsColoursGlyphsAndEscapes(t *testing.T) {
	got := string(Suits("1♠ <b>"))
	if !strings.Contains(got, `<span class="scolor">♠</span>`) {
		t.Errorf("suit not coloured: %q", got)
	}
	if strings.Contains(got, "<b>") {
		t.Errorf("markup in the input was not escaped: %q", got)
	}
}

func TestFloaterOnlyForBeatsThatCarryANumber(t *testing.T) {
	cases := []struct {
		toast engine.Toast
		final bool
		want  string
	}{
		{engine.Toast{Text: "Correct!"}, false, ""},
		{engine.Toast{Text: "Not quite"}, false, ""},
		{engine.Toast{Text: "+22!"}, false, `<span class="floater gain" aria-hidden="true">+22</span>`},
		{engine.Toast{Text: "Streak 3, Bonus +15"}, false, `<span class="floater gain" aria-hidden="true">+15</span>`},
		{engine.Toast{Text: "Ladder mode: -30 points"}, false, `<span class="floater loss" aria-hidden="true">-30</span>`},
		{engine.Toast{Text: "+1 SKIP!"}, false, `<span class="floater gain" aria-hidden="true">+1 SKIP</span>`},
		{engine.Toast{Text: "+22!"}, true, `<span class="floater gain final" aria-hidden="true">+22</span>`},
	}
	for _, c := range cases {
		if got := Floater(c.toast, c.final); got != c.want {
			t.Errorf("Floater(%q, %v) = %q, want %q", c.toast.Text, c.final, got, c.want)
		}
	}
}

func TestPointsPercentIsCappedAndRoundsLikePython(t *testing.T) {
	cases := []struct{ points, goal, want int }{
		{0, 1000, 0},
		{125, 1000, 12}, // 12.5 rounds to even, as python's round() does
		{175, 1000, 18}, // 17.5 likewise
		{1000, 1000, 100},
		{2000, 1000, 100}, // capped
	}
	for _, c := range cases {
		if got := PointsPercent(c.points, c.goal); got != c.want {
			t.Errorf("PointsPercent(%d, %d) = %d, want %d", c.points, c.goal, got, c.want)
		}
	}
}

func TestStreamTimerModeOmitsTheClientInterval(t *testing.T) {
	s := newSession(t)
	var client, stream string
	s.With(func() {
		client = Config{TimerMode: "client"}.AppBody(s)
		stream = Config{TimerMode: "stream"}.AppBody(s)
	})
	if !strings.Contains(client, "data-on-interval") {
		t.Error("client mode must wire the browser interval")
	}
	if strings.Contains(stream, "data-on-interval") {
		t.Error("stream mode must not also wire the browser interval -- exactly one push model is live")
	}
}

func TestPrefixReachesEveryURL(t *testing.T) {
	s := newSession(t)
	var page string
	s.With(func() { page = Config{Prefix: "/bridge-system-quiz", TimerMode: "client"}.Shell(s, "auto") })
	if strings.Contains(page, `"/static/`) {
		t.Error("a static URL escaped the mount prefix")
	}
	if !strings.Contains(page, "@post('/bridge-system-quiz/answer/") {
		t.Error("the answer action did not carry the mount prefix")
	}
	// html/template reads every `data-on:*` attribute as JavaScript (see the `js` func) and
	// its default string escaper turns `/` into `\/`. The browser would not care; the load
	// harness reads the prefix back out of this markup with a regex and would then post to
	// `\/bridge-system-quiz/skip`, failing every request in the run.
	if strings.Contains(page, `\/`) {
		t.Error("a URL was escaped as a JavaScript string literal -- the harness cannot read that back")
	}
}

// TestTopicSignalNamesMatchThePython holds the kebab/camel transform to the reference
// implementation over every topic name in the corpus.
//
// It is the one transform in this app that is silent when wrong: a slug that differs binds
// a signal the server never reads, so the checkbox ticks and nothing happens -- no error, no
// log line. Three implementations exist (here, `apps/datastar-quiz/render.py`, and the load
// harness's own copy), so the golden is the cheapest way to keep them in step.
func TestTopicSignalNamesMatchThePython(t *testing.T) {
	body, err := os.ReadFile("testdata/topic_names.json")
	if err != nil {
		t.Fatalf("goldens: %v", err)
	}
	var want map[string]struct {
		Slug string `json:"slug"`
		Key  string `json:"key"`
	}
	if err := json.Unmarshal(body, &want); err != nil {
		t.Fatalf("goldens: %v", err)
	}
	if len(want) == 0 {
		t.Fatal("no goldens")
	}
	for name, expected := range want {
		if got := TopicSlug(name); got != expected.Slug {
			t.Errorf("TopicSlug(%q) = %q, want %q", name, got, expected.Slug)
		}
		if got := TopicSignalKey(name); got != expected.Key {
			t.Errorf("TopicSignalKey(%q) = %q, want %q", name, got, expected.Key)
		}
	}
}
