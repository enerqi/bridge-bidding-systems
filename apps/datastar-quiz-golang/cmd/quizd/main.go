// Command quizd serves the Go port of the bidding quiz.
//
// The point of this program is the COMPARISON with `apps/datastar-quiz/` (Datastar +
// Litestar) and `apps/quiz/` (Panel): the same hypermedia architecture, the same corpus, the
// same routes, driven by the same load harness, so that what differs is the runtime and the
// language rather than the design. Everything in here that could tilt that comparison is a
// flag with a default that says so.
//
// TWO CORE BUDGETS, BOTH REPORTED. The python app is one asyncio loop in one process: one
// core, whatever the machine has (measured: the granian worker pins at ~89% of one core and
// 3.7% of 24). Go will use all of them by default, so a naive comparison says "Go is 20x
// faster" when it means "Go used 20 cores".
//
//	--procs 1     the honest like-for-like: same work, same core budget, and the number
//	              that says what the runtime costs
//	--procs 0     unrestricted (the default) -- what the language actually buys you on this
//	              box, which is the other half of the question and the more useful one for a
//	              real deployment
//
// GOGC and GOMEMLIMIT are settable for the same reason: a GC that happens to run
// mid-percentile is a real effect and should be a deliberate one. Every setting a run used
// is logged at startup, so a log line is enough to reconstruct it.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strconv"
	"syscall"
	"time"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/session"
	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/web"
)

func main() {
	if err := run(); err != nil {
		slog.Error("quizd", "err", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		addr = flag.String("addr", envOr("DSQUIZ_ADDR", "127.0.0.1"), "interface to listen on")
		port = flag.Int("port", envInt("DSQUIZ_PORT", 5060), "port to listen on")
		// GOMAXPROCS is honoured by the runtime already; --procs exists so a run RECORDS
		// its own setting in the log rather than leaving it to be reconstructed from the
		// environment afterwards.
		procs = flag.Int("procs", envInt("GOMAXPROCS", 0), "GOMAXPROCS; 0 leaves the runtime default (every core)")
		gogc  = flag.Int("gogc", envInt("GOGC", 0), "GOGC percentage; 0 leaves the runtime default (100)")
		// bytes; 0 leaves it off. `GOMEMLIMIT=256MiB` is the env form.
		memLimit = flag.Int64("memlimit", envInt64("DSQUIZ_MEMLIMIT", 0), "soft memory limit in bytes; 0 leaves it off")

		timerMode = flag.String("timer", envOr("DSQUIZ_TIMER", "client"), `countdown push model: "client" or "stream"`)
		morphMode = flag.String("morph", envOr("DSQUIZ_MORPH", "fat"), `how much DOM a patch carries: "fat" or "fragment"`)
		prefix    = flag.String("prefix", envOr("DSQUIZ_PREFIX", ""), "mount prefix, e.g. /bridge-system-quiz")
		debugMode = flag.String("debug", envOr("DSQUIZ_DEBUG", ""), `debug panel: "" (per-session ?debug), "1" (always), "0" (never)`)
		pprofOn   = flag.Bool("pprof", envOr("DSQUIZ_DEBUG", "") == "1", "register /debug/pprof (see the README; an open pprof endpoint is a production mistake)")
	)
	flag.Parse()

	if *procs > 0 {
		runtime.GOMAXPROCS(*procs)
	}
	if *gogc > 0 {
		debug.SetGCPercent(*gogc)
	}
	if *memLimit > 0 {
		debug.SetMemoryLimit(*memLimit)
	}

	// The mount prefix is normalised the way the python normalises DSQUIZ_PREFIX: one
	// leading slash, no trailing one, empty for a root mount.
	mount := normalisePrefix(*prefix)

	// THE CORPUS IS LOADED AT STARTUP, and there is deliberately no lazy path to fall back
	// to -- so DSQUIZ_PREWARM has no counterpart here and the flag does not exist.
	//
	// The python has one because its corpus work happened inside a REQUEST until this week,
	// and the yappi profile caught it: 1.3s of `load_bid_tables` plus 4.3s of
	// `prepare_sequence_bids` landing on the first visitor to open the second system.
	// `DSQUIZ_PREWARM=0` puts that back, which is worth having while iterating under
	// --reload. A Go binary has no reload to iterate under, and a first request that pays
	// for the whole corpus would poison exactly the percentiles this port exists to report.
	started := time.Now()
	if err := corpus.Load(); err != nil {
		return err
	}
	warm := time.Since(started)

	store := session.NewStore()
	done := make(chan struct{})
	defer close(done)
	store.StartSweeper(done)

	server, err := web.New(web.Config{
		TimerMode: *timerMode,
		MorphMode: *morphMode,
		Prefix:    mount,
		DebugMode: *debugMode,
		Pprof:     *pprofOn,
	}, store)
	if err != nil {
		return err
	}

	listen := fmt.Sprintf("%s:%d", *addr, *port)
	httpServer := &http.Server{
		Addr:    listen,
		Handler: server.Handler(),
		// No WriteTimeout: `/timer` is a HELD connection in stream mode and the answer
		// stream spends seconds in deliberate pauses, so a write deadline would cut exactly
		// the responses this app exists to measure. ReadHeaderTimeout still bounds a client
		// that opens a socket and says nothing.
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}

	slog.Info("quizd listening",
		"addr", listen,
		"prefix", mount,
		"timer", *timerMode,
		"morph", *morphMode,
		"debug", *debugMode,
		"pprof", *pprofOn,
		"gomaxprocs", runtime.GOMAXPROCS(0),
		"numcpu", runtime.NumCPU(),
		"gogc", *gogc,
		"memlimit", *memLimit,
		"corpus_ms", warm.Milliseconds(),
	)

	// A load run is stopped with ctrl-c; that should not lose the connections mid-flight.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	errs := make(chan error, 1)
	go func() { errs <- httpServer.ListenAndServe() }()

	select {
	case err := <-errs:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-stop:
		slog.Info("quizd stopping")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return httpServer.Shutdown(ctx)
	}
}

// normalisePrefix mirrors the python: `DSQUIZ_PREFIX=bridge-quiz-ds` and
// `DSQUIZ_PREFIX=/bridge-quiz-ds/` both mean `/bridge-quiz-ds`, and unset means the root.
func normalisePrefix(prefix string) string {
	trimmed := prefix
	for len(trimmed) > 0 && (trimmed[0] == '/' || trimmed[len(trimmed)-1] == '/') {
		if trimmed[0] == '/' {
			trimmed = trimmed[1:]
			continue
		}
		trimmed = trimmed[:len(trimmed)-1]
	}
	if trimmed == "" {
		return ""
	}
	return "/" + trimmed
}

func envOr(name, fallback string) string {
	if value, ok := os.LookupEnv(name); ok && value != "" {
		return value
	}
	return fallback
}

func envInt(name string, fallback int) int {
	if value, ok := os.LookupEnv(name); ok {
		if parsed, err := strconv.Atoi(value); err == nil {
			return parsed
		}
	}
	return fallback
}

func envInt64(name string, fallback int64) int64 {
	if value, ok := os.LookupEnv(name); ok {
		if parsed, err := strconv.ParseInt(value, 10, 64); err == nil {
			return parsed
		}
	}
	return fallback
}
