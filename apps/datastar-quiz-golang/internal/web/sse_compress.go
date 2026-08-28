package web

import (
	"compress/gzip"
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/andybalholm/brotli"
)

// COMPRESSING AN SSE STREAM IS ITS OWN PROBLEM, and neither of the two obvious answers works.
//
// The datastar SDK offers `WithCompression`, which wraps its writer and flushes the
// compressor after every event -- correct pacing, but it never CLOSES the compressor, so the
// stream ends without its terminating block. A browser tolerates that; the load harness does
// not. `just dsperf smoke` failed every POST with `brotli.error: brotli: decoder failed`,
// which is what an unterminated brotli stream looks like to a client that decodes the whole
// body at once. That is a real failure, not a harness quirk: an intermediary or a fetch()
// caller is entitled to reject a truncated stream too.
//
// The other answer, wrapping the SSE routes in the `httpcompression` middleware, closes
// properly but buffers: its own Flush is documented as "a no-op until enough data has been
// written to decide whether the response should be compressed or not (e.g. less than MinSize
// bytes have been written)". The answer choreography's early frames are a few dozen bytes
// each, so they would sit in the buffer -- and the pacing of those frames is precisely what
// this app is here to measure.
//
// So the SSE routes compress through this: negotiate once, flush the compressor and the
// response after every event, and CLOSE at the end of the handler. The middleware still
// covers everything else (the document, the assets, the sounds), where its buffering is the
// right behaviour and MinSize means a 40-byte 304 is not brotli'd for nothing.
//
// MinSize deliberately does NOT apply here. A stream has no length to compare it against,
// and litestar's does not either -- its brotli facade calls `process(chunk)` then `flush()`
// for every ASGI chunk while `more_body` is set, which is the behaviour being matched.

// compressedWriter is an http.ResponseWriter whose body goes through a compressor.
//
// It implements http.Flusher, which is what `http.ResponseController.Flush` (and therefore
// the SDK's per-event flush) finds: flushing has to reach the COMPRESSOR first, or the
// bytes for the event just written are still inside it when the socket is flushed.
type compressedWriter struct {
	http.ResponseWriter
	encoder io.WriteCloser
}

func (w *compressedWriter) Write(body []byte) (int, error) { return w.encoder.Write(body) }

func (w *compressedWriter) Flush() {
	if flusher, ok := w.encoder.(interface{ Flush() error }); ok {
		_ = flusher.Flush()
	}
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

// Unwrap lets http.ResponseController reach the real writer for anything this type does not
// implement itself.
func (w *compressedWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// THE ENCODERS ARE POOLED AND THEIR WINDOW IS PINNED, AND NEITHER IS A MICRO-OPTIMISATION.
//
// A brotli encoder allocates its sliding window up front, and at the library's automatic
// setting that is hundreds of kilobytes per encoder. One per SSE response means one per
// interaction: *measured* at 400 simulated users on one core, the server's resident set
// reached **506 MB** against the python's ~120 MB. A heap profile of the running server --
// which is the thing this port can do and the python could not (see the README) -- put
// `brotli.ringBufferInitBuffer` at **282 MB, 81.6% of the live heap**, with another 32 MB in
// the hashers.
//
// Two fixes, both aimed at that line:
//
//   - POOL the encoders, so a burst of interactions reuses them instead of allocating a
//     window each. `httpcompression` pools its writers for exactly this reason; hand-rolling
//     the SSE path means hand-rolling the pool.
//   - PIN THE WINDOW at 2^16 = 64 KB. The window only has to be as large as the data a
//     stream can back-reference into, and the largest thing this app ever streams is one fat
//     morph patch at ~24 KB -- so 64 KB costs nothing in ratio and is an order of magnitude
//     less memory per encoder. (The middleware that compresses the ASSETS keeps the default:
//     `bulma.min.css` is 678 KB and would genuinely lose ratio, and those responses are
//     short-lived enough that their pool stays small.)
//
// `Reset(w)` is what makes a pooled encoder safe to reuse: it drops the previous stream
// entirely, so a half-written response cannot leak into the next one.
const sseWindowBits = 16

var (
	brotliPool = sync.Pool{New: func() any {
		return brotli.NewWriterOptions(io.Discard, brotli.WriterOptions{Quality: 5, LGWin: sseWindowBits})
	}}
	gzipPool = sync.Pool{New: func() any {
		writer, _ := gzip.NewWriterLevel(io.Discard, gzip.DefaultCompression)
		return writer
	}}
)

// compressSSE negotiates an encoding for a stream and returns the writer to hand to the SDK
// plus the closer that terminates it and returns the encoder to its pool. With no acceptable
// encoding it returns the response writer unchanged and a no-op closer.
//
// Server priority, brotli first: it is what Litestar is pinned to, and quality 5 is the knee
// (measured on this app's own fat patch -- q6 costs 68% more time for 0.4% fewer bytes).
func compressSSE(w http.ResponseWriter, r *http.Request) (http.ResponseWriter, func()) {
	accepted := acceptedEncodings(r)
	var (
		encoder io.WriteCloser
		release func()
	)
	switch {
	case accepted["br"]:
		writer := brotliPool.Get().(*brotli.Writer)
		writer.Reset(w)
		encoder, release = writer, func() { brotliPool.Put(writer) }
		w.Header().Set("Content-Encoding", "br")
	case accepted["gzip"]:
		writer := gzipPool.Get().(*gzip.Writer)
		writer.Reset(w)
		encoder, release = writer, func() { gzipPool.Put(writer) }
		w.Header().Set("Content-Encoding", "gzip")
	default:
		return w, func() {}
	}
	// the response varies by what the client said it accepts, so caches must key on it --
	// which matters for the assets even though these streams are `no-store` anyway
	w.Header().Add("Vary", "Accept-Encoding")
	wrapped := &compressedWriter{ResponseWriter: w, encoder: encoder}
	return wrapped, func() {
		// Close writes the terminating block; the reset on the next Get is what detaches the
		// encoder from this response's writer, so the pooled value never holds a dead one
		// for long -- and Reset is called before any byte is written either way.
		_ = encoder.Close()
		release()
	}
}

// acceptedEncodings is the set of encodings the client will take, ignoring q-values that
// disable one (`br;q=0`). Small enough to do by hand; the alternative is a dependency for
// three lines.
func acceptedEncodings(r *http.Request) map[string]bool {
	out := map[string]bool{}
	for _, part := range strings.Split(r.Header.Get("Accept-Encoding"), ",") {
		fields := strings.Split(strings.TrimSpace(part), ";")
		name := strings.ToLower(strings.TrimSpace(fields[0]))
		if name == "" {
			continue
		}
		disabled := false
		for _, parameter := range fields[1:] {
			if strings.EqualFold(strings.ReplaceAll(strings.TrimSpace(parameter), " ", ""), "q=0") {
				disabled = true
			}
		}
		if !disabled {
			out[name] = true
		}
	}
	return out
}
