package web

import "net/http/pprof"

// registerPprof arms the profiling endpoints.
//
// THIS IS WHERE GO IS SIMPLY BETTER, and it is worth saying why. The python side spent a day
// on this (`apps/datastar-quiz/profiling.py`): py-spy is a SAMPLING profiler that PAUSES the
// process to read stacks, and with one asyncio loop on one core the pause *is* the outage --
// at 100 Hz against 100 users the P90 went from ~50 ms to 18 SECONDS. Its `--nonblocking`
// mode does not pause and then loses ~35% of samples to torn reads (measured: 108 samples,
// 59 errors). The workable answer was yappi, an instrumenting profiler behind an env var, at
// several times slower -- so the profile answers "where does the time go" and can never
// answer "how fast is it".
//
// Here the same question is a CPU profile of a live, unmodified, full-speed server:
//
//	go tool pprof -http=: "http://127.0.0.1:5060/debug/pprof/profile?seconds=30"
//
// `/debug/pprof/trace` is the scheduler view, which is what to reach for under the held
// timer streams -- goroutine behaviour is the thing the python could not have.
//
// Gated behind DSQUIZ_DEBUG, exactly as the python gates its profiler: an open pprof endpoint
// is a production mistake. Not compressed either -- a pprof profile is already compressed,
// and the middleware would only spend CPU on it.
func (s *Server) registerPprof() {
	prefix := s.cfg.Prefix + "/debug/pprof/"
	s.mux.HandleFunc("GET "+prefix+"{$}", pprof.Index)
	s.mux.HandleFunc("GET "+prefix+"cmdline", pprof.Cmdline)
	s.mux.HandleFunc("GET "+prefix+"profile", pprof.Profile)
	s.mux.HandleFunc("GET "+prefix+"symbol", pprof.Symbol)
	s.mux.HandleFunc("POST "+prefix+"symbol", pprof.Symbol)
	s.mux.HandleFunc("GET "+prefix+"trace", pprof.Trace)
	// heap, goroutine, allocs, block, mutex, threadcreate -- pprof.Index serves these by
	// name, and Handler(name) is what makes them reachable under a mount prefix
	for _, name := range []string{"heap", "goroutine", "allocs", "block", "mutex", "threadcreate"} {
		s.mux.Handle("GET "+prefix+name, pprof.Handler(name))
	}
}
