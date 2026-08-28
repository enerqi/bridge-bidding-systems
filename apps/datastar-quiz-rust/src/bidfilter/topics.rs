//! Topics -- pre-composed bundles of patterns -- and whole-filter parsing.

use super::pattern::{self, Pattern, normalize_filter_text, parse_pattern, split_entries};

/// A named bundle of patterns; an auction matches the topic if it matches any one of them.
///
/// The python reads these from a per-variant toml beside `apps/quiz/bidfilter.py` (whole-file
/// replacement, no merging). Here they arrive with the exported corpus, already filtered to the bml
/// system they apply to and already in file order -- which is the order the picker renders them in.
#[derive(Clone, Debug)]
pub struct Topic {
    pub name: String,
    pub patterns: Vec<String>,
    pub description: String,
}

/// A variant's topic list, in file order, with the parsed patterns alongside.
///
/// Parsing happens once at load: a topic whose patterns do not parse is dropped rather than
/// breaking the whole list, exactly as the python's `load_topics` does.
#[derive(Debug, Default)]
pub struct Topics {
    pub list: Vec<Topic>,
    /// parsed patterns per topic, index-aligned with `list`
    parsed: Vec<Vec<Pattern>>,
    /// normalised name per topic, index-aligned -- searched in file order, so a fuzzy match is
    /// deterministic
    normalised: Vec<String>,
}

impl Topics {
    pub fn new(list: Vec<Topic>) -> Topics {
        let mut topics = Topics::default();
        for topic in list {
            if topic.patterns.is_empty() {
                continue;
            }
            let Ok(parsed) = topic
                .patterns
                .iter()
                .map(|p| parse_pattern(p))
                .collect::<Result<Vec<_>, _>>()
            else {
                continue;
            };
            topics.normalised.push(norm_name(&topic.name));
            topics.list.push(topic);
            topics.parsed.push(parsed);
        }
        topics
    }

    pub fn len(&self) -> usize {
        self.list.len()
    }

    pub fn is_empty(&self) -> bool {
        self.list.is_empty()
    }

    /// Resolve free-form text to a single topic index.
    ///
    /// Tried in order, each ignoring case and superfluous whitespace: exact name, then (unless
    /// `fuzzy` is off) unique prefix, then unique substring. Ambiguous input resolves to `None` so
    /// the caller can fall back to treating it as a bid pattern.
    pub fn match_name(&self, text: &str, fuzzy: bool) -> Option<usize> {
        let target = norm_name(text);
        if target.is_empty() {
            return None;
        }
        if let Some(index) = self.normalised.iter().position(|name| *name == target) {
            return Some(index);
        }
        if !fuzzy {
            return None;
        }
        // prefix first, then substring: a unique prefix is the stronger claim
        let tests: [fn(&str, &str) -> bool; 2] = [
            |name, target| name.starts_with(target),
            |name, target| name.contains(target),
        ];
        for test in tests {
            let mut hit = None;
            let mut count = 0usize;
            for (index, name) in self.normalised.iter().enumerate() {
                if test(name, &target) {
                    hit = Some(index);
                    count += 1;
                }
            }
            if count == 1 {
                return hit;
            }
        }
        None
    }
}

/// Fold a topic name for comparison the same way user input is normalised, so a name containing a
/// dash still matches what the user typed.
fn norm_name(name: &str) -> String {
    normalize_filter_text(name).to_lowercase()
}

/// The result of interpreting a filter string.
///
/// `patterns` is the flat OR list actually matched against; `entries` records what each
/// comma-separated entry resolved to, and `canonical_text` is the input rewritten with resolved
/// topic names (what the input box should show after the user commits).
#[derive(Debug, Default)]
pub struct ParsedFilter {
    pub patterns: Vec<Pattern>,
    pub entries: Vec<String>,
    pub topic_names: Vec<String>,
    pub canonical_text: String,
    pub errors: Vec<String>,
}

/// Interpret a whole filter string: `topic name, 1D-1M, 1H-(X)`.
///
/// Each entry is resolved in this order: an exact topic name, then a bid pattern, then a fuzzy
/// topic name (unique prefix or substring -- this is what makes typing part of a topic and pressing
/// Enter select it). Patterns are tried before the fuzzy step so a valid pattern is never hijacked
/// by a topic that happens to contain it in its name.
///
/// Unresolvable entries land in `errors` and are skipped; the remaining entries still filter, so
/// one typo does not discard the rest.
pub fn parse_filter(text: &str, topics: Option<&Topics>) -> ParsedFilter {
    let entries = split_entries(text);
    let mut out = ParsedFilter {
        entries,
        ..Default::default()
    };
    let mut canonical: Vec<&str> = Vec::new();
    let mut canonical_owned: Vec<String> = Vec::new();

    for entry in &out.entries {
        let mut index = topics.and_then(|t| t.match_name(entry, false));
        if index.is_none() {
            match parse_pattern(entry) {
                Ok(parsed) => {
                    out.patterns.push(parsed);
                    canonical_owned.push(pattern::canonical_pattern_text(entry));
                    continue;
                }
                Err(_) => index = topics.and_then(|t| t.match_name(entry, true)), // fuzzy fallback
            }
        }
        let Some(index) = index else {
            out.errors.push(entry.clone());
            continue;
        };
        let topics = topics.expect("an index only comes from a topic list");
        out.patterns.extend(topics.parsed[index].iter().cloned());
        canonical_owned.push(topics.list[index].name.clone());
        out.topic_names.push(topics.list[index].name.clone());
    }
    canonical.extend(canonical_owned.iter().map(String::as_str));
    out.canonical_text = canonical.join(", ");
    out
}
