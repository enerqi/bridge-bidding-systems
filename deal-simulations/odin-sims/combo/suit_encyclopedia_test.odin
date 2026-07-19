package combo

import "core:fmt"
import "core:testing"

// Every baked entry must be found by looking up its own holding: its engine key is in the map by
// construction. (Several entries may share an engine key — equivalent holdings — so the returned entry is not
// necessarily the same index; it must, however, always be a hit.)
@(test)
test_encyclopedia_roundtrip :: proc(t: ^testing.T) {
	miss := 0
	for e in enc_entries {
		if _, ok := encyclopedia_lookup(e.n, e.s); !ok {
			miss += 1
			if miss <= 8 {fmt.printfln("  MISS n=%x s=%x line=%q", e.n, e.s, e.line)}
		}
	}
	testing.expectf(t, miss == 0, "%d/%d entries failed round-trip lookup", miss, len(enc_entries))
}

// Spot-check a known holding + engine-equivalence of low spots + orientation invariance.
@(test)
test_encyclopedia_known :: proc(t: ^testing.T) {
	// AK982 / J43 length case (book: cash A K, 4 tricks ~96%).
	e, ok := encyclopedia_lookup(0x18c1, 0x0206)
	testing.expect(t, ok)
	fmt.printfln("AK982/J43 -> line=%q targets=%v", e.line, e.targets[:e.nt])
	testing.expect(t, e.nt >= 1 && e.targets[e.nt - 1].pct >= 90)

	// Orientation invariance: swapping the two hands finds the same entry.
	e2, ok2 := encyclopedia_lookup(0x0206, 0x18c1)
	testing.expect(t, ok2)
	testing.expect(t, e2.n == e.n && e2.s == e.s)

	// Engine-equivalence: a holding differing only in which low spot NS holds must resolve to the SAME entry.
	// N=AKJ (0x1A00); S=3,2 (0x0003) vs S=7,5 (0x0028) are equivalent -> same lookup result if either is baked.
	a, oka := encyclopedia_lookup(0x1A00, 0x0003)
	b, okb := encyclopedia_lookup(0x1A00, 0x0028)
	testing.expect(t, oka == okb)
	if oka && okb {testing.expect(t, a.n == b.n && a.s == b.s)}
}
