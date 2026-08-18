"""The sound effects, synthesised at import. No audio files in the repo, and no audio library.

Five short WAVs -- a chime for a right answer, a thud for a wrong one, an arpeggio when a milestone
pays for a skip, a fanfare at the finale, and a tick for the last seconds of the countdown. They are
built here from `math.sin` and written with the stdlib `wave` module, which is a few dozen lines and
means the repo carries no binary assets, no licence question about somebody's sample pack, and no
build step: change a number below and the next request serves the new sound.

8 kHz, 8-bit, mono, deliberately. These are blips heard once through laptop speakers; the fidelity
that costs bytes here buys nothing. The whole set is ~20 KB and is fetched only if the player turns
sound on -- the `<audio>` elements in `shell.html.j2` have no `src` until `$_sound` is true.

TWO THINGS WORTH KNOWING

* **The tick's length is its rate limit.** `data-on-interval` runs at 100 ms, so a tick fired from it
  would be a 10 Hz buzz. `HTMLMediaElement.play()` on an element that is ALREADY playing is a no-op,
  so `tick` is a 45 ms blip followed by silence out to a full second: the sample's own duration is
  what spaces the ticks, and no timer state has to be kept anywhere. Silence is one repeated byte, so
  the padding costs ~50 bytes over the wire once compressed.
* **Nothing here is louder than it needs to be.** There is no volume control (that would need real
  JavaScript -- see the `<audio>` note in `shell.html.j2`), so the peak amplitude is baked in at a
  third of full scale and the envelopes decay fast.
"""

from __future__ import annotations

import io
import math
import wave

SAMPLE_RATE = 8000
# 8-bit WAV is UNSIGNED, centred on 128 -- a signed reading of it is the classic "why does it click".
_ZERO = 128
# Peak amplitude, as a fraction of full scale. Quiet on purpose: no volume control exists.
_PEAK = 0.33
# Fade applied to the first and last few milliseconds of every note. Without it the waveform starts
# and ends on a discontinuity, which is heard as a click on top of the note.
_EDGE_SECONDS = 0.004


def _note(frequency: float, seconds: float, *, decay: float = 6.0, gain: float = 1.0) -> list[float]:
    """One sine tone with an exponential decay, as floats in [-1, 1]."""
    count = int(SAMPLE_RATE * seconds)
    samples = []
    for index in range(count):
        t = index / SAMPLE_RATE
        envelope = math.exp(-decay * t / seconds) if seconds else 0.0
        edge = min(1.0, t / _EDGE_SECONDS, (seconds - t) / _EDGE_SECONDS)
        samples.append(math.sin(2 * math.pi * frequency * t) * envelope * max(0.0, edge) * gain)
    return samples


def _silence(seconds: float) -> list[float]:
    return [0.0] * int(SAMPLE_RATE * seconds)


def _mix(*layers: list[float]) -> list[float]:
    """Sum layers of equal-or-different length (a chord, or a note over a tail)."""
    length = max((len(layer) for layer in layers), default=0)
    out = [0.0] * length
    for layer in layers:
        for index, value in enumerate(layer):
            out[index] += value
    return out


def _wav(samples: list[float]) -> bytes:
    """PCM bytes, clipped rather than wrapped -- a wrapped overflow is a loud crack."""
    frames = bytes(max(0, min(255, _ZERO + int(value * _PEAK * 127))) for value in samples)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(1)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(frames)
    return buffer.getvalue()


def _build() -> dict[str, bytes]:
    # A rising pair says "that went up"; the fifth is the interval that reads as resolved rather than
    # merely different. Short, because it plays under the first toast and must not sit on top of it.
    correct = _note(659.25, 0.09) + _note(987.77, 0.16)  # E5 -> B5
    # Down, and low enough to be a different kind of sound rather than a sadder version of the same
    # one. A touch of the octave below gives it a body the pure tone lacks at this pitch.
    wrong = _mix(_note(196.00, 0.22, decay=4.0), _note(98.00, 0.22, decay=4.0, gain=0.5))  # G3 + G2
    # A skip is EARNED -- three notes up the major triad, brighter than the answer chime, because it
    # is the rarer event and it competes with the gauge sweep for the player's attention.
    skip = _note(1046.50, 0.07) + _note(1318.51, 0.07) + _note(1567.98, 0.20)  # C6 E6 G6
    # The finale, once per quiz: the same triad with a held root on top, long enough to be a flourish.
    final = (
        _note(523.25, 0.12)
        + _note(659.25, 0.12)
        + _note(783.99, 0.12)
        + _mix(_note(1046.50, 0.45, decay=3.0), _note(783.99, 0.45, decay=3.0, gain=0.5))
    )
    # The countdown. See the module docstring: the trailing silence is the rate limit.
    tick = _note(1200.0, 0.045, decay=9.0) + _silence(0.955)
    return {
        "correct": _wav(correct),
        "wrong": _wav(wrong),
        "skip": _wav(skip),
        "final": _wav(final),
        "tick": _wav(tick),
    }


# name -> WAV bytes. Built once at import; the whole set is ~20 KB in memory.
SOUNDS: dict[str, bytes] = _build()

# The order the `<audio>` elements are rendered in, and the names the beats use.
NAMES: tuple[str, ...] = tuple(SOUNDS)
