// Package sfx is the sound effects, synthesised at startup. No audio files in the repo,
// and no audio library: a port of `apps/datastar-quiz/sfx.py`.
//
// Five short WAVs -- a chime for a right answer, a thud for a wrong one, an arpeggio when a
// milestone pays for a skip, a fanfare at the finale, and a tick for the last seconds of
// the countdown. They are built from math.Sin and a hand-written RIFF header, which is a
// few dozen lines and means the repo carries no binary assets, no licence question about
// somebody's sample pack, and no build step.
//
// 8 kHz, 8-bit, mono, deliberately. These are blips heard once through laptop speakers; the
// fidelity that costs bytes here buys nothing. The whole set is ~20 KB and is fetched only
// if the player turns sound on -- the <audio> elements have no src until then.
//
// TWO THINGS WORTH KNOWING
//
//   - **The tick's length is its rate limit.** `data-on-interval` runs at 100 ms, so a tick
//     fired from it would be a 10 Hz buzz. HTMLMediaElement.play() on an element that is
//     ALREADY playing is a no-op, so `tick` is a 45 ms blip followed by silence out to a
//     full second: the sample's own duration is what spaces the ticks, and no timer state
//     has to be kept anywhere.
//   - **Nothing here is louder than it needs to be.** There is no volume control (that
//     would need real JavaScript), so the peak amplitude is baked in at a third of full
//     scale and the envelopes decay fast.
package sfx

import (
	"encoding/binary"
	"math"
)

const (
	sampleRate = 8000
	// 8-bit WAV is UNSIGNED, centred on 128 -- a signed reading of it is the classic
	// "why does it click".
	zero = 128
	// Peak amplitude, as a fraction of full scale. Quiet on purpose: no volume control
	// exists.
	peak = 0.33
	// Fade applied to the first and last few milliseconds of every note. Without it the
	// waveform starts and ends on a discontinuity, which is heard as a click on top of
	// the note.
	edgeSeconds = 0.004
)

type noteOption func(*noteConfig)

type noteConfig struct {
	decay float64
	gain  float64
}

func withDecay(decay float64) noteOption { return func(c *noteConfig) { c.decay = decay } }
func withGain(gain float64) noteOption   { return func(c *noteConfig) { c.gain = gain } }

// note is one sine tone with an exponential decay, as floats in [-1, 1].
func note(frequency, seconds float64, opts ...noteOption) []float64 {
	cfg := noteConfig{decay: 6.0, gain: 1.0}
	for _, opt := range opts {
		opt(&cfg)
	}
	count := int(sampleRate * seconds)
	samples := make([]float64, count)
	for index := range samples {
		t := float64(index) / sampleRate
		envelope := 0.0
		if seconds != 0 {
			envelope = math.Exp(-cfg.decay * t / seconds)
		}
		edge := math.Min(1.0, math.Min(t/edgeSeconds, (seconds-t)/edgeSeconds))
		samples[index] = math.Sin(2*math.Pi*frequency*t) * envelope * math.Max(0, edge) * cfg.gain
	}
	return samples
}

func silence(seconds float64) []float64 {
	return make([]float64, int(sampleRate*seconds))
}

// mix sums layers of equal-or-different length (a chord, or a note over a tail).
func mix(layers ...[]float64) []float64 {
	length := 0
	for _, layer := range layers {
		length = max(length, len(layer))
	}
	out := make([]float64, length)
	for _, layer := range layers {
		for index, value := range layer {
			out[index] += value
		}
	}
	return out
}

func join(parts ...[]float64) []float64 {
	var out []float64
	for _, part := range parts {
		out = append(out, part...)
	}
	return out
}

// wav is PCM bytes with a RIFF header, clipped rather than wrapped -- a wrapped overflow is
// a loud crack.
func encodeWAV(samples []float64) []byte {
	frames := make([]byte, len(samples))
	for i, value := range samples {
		// int() in python truncates toward zero, which is what int(...) does here too
		frames[i] = byte(min(255, max(0, zero+int(value*peak*127))))
	}
	const headerSize = 44
	out := make([]byte, 0, headerSize+len(frames))
	out = append(out, "RIFF"...)
	out = binary.LittleEndian.AppendUint32(out, uint32(36+len(frames)))
	out = append(out, "WAVE"...)
	out = append(out, "fmt "...)
	out = binary.LittleEndian.AppendUint32(out, 16) // PCM header length
	out = binary.LittleEndian.AppendUint16(out, 1)  // PCM
	out = binary.LittleEndian.AppendUint16(out, 1)  // mono
	out = binary.LittleEndian.AppendUint32(out, sampleRate)
	out = binary.LittleEndian.AppendUint32(out, sampleRate) // byte rate: 1 channel x 1 byte
	out = binary.LittleEndian.AppendUint16(out, 1)          // block align
	out = binary.LittleEndian.AppendUint16(out, 8)          // bits per sample
	out = append(out, "data"...)
	out = binary.LittleEndian.AppendUint32(out, uint32(len(frames)))
	return append(out, frames...)
}

// Sounds is name -> WAV bytes. Built once at startup; the whole set is ~20 KB in memory.
var Sounds = build()

// Names is the order the <audio> elements are rendered in, and the names the beats use.
var Names = []string{"correct", "wrong", "skip", "final", "tick"}

func build() map[string][]byte {
	// A rising pair says "that went up"; the fifth is the interval that reads as resolved
	// rather than merely different. Short, because it plays under the first toast.
	correct := join(note(659.25, 0.09), note(987.77, 0.16)) // E5 -> B5
	// Down, and low enough to be a different kind of sound rather than a sadder version of
	// the same one. A touch of the octave below gives it a body the pure tone lacks.
	wrong := mix(note(196.00, 0.22, withDecay(4.0)), note(98.00, 0.22, withDecay(4.0), withGain(0.5)))
	// A skip is EARNED -- three notes up the major triad, brighter than the answer chime,
	// because it is the rarer event and it competes with the gauge sweep for attention.
	skip := join(note(1046.50, 0.07), note(1318.51, 0.07), note(1567.98, 0.20)) // C6 E6 G6
	// The finale, once per quiz: the same triad with a held root on top.
	final := join(
		note(523.25, 0.12),
		note(659.25, 0.12),
		note(783.99, 0.12),
		mix(note(1046.50, 0.45, withDecay(3.0)), note(783.99, 0.45, withDecay(3.0), withGain(0.5))),
	)
	// The countdown. See the package doc: the trailing silence is the rate limit.
	tick := join(note(1200.0, 0.045, withDecay(9.0)), silence(0.955))

	return map[string][]byte{
		"correct": encodeWAV(correct),
		"wrong":   encodeWAV(wrong),
		"skip":    encodeWAV(skip),
		"final":   encodeWAV(final),
		"tick":    encodeWAV(tick),
	}
}

// Has reports whether a beat name exists.
func Has(name string) bool {
	_, ok := Sounds[name]
	return ok
}
