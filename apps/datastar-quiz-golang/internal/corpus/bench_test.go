package corpus

import (
	"testing"

	"github.com/enerqi/bridge-bidding-system/apps/datastar-quiz-golang/internal/bidfilter"
)

// The filter is where the CPU goes, so these are the numbers the comparison turns on.
// Measured on the python, warm, over 7,627 auctions: `check_filter("1C")` 15.8 ms and a
// topic 43 ms, against ~2 ms for scoring an answer. Under load those two preview routes were
// the only ones to miss their latency targets (400 users, P95 420 ms and 520 ms), which is
// what the memo was added for -- and it gets an 87.6% hit rate there.
//
//	go test -bench . ./internal/corpus/
//
// `Cold` is one uncached call: the memo is cleared each iteration, so it measures the match
// itself. `Warm` is the memo path, which is what 87.6% of the load run actually pays.

func benchFilter(b *testing.B, variant, text string, cold bool) {
	b.Helper()
	if err := Load(); err != nil {
		b.Fatalf("corpus: %v", err)
	}
	system := Get(variant)
	if system == nil {
		b.Fatalf("no such variant: %s", variant)
	}
	b.ReportAllocs()
	for b.Loop() {
		if cold {
			system.ClearFilterCache()
		}
		if got := system.CheckFilter(text, 8); got.Status == "" {
			b.Fatal("no answer")
		}
	}
}

func BenchmarkCheckFilterColdPattern(b *testing.B) { benchFilter(b, "swedish", "1C", true) }
func BenchmarkCheckFilterColdTopic(b *testing.B)   { benchFilter(b, "swedish", "1C opening", true) }
func BenchmarkCheckFilterWarmPattern(b *testing.B) { benchFilter(b, "swedish", "1C", false) }
func BenchmarkCheckFilterColdSquad(b *testing.B)   { benchFilter(b, "squad", "1C", true) }

// BenchmarkPrepareCorpus is the startup cost: parsing every auction into the positions the
// matcher walks. On the python this is `prepare_sequence_bids`, measured at 4.25s for both
// systems -- and it used to happen inside the first request that needed it.
func BenchmarkPrepareCorpus(b *testing.B) {
	if err := Load(); err != nil {
		b.Fatalf("corpus: %v", err)
	}
	sequences := make([][]string, len(Get("swedish").Auctions))
	for i, auction := range Get("swedish").Auctions {
		sequences[i] = auction.Sequence
	}
	b.ReportAllocs()
	for b.Loop() {
		_ = prepareForBench(sequences)
	}
}

// prepareForBench exists so the benchmark can measure the preparation without the package
// re-exporting it: `prepared` is unexported because nothing outside this package has any use
// for it.
func prepareForBench(sequences [][]string) []bidfilter.Variants {
	return bidfilter.PrepareSequenceBids(sequences)
}
