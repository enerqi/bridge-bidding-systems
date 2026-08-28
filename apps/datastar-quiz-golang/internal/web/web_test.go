package web

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/session"
)

// These are the python suite's BEHAVIOURS, ported: `test_routes`, `test_stale_pages`,
// `test_morph_modes`, `test_variants`, `test_timer_modes` and `test_url_prefix`. The
// handoff's warning is the reason they are here rather than left for later -- "the python
// port's own history is a list of behaviours that look optional until they are missing --
// the 204 no-ops, the question nonce, the per-variant session keying -- and each one
// silently corrupts a load run rather than failing it."

const signalsBody = `{"difficulty":5,"ladderMode":false,"targetOn":false,"targetPct":80,"filterText":"","topics":{}}`

// client is a browser: one cookie jar against one server.
type client struct {
	t      *testing.T
	server *Server
	cookie *http.Cookie
}

func newClient(t *testing.T, cfg Config) *client {
	t.Helper()
	if err := corpus.Load(); err != nil {
		t.Fatalf("corpus: %v", err)
	}
	server, err := New(cfg, session.NewStore())
	if err != nil {
		t.Fatalf("server: %v", err)
	}
	return &client{t: t, server: server}
}

func (c *client) do(method, path, body string) *httptest.ResponseRecorder {
	c.t.Helper()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	r := httptest.NewRequest(method, path, reader)
	if body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	if c.cookie != nil {
		r.AddCookie(c.cookie)
	}
	w := httptest.NewRecorder()
	c.server.Handler().ServeHTTP(w, r)
	for _, set := range w.Result().Cookies() {
		if set.Name == session.Cookie {
			c.cookie = set
		}
	}
	return w
}

func (c *client) get(path string) *httptest.ResponseRecorder { return c.do(http.MethodGet, path, "") }
func (c *client) post(path string) *httptest.ResponseRecorder {
	return c.do(http.MethodPost, path, signalsBody)
}

var answerRE = regexp.MustCompile(`@post\('([^']*)/answer/(\d+)/(\d+)(\?[^']*)?'\)`)

// question reads the nonce and candidate count out of whatever the page (or a fat patch)
// last said -- the same thing the load harness does.
func question(t *testing.T, body string) (qid int64, candidates int) {
	t.Helper()
	matches := answerRE.FindAllStringSubmatch(body, -1)
	if len(matches) == 0 {
		return 0, 0
	}
	qid, _ = strconv.ParseInt(matches[0][2], 10, 64)
	for _, m := range matches {
		index, _ := strconv.Atoi(m[3])
		candidates = max(candidates, index+1)
	}
	return qid, candidates
}

func defaultConfig() Config { return Config{TimerMode: "client", MorphMode: "fat"} }

func TestPageCarriesAQuestion(t *testing.T) {
	c := newClient(t, defaultConfig())
	page := c.get("/")
	if page.Code != http.StatusOK {
		t.Fatalf("GET / = %d", page.Code)
	}
	if got := page.Header().Get("Cache-Control"); got != "no-store" {
		// this page IS session state rendered into HTML; a cached copy is a different
		// player's answer sheet at worst and a stale question at best
		t.Errorf("Cache-Control = %q, want no-store", got)
	}
	qid, candidates := question(t, page.Body.String())
	if qid == 0 || candidates != 5 {
		t.Fatalf("qid = %d, candidates = %d (want a nonce and the initial 5)", qid, candidates)
	}
	if c.cookie == nil || !c.cookie.HttpOnly || c.cookie.SameSite != http.SameSiteLaxMode {
		t.Errorf("session cookie = %+v, want HttpOnly and SameSite=Lax", c.cookie)
	}
}

func TestAnsweringScoresAndAdvances(t *testing.T) {
	c := newClient(t, defaultConfig())
	qid, _ := question(t, c.get("/").Body.String())

	stream := c.post("/answer/" + strconv.FormatInt(qid, 10) + "/0")
	if stream.Code != http.StatusOK {
		t.Fatalf("POST /answer = %d", stream.Code)
	}
	body := stream.Body.String()
	// the streak lands with the FIRST beat, not with the view patch at the end
	if !strings.HasPrefix(body, "event: datastar-patch-signals\ndata: signals {\"_streak\":") {
		t.Errorf("the stream did not open with the streak patch:\n%.120s", body)
	}
	// the verdict chime goes before the toast it belongs to
	sfx := strings.Index(body, "sfx-correct")
	if sfx < 0 {
		sfx = strings.Index(body, "sfx-wrong")
	}
	toast := strings.Index(body, `class="toast`)
	if sfx < 0 || toast < 0 || sfx > toast {
		t.Errorf("the verdict sound did not arrive before the first toast (sfx %d, toast %d)", sfx, toast)
	}
	// and the stream ends with the view patch
	if !strings.Contains(body, "selector #app") {
		t.Error("the stream did not end with a fat view patch")
	}
}

// TestAStaleQidResyncsRatherThanScoring is the trap that produced "I answered one question
// and it showed me another": qids used to restart at 1 per session, so an answer from a page
// whose session had been replaced passed the staleness guard by coincidence.
func TestAStaleQidResyncsRatherThanScoring(t *testing.T) {
	c := newClient(t, defaultConfig())
	qid, _ := question(t, c.get("/").Body.String())

	first := c.post("/answer/" + strconv.FormatInt(qid, 10) + "/0")
	if first.Code != http.StatusOK {
		t.Fatalf("first answer = %d", first.Code)
	}
	// A WRONG answer keeps its nonce -- the reveal is the same question, still on screen --
	// so leave the reveal before replaying, or the replay is not stale at all. (Which is
	// also why the reveal has no buttons: there is nothing to double-click.)
	if strings.Contains(first.Body.String(), "Next question") {
		c.post("/next")
	}
	// the same qid again: the nonce has moved on, so nothing scores
	second := c.post("/answer/" + strconv.FormatInt(qid, 10) + "/0")
	body := second.Body.String()
	if second.Code != http.StatusOK || !strings.Contains(body, "caught up") {
		t.Fatalf("a replayed answer should resync the page, got %d:\n%.200s", second.Code, body)
	}
	if !strings.Contains(body, "selector #app") {
		t.Error("the resync must be a FAT patch -- the title, score, drawer and topics are all stale")
	}
}

// TestAReplacedSessionResyncs is the six-hour gap and the server restart: the browser still
// has a cookie, the store has no quiz under it.
func TestAReplacedSessionResyncs(t *testing.T) {
	c := newClient(t, defaultConfig())
	qid, _ := question(t, c.get("/").Body.String())
	// a cookie the store has never seen
	c.cookie = &http.Cookie{Name: session.Cookie, Value: "a-browser-from-before-the-restart"}

	reply := c.post("/answer/" + strconv.FormatInt(qid, 10) + "/0")
	if reply.Code != http.StatusOK || !strings.Contains(reply.Body.String(), "caught up") {
		t.Fatalf("a replaced session should resync, got %d", reply.Code)
	}
}

// TestNoOpsAre204 is the one the load harness cares about most: a 200 with an empty body
// would be a lie, and treating these as failures is what made `/timer` read as 100% failed.
func TestNoOpsAre204(t *testing.T) {
	c := newClient(t, defaultConfig())
	c.get("/")

	// Next while not on a reveal
	if got := c.post("/next").Code; got != http.StatusNoContent {
		t.Errorf("POST /next off a reveal = %d, want 204", got)
	}
	// a settings POST that changed nothing (the body restates what the session already has)
	c.do(http.MethodPost, "/settings", `{"difficulty":5,"ladderMode":true,"targetOn":false,"targetPct":70}`)
	if got := c.do(http.MethodPost, "/settings", `{"difficulty":5,"ladderMode":true,"targetOn":false,"targetPct":70}`).Code; got != http.StatusNoContent {
		t.Errorf("an unchanged settings POST = %d, want 204", got)
	}
	// /timer in the default client mode
	if got := c.get("/timer").Code; got != http.StatusNoContent {
		t.Errorf("GET /timer in client mode = %d, want 204", got)
	}
	// the debug routes on an unarmed session -- 204, not 404: it does not advertise
	// whether they exist
	for _, path := range []string{"/debug/points/100", "/debug/goal/200", "/debug/reveal", "/debug/complete"} {
		if got := c.post(path).Code; got != http.StatusNoContent {
			t.Errorf("POST %s unarmed = %d, want 204", path, got)
		}
	}
}

func TestSkipsRunOut(t *testing.T) {
	c := newClient(t, defaultConfig())
	c.get("/")
	for i := 1; i <= 3; i++ {
		if got := c.post("/skip").Code; got != http.StatusOK {
			t.Fatalf("skip %d = %d, want 200", i, got)
		}
	}
	if got := c.post("/skip").Code; got != http.StatusNoContent {
		t.Errorf("the fourth skip = %d, want 204 -- three is what a quiz starts with", got)
	}
}

// TestSessionsAreKeyedByBrowserAndVariant is the cross-tab bleed the store exists to end:
// one cookie, two systems, two quizzes.
func TestSessionsAreKeyedByBrowserAndVariant(t *testing.T) {
	c := newClient(t, defaultConfig())
	squad := c.get("/")
	if !strings.Contains(squad.Body.String(), "?squad')") {
		t.Fatal("the squad page's action URLs do not name the squad variant")
	}
	squadQID, _ := question(t, squad.Body.String())

	swedish := c.get("/?swedish")
	if !strings.Contains(swedish.Body.String(), "?swedish')") {
		t.Fatal("?swedish did not switch the system")
	}
	swedishQID, _ := question(t, swedish.Body.String())
	if swedishQID == squadQID {
		t.Error("the two systems share a question nonce -- they are one session, not two")
	}

	// the squad tab is still about the squad session: its action URL names its own variant,
	// and the qid it holds is still live there
	back := c.get("/?squad")
	if gotQID, _ := question(t, back.Body.String()); gotQID != squadQID {
		t.Errorf("returning to squad drew a new question (%d, was %d) -- the quiz was replaced", gotQID, squadQID)
	}

	// ...and a BARE url means "take me home" to the default
	if !strings.Contains(c.get("/").Body.String(), "?squad')") {
		t.Error("a bare URL should mean the default variant")
	}
	// while a query naming no variant keeps whatever the browser is on
	c.get("/?swedish")
	if !strings.Contains(c.get("/?debug").Body.String(), "?swedish')") {
		t.Error("?debug must not be read as 'switch me back to the default'")
	}
}

func TestMorphModes(t *testing.T) {
	for mode, selector := range map[string]string{"fat": "selector #app", "fragment": "selector #quiz"} {
		cfg := defaultConfig()
		cfg.MorphMode = mode
		c := newClient(t, cfg)
		c.get("/")
		body := c.post("/skip").Body.String()
		if !strings.Contains(body, selector) {
			t.Errorf("%s morph did not patch %s", mode, selector)
		}
		if mode == "fragment" && strings.Contains(body, "selector #app") {
			t.Error("fragment morph patched the whole app")
		}
	}
}

func TestTimerStreamPushesTheCountdown(t *testing.T) {
	cfg := defaultConfig()
	cfg.TimerMode = "stream"
	c := newClient(t, cfg)
	page := c.get("/")
	if strings.Contains(page.Body.String(), "data-on-interval") {
		t.Error("stream mode must not also wire the browser interval")
	}
	if !strings.Contains(page.Body.String(), "@get('/timer?squad')") {
		t.Error("stream mode must open the held connection from data-init on <body>")
	}

	// the held stream: read it for a few ticks, then hang up
	r := httptest.NewRequest(http.MethodGet, "/timer", nil)
	r.AddCookie(c.cookie)
	// hang up after 400ms, which is what a browser closing a tab does to a held stream
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	w := httptest.NewRecorder()
	c.server.Handler().ServeHTTP(w, r.WithContext(ctx))
	body := w.Body.String()
	if ticks := strings.Count(body, "_timeLeftPct"); ticks < 2 {
		t.Errorf("the held stream pushed %d ticks in 400ms, want several at 100ms", ticks)
	}
}

func TestFilterPreviewCommitsNothingAndApplyRestarts(t *testing.T) {
	c := newClient(t, defaultConfig())
	page := c.get("/")
	before, _ := question(t, page.Body.String())

	preview := c.get(`/filter/preview?datastar=%7B%22filterText%22%3A%221C%22%7D`)
	if preview.Code != http.StatusOK || !strings.Contains(preview.Body.String(), "auctions match") {
		t.Fatalf("preview = %d: %.200s", preview.Code, preview.Body.String())
	}
	// asking never commits: the question is the one it was
	if after, _ := question(t, c.get("/").Body.String()); after != before {
		t.Error("a preview restarted the quiz")
	}

	apply := c.do(http.MethodPost, "/filter/apply", `{"filterText":"1C"}`)
	if apply.Code != http.StatusOK {
		t.Fatalf("apply = %d", apply.Code)
	}
	if after, _ := question(t, apply.Body.String()); after == before {
		t.Error("applying a filter must restart the quiz")
	}
	// the canonical text comes back so the box shows what is really in force
	if !strings.Contains(apply.Body.String(), `"filterText":"1C"`) {
		t.Errorf("apply did not echo the canonical filter text:\n%.300s", apply.Body.String())
	}
	// ...and re-applying the same filter changes nothing, so the quiz is not restarted
	again := c.do(http.MethodPost, "/filter/apply", `{"filterText":" 1c "}`)
	if strings.Contains(again.Body.String(), "selector #app") {
		t.Error("re-applying an unchanged filter restarted the quiz")
	}
}

func TestDebugPanelIsArmedByTheQueryAndSticks(t *testing.T) {
	c := newClient(t, defaultConfig())
	if strings.Contains(c.get("/").Body.String(), `id="debug"`) {
		t.Error("the debug panel is on without being asked for")
	}
	if !strings.Contains(c.get("/?debug").Body.String(), `id="debug"`) {
		t.Fatal("?debug did not arm the panel")
	}
	// sticky: the interactions POST to bare paths with no query
	if got := c.post("/debug/points/100").Code; got != http.StatusOK {
		t.Errorf("an armed debug route = %d, want 200", got)
	}
	// a plain reload disarms it again, which is the lifetime panel's own flag had
	if strings.Contains(c.get("/").Body.String(), `id="debug"`) {
		t.Error("a plain reload should disarm the panel")
	}
}

func TestDebugModeOffForbidsTheQuery(t *testing.T) {
	cfg := defaultConfig()
	cfg.DebugMode = "0"
	c := newClient(t, cfg)
	if strings.Contains(c.get("/?debug").Body.String(), `id="debug"`) {
		t.Error("DSQUIZ_DEBUG=0 must forbid ?debug -- the panel can hand itself points")
	}
	if got := c.post("/debug/points/100").Code; got != http.StatusNoContent {
		t.Errorf("a forbidden debug route = %d, want 204", got)
	}
}

func TestDebugCompleteGoesThroughTheRealScoringPath(t *testing.T) {
	cfg := defaultConfig()
	cfg.DebugMode = "1"
	c := newClient(t, cfg)
	c.get("/")
	c.post("/debug/goal/200")
	body := c.post("/debug/complete").Body.String()
	if !strings.Contains(body, `class="finale"`) {
		t.Errorf("the finale did not arrive:\n%.400s", body)
	}
	if !strings.Contains(body, "sfx-final") {
		t.Error("the finale's own sound is part of that beat")
	}
	// and the completed quiz then no-ops an answer rather than resyncing
	if got := c.post("/answer/999999/0").Code; got != http.StatusOK {
		t.Logf("an answer to a finished quiz replied %d", got) // a stale qid resyncs; both are correct
	}
}

func TestMountPrefix(t *testing.T) {
	cfg := defaultConfig()
	cfg.Prefix = "/bridge-system-quiz"
	c := newClient(t, cfg)
	page := c.get("/bridge-system-quiz/")
	if page.Code != http.StatusOK {
		t.Fatalf("the prefixed page = %d", page.Code)
	}
	if !strings.Contains(page.Body.String(), "@post('/bridge-system-quiz/answer/") {
		t.Error("the action URLs did not carry the mount prefix")
	}
	if c.cookie.Path != "/bridge-system-quiz" {
		t.Errorf("cookie path = %q, want the mount point", c.cookie.Path)
	}
	if got := c.get("/").Code; got != http.StatusNotFound {
		t.Errorf("the root of a prefixed mount = %d, want 404", got)
	}
	if got := c.get("/bridge-system-quiz/static/app-pico.css").Code; got != http.StatusOK {
		t.Errorf("prefixed static = %d", got)
	}
}

func TestSoundsAreSynthesisedAndCachedHard(t *testing.T) {
	c := newClient(t, defaultConfig())
	for _, name := range []string{"correct", "wrong", "skip", "final", "tick"} {
		reply := c.get("/sfx/" + name)
		if reply.Code != http.StatusOK || reply.Body.Len() < 100 {
			t.Errorf("/sfx/%s = %d, %d bytes", name, reply.Code, reply.Body.Len())
		}
		if got := reply.Header().Get("Content-Type"); got != "audio/wav" {
			t.Errorf("/sfx/%s content type = %q", name, got)
		}
		if !strings.Contains(reply.Header().Get("Cache-Control"), "31536000") {
			t.Errorf("/sfx/%s is not cached hard -- the ?v= build stamp is what busts it", name)
		}
	}
	if got := c.get("/sfx/nonesuch").Code; got != http.StatusNotFound {
		t.Errorf("an unknown sound = %d, want 404", got)
	}
}

func TestSettingsAreClampedAndEchoedBack(t *testing.T) {
	c := newClient(t, defaultConfig())
	c.get("/")
	// difficulty 99 is clamped to 8, and the effective value is echoed so the slider cannot
	// sit stale in the UI until a reload
	body := c.do(http.MethodPost, "/settings", `{"difficulty":99,"targetPct":500}`).Body.String()
	if !strings.Contains(body, `"difficulty":8`) {
		t.Errorf("difficulty was not clamped and echoed:\n%.300s", body)
	}
	if !strings.Contains(body, `"targetPct":90`) {
		t.Errorf("targetPct was not clamped and echoed:\n%.300s", body)
	}
	// the new difficulty is the new candidate count
	if _, candidates := question(t, body); candidates != 8 {
		t.Errorf("candidates = %d, want 8 after difficulty 8", candidates)
	}
	// junk falls back to the default rather than erroring
	body = c.do(http.MethodPost, "/settings", `{"difficulty":"nonsense"}`).Body.String()
	if !strings.Contains(body, `"difficulty":5`) {
		t.Errorf("an unusable difficulty should fall back to the default:\n%.300s", body)
	}
}

func TestMalformedSignalsAreNotAServerError(t *testing.T) {
	c := newClient(t, defaultConfig())
	c.get("/")
	if got := c.do(http.MethodPost, "/settings", `{not json`).Code; got != http.StatusNoContent {
		t.Errorf("a malformed body = %d, want 204 -- absent signals mean nothing to adopt", got)
	}
}
