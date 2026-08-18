"""Sound: five synthesised WAVs, off by default, and not one line of helper JavaScript.

What is worth pinning here is mostly what sound must NOT do:

* **off by default and silent when off** -- the checkbox has no `checked`, the signal is declared
  `False`, and the `<audio>` elements have no `src` until it is true, so a player who never asks for
  sound never even fetches it.
* **no `<script>`** -- the app's rule is datastar attributes and CSS. `play()` in an attribute
  expression is that; a helper module would be the thing to argue about.
* **the tick cannot become a buzz** -- it is fired from a 100ms interval, and the only thing stopping
  it repeating ten times a second is the second of silence padding the sample. That is a property of
  the audio, so it is asserted against the audio.
"""

from __future__ import annotations

import io
import itertools
import re
import struct
import wave

import pytest
from litestar.testing import TestClient
from markup import found

import app as app_module
import corpus
import engine
import render
import sfx
import state


@pytest.fixture
def client():
    with TestClient(app=app_module.app) as test_client:
        test_client.headers.update({"Datastar-Request": "true"})
        yield test_client


def session_of(client):
    return app_module.STORE.get(client.cookies["dsq_sid"])


def answer_correctly(client) -> str:
    client.get("/")
    session = session_of(client)
    assert session is not None
    correct = session.question.candidates.index(session.question.answer_candidate)
    return client.post(f"/answer/{session.qid}/{correct}", content="{}").text


# --- the samples themselves --------------------------------------------------


def test_every_beat_has_a_sound_and_every_sound_is_a_wav():
    assert set(sfx.SOUNDS) == {"correct", "wrong", "skip", "final", "tick"}
    for name, audio in sfx.SOUNDS.items():
        assert audio.startswith(b"RIFF"), name
        assert audio[8:12] == b"WAVE", name


@pytest.mark.parametrize("name", sorted(sfx.SOUNDS))
def test_the_wavs_are_readable_and_small(name):
    """Readable by the stdlib parser, which is a closer proxy for "a browser will take it" than
    checking the header bytes -- and small, because these are blips over laptop speakers."""
    with wave.open(io.BytesIO(sfx.SOUNDS[name]), "rb") as handle:
        assert handle.getnchannels() == 1
        assert handle.getsampwidth() == 1
        assert handle.getframerate() == sfx.SAMPLE_RATE
        assert handle.getnframes() > 0
    assert len(sfx.SOUNDS[name]) < 20_000, "a sound effect should not be a download"


def test_the_ticks_own_length_is_the_rate_limit():
    """The countdown tick rides a 100ms interval, so ten a second is what stops it being one a
    second. `play()` is ignored while the element is still playing, so the sample is padded with
    silence to a full second and the spacing needs no timer state anywhere.

    If this drops back to the length of the blip, the last three seconds become a buzz.
    """
    frames = len(sfx.SOUNDS["tick"]) - 44  # 44-byte canonical WAV header, 1 byte per frame
    assert frames / sfx.SAMPLE_RATE == pytest.approx(1.0, abs=0.02)
    # ...and the padding really is silence, not a held tone
    assert sfx.SOUNDS["tick"][-200:] == bytes([128]) * 200


def test_nothing_clips():
    """8-bit PCM wraps rather than saturates, and a wrapped sample is a loud crack. `_wav` clamps;
    this checks the levels never get near the rail in the first place."""
    for name, audio in sfx.SOUNDS.items():
        body = audio[44:]
        assert max(body) < 250, name
        assert min(body) > 5, name


def test_a_note_is_the_pitch_it_says_it_is():
    """A zero-crossing count is a crude frequency meter, and enough to catch a sample rate or a
    phase mistake that would leave every sound a semitone-and-a-half wrong."""
    samples = sfx._note(1000.0, 0.05, decay=0.0)
    crossings = sum(1 for a, b in itertools.pairwise(samples) if (a < 0) != (b < 0))
    assert crossings == pytest.approx(100, abs=4)  # 1000Hz x 0.05s x 2 crossings per cycle


# --- serving them ------------------------------------------------------------


def test_the_route_serves_wav_bytes(client):
    response = client.get("/sfx/correct")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/wav")
    assert response.content == sfx.SOUNDS["correct"]


def test_the_route_caches_hard(client):
    """The bytes for a name never change within a build, and the page appends `?v=<build stamp>`, so
    a changed synth arrives as a new URL rather than waiting out a cache."""
    cache = client.get("/sfx/tick").headers["cache-control"]
    assert "max-age=31536000" in cache
    assert "public" in cache


def test_an_unknown_sound_is_a_plain_404(client):
    assert client.get("/sfx/nope").status_code == 404


def test_there_are_no_audio_files_in_the_repo():
    """The point of synthesising them: no binaries in a documentation repo, no licence to track, and
    no regeneration step -- change a number in `sfx.py` and the next request serves the new sound."""
    static = render.TEMPLATE_DIR.parent / "static"
    assert not list(static.rglob("*.wav"))
    assert not list(static.rglob("*.mp3"))


# --- off by default ----------------------------------------------------------


def test_the_signal_is_declared_local_and_false():
    """Local like every other appearance preference, so the server never learns it -- and the ONE
    that starts off: the others change how the page looks to whoever asked, audio arrives in a room."""
    assert render.local_ui_signals()["_sound"] is False


def test_the_checkbox_agrees_with_the_declared_default(client):
    """A `checked` box would upload `true` into the signal on first paint and the quiz would start
    making noise on its own -- the same trap the game-feel box documents from the other side."""
    box = found(r'<input type="checkbox"[^>]*data-bind="_sound"[^>]*/>', client.get("/").text).group(0)
    assert "checked" not in box


def test_nothing_is_fetched_until_sound_is_switched_on(client):
    """The `<audio>` elements have no `src` attribute at all: the URL is built by `data-attr:src`
    from `$_sound`, so with sound off the page is exactly the three requests it always was."""
    body = client.get("/").text
    for name in sfx.NAMES:
        element = found(rf'<audio id="sfx-{name}".*?>', body, re.DOTALL).group(0)
        assert "data-attr:src=" in element
        assert "$_sound ?" in element
        assert ' src="' not in element, "a static src fetches for players who never turn sound on"


def test_the_audio_elements_live_outside_the_morph_target(client):
    """Inside `#app` they would be replaced on every interaction -- re-fetched constantly, and cut
    off mid-play. So they are in the document and NOT in the fat patch, which is the same distinction
    `<body data-init>` needed for the held timer stream."""
    session = session_of(client) if client.cookies.get("dsq_sid") else None
    if session is None:
        client.get("/")
        session = session_of(client)
    assert session is not None
    assert "sfx-correct" in render.shell(session)
    assert "sfx-correct" not in render.app_body(session)
    assert "sfx-correct" not in client.post("/skip", content="{}").text


def test_the_urls_carry_the_build_stamp(client):
    assert f"/sfx/correct?v={render.build_stamp()}" in client.get("/").text


def test_no_javascript_was_added_for_any_of_it():
    """`play()` in a datastar expression is the same kind of thing as every other handler in this
    app. A helper script is not, which is why sound has no volume control."""
    for template in render.TEMPLATE_DIR.glob("*.j2"):
        markup = template.read_text(encoding="utf-8")
        assert "<script" not in markup or "datastar.js" in markup


# --- the beats ---------------------------------------------------------------


def test_a_right_answer_plays_the_chime(client):
    body = answer_correctly(client)
    assert "selector #sfx" in body
    assert "sfx-correct" in body
    assert "sfx-wrong" not in body


def test_a_wrong_answer_plays_the_other_one(client):
    client.get("/")
    session = session_of(client)
    assert session is not None
    wrong = next(i for i, c in enumerate(session.question.candidates) if c != session.question.answer_candidate)
    body = client.post(f"/answer/{session.qid}/{wrong}", content="{}").text
    assert "sfx-wrong" in body
    assert "sfx-correct" not in body


def test_the_verdict_sound_leads_the_toast_that_says_the_same_thing(client):
    """A sound that lands after the words have appeared reads as a reaction to reading them."""
    body = answer_correctly(client)
    assert body.index("sfx-correct") < body.index("Correct!")


def test_every_beat_is_gated_on_the_signal(client):
    """The preference is local, so the server cannot know it and streams the beat either way -- the
    expression is the gate, exactly as `body.juice` gates the floaters."""
    for line in answer_correctly(client).splitlines():
        if "sfx-" in line:
            assert "$_sound &&" in line, line


def test_the_sink_is_cleared_at_the_start_of_the_stream(client):
    """Markers are APPENDED (an appended element is always new, so `data-init` always runs), which
    means something has to empty the sink -- and doing it first rather than last never removes a
    marker while the sound it started is still playing."""
    body = answer_correctly(client)
    clear = body.index("selector #sfx")
    assert "mode inner" in body[max(0, clear - 200) : clear + 200]
    assert body.index("elements <span") > clear


def test_a_milestone_plays_and_sweeps_the_gauge(client):
    """The gauge carries the milestone notches, so it is the thing that should acknowledge one being
    collected -- it used to say nothing, leaving the award to one toast among four."""
    client.get("/")
    session = session_of(client)
    assert session is not None
    # one point short of the first milestone (10% of the goal), so any correct answer crosses it
    session.score.total_points = int(engine.SCORE_MILESTONES[0] * session.points_goal) - 1
    correct = session.question.candidates.index(session.question.answer_candidate)
    body = client.post(f"/answer/{session.qid}/{correct}", content="{}").text

    assert "+1 SKIP!" in body
    assert "sfx-skip" in body
    assert 'class="meter-sweep"' in body
    assert f"selector {app_module.METER_SELECTOR}" in body


def test_an_ordinary_answer_sweeps_nothing(client):
    assert "meter-sweep" not in answer_correctly(client)


def test_the_sweep_is_driven_by_the_flag_not_by_the_wording():
    """`app._answer_stream` keys off `Toast.awards_skip`. Matching on "+1 SKIP!" would make a copy
    edit silently drop the sweep and the sound, which is the sort of break nothing would catch."""
    awarding = [toast for toast in _milestone_toasts() if toast.awards_skip]
    assert len(awarding) == 1
    assert "SKIP" in awarding[0].text
    assert all(not toast.awards_skip for toast in _milestone_toasts() if "SKIP" not in toast.text)


def _milestone_toasts() -> list[engine.Toast]:
    score = engine.Score(total_points=int(engine.SCORE_MILESTONES[0] * engine.POINTS_GOAL) - 1)
    question = state.new_session(corpus.DEFAULT_VARIANT).question
    outcome, _ = engine.answer(
        score=score,
        question=question,
        candidate=question.answer_candidate,
        percent_left=50,
        ladder_mode=False,
        target_on=False,
        target_pct=70,
        last_correct_points=0,
    )
    assert outcome.awarded_skips >= 1
    return outcome.toasts


def test_the_finale_has_its_own_flourish(client, monkeypatch):
    monkeypatch.setattr(app_module, "DEBUG_MODE", "1")
    client.get("/")
    body = client.post("/debug/complete", content="{}").text
    assert "sfx-final" in body
    # ...and it is the last sound of the answer, not one laid over the "Correct!" chime
    assert body.index("sfx-final") > body.index("sfx-correct")


def test_an_unknown_beat_is_a_programming_error():
    with pytest.raises(KeyError):
        render.sfx_beat("applause")


# --- the countdown tick ------------------------------------------------------


def test_the_tick_rides_the_countdown_interval(client):
    """One interval, not a second one: the drain and the tick are the same 100ms beat."""
    interval = found(r'data-on-interval__duration\.100ms="([^"]+)"', client.get("/").text).group(1)
    assert "$_sound &&" in interval
    assert "sfx-tick" in interval
    # under three seconds left, expressed without a division: pct x ms < 3000 x 100
    assert "$_timeLeftPct * $_questionMs < 300000" in interval
    # and it stays behind the guards the drain already has
    assert interval.startswith("$_ticking && !$_answering")


def test_the_stream_timer_has_no_tick(client, monkeypatch):
    """In `DSQUIZ_TIMER=stream` the interval attribute does not exist at all -- the server pushes the
    percentage. A tick there would have to be an element patch per second per tab, which is a cost
    the comparison should not absorb quietly."""
    monkeypatch.setattr(render, "timer_mode", lambda: "stream")
    body = client.get("/").text
    assert "data-on-interval" not in body
    # the `<audio id="sfx-tick">` element is still in the page (it is the document's, not the
    # timer's); what must be gone is anything that PLAYS it
    assert "sfx-tick')?.play()" not in body


def test_the_wav_header_is_the_one_browsers_expect():
    """A quick structural check of the format `wave` wrote: PCM (format 1), mono, 8-bit."""
    header = sfx.SOUNDS["correct"][:44]
    channels, rate, _, _, bits = struct.unpack("<HIIHH", header[22:36])
    assert (channels, rate, bits) == (1, sfx.SAMPLE_RATE, 8)
