package bidfilter

import "strings"

// Topic is a named bundle of patterns; an auction matches the topic if it matches any one
// of them.
//
// The python reads these from a per-variant toml beside `apps/quiz/bidfilter.py`
// (`topics_file_for`, whole-file replacement, no merging). Here they arrive with the
// exported corpus, already filtered to the bml system they apply to and already in file
// order -- which is the order the picker renders them in.
type Topic struct {
	Name        string
	Patterns    []string
	Description string
}

// Topics is a variant's topic list, in file order, with the parsed patterns alongside.
// Parsing happens once at load: a topic whose patterns do not parse is dropped rather than
// breaking the whole list, exactly as `load_topics` does.
type Topics struct {
	List []Topic
	// parsed patterns per topic, index-aligned with List
	parsed [][]Pattern
	// normalised name -> index in List, for name resolution
	byNorm map[string]int
	// the normalised names in file order, so a fuzzy match scans deterministically
	normOrder []string
}

// NewTopics parses and indexes a variant's topics. Topics whose patterns do not parse are
// skipped.
func NewTopics(list []Topic) *Topics {
	t := &Topics{byNorm: map[string]int{}}
	for _, topic := range list {
		if len(topic.Patterns) == 0 {
			continue
		}
		patterns := make([]Pattern, 0, len(topic.Patterns))
		ok := true
		for _, p := range topic.Patterns {
			parsed, err := ParsePattern(p)
			if err != nil {
				ok = false
				break
			}
			patterns = append(patterns, parsed)
		}
		if !ok {
			continue
		}
		norm := normName(topic.Name)
		if _, seen := t.byNorm[norm]; !seen {
			t.normOrder = append(t.normOrder, norm)
		}
		t.byNorm[norm] = len(t.List)
		t.List = append(t.List, topic)
		t.parsed = append(t.parsed, patterns)
	}
	return t
}

// Len is how many topics this variant offers.
func (t *Topics) Len() int {
	if t == nil {
		return 0
	}
	return len(t.List)
}

// normName folds a topic name for comparison the same way user input is normalised, so a
// name containing a dash still matches what the user typed.
func normName(name string) string {
	return strings.ToLower(NormalizeFilterText(name))
}

// MatchName resolves free-form text to a single topic index, or -1.
//
// Tried in order, each ignoring case and superfluous whitespace: exact name, then (unless
// fuzzy is off) unique prefix, then unique substring. Ambiguous input resolves to -1 so
// the caller can fall back to treating it as a bid pattern.
func (t *Topics) MatchName(text string, fuzzy bool) int {
	if t == nil {
		return -1
	}
	target := normName(text)
	if target == "" {
		return -1
	}
	if index, ok := t.byNorm[target]; ok {
		return index
	}
	if !fuzzy {
		return -1
	}
	for _, test := range []func(string, string) bool{strings.HasPrefix, strings.Contains} {
		hit, count := -1, 0
		for _, norm := range t.normOrder {
			if test(norm, target) {
				hit, count = t.byNorm[norm], count+1
			}
		}
		if count == 1 {
			return hit
		}
	}
	return -1
}

// ParsedFilter is the result of interpreting a filter string.
//
// Patterns is the flat OR list actually matched against; Entries records what each
// comma-separated entry resolved to, and CanonicalText is the input rewritten with
// resolved topic names (what the input box should show after the user commits).
type ParsedFilter struct {
	Patterns      []Pattern
	Entries       []string
	TopicNames    []string
	CanonicalText string
	Errors        []string
}

// SplitEntries splits normalised filter text on commas into non-empty entries.
func SplitEntries(text string) []string {
	var out []string
	for _, e := range strings.Split(NormalizeFilterText(text), ",") {
		if e = strings.TrimSpace(e); e != "" {
			out = append(out, e)
		}
	}
	return out
}

// ParseFilter interprets a whole filter string: `topic name, 1D-1M, 1H-(X)`.
//
// Each entry is resolved in this order: an exact topic name, then a bid pattern, then a
// fuzzy topic name (unique prefix or substring -- this is what makes typing part of a
// topic and pressing Enter select it). Patterns are tried before the fuzzy step so a valid
// pattern is never hijacked by a topic that happens to contain it in its name.
//
// Unresolvable entries land in Errors and are skipped; the remaining entries still filter,
// so one typo does not discard the rest.
func ParseFilter(text string, topics *Topics) ParsedFilter {
	entries := SplitEntries(text)
	out := ParsedFilter{Entries: entries}
	var canonical []string
	for _, entry := range entries {
		index := topics.MatchName(entry, false)
		if index < 0 {
			if pattern, err := ParsePattern(entry); err == nil {
				out.Patterns = append(out.Patterns, pattern)
				canonical = append(canonical, CanonicalPatternText(entry))
				continue
			}
			index = topics.MatchName(entry, true) // fuzzy fallback
		}
		if index < 0 {
			out.Errors = append(out.Errors, entry)
			continue
		}
		out.Patterns = append(out.Patterns, topics.parsed[index]...)
		canonical = append(canonical, topics.List[index].Name)
		out.TopicNames = append(out.TopicNames, topics.List[index].Name)
	}
	out.CanonicalText = strings.Join(canonical, ", ")
	return out
}
