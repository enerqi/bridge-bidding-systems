package session

import (
	"sync"
	"time"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/corpus"
)

type key struct {
	sid     string
	variant string
}

// Store is the process-local session registry with TTL eviction, keyed by
// (browser, variant).
//
// ONE QUIZ PER VARIANT PER BROWSER, which is what panel had for free by keying its sessions
// on the variant. The single-session version replaced the whole quiz whenever `?swedish`
// was opened, and with one cookie per browser that reached across tabs: the squad tab, the
// back-history entry and the phone's first tab were all left holding a quiz that no longer
// existed, mid-score. Now switching systems parks one and resumes the other, both keep
// their score, and the two can be played in two tabs at once.
//
// The sid still identifies the browser, so it stays a single cookie. `current` remembers
// which variant a browser last *navigated* to, for the one request that cannot say: a page
// load with a query that names no variant (`?debug`), which must not be read as "take me
// back to squad".
//
// `map` + `sync.RWMutex` rather than a cache library, as the handoff asks: the semantics
// are specific (per-variant keying, a nonce per question, a TTL sweep) and small.
type Store struct {
	mu       sync.RWMutex
	sessions map[key]*Session
	current  map[string]string
	ttl      time.Duration
}

// NewStore builds an empty store with the default six-hour TTL.
func NewStore() *Store { return NewStoreWithTTL(TTL) }

// NewStoreWithTTL is NewStore with the lifetime named, for tests.
func NewStoreWithTTL(ttl time.Duration) *Store {
	return &Store{sessions: map[key]*Session{}, current: map[string]string{}, ttl: ttl}
}

// Get is this browser's session for variantKey, or for whatever it is currently on when
// variantKey is empty. Nil when there is none.
func (s *Store) Get(sid, variantKey string) *Session {
	if sid == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if variantKey == "" {
		variantKey = s.current[sid]
		if variantKey == "" {
			return nil
		}
	}
	found := s.sessions[key{sid, variantKey}]
	if found != nil {
		found.With(func() { found.Touched = time.Now() })
	}
	return found
}

// CurrentVariant is the variant this browser last navigated to, if the store still has it.
func (s *Store) CurrentVariant(sid string) string {
	if sid == "" {
		return ""
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.current[sid]
}

// Create builds a quiz for a system under the given browser id (a new browser if there is
// none).
func (s *Store) Create(system *corpus.System, sid string) *Session {
	created := New(system, sid)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[key{created.SID, system.Variant.Key}] = created
	// Only if absent, not an assignment: a browser with NO mark has to get one from
	// somewhere, and the quiz it just had built is the only candidate. A browser that
	// already has one keeps it -- moving the mark is a navigation's job, so a rebuild
	// triggered by a background tab's click cannot decide what the next `?debug` page load
	// resumes.
	if _, ok := s.current[created.SID]; !ok {
		s.current[created.SID] = system.Variant.Key
	}
	return created
}

// Remember notes which variant this browser is on. Page loads only: an interaction from a
// background tab must not move the mark, since that is the cross-tab bleed this store
// exists to end.
func (s *Store) Remember(sess *Session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.current[sess.SID] = sess.System.Variant.Key
}

// Discard drops one of a browser's quizzes, or (with an empty variant key) every one.
func (s *Store) Discard(sid, variantKey string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if variantKey != "" {
		delete(s.sessions, key{sid, variantKey})
	} else {
		for k := range s.sessions {
			if k.sid == sid {
				delete(s.sessions, k)
			}
		}
	}
	if variantKey == "" || s.current[sid] == variantKey {
		delete(s.current, sid)
	}
}

// Len is how many quizzes the store holds.
func (s *Store) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.sessions)
}

// Sweep drops sessions older than the TTL and forgets browsers with none left.
//
// A goroutine on a ticker rather than the python's lazy "sweep if it has been ten minutes
// since the last request" -- a background task is the natural shape here, and it means an
// idle server actually releases the memory rather than holding it until somebody knocks.
func (s *Store) Sweep(now time.Time) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	dropped := 0
	for k, sess := range s.sessions {
		var touched time.Time
		sess.With(func() { touched = sess.Touched })
		if now.Sub(touched) > s.ttl {
			delete(s.sessions, k)
			dropped++
		}
	}
	live := map[string]bool{}
	for k := range s.sessions {
		live[k.sid] = true
	}
	for sid := range s.current {
		if !live[sid] {
			delete(s.current, sid)
		}
	}
	return dropped
}

// StartSweeper runs Sweep every ten minutes until done is closed.
func (s *Store) StartSweeper(done <-chan struct{}) {
	ticker := time.NewTicker(sweepPeriod)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case now := <-ticker.C:
				s.Sweep(now)
			}
		}
	}()
}
