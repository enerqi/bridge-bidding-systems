//! The quiz rules: question generation, scoring, the time bonus, milestone skip awards, completion.
//!
//! No HTTP, no HTML, no signals -- this is the state machine the routes drive, ported from
//! `apps/datastar-quiz/engine.py` (which is itself a port of the panel app's `points` /
//! `on_answer_click`). Keeping it separate is what lets it be benchmarked with `cargo bench` and
//! compared against the python microbenchmarks with no server in the way.
//!
//! Scoring applies the whole state change at once and *returns* the instalments as [`Toast`]s: the
//! SSE handler replays them with the same delays, but a mid-stream reload sees final state rather
//! than a half-scored session.

use std::fmt::Write as _;

use rand::RngExt;

use crate::corpus::Auction;

pub const INITIAL_DIFFICULTY: u8 = 5;
pub const MIN_DIFFICULTY: u8 = 4;
pub const MAX_DIFFICULTY: u8 = 8;

pub const POINTS_GOAL: i64 = 1000;
pub const INITIAL_SKIPS: i64 = 3;

/// The fractions of the goal that each pay for one skip.
pub const SCORE_MILESTONES: [f64; 6] = [0.1, 0.25, 0.45, 0.65, 0.8, 1.0];

/// Seconds allowed per question, by difficulty (the panel's `reset_time_bonus_by_difficulty`).
fn seconds_per_level(difficulty: u8) -> u8 {
    match difficulty {
        4 => 8,
        5 => 7,
        6 => 6,
        7 => 5,
        8 => 4,
        _ => 4,
    }
}

/// The allowance for one question.
pub fn seconds_for_difficulty(difficulty: u8) -> f64 {
    f64::from(difficulty) * f64::from(seconds_per_level(difficulty))
}

/// python's `round()` on a float: half to EVEN, not half away from zero.
///
/// Used everywhere the python rounds, because the two disagree at every .5 -- and the percentages
/// here land on one often enough for it to show (a 50% time bonus on an even candidate count, the
/// gauge at exactly 12.5%).
pub fn py_round(value: f64) -> i64 {
    value.round_ties_even() as i64
}

/// The time bonus percentage, as the panel's `TimeBonus` progress bar computed it.
pub fn percent_time_left(elapsed: f64, allowed: f64) -> i64 {
    if allowed <= 0.0 {
        return 0;
    }
    py_round((allowed - elapsed).max(0.0) / allowed * 100.0)
}

/// Turn a signal value from the browser into a difficulty. Anything unusable is the default.
///
/// The shapes are what a datastar signal payload can carry: a number, a string, a bool, or
/// something else entirely. The python accepts int/float/str (and bool, which is an int there),
/// truncates toward zero, and falls back on anything it cannot read; this does the same.
pub fn clamp_difficulty(value: Option<&serde_json::Value>) -> u8 {
    let Some(value) = value else {
        return INITIAL_DIFFICULTY;
    };
    let raw: i64 = match value {
        serde_json::Value::Number(number) => match number.as_f64() {
            // truncates toward zero, as python's int()
            Some(float) => float as i64,
            None => return INITIAL_DIFFICULTY,
        },
        serde_json::Value::String(text) => match text.trim().parse::<i64>() {
            Ok(parsed) => parsed,
            Err(_) => return INITIAL_DIFFICULTY,
        },
        serde_json::Value::Bool(flag) => i64::from(*flag),
        _ => return INITIAL_DIFFICULTY,
    };
    raw.clamp(i64::from(MIN_DIFFICULTY), i64::from(MAX_DIFFICULTY)) as u8
}

// --- questions --------------------------------------------------------------

/// Which way round a question is asked.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ChoiceType {
    /// several auctions, one description -- pick the auction it describes
    Auctions,
    /// one auction, several descriptions -- pick the one that fits
    Descriptions,
}

/// One question as the browser will see it.
#[derive(Clone, Debug, Default)]
pub struct Question {
    pub candidates: Vec<String>,
    pub answer: String,
    pub answer_candidate: String,
    pub choice_type: Option<ChoiceType>,
}

impl Question {
    /// Where the right answer sits among the candidates.
    pub fn answer_index(&self) -> Option<usize> {
        self.candidates
            .iter()
            .position(|candidate| *candidate == self.answer_candidate)
    }
}

/// `quiz.prettify_description`: trim, and spell the suit shorthand out. The remaining
/// `!x`-to-glyph work is presentation and happens in the renderer.
fn prettify_description(text: &str) -> String {
    let trimmed = text.trim();
    if !trimmed.contains('!') {
        return trimmed.to_owned();
    }
    let mut out = String::with_capacity(trimmed.len());
    let mut rest = trimmed;
    while let Some(index) = rest.find('!') {
        out.push_str(&rest[..index]);
        let tail = &rest[index..];
        let replacement = match tail.as_bytes().get(1) {
            Some(b'c') => Some('C'),
            Some(b'd') => Some('D'),
            Some(b'h') => Some('H'),
            Some(b's') => Some('S'),
            _ => None,
        };
        match replacement {
            Some(letter) => {
                out.push(letter);
                rest = &tail[2..];
            }
            None => {
                out.push('!');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// How the parts of one auction are joined for display -- the same ` --> ` the panel app used,
/// which the renderer then turns into a glyph.
pub const AUCTION_SEPARATOR: &str = " --> ";

/// Bounds the "keep drawing until the descriptions are distinct" loop.
///
/// The python spins forever if a working set holds fewer distinct non-blank descriptions than the
/// question needs candidates, and it cannot happen in practice: a filter selecting fewer than
/// [`MAX_DIFFICULTY`] auctions is rejected as `too_few` and the whole system is used instead. A task
/// that never returns is a worse failure than a repeated candidate, so the loop gives up rather
/// than hanging -- on any corpus where the python terminates, this bound is never reached.
const MAX_DRAWS: usize = 10_000;

/// Draw one question from a working set: `quiz.generate_question`, with the choice type picked at
/// random as `random_multi_choice_type` does.
///
/// `working_set` is INDICES into `auctions`: an unfiltered session points at every one, and a
/// filtered session shares the memo's `Arc<[u32]>` of hits. Either way nothing is copied to draw a
/// question.
pub fn new_question(auctions: &[Auction], working_set: &[u32], difficulty: u8) -> Question {
    let mut rng = rand::rng();
    let choice_type = if rng.random_bool(0.5) {
        ChoiceType::Auctions
    } else {
        ChoiceType::Descriptions
    };
    new_question_of_type(auctions, working_set, difficulty, choice_type)
}

/// [`new_question`] with the choice type named, for tests.
pub fn new_question_of_type(
    auctions: &[Auction],
    working_set: &[u32],
    difficulty: u8,
    choice_type: ChoiceType,
) -> Question {
    let count = usize::from(difficulty);
    let mut question = Question {
        choice_type: Some(choice_type),
        candidates: Vec::with_capacity(count),
        ..Default::default()
    };
    if working_set.is_empty() {
        return question;
    }
    let mut rng = rand::rng();
    let answer_index = rng.random_range(0..count);
    let mut seen: Vec<String> = Vec::with_capacity(count);

    for index in 0..count {
        let mut description = String::new();
        let mut auction = String::new();
        for _ in 0..MAX_DRAWS {
            let picked = &auctions[working_set[rng.random_range(0..working_set.len())] as usize];
            let pretty = prettify_description(&picked.description);
            // some auction sequences, some preludes do not have descriptions
            if !pretty.trim().is_empty() && !seen.contains(&pretty) {
                auction = picked.sequence.join(AUCTION_SEPARATOR);
                description = pretty;
                break;
            }
        }
        if description.is_empty() {
            break;
        }
        seen.push(description.clone());

        match choice_type {
            ChoiceType::Auctions => {
                if index == answer_index {
                    question.answer = description;
                    question.answer_candidate = auction.clone();
                }
                question.candidates.push(auction);
            }
            ChoiceType::Descriptions => {
                if index == answer_index {
                    question.answer = auction;
                    question.answer_candidate = description.clone();
                }
                question.candidates.push(description);
            }
        }
    }
    question
}

// --- scoring ----------------------------------------------------------------

/// One answer's score, broken into the instalments the toasts reveal.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Points {
    pub from_candidate_lengths: i64,
    pub from_streak_bonus: i64,
    pub from_time_bonus: i64,
}

impl Points {
    pub fn total(&self) -> i64 {
        self.from_candidate_lengths + self.from_streak_bonus + self.from_time_bonus
    }
}

/// The verbatim port of `quiz_app.points` -- longer auctions are worth more, with a streak
/// multiplier and a time multiplier on top.
pub fn score_points(question: &Question, streak: i64, percent_left: i64) -> Points {
    let from_candidate_lengths: i64 = question
        .candidates
        .iter()
        .map(|candidate| candidate.replace("-->", "").split_whitespace().count() as i64)
        .sum();
    let from_streak_bonus = if streak > 1 {
        let percent_bonus = (streak as f64 * 10.0 / 100.0).min(1.0);
        py_round(from_candidate_lengths as f64 * percent_bonus)
    } else {
        0
    };
    let from_time_bonus = if percent_left > 0 {
        py_round(from_candidate_lengths as f64 * (percent_left as f64 / 100.0))
    } else {
        0
    };
    Points {
        from_candidate_lengths,
        from_streak_bonus,
        from_time_bonus,
    }
}

/// One notification, and how long the stream should pause after showing it.
///
/// `kind` matches the panel notification methods (success / info / warning) so the CSS can keep the
/// same colour language.
#[derive(Clone, Debug, Default)]
pub struct Toast {
    pub kind: &'static str,
    pub text: String,
    pub pause: f64,
    /// The running points total *as at this toast*. The state change is applied in one go, but the
    /// panel app revealed the points in instalments, so each toast carries the number to show.
    pub points_after: Option<i64>,
    /// This beat is a milestone paying for a skip. A flag rather than a text match in the renderer:
    /// the words are presentation and have been reworded once already, and "+1 SKIP!" appearing in
    /// the stream handler would make an unrelated copy edit silently drop the gauge sweep and the
    /// sound that go with it.
    pub awards_skip: bool,
}

/// The outcome of scoring one answer.
#[derive(Clone, Debug, Default)]
pub struct Answered {
    pub correct: bool,
    pub toasts: Vec<Toast>,
    pub completed: bool,
    pub awarded_skips: i64,
}

/// The part of a session the score panel renders.
#[derive(Clone, Debug)]
pub struct Score {
    pub questions_correct: i64,
    pub questions_attempted: i64,
    pub streak: i64,
    pub total_points: i64,
    /// The milestones not yet collected, highest first -- popped from the back as the points pass
    /// them, exactly as the python's reversed list is.
    pub available_milestones: Vec<f64>,
}

impl Default for Score {
    fn default() -> Self {
        let mut score = Score {
            questions_correct: 0,
            questions_attempted: 0,
            streak: 0,
            total_points: 0,
            available_milestones: Vec::new(),
        };
        score.reset();
        score
    }
}

impl Score {
    /// The proportion of attempts that were right.
    pub fn percentage(&self) -> i64 {
        if self.questions_attempted > 0 {
            py_round(self.questions_correct as f64 / self.questions_attempted as f64 * 100.0)
        } else {
            0
        }
    }

    /// Return the ledger to the start of a quiz.
    pub fn reset(&mut self) {
        self.questions_correct = 0;
        self.questions_attempted = 0;
        self.streak = 0;
        self.total_points = 0;
        self.available_milestones.clear();
        self.available_milestones
            .extend(SCORE_MILESTONES.iter().rev());
    }
}

/// Everything scoring one answer needs beyond the ledger.
pub struct AnswerInput<'a> {
    pub question: &'a Question,
    pub candidate: &'a str,
    pub percent_left: i64,
    pub ladder_mode: bool,
    pub target_on: bool,
    pub target_pct: i64,
    pub last_correct_points: i64,
    /// A parameter rather than the module constant so the debug panel can shorten a quiz without a
    /// global mutation -- the goal decides both completion and where the skip milestones fall, and
    /// two sessions in one process may disagree.
    pub points_goal: i64,
}

/// Score one answer. Mutates `score` and returns the toast script plus the new "last correct
/// points" (what a wrong answer costs in ladder mode).
///
/// A wrong answer's toasts are deliberately brief: the answer itself is revealed in place in the
/// question card, not spelled out in a notification the player must wait behind.
pub fn answer(score: &mut Score, input: AnswerInput<'_>) -> (Answered, i64) {
    let correct = input.candidate == input.question.answer_candidate;
    let mut toasts = Vec::new();

    if !correct {
        score.streak = 0;
        score.questions_attempted += 1;
        let score_was_non_zero = score.total_points > 0;
        if input.ladder_mode {
            score.total_points = (score.total_points - input.last_correct_points).max(0);
        }
        toasts.push(Toast {
            kind: "warning",
            text: "Not quite".into(),
            pause: 0.6,
            ..Default::default()
        });
        if input.ladder_mode && input.last_correct_points > 0 && score_was_non_zero {
            toasts.push(Toast {
                kind: "warning",
                text: format!("Ladder mode: -{} points", input.last_correct_points),
                pause: 0.6,
                points_after: Some(score.total_points),
                awards_skip: false,
            });
        }
        return (
            Answered {
                correct: false,
                toasts,
                completed: false,
                awarded_skips: 0,
            },
            input.last_correct_points,
        );
    }

    score.streak += 1;
    let increase = score_points(input.question, score.streak, input.percent_left);

    toasts.push(Toast {
        kind: "success",
        text: "Correct!".into(),
        pause: 0.5,
        ..Default::default()
    });
    score.total_points += increase.from_candidate_lengths;
    let mut text = String::with_capacity(8);
    let _ = write!(text, "+{}!", increase.from_candidate_lengths);
    toasts.push(Toast {
        kind: "info",
        text,
        pause: 0.5,
        points_after: Some(score.total_points),
        awards_skip: false,
    });
    if increase.from_streak_bonus > 0 {
        score.total_points += increase.from_streak_bonus;
        toasts.push(Toast {
            kind: "info",
            text: format!(
                "Streak {}, Bonus +{}",
                score.streak, increase.from_streak_bonus
            ),
            pause: 0.5,
            points_after: Some(score.total_points),
            awards_skip: false,
        });
    }
    if increase.from_time_bonus > 0 {
        score.total_points += increase.from_time_bonus;
        toasts.push(Toast {
            kind: "info",
            text: format!("Time Bonus +{}", increase.from_time_bonus),
            pause: 0.5,
            points_after: Some(score.total_points),
            awards_skip: false,
        });
    }

    score.questions_attempted += 1;
    score.questions_correct += 1;

    let mut awarded_skips = 0;
    while let Some(last) = score.available_milestones.last().copied() {
        if last * input.points_goal as f64 > score.total_points as f64 {
            break;
        }
        score.available_milestones.pop();
        awarded_skips += 1;
        toasts.push(Toast {
            kind: "success",
            text: "+1 SKIP!".into(),
            pause: 0.5,
            points_after: None,
            awards_skip: true,
        });
    }

    let mut completed = false;
    if score.total_points >= input.points_goal {
        let percentage = score.percentage();
        if !input.target_on || percentage >= input.target_pct {
            completed = true;
        } else {
            toasts.push(Toast {
                kind: "warning",
                text: format!(
                    "Current score {percentage}%, target score {}%",
                    input.target_pct
                ),
                pause: 0.5,
                ..Default::default()
            });
        }
    }

    // the panel handler paused a further second before moving on when the answer was right
    toasts.push(Toast {
        kind: "info",
        text: String::new(),
        pause: 1.0,
        ..Default::default()
    });

    (
        Answered {
            correct: true,
            toasts,
            completed,
            awarded_skips,
        },
        increase.total(),
    )
}
