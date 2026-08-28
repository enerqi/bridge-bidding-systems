// Package web is the hypermedia surface of the quiz: a port of `apps/datastar-quiz/app.py`.
//
// Every handler is the same shape -- mutate the authoritative session, then stream back the
// patches that make the browser agree. There is no client-side model to keep in step, which
// is the whole point of the experiment.
//
// The action lives in the URL (`/answer/<qid>/<index>`), not in a signal, so a stale or
// repeated click is rejected by comparing the question nonce -- replacing panel's "clicks
// occurred too quickly" guard with something a reload cannot defeat.
package web

import (
	"embed"
	"encoding/json"
	"io"
	"io/fs"
	"net/http"
	"strings"

	"github.com/CAFxX/httpcompression"
	"github.com/CAFxX/httpcompression/contrib/andybalholm/brotli"
	"github.com/CAFxX/httpcompression/contrib/klauspost/gzip"
	"github.com/starfederation/datastar-go/datastar"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/assets"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/render"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/session"
)

// The element targets. Only `#quiz` and `#toasts` are ever patched as elements; everything
// else the server owns arrives as `_`-prefixed signals.
const (
	appSelector    = "#app"
	quizSelector   = "#quiz"
	toastsSelector = "#toasts"
	// The sound sink lives OUTSIDE `#app`, with the <audio> elements, so a fat morph cannot
	// disturb a sound mid-play. The gauge is inside it, which is exactly what the milestone
	// sweep wants: the next view patch takes the shine away with no cleanup.
	sfxSelector   = "#sfx"
	meterSelector = appSelector + " .points-meter"
)

// Config is the deployment-shaped configuration, all of it from `DSQUIZ_*` environment
// variables with the same names the python app uses, so one environment drives both.
type Config struct {
	// TimerMode is which push model drives the countdown bar. The whole point of the port
	// is comparing these, so both exist and the choice is one env var:
	//
	//	"client" (default) -- the browser walks `$_timeLeftPct` down with `data-on-interval`.
	//	    No held connection; the server states the allowance once per question and
	//	    nothing else. The bonus that scores is recomputed server-side either way, so the
	//	    bar is only ever an animation.
	//	"stream"           -- `GET /timer` is held open and pushes `patch_signals` every
	//	    tick, panel's model exactly. Costs one connection per tab and per-tick server
	//	    work per client. On python this is the expensive mode nobody would ship; here it
	//	    is a goroutine and a ticker, which is one of the two axes worth measuring.
	TimerMode string
	// MorphMode is how much DOM a state change sends back. The Tao's advice is "fat morph":
	// send large chunks and let the morph work out what changed.
	//
	//	"fat" (default) -- patch #app, the whole page below <body>. The server never has to
	//	    remember which fragments a change touches.
	//	"fragment"      -- patch #quiz only. Smaller, but every server-owned value outside
	//	    that fragment has to be re-stated as a signal or it drifts. Measured on the
	//	    python at 1000 users: ~40% off the P99 tail and nothing on throughput.
	MorphMode string
	// Prefix is where the app is mounted when it is not at the root of a host. Requests
	// must arrive WITH the prefix still attached (`proxy_pass http://ds_quiz;` with no
	// trailing slash).
	Prefix string
	// DebugMode: "" means `?debug` arms the panel for that session; "1" means on for every
	// session; "0" means off and `?debug` cannot turn it on -- the one to set on a public
	// deployment, because the panel can hand itself points and jump to the end.
	DebugMode string
	// Pprof registers `/debug/pprof/*` (see the profiling note in the README). An open
	// pprof endpoint is a production mistake, so it is gated exactly as the python gates
	// its yappi routes.
	Pprof bool
}

// Server holds the process-wide state: the session store and the render configuration.
type Server struct {
	cfg      Config
	renderer render.Config
	store    *session.Store
	mux      *http.ServeMux
	// compress wraps the non-SSE routes. The SSE routes compress themselves through the
	// datastar SDK instead -- see the note on newSSE.
	compress func(http.Handler) http.Handler
}

// New builds the server. The corpus must already be loaded.
func New(cfg Config, store *session.Store) (*Server, error) {
	if err := render.ValidatePrefix(cfg.Prefix); err != nil {
		return nil, err
	}
	compress, err := newCompressor()
	if err != nil {
		return nil, err
	}
	s := &Server{
		cfg:      cfg,
		renderer: render.Config{Prefix: cfg.Prefix, TimerMode: cfg.TimerMode},
		store:    store,
		mux:      http.NewServeMux(),
		compress: compress,
	}
	s.routes()
	return s, nil
}

// Handler is the whole app, mounted at its prefix.
func (s *Server) Handler() http.Handler { return s.mux }

// newCompressor is the same negotiation Litestar is pinned to: brotli quality 5, gzip
// fallback, minimum size 256 bytes.
//
// Quality 5 is pinned rather than left to a default, because it is the knee. Measured on
// the python app's own 23.6KB fat patch: q5 4,069 B in 0.56 ms; q6 costs 68% more time for
// 0.4% fewer bytes; q9 is 8x the CPU for 1%; q11 is 40x for 10%. q5 also beats gzip -9 on
// size at ~2x its cost.
func newCompressor() (func(http.Handler) http.Handler, error) {
	brotliCompressor, err := brotli.New(brotli.Options{Quality: 5})
	if err != nil {
		return nil, err
	}
	gzipCompressor, err := gzip.New(gzip.Options{Level: gzip.DefaultCompression})
	if err != nil {
		return nil, err
	}
	return httpcompression.Adapter(
		httpcompression.Compressor(brotli.Encoding, 1, brotliCompressor),
		httpcompression.Compressor(gzip.Encoding, 0, gzipCompressor),
		httpcompression.MinSize(256),
	)
}

func (s *Server) routes() {
	prefix := s.cfg.Prefix
	// GET / is `no-store`, and not as a nicety: this page IS session state -- the current
	// question, the score, the reveal you are parked on -- rendered into HTML. A cached copy
	// is a different player's answer sheet at worst and a stale question at best.
	s.handle("GET "+prefix+"/{$}", s.index)

	s.handleDS("POST "+prefix+"/answer/{qid}/{index}", s.answer)
	s.handleDS("POST "+prefix+"/next", s.next)
	s.handleDS("POST "+prefix+"/skip", s.skip)
	s.handleDS("POST "+prefix+"/restart", s.restart)
	s.handleDS("POST "+prefix+"/settings", s.settings)
	s.handleDS("GET "+prefix+"/timer", s.timer)

	s.handleDS("GET "+prefix+"/filter/preview", s.filterPreview)
	s.handleDS("GET "+prefix+"/filter/preview-topics", s.topicsPreview)
	s.handleDS("GET "+prefix+"/filter/topics-reset", s.topicsReset)
	s.handleDS("POST "+prefix+"/filter/apply", s.filterApply)
	s.handleDS("POST "+prefix+"/filter/apply-topics", s.topicsApply)

	// The debug panel: the panel app's row of buttons for reaching a state that takes
	// minutes of honest play. Every route is a no-op unless the session is armed, so an
	// unarmed instance answers with a 204 rather than a 404 -- the same "nothing to do"
	// answer a stale qid gets, and it does not advertise whether the routes exist.
	s.handleDS("POST "+prefix+"/debug/points/{delta}", s.debugPoints)
	s.handleDS("POST "+prefix+"/debug/goal/{value}", s.debugGoal)
	s.handleDS("POST "+prefix+"/debug/complete", s.debugComplete)
	s.handleDS("POST "+prefix+"/debug/reveal", s.debugReveal)

	s.handle("GET "+prefix+"/sfx/{name}", s.sound)

	// `no-cache` means REVALIDATE, not "do not cache": the browser keeps the file and asks
	// with its etag, so an unchanged sheet costs a 304 and a changed one arrives
	// immediately. Without it a browser is entitled to invent a freshness lifetime, which is
	// how an edited stylesheet kept not showing up until a hard reload.
	s.mux.Handle("GET "+prefix+"/static/", s.compress(assetHandler(assets.Static, "static")))
	// the completion image lives with the panel app; copied in, served read-only
	s.mux.Handle("GET "+prefix+"/media/", s.compress(assetHandler(assets.Media, "media")))

	if s.cfg.Pprof {
		s.registerPprof()
	}
}

// handle registers a route through the buffering compression middleware. Only the routes
// that produce a WHOLE response use it -- the document, the sounds, the assets. The datastar
// routes are streams and compress themselves; see compressSSE for why the two cannot be the
// same mechanism.
func (s *Server) handle(pattern string, fn http.HandlerFunc) {
	s.mux.Handle(pattern, s.compress(fn))
}

// handleDS registers one datastar (SSE) route, uncompressed by the middleware.
func (s *Server) handleDS(pattern string, fn http.HandlerFunc) {
	s.mux.Handle(pattern, fn)
}

func assetHandler(files embed.FS, dir string) http.Handler {
	sub, err := fs.Sub(files, dir)
	if err != nil {
		panic("assets: " + err.Error())
	}
	server := http.FileServerFS(sub)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		// strip everything up to and including `/<dir>/`
		if index := strings.Index(r.URL.Path, "/"+dir+"/"); index >= 0 {
			r = r.Clone(r.Context())
			r.URL.Path = r.URL.Path[index+len(dir)+1:]
		}
		server.ServeHTTP(w, r)
	})
}

// --- datastar plumbing ------------------------------------------------------

// event is one thing to send once the response has been committed. Handlers build a slice
// of these and hand it to respond, which is what makes "no events" a 204 rather than an
// empty 200 -- see respond.
type event func(*datastar.ServerSentEventGenerator) error

// respond writes the session cookie and then the events.
//
// A 204 IS A NO-OP, NOT AN ERROR. A datastar response with no events is `204 No Content`,
// and this app returns one deliberately whenever a press no longer applies: Skip with none
// left, Next while not on a reveal, a settings POST that changed nothing, an answer to a
// finished quiz, `/timer` in client mode. The load harness treats 200 and 204 alike; a
// server that answered 200 with an empty body would be lying about having done something.
func (s *Server) respond(w http.ResponseWriter, r *http.Request, sess *session.Session, events []event) {
	s.setCookie(w, sess)
	if len(events) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	sse, done := s.openSSE(w, r)
	defer done()
	for _, send := range events {
		if err := send(sse); err != nil {
			return // the client went away mid-stream; nothing to report
		}
	}
}

// openSSE upgrades the response and returns the closer that terminates the compressed
// stream. The caller must defer the closer: an unterminated brotli stream is one a client
// refuses to decode -- see compressSSE.
//
// The SDK's own `WithCompression` is deliberately not used, for the same reason.
func (s *Server) openSSE(w http.ResponseWriter, r *http.Request) (*datastar.ServerSentEventGenerator, func()) {
	writer, done := compressSSE(w, r)
	return datastar.NewSSE(writer, r), done
}

func patchElements(html, selector string, mode datastar.ElementPatchMode) event {
	return func(sse *datastar.ServerSentEventGenerator) error {
		return sse.PatchElements(html, datastar.WithSelector(selector), datastar.WithMode(mode))
	}
}

func patchSignals(signals map[string]any) event {
	body := render.MarshalSignals(signals)
	return func(sse *datastar.ServerSentEventGenerator) error {
		return sse.PatchSignals(body)
	}
}

func (s *Server) setCookie(w http.ResponseWriter, sess *session.Session) {
	if sess == nil {
		return
	}
	path := s.cfg.Prefix
	if path == "" {
		path = "/"
	}
	http.SetCookie(w, &http.Cookie{
		Name: session.Cookie,
		// scoped to the mount point, so two apps sharing a host cannot overwrite each
		// other's session cookie -- the name is the same in both, only the path differs
		Path:     path,
		Value:    sess.SID,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

// readSignals is the datastar signal payload on this request, or nil if the body is not
// usable.
//
// A map rather than a struct, which is what the python has: presence matters. `difficulty`
// missing means "the browser did not say", and a struct's zero value cannot tell that from
// "the browser said 0". A malformed payload is a client mistake, not a server error, and
// every handler here treats absent signals as "nothing to adopt" already.
func readSignals(r *http.Request) map[string]any {
	var body []byte
	if r.Method == http.MethodGet || r.Method == http.MethodDelete {
		raw := r.URL.Query().Get("datastar")
		if raw == "" {
			return nil
		}
		body = []byte(raw)
	} else {
		var err error
		body, err = io.ReadAll(io.LimitReader(r.Body, maxSignalBody))
		if err != nil || len(body) == 0 {
			return nil
		}
	}
	signals := map[string]any{}
	if err := json.Unmarshal(body, &signals); err != nil {
		return nil
	}
	return signals
}

// maxSignalBody bounds what a request may upload as signals. The payload is a handful of
// scalars plus one flag per topic; anything larger is not this app's client.
const maxSignalBody = 1 << 20
