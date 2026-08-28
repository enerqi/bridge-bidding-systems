"""Who the simulated players are.

A load test whose users are all identical measures one code path very precisely. These profiles
vary the things this app actually branches on:

* **the system** -- squad or `?swedish`. Different `.bml` corpus, different topics file, and a
  separate session per (browser, variant), so the mix decides how many bid tables stay hot.
* **the settings** -- difficulty is the number of candidate answers per question (4-8), which
  changes both the render size and the scoring; ladder mode and the target percentage change which
  toasts a scored answer produces, and therefore how long its SSE stream is held open.
* **the pace** -- think time relative to the 4-8 second question clock.

Each `FastHttpUser` instance draws one profile in `on_start` and keeps it for its life, because a
person does not re-roll their difficulty between questions.
"""

from __future__ import annotations

import random
from dataclasses import dataclass

from common import config, datastar

FILTER_PHRASES = (
    "1C",
    "1D",
    "1N",
    "2C",
    "1C--1D",
    "1D-1M",
    "1N--2C",
    "1C (1S) X",
    "1H-2H",
    "2N",
)
"""Auction prefixes typed into the filter box. Real patterns from the corpus rather than junk: an
unparseable filter is rejected early and would measure the error path, not the matcher."""


@dataclass
class Profile:
    variant_query: str
    signals: datastar.Signals
    think_min: float
    think_max: float
    label: str

    def think(self) -> float:
        return random.uniform(self.think_min, self.think_max)


def _pace() -> tuple[float, float, str]:
    roll = random.random()
    if roll < config.FAST_SHARE:
        return (*config.THINK_FAST, "fast")
    if roll < config.FAST_SHARE + config.SLOW_SHARE:
        return (*config.THINK_SLOW, "slow")
    return (*config.THINK_TYPICAL, "typical")


def random_profile() -> Profile:
    """One player. The variant query is only a fallback -- once the page has been loaded, the real
    one is read off its action URLs (`View.variant_query`), which is what a mounted deployment or a
    future third system would need anyway."""
    swedish = random.random() < config.SWEDISH_SHARE
    think_min, think_max, label = _pace()
    return Profile(
        variant_query="?swedish" if swedish else "",
        signals=datastar.Signals(
            # weighted towards the middle of the 4-8 range, which is where the app's own default sits
            difficulty=random.choice([4, 4, 5, 5, 5, 6, 6, 6, 7, 8]),
            ladder_mode=random.random() < 0.3,
            target_on=random.random() < 0.25,
            target_pct=random.choice([70, 75, 80, 85, 90]),
        ),
        think_min=think_min,
        think_max=think_max,
        label=f"{'swedish' if swedish else 'squad'}/{label}",
    )


def typed_prefixes(phrase: str) -> list[str]:
    """A phrase as the sequence of previews typing it produces.

    The box debounces at 300ms, so a typist does not generate one request per character -- they
    generate one per pause. Two to four chunks per phrase is what that looks like.
    """
    if len(phrase) < 3:
        return [phrase]
    cuts = sorted(random.sample(range(1, len(phrase)), min(random.randint(1, 3), len(phrase) - 1)))
    return [phrase[:cut] for cut in cuts] + [phrase]
