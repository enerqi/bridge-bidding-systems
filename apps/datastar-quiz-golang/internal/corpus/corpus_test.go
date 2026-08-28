package corpus

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"
)

// golden is one probe recorded from the PYTHON implementation by
// `apps/datastar-quiz/tools/export_filter_goldens.py`.
//
// The unit tests in internal/bidfilter cover the pattern language case by case; this
// covers the other half -- that the ported matcher selects the SAME auctions out of the
// real corpus as the reference does. The digest is over the matching indices, so a single
// auction moving in or out fails the test.
type golden struct {
	Text       string   `json:"text"`
	MinHits    int      `json:"min_hits"`
	Status     string   `json:"status"`
	Hits       int      `json:"hits"`
	Digest     string   `json:"digest"`
	Canonical  string   `json:"canonical"`
	Errors     []string `json:"errors"`
	TopicNames []string `json:"topic_names"`
}

func TestFilterAgreesWithThePythonImplementation(t *testing.T) {
	if err := Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}
	body, err := os.ReadFile("testdata/filter_goldens.json")
	if err != nil {
		t.Fatalf("goldens: %v", err)
	}
	var goldens map[string][]golden
	if err := json.Unmarshal(body, &goldens); err != nil {
		t.Fatalf("goldens: %v", err)
	}
	if len(goldens) == 0 {
		t.Fatal("no goldens")
	}
	for key, probes := range goldens {
		system := Get(key)
		if system == nil {
			t.Fatalf("no such variant: %s", key)
		}
		// index by identity of the auction slice entry -- the go corpus is loaded in the
		// same order the python exported it, so position is the shared identifier
		position := map[*Auction]int{}
		for i := range system.Auctions {
			position[&system.Auctions[i]] = i
		}
		for _, want := range probes {
			check := system.CheckFilter(want.Text, want.MinHits)
			label := key + " " + strconv.Quote(want.Text)
			if check.Status != want.Status {
				t.Errorf("%s: status %q, want %q", label, check.Status, want.Status)
			}
			if len(check.Hits) != want.Hits {
				t.Errorf("%s: %d hits, want %d", label, len(check.Hits), want.Hits)
			}
			if got := digestOf(system, check); got != want.Digest {
				t.Errorf("%s: selected a different set of auctions (digest %s, want %s)", label, got[:12], want.Digest[:12])
			}
			if check.Parsed.CanonicalText != want.Canonical {
				t.Errorf("%s: canonical %q, want %q", label, check.Parsed.CanonicalText, want.Canonical)
			}
			if !sameStrings(check.Parsed.Errors, want.Errors) {
				t.Errorf("%s: errors %v, want %v", label, check.Parsed.Errors, want.Errors)
			}
			if !sameStrings(check.Parsed.TopicNames, want.TopicNames) {
				t.Errorf("%s: topics %v, want %v", label, check.Parsed.TopicNames, want.TopicNames)
			}
		}
	}
}

// digestOf reproduces the python golden's sha256 over the selected auctions' indices.
// The "everything matches" branch returns the shared slice, so the fast path is a
// comparison of slice identity rather than a scan.
func digestOf(system *System, check FilterCheck) string {
	indices := make([]string, 0, len(check.Hits))
	if len(check.Hits) == len(system.Auctions) && (len(check.Hits) == 0 || &check.Hits[0] == &system.Auctions[0]) {
		for i := range system.Auctions {
			indices = append(indices, strconv.Itoa(i))
		}
	} else {
		next := 0
		for _, hit := range check.Hits {
			for next < len(system.Auctions) && !sameAuction(system.Auctions[next], hit) {
				next++
			}
			indices = append(indices, strconv.Itoa(next))
			next++
		}
	}
	sum := sha256.Sum256([]byte(strings.Join(indices, ",")))
	return hex.EncodeToString(sum[:])
}

func sameAuction(a, b Auction) bool {
	if a.Description != b.Description || len(a.Sequence) != len(b.Sequence) {
		return false
	}
	for i := range a.Sequence {
		if a.Sequence[i] != b.Sequence[i] {
			return false
		}
	}
	return true
}

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestFilterCacheRemembers(t *testing.T) {
	if err := Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}
	system := Default()
	system.ClearFilterCache()
	first := system.CheckFilter("1C", 8)
	second := system.CheckFilter(" 1C ", 8) // normalised to the same key
	if len(first.Hits) != len(second.Hits) {
		t.Errorf("normalised text produced a different answer")
	}
	info := system.FilterCacheInfo()
	if info.Hits != 1 || info.Misses != 1 {
		t.Errorf("cache info = %+v, want 1 hit and 1 miss", info)
	}
	// case is deliberately NOT folded: `m` is the minors and `M` the majors
	if len(system.CheckFilter("1m", 8).Hits) == len(system.CheckFilter("1M", 8).Hits) {
		t.Log("1m and 1M happen to select the same number of auctions; the keys are still distinct")
	}
	if info := system.FilterCacheInfo(); info.Size < 2 {
		t.Errorf("cache size = %d, want at least 2 entries", info.Size)
	}
}
