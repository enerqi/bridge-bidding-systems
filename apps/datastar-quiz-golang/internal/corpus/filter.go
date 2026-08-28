package corpus

import (
	"container/list"
	"sync"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/bidfilter"
)

// FilterCheck is what a filter string *would* select. Asking never commits it.
type FilterCheck struct {
	Status string // "all" | "ok" | "error" | "too_few"
	Hits   []Auction
	Parsed bidfilter.ParsedFilter
}

// Usable reports whether the caller should adopt the hits rather than falling back to the
// whole system.
func (c FilterCheck) Usable() bool { return c.Status == "ok" }

// FilterCacheSize is how many distinct filters to remember.
//
// Each entry holds a slice of auctions -- and the "everything matches" branch returns the
// shared slice rather than a copy, so the real worst case is much smaller than 7,627
// entries per filter. 256 was chosen (as in the python) to be comfortably larger than the
// topic list plus the prefixes a typist produces, and small enough that it cannot become a
// memory leak: the text is user input, so an unbounded cache would be a way to grow the
// process without limit.
const FilterCacheSize = 256

type filterKey struct {
	text    string
	minHits int
}

// filterCache is an LRU over CheckFilter, which is the app's most expensive routine and is
// called per keystroke. The python measures 15.8ms for `1C` and 43ms for a topic against
// 7,627 auctions, and an 87.6% hit rate under load; both preview routes missed their
// latency targets without it.
//
// The KEY is the NORMALISED text, which costs nothing extra and is exact rather than
// approximate: ParseFilter starts by normalising, so ` 1C-1D `, `1C  --  1D` and `1C--1D`
// already produce identical results. Case is deliberately NOT folded in on top of that:
// `m` is the minors and `M` the majors, so a case-insensitive key would answer `1m` with
// the majors. `1c` and `1C` cost two entries and agree.
//
// Nothing here can go stale: every input is fixed for the life of the process (the corpus
// is embedded, the topics are loaded once), and the result is read-only -- Hits is shared
// between sessions, which is what the unfiltered path already does with the whole auction
// slice.
type filterCache struct {
	mu      sync.Mutex
	size    int
	entries map[filterKey]*list.Element
	order   *list.List // front = most recently used
	hits    uint64
	misses  uint64
}

type cacheEntry struct {
	key   filterKey
	value FilterCheck
}

func newFilterCache(size int) *filterCache {
	return &filterCache{size: size, entries: map[filterKey]*list.Element{}, order: list.New()}
}

func (c *filterCache) get(key filterKey) (FilterCheck, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	element, ok := c.entries[key]
	if !ok {
		c.misses++
		return FilterCheck{}, false
	}
	c.hits++
	c.order.MoveToFront(element)
	return element.Value.(*cacheEntry).value, true
}

func (c *filterCache) put(key filterKey, value FilterCheck) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if element, ok := c.entries[key]; ok {
		element.Value.(*cacheEntry).value = value
		c.order.MoveToFront(element)
		return
	}
	c.entries[key] = c.order.PushFront(&cacheEntry{key: key, value: value})
	for c.order.Len() > c.size {
		oldest := c.order.Back()
		c.order.Remove(oldest)
		delete(c.entries, oldest.Value.(*cacheEntry).key)
	}
}

// CacheInfo is the memo's hit/miss counts and current size, for the debug panel and for
// reporting the hit rate under load.
type CacheInfo struct {
	Hits, Misses  uint64
	Size, MaxSize int
}

// FilterCacheInfo reports this system's memo statistics.
func (s *System) FilterCacheInfo() CacheInfo {
	c := s.filterCache
	c.mu.Lock()
	defer c.mu.Unlock()
	return CacheInfo{Hits: c.hits, Misses: c.misses, Size: c.order.Len(), MaxSize: c.size}
}

// ClearFilterCache empties the memo. For tests and for a clean measurement window.
func (s *System) ClearFilterCache() {
	c := s.filterCache
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries = map[filterKey]*list.Element{}
	c.order.Init()
	c.hits, c.misses = 0, 0
}

// CheckFilter is the port of the python `corpus.check_filter`.
//
// Used both to validate as the user types and to apply on commit, so the preview can never
// disagree with the result. Statuses other than "ok" mean the caller should fall back to
// the whole system -- question generation needs minHits distinct auctions to build the
// hardest question.
func (s *System) CheckFilter(text string, minHits int) FilterCheck {
	key := filterKey{text: bidfilter.NormalizeFilterText(text), minHits: minHits}
	if cached, ok := s.filterCache.get(key); ok {
		return cached
	}
	check := s.checkFilterUncached(key.text, minHits)
	s.filterCache.put(key, check)
	return check
}

func (s *System) checkFilterUncached(normalised string, minHits int) FilterCheck {
	parsed := bidfilter.ParseFilter(normalised, s.Topics)
	if len(parsed.Patterns) == 0 {
		status := "all"
		if len(parsed.Errors) > 0 {
			status = "error"
		}
		return FilterCheck{Status: status, Hits: s.Auctions, Parsed: parsed}
	}
	var hits []Auction
	for i, prepared := range s.prepared {
		if bidfilter.BidsMatchAny(prepared, parsed.Patterns) {
			hits = append(hits, s.Auctions[i])
		}
	}
	if len(hits) < minHits {
		return FilterCheck{Status: "too_few", Hits: hits, Parsed: parsed}
	}
	return FilterCheck{Status: "ok", Hits: hits, Parsed: parsed}
}
