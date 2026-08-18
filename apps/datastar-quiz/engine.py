"""Quiz rules: scoring, the time bonus, milestone skip awards, completion.

No HTTP, no HTML, no signals -- this is the state machine the routes drive, ported from the
panel app's `points` / `on_answer_click` / `reset_time_bonus_by_difficulty`
(`quiz_app.py:389-635`). Keeping it separate is what lets the tests assert parity with the
panel implementation directly.

The panel version interleaved scoring with `await asyncio.sleep(...)` and toast calls, so the
score arrived at the browser in instalments. Here `answer` applies the whole state change at
once and *returns* the instalments as `Toast`s: the SSE handler replays them with the same
delays, but a mid-stream reload sees final state rather than a half-scored session.
"""

from __future__ import annotations

import msgspec

# via corpus, not `import quiz`: importing corpus is what puts `apps/quiz/` on sys.path, and a
# bare `import quiz` here would be sorted above it and fail whenever engine is imported first
from corpus import quiz

INITIAL_DIFFICULTY = 5
MIN_DIFFICULTY = 4
MAX_DIFFICULTY = 8

POINTS_GOAL = 1000
SCORE_MILESTONES = [0.1, 0.25, 0.45, 0.65, 0.8, 1]
INITIAL_SKIPS = 3

# seconds allowed per question, by difficulty (`reset_time_bonus_by_difficulty`)
_SECONDS_PER_LEVEL = {4: 8, 5: 7, 6: 6, 7: 5, 8: 4}


def seconds_for_difficulty(difficulty: int) -> float:
    return float(difficulty * _SECONDS_PER_LEVEL.get(difficulty, 4))


def percent_time_left(elapsed: float, allowed: float) -> int:
    """The time bonus percentage, as the panel `TimeBonus` progress bar computed it."""
    if allowed <= 0:
        return 0
    return round(max(allowed - elapsed, 0.0) / allowed * 100)


def clamp_difficulty(value: object) -> int:
    """A signal value from the browser, clamped to a difficulty. Anything unusable is the default."""
    if not isinstance(value, int | float | str):
        return INITIAL_DIFFICULTY
    try:
        difficulty = int(value)
    except ValueError:
        return INITIAL_DIFFICULTY
    return max(MIN_DIFFICULTY, min(MAX_DIFFICULTY, difficulty))


class Points(msgspec.Struct, frozen=True):
    from_candidate_lengths: int
    from_streak_bonus: int
    from_time_bonus: int

    @property
    def total(self) -> int:
        return self.from_candidate_lengths + self.from_streak_bonus + self.from_time_bonus


def points(question: quiz.Question, streak: int, percent_left: int) -> Points:
    """Verbatim port of `quiz_app.points` -- longer auctions are worth more, with a streak
    multiplier and a time multiplier on top."""
    from_candidate_lengths = 0
    for candidate in question.candidates:
        tokens_without_sep = candidate.replace("-->", "")
        from_candidate_lengths += len(tokens_without_sep.split())

    if streak > 1:
        percent_bonus = min(streak * 10 / 100, 1.0)
        streak_bonus = round(from_candidate_lengths * percent_bonus)
    else:
        streak_bonus = 0

    time_bonus = round(from_candidate_lengths * (percent_left / 100)) if percent_left > 0 else 0

    return Points(
        from_candidate_lengths=from_candidate_lengths,
        from_streak_bonus=streak_bonus,
        from_time_bonus=time_bonus,
    )


class Toast(msgspec.Struct, frozen=True):
    """One notification, and how long the stream should pause after showing it.

    `kind` matches the panel notification methods (success / info / warning) so the CSS can
    keep the same colour language.
    """

    kind: str
    text: str
    pause: float
    # The running points total *as at this toast*. The state change is applied in one go, but
    # the panel app revealed the points in instalments (candidate length, then streak bonus,
    # then time bonus), so each toast carries the number to show alongside it.
    points_after: int | None = None
    # This beat is a milestone paying for a skip. A flag rather than a text match in the renderer:
    # the words are presentation and have already been reworded once, and "+1 SKIP!" appearing in
    # `app._answer_stream` would make an unrelated copy edit silently drop the gauge sweep and the
    # sound that go with it. `Answered.awarded_skips` counts them; this says WHICH beat they land on.
    awards_skip: bool = False


class Answered(msgspec.Struct, frozen=True):
    correct: bool
    toasts: list[Toast]
    completed: bool
    awarded_skips: int


class Score(msgspec.Struct):
    """The part of a session the score panel renders."""

    questions_correct: int = 0
    questions_attempted: int = 0
    streak: int = 0
    total_points: int = 0
    available_milestones: list[float] = msgspec.field(default_factory=lambda: list(reversed(SCORE_MILESTONES)))

    def percentage(self) -> int:
        if self.questions_attempted > 0:
            return round((self.questions_correct / self.questions_attempted) * 100)
        return 0

    def reset(self) -> None:
        self.questions_correct = 0
        self.questions_attempted = 0
        self.streak = 0
        self.total_points = 0
        self.available_milestones = list(reversed(SCORE_MILESTONES))


def answer(
    *,
    score: Score,
    question: quiz.Question,
    candidate: str,
    percent_left: int,
    ladder_mode: bool,
    target_on: bool,
    target_pct: int,
    last_correct_points: int,
    points_goal: int = POINTS_GOAL,
) -> tuple[Answered, int]:
    """Score one answer. Mutates `score`; returns the toast script and the new
    `last_correct_points` (what a wrong answer costs in ladder mode).

    `points_goal` is a parameter rather than the module constant so the debug panel can shorten a quiz
    without a global mutation -- the goal decides both completion and where the skip milestones fall,
    and two sessions in one process may disagree about it.

    A wrong answer's toasts are deliberately brief: the answer itself is revealed in place in the
    question card (`reveal.html.j2`), not spelled out in a notification the player must wait behind.
    """
    correct = candidate == question.answer_candidate
    toasts: list[Toast] = []

    if not correct:
        score.streak = 0
        score.questions_attempted += 1
        score_was_non_zero = score.total_points > 0
        if ladder_mode:
            score.total_points = max(score.total_points - last_correct_points, 0)
        toasts.append(Toast("warning", "Not quite", 0.6))
        if ladder_mode and last_correct_points > 0 and score_was_non_zero:
            toasts.append(Toast("warning", f"Ladder mode: -{last_correct_points} points", 0.6, score.total_points))
        return Answered(False, toasts, completed=False, awarded_skips=0), last_correct_points

    score.streak += 1
    increase = points(question, score.streak, percent_left)

    toasts.append(Toast("success", "Correct!", 0.5))
    score.total_points += increase.from_candidate_lengths
    toasts.append(Toast("info", f"+{increase.from_candidate_lengths}!", 0.5, score.total_points))
    if increase.from_streak_bonus > 0:
        score.total_points += increase.from_streak_bonus
        toasts.append(
            Toast(
                "info",
                f"Streak {score.streak}, Bonus +{increase.from_streak_bonus}",
                0.5,
                score.total_points,
            )
        )
    if increase.from_time_bonus > 0:
        score.total_points += increase.from_time_bonus
        toasts.append(Toast("info", f"Time Bonus +{increase.from_time_bonus}", 0.5, score.total_points))

    score.questions_attempted += 1
    score.questions_correct += 1

    awarded_skips = 0
    while score.available_milestones and score.available_milestones[-1] * points_goal <= score.total_points:
        score.available_milestones.pop()
        awarded_skips += 1
        toasts.append(Toast("success", "+1 SKIP!", 0.5, awards_skip=True))

    completed = False
    if score.total_points >= points_goal:
        percentage = score.percentage()
        if (not target_on) or percentage >= target_pct:
            completed = True
        else:
            toasts.append(Toast("warning", f"Current score {percentage}%, target score {target_pct}%", 0.5))

    # the panel handler paused a further second before moving on when the answer was right
    toasts.append(Toast("info", "", 1.0))

    return (
        Answered(True, toasts, completed=completed, awarded_skips=awarded_skips),
        increase.total,
    )


def new_question(sequences: list, difficulty: int) -> quiz.Question:
    return quiz.generate_question(
        sequences,
        choice_type=quiz.random_multi_choice_type(),
        multi_choice_count=difficulty,
    )
