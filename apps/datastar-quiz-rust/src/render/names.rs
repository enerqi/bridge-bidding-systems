//! The datastar attribute-key naming transform.
//!
//! HTML lowercases attribute names, so `data-bind:filterText` reaches datastar as
//! `data-bind:filtertext` and binds a *different* signal from the `filterText` the server seeded.
//! Datastar's answer is to write attribute keys in kebab-case and convert: `bind.ts` runs the key
//! through `camel`, which is `kebab` then de-dashing. `kebab` also splits letter/digit boundaries,
//! so `1c_opening` becomes the signal `1COpening` -- which is why a slug cannot simply be assumed to
//! survive the trip.
//!
//! These mirror that transform, so the markup and the server agree on the name. There are now FOUR
//! implementations of one five-line transform (here, the python, the Go port, and the load
//! harness's own copy), because getting it wrong is silent: the checkbox ticks and nothing happens.
//! `tests/render.rs` holds this one to a golden exported from the python.
//!
//! Written as character scans rather than five regex passes. The python memoises them because a
//! yappi profile of a 60-user minute counted 37,868 calls to `datastar_kebab` for values that never
//! change; here the whole derived row set is computed once per system instead, and the scan itself
//! allocates one string.

/// datastar's `kebab`, which is what an attribute key goes through.
pub fn datastar_kebab(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len() + 4);
    for (index, ch) in chars.iter().copied().enumerate() {
        let previous = index.checked_sub(1).map(|i| chars[i]);
        let next = chars.get(index + 1).copied();
        if let Some(previous) = previous {
            // `([A-Z]+)([A-Z][a-z])` -- an acronym running into a word
            let acronym_break = previous.is_ascii_uppercase()
                && ch.is_ascii_uppercase()
                && next.is_some_and(|n| n.is_ascii_lowercase());
            // `([a-z0-9])([A-Z])` -- ordinary camel case
            let camel_break = (previous.is_ascii_lowercase() || previous.is_ascii_digit())
                && ch.is_ascii_uppercase();
            // `([a-z])([0-9]+)` and `([0-9]+)([a-z])`, both case-insensitive -- the
            // letter/digit boundary that turns `1c-opening` into `1-c-opening`
            let digit_break = (previous.is_ascii_alphabetic() && ch.is_ascii_digit())
                || (previous.is_ascii_digit() && ch.is_ascii_alphabetic());
            if (acronym_break || camel_break || digit_break) && !out.ends_with('-') {
                out.push('-');
            }
        }
        // `[\s_]+` collapses to one dash
        if ch.is_whitespace() || ch == '_' {
            if !out.ends_with('-') {
                out.push('-');
            }
            continue;
        }
        out.extend(ch.to_lowercase());
    }
    out
}

/// The name a kebab attribute key actually writes into the signal store.
pub fn datastar_camel(text: &str) -> String {
    let kebab = datastar_kebab(text);
    let mut out = String::with_capacity(kebab.len());
    let mut upper_next = false;
    for ch in kebab.chars() {
        if ch == '-' {
            upper_next = true;
            continue;
        }
        if upper_next {
            out.extend(ch.to_uppercase());
            upper_next = false;
        } else {
            out.push(ch);
        }
    }
    out
}

/// The attribute form of a topic name: `data-bind:topics.<slug>`.
pub fn topic_slug(name: &str) -> String {
    // `[^0-9A-Za-z\s_-]+` -> a space, before the kebab pass
    let cleaned: String = name
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch.is_whitespace() || ch == '_' || ch == '-' {
                ch
            } else {
                ' '
            }
        })
        .collect();
    let kebab = datastar_kebab(&cleaned);
    // `-{2,}` -> `-`, then trim
    let mut collapsed = String::with_capacity(kebab.len());
    for ch in kebab.chars() {
        if ch == '-' && collapsed.ends_with('-') {
            continue;
        }
        collapsed.push(ch);
    }
    let trimmed = collapsed.trim_matches('-');
    if trimmed.is_empty() {
        "topic".to_owned()
    } else {
        trimmed.to_owned()
    }
}

/// The name that same binding writes into the signal store.
pub fn topic_signal_key(name: &str) -> String {
    datastar_camel(&topic_slug(name))
}
