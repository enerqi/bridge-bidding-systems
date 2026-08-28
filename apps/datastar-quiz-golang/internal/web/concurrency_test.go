package web

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/session"
)

// TestConcurrentBrowsersAndTabs is the test the python never needed.
//
// Litestar on one asyncio loop cannot have two handlers inside the same session at once, so
// nothing there is guarded. Here every request is a goroutine: two tabs of one browser, a
// click arriving during an answer stream, and the held timer connection all touch one
// Session, and every session shares the store, the filter memo and the derived topic rows.
//
// `go test -race` is the tool for this and the handoff asks for it; on the machine this was
// written on the race runtime does not start (`exit status 0xc0000139`, a mingw-8.1 problem
// rather than a Go one -- it fails the same way on an empty package), so this test earns its
// place without it: the runtime detects a concurrent map write and a concurrent map
// iteration on its own and turns either into an unrecoverable throw, which is exactly what
// an unguarded store, memo or choices cache would produce here. Run it with -race wherever
// the toolchain has a working C compiler.
func TestConcurrentBrowsersAndTabs(t *testing.T) {
	if err := corpus.Load(); err != nil {
		t.Fatalf("corpus: %v", err)
	}
	server, err := New(defaultConfig(), session.NewStore())
	if err != nil {
		t.Fatalf("server: %v", err)
	}
	handler := server.Handler()

	// Two browsers, two tabs each, and one of the tabs is on the other system -- which is
	// the case the (browser, variant) keying exists for.
	const browsers = 8
	const rounds = 12
	var wg sync.WaitGroup
	for b := 0; b < browsers; b++ {
		for _, query := range []string{"?squad", "?swedish"} {
			wg.Add(1)
			go func(browser int, query string) {
				defer wg.Done()
				cookie := &http.Cookie{Name: session.Cookie, Value: "browser-" + strings.Repeat("x", browser+1)}
				call := func(method, path, body string) string {
					var reader *strings.Reader
					if body != "" {
						reader = strings.NewReader(body)
					}
					var r *http.Request
					if reader != nil {
						r = httptest.NewRequest(method, path, reader)
						r.Header.Set("Content-Type", "application/json")
					} else {
						r = httptest.NewRequest(method, path, nil)
					}
					r.AddCookie(cookie)
					w := httptest.NewRecorder()
					handler.ServeHTTP(w, r)
					return w.Body.String()
				}
				for i := 0; i < rounds; i++ {
					page := call(http.MethodGet, "/"+query, "")
					qid, _ := question(t, page)
					if qid == 0 {
						continue
					}
					// answer, skip, restart and a filter preview all at once from the two
					// tabs of the same browser
					call(http.MethodPost, "/skip"+query, signalsBody)
					call(http.MethodGet, "/filter/preview"+query+"&datastar=%7B%22filterText%22%3A%221C%22%7D", "")
					call(http.MethodPost, "/settings"+query, `{"difficulty":8}`)
					call(http.MethodPost, "/restart"+query, signalsBody)
				}
			}(b, query)
		}
	}
	wg.Wait()
}
