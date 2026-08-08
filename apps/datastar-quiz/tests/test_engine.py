"""Rules tests, including parity with the panel implementation.

The parity test does not import `apps/quiz/quiz_app.py` -- that would pull in panel and run a
whole app at import time. Instead it lifts the `Points` dataclass and the `points` function out
of that file's AST and executes just those two definitions, so the assertion is against the
code that is actually running in the panel app, and the panel app is only ever read.
"""

from __future__ import annotations

import ast
import sys
import types
from dataclasses import dataclass
from pathlib import Path

import pytest

import corpus
import engine

PANEL_APP = Path(__file__).resolve().parents[2] / "quiz" / "quiz_app.py"


def question_of(candidates: list[str], answer_candidate: str = "") -> corpus.quiz.Question:
    """A real `quiz.Question`, so the rules are exercised against the type they see in anger."""
    return corpus.quiz.Question(
        candidates=candidates,
        answer="the description",
        answer_candidate=answer_candidate or (candidates[0] if candidates else ""),
        choice_type=corpus.quiz.MultiChoiceType.Auctions,
        _debug_bid_sequences=[],
    )


@pytest.fixture(scope="module")
def panel_points():
    """The panel app's own `points`, extracted from source without importing panel."""
    tree = ast.parse(PANEL_APP.read_text(encoding="utf-8"), filename=str(PANEL_APP))
    wanted = {
        node.name: node
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in {"Points", "points"}
    }
    assert wanted.keys() == {"Points", "points"}, "quiz_app.py no longer defines Points/points"

    module = types.ModuleType("panel_points_extract")
    # `points` annotates its argument as `quiz.Question`, evaluated at def time
    module.__dict__.update({"dataclass": dataclass, "quiz": corpus.quiz})
    # @dataclass resolves string annotations through sys.modules[cls.__module__]
    sys.modules[module.__name__] = module
    exec(  # noqa: S102 -- executing two definitions lifted from a file in this repo
        compile(ast.Module(body=[wanted["Points"], wanted["points"]], type_ignores=[]), str(PANEL_APP), "exec"),
        module.__dict__,
    )
    return module.points


AUCTIONS = [
    ["1C", "1H", "2N"],
    ["1D --> 1S --> 3N", "1C"],
    ["1N", "2D/2H", "3C", "4S", "6N"],
    [],
]


@pytest.mark.parametrize("candidates", AUCTIONS)
@pytest.mark.parametrize("streak", [0, 1, 2, 5, 12])
@pytest.mark.parametrize("percent_left", [0, 1, 37, 100])
def test_points_match_panel(panel_points, candidates, streak, percent_left):
    question = question_of(candidates)
    ours = engine.points(question, streak, percent_left)
    theirs = panel_points(question, streak, percent_left)
    assert (ours.from_candidate_lengths, ours.from_streak_bonus, ours.from_time_bonus) == (
        theirs.from_candidate_lengths,
        theirs.from_streak_bonus,
        theirs.from_time_bonus,
    )


def test_seconds_for_difficulty_matches_panel_table():
    # difficulty * seconds_per_level[difficulty]
    assert engine.seconds_for_difficulty(4) == 32
    assert engine.seconds_for_difficulty(5) == 35
    assert engine.seconds_for_difficulty(8) == 32
    # levels outside the table fall back to 4 seconds per level, as in panel
    assert engine.seconds_for_difficulty(9) == 36


def test_percent_time_left():
    assert engine.percent_time_left(0, 10) == 100
    assert engine.percent_time_left(5, 10) == 50
    assert engine.percent_time_left(12, 10) == 0
    assert engine.percent_time_left(1, 0) == 0


def test_clamp_difficulty():
    assert engine.clamp_difficulty(6) == 6
    assert engine.clamp_difficulty("7") == 7
    assert engine.clamp_difficulty(99) == engine.MAX_DIFFICULTY
    assert engine.clamp_difficulty(1) == engine.MIN_DIFFICULTY
    assert engine.clamp_difficulty(None) == engine.INITIAL_DIFFICULTY


def test_correct_answer_scores_and_streaks():
    score = engine.Score()
    question = question_of(["1C 1H 2N", "1D 1S"], answer_candidate="1C 1H 2N")

    outcome, last_points = engine.answer(
        score=score,
        question=question,
        candidate="1C 1H 2N",
        percent_left=100,
        ladder_mode=True,
        target_on=False,
        target_pct=70,
        last_correct_points=0,
    )

    assert outcome.correct
    assert score.streak == 1
    assert score.questions_correct == 1
    assert score.questions_attempted == 1
    assert score.total_points == last_points > 0
    assert [t.text for t in outcome.toasts][:2] == [
        "Correct!",
        f"+{engine.points(question, 1, 100).from_candidate_lengths}!",
    ]
    # the running total shown alongside each toast ends at the final score
    assert [t.points_after for t in outcome.toasts if t.points_after is not None][-1] == score.total_points


def test_wrong_answer_resets_streak_and_charges_ladder_mode():
    score = engine.Score(total_points=100, streak=4)
    question = question_of(["1C", "1D"], answer_candidate="1D")

    outcome, last_points = engine.answer(
        score=score,
        question=question,
        candidate="1C",
        percent_left=50,
        ladder_mode=True,
        target_on=False,
        target_pct=70,
        last_correct_points=30,
    )

    assert not outcome.correct
    assert score.streak == 0
    assert score.total_points == 70  # 100 - the last correct answer's worth
    assert last_points == 30  # unchanged: it is what the *next* wrong answer costs
    texts = [t.text for t in outcome.toasts]
    assert "Not quite" in texts
    assert "Ladder mode: -30 points" in texts
    # the answer itself is revealed in the card, not read out in a toast the player waits behind
    assert not any(text.startswith("Answer:") for text in texts)
    assert sum(t.pause for t in outcome.toasts) < 2.0


def test_no_ladder_charge_when_score_already_zero():
    score = engine.Score(total_points=0)
    question = question_of(["1C", "1D"], answer_candidate="1D")

    outcome, _ = engine.answer(
        score=score,
        question=question,
        candidate="1C",
        percent_left=0,
        ladder_mode=True,
        target_on=False,
        target_pct=70,
        last_correct_points=30,
    )

    assert score.total_points == 0
    assert not any("Ladder mode" in t.text for t in outcome.toasts)


def test_milestones_award_skips_once_each():
    score = engine.Score(total_points=engine.POINTS_GOAL - 1, questions_attempted=9, questions_correct=9)
    question = question_of(["1C 1H 2N 3C 4D", "1D"], answer_candidate="1C 1H 2N 3C 4D")

    outcome, _ = engine.answer(
        score=score,
        question=question,
        candidate="1C 1H 2N 3C 4D",
        percent_left=100,
        ladder_mode=False,
        target_on=False,
        target_pct=70,
        last_correct_points=0,
    )

    # crossing the goal collects every milestone still outstanding
    assert outcome.awarded_skips == len(engine.SCORE_MILESTONES)
    assert score.available_milestones == []
    assert outcome.completed


def test_target_percentage_gates_completion():
    # 1 of 2 correct so far = 50%, below a 70% target
    score = engine.Score(total_points=engine.POINTS_GOAL, questions_attempted=2, questions_correct=1)
    question = question_of(["1C", "1D"], answer_candidate="1C")

    outcome, _ = engine.answer(
        score=score,
        question=question,
        candidate="1C",
        percent_left=0,
        ladder_mode=False,
        target_on=True,
        target_pct=70,
        last_correct_points=0,
    )

    assert not outcome.completed
    assert any("target score 70%" in t.text for t in outcome.toasts)
