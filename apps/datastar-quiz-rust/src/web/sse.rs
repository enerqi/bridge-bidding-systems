//! Streaming datastar events, compressed.
//!
//! # COMPRESSING AN SSE STREAM IS ITS OWN PROBLEM, and every ecosystem gets it wrong differently
//!
//! Litestar compresses the stream and flushes the compressor per ASGI chunk, which is correct, and
//! is the behaviour the other ports have to match or the wire comparison is meaningless.
//!
//! The Go SDK offers `WithCompression`, which flushes after every event but never CLOSES the
//! compressor, so the stream ends without its terminating block: `just dsperf smoke` failed every
//! POST there with `brotli: decoder failed`.
//!
//! `tower-http`'s `CompressionLayer` makes the opposite choice and is explicit about it: its
//! `DefaultPredicate` skips `text/event-stream` outright, and its own `Flush` is documented as a
//! no-op until enough bytes have accumulated to decide whether to compress at all. So a Rust app
//! that simply adds the layer silently ships UNCOMPRESSED streams -- which is safe, and would have
//! quietly handed this port a 5x wire-size advantage in the comparison it exists to make.
//!
//! So the SSE routes compress through this instead: negotiate once, flush the compressor and the
//! socket after every event, and finish the stream properly at the end. The middleware still covers
//! the document, the assets and the sounds, where its buffering is right and its minimum size means
//! a tiny response is not brotli'd for nothing.
//!
//! # One encoder per response, no pool -- and the window left alone
//!
//! A brotli encoder allocates its sliding window and hash tables up front. In the Go port that cost
//! showed up twice over: one encoder per SSE response took the resident set to 506 MB at 400 users,
//! with `ringBufferInitBuffer` at 282 MB -- 81.6% of the live heap. The fix there was a `sync.Pool`
//! PLUS pinning the window to 2^16, on the reasoning that the window only has to be as large as the
//! ~28 KB the app ever streams.
//!
//! **Copying the second half of that fix into Rust was a mistake, and it was measured.** In this
//! crate `lgwin` does not merely bound the back-reference distance -- it also sizes the metablocks
//! the encoder emits, so a small window makes quality 5 re-run its match finder over and over:
//!
//! ```text
//! fresh encoder + the real 23 KB page + finish   q5 lgwin16   6078 us  -> 5333 bytes
//! fresh encoder + the real 23 KB page + finish   q5 lgwin22    789 us  -> 5294 bytes
//! ```
//!
//! 7.7x the CPU for 0.7% WORSE compression. End to end that was 158 req/s against the Go port's
//! 908; with the window left at the crate's default it is back where it belongs. The lesson ported
//! cleanly; the constant did not.
//!
//! There is deliberately no POOL, and that half is the experiment this app exists to run: the
//! encoder is dropped at the end of the response and its memory is returned to the allocator
//! *then*, not whenever a collector next runs. `RESULTS.md` reports whether that is enough.

use axum::body::Bytes;
use brotli::enc::BrotliEncoderParams;
use std::io::Write;

/// Quality 5 is what Litestar is pinned to and is the knee: measured on this app's own fat patch,
/// q6 costs 68% more time for 0.4% fewer bytes, q9 is 8x the CPU for 1%.
///
/// The WINDOW is deliberately left at the crate's default -- see the module note for the 7.7x that
/// pinning it cost.
const BROTLI_QUALITY: i32 = 5;
/// The encoder's internal output buffer. One flush of a fat patch is ~5 KB.
const BROTLI_BUFFER: usize = 8192;

/// Which encoding a stream will use.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Encoding {
    Identity,
    Brotli,
    Gzip,
}

impl Encoding {
    pub fn header_value(self) -> Option<&'static str> {
        match self {
            Encoding::Identity => None,
            Encoding::Brotli => Some("br"),
            Encoding::Gzip => Some("gzip"),
        }
    }
}

/// Server priority, brotli first -- the same order Litestar negotiates in.
///
/// q-values that DISABLE an encoding (`br;q=0`) are honoured; the finer preference ordering is not,
/// because the server has an opinion and this is the one the comparison pins.
pub fn negotiate(accept_encoding: Option<&str>) -> Encoding {
    let Some(header) = accept_encoding else {
        return Encoding::Identity;
    };
    let mut brotli = false;
    let mut gzip = false;
    for part in header.split(',') {
        let mut fields = part.split(';');
        let name = fields.next().unwrap_or("").trim();
        let disabled = fields.any(|parameter| {
            let parameter: String = parameter.chars().filter(|ch| !ch.is_whitespace()).collect();
            parameter.eq_ignore_ascii_case("q=0") || parameter.eq_ignore_ascii_case("q=0.0")
        });
        if disabled {
            continue;
        }
        if name.eq_ignore_ascii_case("br") {
            brotli = true;
        } else if name.eq_ignore_ascii_case("gzip") {
            gzip = true;
        }
    }
    if brotli {
        Encoding::Brotli
    } else if gzip {
        Encoding::Gzip
    } else {
        Encoding::Identity
    }
}

type BrotliWriter = brotli::CompressorWriter<Vec<u8>>;
type GzipWriter = flate2::write::GzEncoder<Vec<u8>>;

/// The body side of one SSE response: takes event text, hands back the bytes to put on the wire.
///
/// Each [`push`](Self::push) flushes, so a frame leaves the server when it is yielded -- which is
/// the property the answer choreography is measured on.
pub enum Stream {
    Identity,
    Brotli(Box<BrotliWriter>),
    Gzip(Box<GzipWriter>),
}

impl Stream {
    pub fn new(encoding: Encoding) -> Stream {
        match encoding {
            Encoding::Identity => Stream::Identity,
            Encoding::Brotli => {
                let params = BrotliEncoderParams {
                    quality: BROTLI_QUALITY,
                    ..Default::default()
                };
                Stream::Brotli(Box::new(brotli::CompressorWriter::with_params(
                    Vec::new(),
                    BROTLI_BUFFER,
                    &params,
                )))
            }
            Encoding::Gzip => Stream::Gzip(Box::new(flate2::write::GzEncoder::new(
                Vec::new(),
                flate2::Compression::default(),
            ))),
        }
    }

    /// Encode one event and return the bytes ready to send.
    pub fn push(&mut self, text: &str) -> Bytes {
        match self {
            Stream::Identity => Bytes::copy_from_slice(text.as_bytes()),
            Stream::Brotli(writer) => {
                let _ = writer.write_all(text.as_bytes());
                let _ = writer.flush();
                Bytes::from(std::mem::take(writer.get_mut()))
            }
            Stream::Gzip(writer) => {
                let _ = writer.write_all(text.as_bytes());
                let _ = writer.flush();
                Bytes::from(std::mem::take(writer.get_mut()))
            }
        }
    }

    /// Finish the stream: write the terminating block and hand back the last bytes.
    ///
    /// This is the step the Go SDK omits, and the reason a client that decodes the whole body at
    /// once rejected every answer it sent.
    pub fn finish(self) -> Bytes {
        match self {
            Stream::Identity => Bytes::new(),
            // `into_inner` runs the encoder's own FINISH, which is what emits the last block
            Stream::Brotli(writer) => Bytes::from(writer.into_inner()),
            Stream::Gzip(writer) => match writer.finish() {
                Ok(tail) => Bytes::from(tail),
                Err(_) => Bytes::new(),
            },
        }
    }
}
