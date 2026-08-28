//! The sound effects, synthesised at startup. No audio files in the repo, and no audio library.
//!
//! Five short WAVs -- a chime for a right answer, a thud for a wrong one, an arpeggio when a
//! milestone pays for a skip, a fanfare at the finale, and a tick for the last seconds of the
//! countdown. They are built from `f64::sin` and a hand-written RIFF header, which means the repo
//! carries no binary assets, no licence question about somebody's sample pack, and no build step.
//!
//! 8 kHz, 8-bit, mono, deliberately. These are blips heard once through laptop speakers; the
//! fidelity that costs bytes here buys nothing. The whole set is ~20 KB and is fetched only if the
//! player turns sound on -- the `<audio>` elements have no `src` until then.
//!
//! TWO THINGS WORTH KNOWING
//!
//! * **The tick's length is its rate limit.** `data-on-interval` runs at 100 ms, so a tick fired
//!   from it would be a 10 Hz buzz. `HTMLMediaElement.play()` on an element that is ALREADY playing
//!   is a no-op, so `tick` is a 45 ms blip followed by silence out to a full second: the sample's
//!   own duration is what spaces the ticks, and no timer state has to be kept anywhere.
//! * **Nothing here is louder than it needs to be.** There is no volume control (that would need
//!   real JavaScript), so the peak amplitude is baked in at a third of full scale and the envelopes
//!   decay fast.

use std::sync::OnceLock;

const SAMPLE_RATE: u32 = 8000;
/// 8-bit WAV is UNSIGNED, centred on 128 -- a signed reading of it is the classic "why does it
/// click".
const ZERO: i32 = 128;
/// Peak amplitude, as a fraction of full scale. Quiet on purpose: no volume control exists.
const PEAK: f64 = 0.33;
/// Fade applied to the first and last few milliseconds of every note. Without it the waveform starts
/// and ends on a discontinuity, which is heard as a click on top of the note.
const EDGE_SECONDS: f64 = 0.004;

/// The order the `<audio>` elements are rendered in, and the names the beats use.
pub const NAMES: &[&str] = &["correct", "wrong", "skip", "final", "tick"];

/// One sine tone with an exponential decay, as floats in [-1, 1].
fn note(frequency: f64, seconds: f64, decay: f64, gain: f64) -> Vec<f64> {
    let count = (f64::from(SAMPLE_RATE) * seconds) as usize;
    (0..count)
        .map(|index| {
            let t = index as f64 / f64::from(SAMPLE_RATE);
            let envelope = if seconds != 0.0 {
                (-decay * t / seconds).exp()
            } else {
                0.0
            };
            let edge = 1.0_f64
                .min(t / EDGE_SECONDS)
                .min((seconds - t) / EDGE_SECONDS);
            (2.0 * std::f64::consts::PI * frequency * t).sin() * envelope * edge.max(0.0) * gain
        })
        .collect()
}

fn silence(seconds: f64) -> Vec<f64> {
    vec![0.0; (f64::from(SAMPLE_RATE) * seconds) as usize]
}

/// Sum layers of equal-or-different length (a chord, or a note over a tail).
fn mix(layers: &[Vec<f64>]) -> Vec<f64> {
    let length = layers.iter().map(Vec::len).max().unwrap_or(0);
    let mut out = vec![0.0; length];
    for layer in layers {
        for (index, value) in layer.iter().enumerate() {
            out[index] += value;
        }
    }
    out
}

fn join(parts: &[Vec<f64>]) -> Vec<f64> {
    parts.iter().flatten().copied().collect()
}

/// PCM bytes with a RIFF header, clipped rather than wrapped -- a wrapped overflow is a loud crack.
fn encode_wav(samples: &[f64]) -> Vec<u8> {
    let frames: Vec<u8> = samples
        .iter()
        // `as i32` truncates toward zero, which is what python's int() does
        .map(|value| (ZERO + (value * PEAK * 127.0) as i32).clamp(0, 255) as u8)
        .collect();
    let mut out = Vec::with_capacity(44 + frames.len());
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + frames.len() as u32).to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // PCM header length
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    out.extend_from_slice(&SAMPLE_RATE.to_le_bytes()); // byte rate: 1 channel x 1 byte
    out.extend_from_slice(&1u16.to_le_bytes()); // block align
    out.extend_from_slice(&8u16.to_le_bytes()); // bits per sample
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(frames.len() as u32).to_le_bytes());
    out.extend_from_slice(&frames);
    out
}

/// The five WAVs, built once. Leaked to `'static` because they live for the process and are handed
/// straight to the response body -- there is no reason for a request to refcount them.
fn sounds() -> &'static [(&'static str, Vec<u8>); 5] {
    static SOUNDS: OnceLock<[(&'static str, Vec<u8>); 5]> = OnceLock::new();
    SOUNDS.get_or_init(|| {
        // A rising pair says "that went up"; the fifth is the interval that reads as resolved rather
        // than merely different. Short, because it plays under the first toast.
        let correct = join(&[note(659.25, 0.09, 6.0, 1.0), note(987.77, 0.16, 6.0, 1.0)]); // E5 -> B5
        // Down, and low enough to be a different kind of sound rather than a sadder version of the
        // same one. A touch of the octave below gives it a body the pure tone lacks.
        let wrong = mix(&[note(196.00, 0.22, 4.0, 1.0), note(98.00, 0.22, 4.0, 0.5)]); // G3 + G2
        // A skip is EARNED -- three notes up the major triad, brighter than the answer chime,
        // because it is the rarer event and it competes with the gauge sweep for attention.
        let skip = join(&[
            note(1046.50, 0.07, 6.0, 1.0),
            note(1318.51, 0.07, 6.0, 1.0),
            note(1567.98, 0.20, 6.0, 1.0),
        ]); // C6 E6 G6
        // The finale, once per quiz: the same triad with a held root on top.
        let final_fanfare = join(&[
            note(523.25, 0.12, 6.0, 1.0),
            note(659.25, 0.12, 6.0, 1.0),
            note(783.99, 0.12, 6.0, 1.0),
            mix(&[note(1046.50, 0.45, 3.0, 1.0), note(783.99, 0.45, 3.0, 0.5)]),
        ]);
        // The countdown. See the module doc: the trailing silence is the rate limit.
        let tick = join(&[note(1200.0, 0.045, 9.0, 1.0), silence(0.955)]);

        [
            ("correct", encode_wav(&correct)),
            ("wrong", encode_wav(&wrong)),
            ("skip", encode_wav(&skip)),
            ("final", encode_wav(&final_fanfare)),
            ("tick", encode_wav(&tick)),
        ]
    })
}

/// One synthesised WAV by name.
pub fn get(name: &str) -> Option<&'static [u8]> {
    sounds()
        .iter()
        .find(|(key, _)| *key == name)
        .map(|(_, bytes)| bytes.as_slice())
}

/// Build them all now, so the first player to turn sound on does not pay for it.
pub fn warm() {
    let _ = sounds();
}
