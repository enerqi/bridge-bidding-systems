package render

import (
	"html/template"
	"regexp"
	"strings"
	"sync"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
)

// --- datastar attribute-key naming ------------------------------------------
//
// HTML lowercases attribute names, so `data-bind:filterText` reaches datastar as
// `data-bind:filtertext` and binds a *different* signal from the `filterText` the server
// seeded. Datastar's answer is to write attribute keys in kebab-case and convert: `bind.ts`
// runs the key through `camel`, which is `kebab` then de-dashing. `kebab` also splits
// letter/digit boundaries, so `1c_opening` becomes the signal `1COpening` -- which is why a
// slug cannot simply be assumed to survive the trip. These mirror that transform, so the
// markup and the server agree on the name.
//
// There are tests for it in `apps/datastar-quiz/tests/test_signal_names.py`, and the load
// harness carries its own copy (`apps/dsquiz-perf/common/datastar.py`) -- three
// implementations of one five-line transform, because getting it wrong is silent.

var (
	kebabUpperRunRE = regexp.MustCompile(`([A-Z]+)([A-Z][a-z])`)
	kebabLowerUpRE  = regexp.MustCompile(`([a-z0-9])([A-Z])`)
	kebabAlphaNumRE = regexp.MustCompile(`(?i)([a-z])([0-9]+)`)
	kebabNumAlphaRE = regexp.MustCompile(`(?i)([0-9]+)([a-z])`)
	kebabSpaceRE    = regexp.MustCompile(`[\s_]+`)
	camelDashRE     = regexp.MustCompile(`-(.)`)
	slugStripRE     = regexp.MustCompile(`[^0-9A-Za-z\s_-]+`)
	slugDashRunRE   = regexp.MustCompile(`-{2,}`)
)

// DatastarKebab is datastar's `kebab`, which is what an attribute key goes through.
func DatastarKebab(text string) string {
	out := kebabUpperRunRE.ReplaceAllString(text, "${1}-${2}")
	out = kebabLowerUpRE.ReplaceAllString(out, "${1}-${2}")
	out = kebabAlphaNumRE.ReplaceAllString(out, "${1}-${2}")
	out = kebabNumAlphaRE.ReplaceAllString(out, "${1}-${2}")
	out = kebabSpaceRE.ReplaceAllString(out, "-")
	return strings.ToLower(out)
}

// DatastarCamel is the name a kebab attribute key actually writes into the signal store.
func DatastarCamel(text string) string {
	return camelDashRE.ReplaceAllStringFunc(DatastarKebab(text), func(match string) string {
		return strings.ToUpper(match[1:])
	})
}

// TopicSlug is the attribute form of a topic name: `data-bind:topics.<slug>`.
func TopicSlug(name string) string {
	slug := DatastarKebab(slugStripRE.ReplaceAllString(name, " "))
	slug = strings.Trim(slugDashRunRE.ReplaceAllString(slug, "-"), "-")
	if slug == "" {
		return "topic"
	}
	return slug
}

// TopicSignalKey is the name that same binding writes into the signal store.
func TopicSignalKey(name string) string { return DatastarCamel(TopicSlug(name)) }

// TopicChoices are the topics picker's rows: built once per variant, not once per render.
//
// The python memoises these four functions because the yappi profile of a 60-user minute
// counted 37,868 calls to `datastar_kebab`, 25,236 to `topic_slug` and 12,632 to
// `topic_signal_key` -- five regex passes each, recomputed on every render, for values that
// are pure functions of a topic name that never changes within a process. The same fix
// applies here, one level up: the whole derived row set is computed once per system.
func TopicChoices(system *corpus.System) []TopicChoice {
	if system == nil {
		return nil
	}
	choicesMu.RLock()
	cached, ok := choices[system.Variant.Key]
	choicesMu.RUnlock()
	if ok {
		return cached
	}
	built := make([]TopicChoice, 0, system.Topics.Len())
	for _, topic := range system.Topics.List {
		slug := TopicSlug(topic.Name)
		built = append(built, TopicChoice{
			Name:        topic.Name,
			Slug:        slug,
			Key:         TopicSignalKey(topic.Name),
			Description: topic.Description,
			Bind:        template.HTMLAttr("data-bind:topics." + slug),
		})
	}
	choicesMu.Lock()
	choices[system.Variant.Key] = built
	choicesMu.Unlock()
	return built
}

var (
	choicesMu sync.RWMutex
	choices   = map[string][]TopicChoice{}
)
