// Package corpus is the `.bml` corpus and the bidding-tree filter over it.
//
// The python app imports `apps/quiz/quiz.py` and parses the notes itself. This port does
// not: writing a third BML parser (after the python one and the Odin `bridge-markup`) is
// weeks of work and is not what the comparison is about. Instead the parsed corpus is
// EXPORTED from the python app by `apps/datastar-quiz/tools/export_corpus.py` and embedded
// here, so both implementations provably draw questions from the same auctions.
//
// What is NOT exported is the filter: the matcher is ported (see internal/bidfilter),
// because that is where the CPU goes and a comparison that skips it is not a comparison.
package corpus

import (
	"embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/bidfilter"
)

// The exported corpus, checked in and regenerated with `just export-corpus`. Embedded
// rather than read from disk so the binary is the deployment: the python app resolves its
// corpus from the script's own location and chdirs to parse it, and neither trick has an
// equivalent that survives `go build` into an arbitrary directory.
//
//go:embed data/*.json
var embedded embed.FS

// Variant is a quiz flavour: which bml system it draws on, and how it is presented.
type Variant struct {
	Key            string
	Title          string
	BMLFile        string
	SystemNotesURL string
}

// Auction is one bidding sequence and what it means -- exactly the public fields of the
// python `quiz.BidSequenceMeaning`.
type Auction struct {
	Sequence    []string `json:"sequence"`
	Description string   `json:"description"`
}

type exportedTopic struct {
	Name        string   `json:"name"`
	Patterns    []string `json:"patterns"`
	Description string   `json:"description"`
}

type exported struct {
	Variant        string          `json:"variant"`
	Title          string          `json:"title"`
	BMLFile        string          `json:"bml_file"`
	SystemNotesURL string          `json:"system_notes_url"`
	Auctions       []Auction       `json:"auctions"`
	Topics         []exportedTopic `json:"topics"`
}

// System is one loaded variant: its auctions, the same auctions pre-parsed for filtering,
// and its topics.
type System struct {
	Variant  Variant
	Auctions []Auction
	// Canonical parsed bids per auction, index-aligned with Auctions. Filtering is then
	// prefix comparison, which is what makes validating on every keystroke cheap enough
	// to do at all.
	prepared []bidfilter.Variants
	Topics   *bidfilter.Topics

	filterCache *filterCache
}

// variantOrder is the order the variants are declared in, which is the order prewarm
// walks them. `squad` is the default -- `?swedish` picks the other.
var variantOrder = []string{"squad", "swedish"}

var (
	loadOnce sync.Once
	loadErr  error
	systems  = map[string]*System{}
)

// DefaultVariantKey is what a bare URL means.
const DefaultVariantKey = "squad"

// Load parses every variant's corpus and pre-parses its auctions for filtering.
//
// Called at startup, not on whoever asks first. The python app learned this the expensive
// way: the yappi profile caught `load_bid_tables` (1.3s) plus `prepare_sequence_bids`
// (4.3s) landing inside a REQUEST, on the first visitor to open the second system. Here
// the parse is already done -- only the preparation is left -- but it is still seconds of
// work that belongs to the process rather than to a player.
//
// Safe to call twice; the second call is a no-op.
func Load() error {
	loadOnce.Do(func() { loadErr = load() })
	return loadErr
}

func load() error {
	for _, key := range variantOrder {
		payload, err := readVariant(key)
		if err != nil {
			return err
		}
		topics := make([]bidfilter.Topic, 0, len(payload.Topics))
		for _, t := range payload.Topics {
			topics = append(topics, bidfilter.Topic{Name: t.Name, Patterns: t.Patterns, Description: t.Description})
		}
		sequences := make([][]string, len(payload.Auctions))
		for i, a := range payload.Auctions {
			sequences[i] = a.Sequence
		}
		systems[key] = &System{
			Variant: Variant{
				Key:            payload.Variant,
				Title:          payload.Title,
				BMLFile:        payload.BMLFile,
				SystemNotesURL: payload.SystemNotesURL,
			},
			Auctions:    payload.Auctions,
			prepared:    bidfilter.PrepareSequenceBids(sequences),
			Topics:      bidfilter.NewTopics(topics),
			filterCache: newFilterCache(FilterCacheSize),
		}
	}
	return nil
}

// CorpusDirEnv names a directory of `<variant>.json` files to load INSTEAD of the embedded
// copy. For regenerating and diffing without a rebuild; unset in any normal run.
const CorpusDirEnv = "DSQUIZ_CORPUS_DIR"

func readVariant(key string) (*exported, error) {
	name := key + ".json"
	var body []byte
	var err error
	if dir := os.Getenv(CorpusDirEnv); dir != "" {
		body, err = os.ReadFile(filepath.Join(dir, name))
	} else {
		body, err = embedded.ReadFile("data/" + name)
	}
	if err != nil {
		return nil, fmt.Errorf("corpus %s: %w", name, err)
	}
	payload := &exported{}
	if err := json.Unmarshal(body, payload); err != nil {
		return nil, fmt.Errorf("corpus %s: %w", name, err)
	}
	if len(payload.Auctions) == 0 {
		return nil, fmt.Errorf("corpus %s: no auctions", name)
	}
	return payload, nil
}

// Get is the loaded system for a variant key, or nil for a key this build does not have.
// Tolerant on purpose: the key may have come from a browser's stored "which system was I
// on", and a renamed variant should hand the player the default rather than an error.
func Get(key string) *System {
	return systems[key]
}

// Default is the system a bare URL means.
func Default() *System { return systems[DefaultVariantKey] }

// Keys are the variant keys, in declaration order.
func Keys() []string { return variantOrder }

// RequestedVariant is the variant a query string explicitly asks for, or nil if it names
// none.
//
// Distinct from VariantForQuery on purpose: an unrelated query (`?debug`) must not be read
// as "switch me back to the default", or a swedish session would flip to squad on the next
// odd link.
func RequestedVariant(query string) *System {
	lowered := strings.ToLower(query)
	for _, key := range []string{"swedish", "squad"} {
		if strings.Contains(lowered, key) {
			return systems[key]
		}
	}
	return nil
}

// VariantSwitchForQuery is what an *existing* session should switch to, or nil to keep the
// variant it has.
//
// Three cases, and the middle one is the whole point:
//
//   - names a variant (`?swedish`, `?squad`) -> that variant, as RequestedVariant;
//   - **no query at all** -> the default. The bare URL is the one people share and link
//     to, so it has to mean "take me home"; without this a `?swedish` session is stuck
//     forever, because nothing in the UI says the way back is a query string nobody
//     remembers;
//   - a non-empty query naming no variant (`?debug`) -> nil, keep what the session has.
func VariantSwitchForQuery(query string) *System {
	if query == "" {
		return Default()
	}
	return RequestedVariant(query)
}
