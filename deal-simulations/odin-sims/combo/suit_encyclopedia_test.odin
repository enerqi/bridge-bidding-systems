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

// The card-validity gate: the engine key is odds-based, so an odds-equivalent holding with DIFFERENT honours
// shares a key with a baked entry (AQ9x/T8x, missing KJ, is the same double-finesse odds as AKJ9/xxx, missing
// QT). Accepting that hit would show the wrong entry's card names ("low to K" on a holding with no king). The
// book does not list AQ9x/T8x, so it MUST resolve to a miss -> engine fallback, not a false hit.
@(test)
test_encyclopedia_card_validity :: proc(t: ^testing.T) {
	// AQ9x / T8x: A,Q,9,5 (0x14a0) opposite T,8,4 (0x0150); no king, no jack.
	n := u16((1 << 12) | (1 << 10) | (1 << 7) | (1 << 5))
	s := u16((1 << 8) | (1 << 6) | (1 << 4))
	e, ok := encyclopedia_lookup(n, s)
	testing.expectf(t, !ok, "AQ9x/T8x must miss (not in book); got line=%q", e.line)

	// Sanity: the engine-equivalent holding that IS baked (AKJ9/xxx, 0x1a80/0x0007) still hits, and its line
	// names only cards it holds.
	e2, ok2 := encyclopedia_lookup(0x1a80, 0x0007)
	testing.expect(t, ok2)
	if ok2 {testing.expect(t, e2.n == 0x1a80 && e2.s == 0x0007)}
}
