//! The quiz rules, ported from `apps/datastar-quiz/tests/test_engine.py` by way of the Go port.
//!
//! That python file asserts its scoring against the PANEL app's own `points` function, so this is
//! the fourth implementation of one formula and the place a silent one-off would look like a
//! game-design decision rather than a bug.

use dsquiz::corpus::Corpus;
use dsquiz::engine::{
    self, AnswerInput, ChoiceType, MAX_DIFFICULTY, MIN_DIFFICULTY, POINTS_GOAL, Points, Question,
    SCORE_MILESTONES, Score,
};
use serde_json::json;

fn question_of(candidates: &[&str], answer_candidate: &str) -> Question {
    let candidates: Vec<String> = candidates.iter().map(|c| (*c).to_owned()).collect();
    let answer_candidate = if answer_candidate.is_empty() {
        candidates.first().cloned().unwrap_or_default()
    } else {
        answer_candidate.to_owned()
    };
    Question {
        candidates,
        answer: "the description".into(),
        answer_candidate,
        choice_type: Some(ChoiceType::Auctions),
    }
}

fn score_one(
    score: &mut Score,
    question: &Question,
    candidate: &str,
    input: Extra,
) -> (engine::Answered, i64) {
    engine::answer(
        score,
        AnswerInput {
            question,
            candidate,
            percent_left: input.percent_left,
            ladder_mode: input.ladder_mode,
            target_on: input.target_on,
            target_pct: 70,
            last_correct_points: input.last_correct_points,
            points_goal: POINTS_GOAL,
        },
    )
}

#[derive(Default)]
struct Extra {
    percent_left: i64,
    ladder_mode: bool,
    target_on: bool,
    last_correct_points: i64,
}

#[test]
fn seconds_for_difficulty_matches_the_panel_table() {
    for (difficulty, want) in [
        (4, 32.0),
        (5, 35.0),
        (6, 36.0),
        (7, 35.0),
        (8, 32.0),
        (9, 36.0),
    ] {
        assert_eq!(
            engine::seconds_for_difficulty(difficulty),
            want,
            "difficulty {difficulty}"
        );
    }
}

#[test]
fn percent_time_left() {
    assert_eq!(engine::percent_time_left(0.0, 10.0), 100);
    assert_eq!(engine::percent_time_left(5.0, 10.0), 50);
    assert_eq!(engine::percent_time_left(12.0, 10.0), 0); // never negative
    assert_eq!(engine::percent_time_left(1.0, 0.0), 0); // no allowance is no bonus
}

#[test]
fn clamp_difficulty() {
    let cases = [
        (json!(6), 6),
        (json!("7"), 7),
        (json!(99), MAX_DIFFICULTY),
        (json!(1), MIN_DIFFICULTY),
        (json!(null), engine::INITIAL_DIFFICULTY),
        (json!("nonsense"), engine::INITIAL_DIFFICULTY),
        (json!([]), engine::INITIAL_DIFFICULTY),
    ];
    for (value, want) in cases {
        assert_eq!(engine::clamp_difficulty(Some(&value)), want, "{value}");
    }
    assert_eq!(engine::clamp_difficulty(None), engine::INITIAL_DIFFICULTY);
}

/// The panel formula: one point per token across every candidate, +10% per streak step (capped at
/// doubling), + the time bonus as a proportion of the same base.
#[test]
fn points_are_candidate_lengths_with_two_multipliers() {
    let question = question_of(&["1C", "1H", "2N"], "");
    let base = 3;
    let cases = [
        (0, 0, 0, 0),
        (1, 0, 0, 0),  // a streak of one is not yet a bonus
        (2, 0, 1, 0),  // round(3 * 0.2) = 1
        (5, 0, 2, 0),  // round(3 * 0.5) = 2 -- half to EVEN, as python's round()
        (12, 0, 3, 0), // the multiplier caps at 1.0
        (0, 100, 0, base),
        (0, 37, 0, 1), // round(3 * 0.37) = 1
    ];
    for (streak, percent_left, streak_bonus, time_bonus) in cases {
        let want = Points {
            from_candidate_lengths: base,
            from_streak_bonus: streak_bonus,
            from_time_bonus: time_bonus,
        };
        assert_eq!(
            engine::score_points(&question, streak, percent_left),
            want,
            "streak {streak}, {percent_left}%"
        );
    }
    // the `-->` joiner is not a token
    let joined = question_of(&["1D --> 1S --> 3N", "1C"], "");
    assert_eq!(
        engine::score_points(&joined, 0, 0).from_candidate_lengths,
        4
    );
    // no candidates, no points, no panic
    assert_eq!(
        engine::score_points(&question_of(&[], ""), 5, 100).total(),
        0
    );
}

#[test]
fn a_correct_answer_scores_and_streaks() {
    let mut score = Score::default();
    let question = question_of(&["1C 1H 2N", "1D 1S"], "1C 1H 2N");
    let (outcome, last_points) = score_one(
        &mut score,
        &question,
        "1C 1H 2N",
        Extra {
            percent_left: 100,
            ladder_mode: true,
            ..Default::default()
        },
    );
    assert!(outcome.correct);
    assert_eq!(
        (
            score.streak,
            score.questions_correct,
            score.questions_attempted
        ),
        (1, 1, 1)
    );
    assert_eq!(score.total_points, last_points);
    assert!(last_points > 0);
    assert_eq!(outcome.toasts[0].text, "Correct!");
    assert!(outcome.toasts[1].text.starts_with('+'));
    // the running total shown alongside each toast ends at the final score
    let last = outcome
        .toasts
        .iter()
        .filter_map(|toast| toast.points_after)
        .next_back();
    assert_eq!(last, Some(score.total_points));
}

#[test]
fn a_wrong_answer_resets_the_streak_and_charges_ladder_mode() {
    let mut score = Score {
        total_points: 100,
        streak: 4,
        ..Score::default()
    };
    let question = question_of(&["1C", "1D"], "1D");
    let (outcome, last_points) = score_one(
        &mut score,
        &question,
        "1C",
        Extra {
            percent_left: 50,
            ladder_mode: true,
            last_correct_points: 30,
            ..Default::default()
        },
    );
    assert!(!outcome.correct);
    assert_eq!(score.streak, 0);
    assert_eq!(
        score.total_points, 70,
        "100 less the last correct answer's worth"
    );
    assert_eq!(last_points, 30, "it is what the NEXT wrong answer costs");
    let texts: Vec<&str> = outcome
        .toasts
        .iter()
        .map(|toast| toast.text.as_str())
        .collect();
    assert!(texts.contains(&"Not quite"));
    assert!(
        texts
            .iter()
            .any(|text| text.contains("Ladder mode: -30 points"))
    );
    // the answer itself is revealed in the card, not read out in a toast the player waits behind
    let pause: f64 = outcome.toasts.iter().map(|toast| toast.pause).sum();
    assert!(pause < 2.0, "a wrong answer blocks for {pause}s");
}

#[test]
fn no_ladder_charge_when_the_score_is_already_zero() {
    let mut score = Score::default();
    let question = question_of(&["1C", "1D"], "1D");
    let (outcome, _) = score_one(
        &mut score,
        &question,
        "1C",
        Extra {
            ladder_mode: true,
            last_correct_points: 30,
            ..Default::default()
        },
    );
    assert_eq!(score.total_points, 0);
    assert!(
        !outcome
            .toasts
            .iter()
            .any(|toast| toast.text.contains("Ladder mode"))
    );
}

#[test]
fn milestones_award_skips_once_each() {
    let mut score = Score {
        total_points: POINTS_GOAL - 1,
        questions_attempted: 9,
        questions_correct: 9,
        ..Score::default()
    };
    let question = question_of(&["1C 1H 2N 3C 4D", "1D"], "1C 1H 2N 3C 4D");
    let (outcome, _) = score_one(
        &mut score,
        &question,
        "1C 1H 2N 3C 4D",
        Extra {
            percent_left: 100,
            ..Default::default()
        },
    );
    // crossing the goal collects every milestone still outstanding
    assert_eq!(outcome.awarded_skips, SCORE_MILESTONES.len() as i64);
    assert!(score.available_milestones.is_empty());
    assert!(outcome.completed);
    // every skip beat is flagged, so the gauge sweep and its sound cannot be lost to a copy edit
    let flagged = outcome
        .toasts
        .iter()
        .filter(|toast| toast.awards_skip)
        .count();
    assert_eq!(flagged as i64, outcome.awarded_skips);
}

#[test]
fn the_target_percentage_gates_completion() {
    // 1 of 2 correct so far = 50%, below a 70% target
    let mut score = Score {
        total_points: POINTS_GOAL,
        questions_attempted: 2,
        questions_correct: 1,
        ..Score::default()
    };
    let question = question_of(&["1C", "1D"], "1C");
    let (outcome, _) = score_one(
        &mut score,
        &question,
        "1C",
        Extra {
            target_on: true,
            ..Default::default()
        },
    );
    assert!(!outcome.completed);
    assert!(
        outcome
            .toasts
            .iter()
            .any(|toast| toast.text.contains("target score 70%"))
    );
}

#[test]
fn a_question_draws_distinct_descriptions() {
    let corpus = Corpus::load().expect("the corpus is embedded");
    let system = corpus.default_system();
    let working: Vec<u32> = (0..system.auctions.len() as u32).collect();
    for difficulty in MIN_DIFFICULTY..=MAX_DIFFICULTY {
        let question = engine::new_question(&system.auctions, &working, difficulty);
        assert_eq!(
            question.candidates.len(),
            usize::from(difficulty),
            "difficulty {difficulty}"
        );
        assert!(
            question.answer_index().is_some(),
            "the answer is not among the candidates"
        );
        if question.choice_type == Some(ChoiceType::Descriptions) {
            let mut seen = question.candidates.clone();
            seen.sort();
            let before = seen.len();
            seen.dedup();
            assert_eq!(seen.len(), before, "a description was offered twice");
        }
    }
}
