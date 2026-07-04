package combo

/*
	joint_test.odin — coverage for the constrained JOINT convolution (`joint_total`) that folds the four
	per-suit tables into the combined trick distribution.

	The analyser weights each suit's E/W split by the exact hypergeometric marginal (`suit_joint_table` +
	`marginal_from_table`). The combined total is NO LONGER an independent convolution of those marginals:
	`joint_total` is a DP over the four suits carrying East's running 0..13 card count, so only splits
	consistent with "East holds exactly 13 of the 26 opponent cards" are counted, and NS's running trick
	total is capped at 13. This removes the length-independence bias the old convolution carried.

	What these tests pin down:

	  * RIGHT — each per-suit marginal is still the EXACT hypergeometric split distribution for that suit
	    alone (`test_vacant_space_marginal_is_exact_hypergeometric`); the joint fix changes only the total.

	  * RIGHT — the total is ALWAYS a proper probability distribution (sums to exactly 1) because the
	    e==13 states of the DP number exactly C(26,13) — no drop, no collapse (all tests assert this).

	  * RIGHT — E[tot] equals the sum of the per-suit means WHENEVER the 13-trick cap never bites (linearity
	    of expectation; the joint constraint correlates the suits but does not change any marginal).
	    Demonstrated on a mirror-length deal (`test_mirror_deal_total_is_exact`).

	  * RIGHT — the length constraint is enforced: a deal that forces two suits to share East's 13-card
	    budget yields exactly the Vandermonde-correct total, not the independent product
	    (`test_joint_length_constraint_and_cap`).

	  * REMAINING model bias — the free-entry per-suit model (assumption 1) can still over-count tricks
	    within a SINGLE consistent deal, so a very strong hand's per-suit means over-sum and the cap parks
	    the surplus at 13; E[tot] < sum-of-means there (`test_strong_deal_is_capped`). The joint fix removes
	    the LENGTH error, not the free-entry one — see COMBO_ANALYSER.md.
*/

import "core:testing"

import "norn:norn"

@(private = "file")
mask :: proc(ranks: ..norn.Rank) -> u16 {
	m: u16
	for r in ranks {
		m |= u16(1) << uint(r)
	}
	return m
}

@(private = "file")
total_mass :: proc(p: [RANKS + 1]f64) -> f64 {
	s := f64(0)
	for k in 0 ..= RANKS {s += p[k]}
	return s
}

@(private = "file")
sum_of_suit_means :: proc(a: Deal_Analysis) -> f64 {
	s := f64(0)
	for suit in norn.Suit {s += expected_tricks(a.suits[suit].p)}
	return s
}

// The per-suit split weight the model uses (`g_binom[26-m][13-a]` normalised by `g_binom[26][13]`) is
// the EXACT hypergeometric marginal for a suit with `m` opponent cards: total weight on "East holds a"
// is C(m,a)*C(26-m,13-a)/C(26,13). Over all a it sums to 1, and the mean East holds is m*13/26 = m/2.
// This is the part of the model that is unimpeachable — each single-suit split is exactly right, and the
// joint fix leaves it untouched (it reweights only the CROSS-suit combination).
@(test)
test_vacant_space_marginal_is_exact_hypergeometric :: proc(t: ^testing.T) {
	denom := g_binom[26][13]
	for m in 0 ..= 13 {
		total := f64(0)
		mean := f64(0)
		for a in 0 ..= m {
			// C(m,a) ways to choose which of the m suit cards go to East, each weighted g_binom[26-m][13-a].
			p := g_binom[m][a] * g_binom[26 - m][13 - a] / denom
			testing.expect(t, p >= -1e-12, "probability must be non-negative")
			total += p
			mean += f64(a) * p
		}
		testing.expectf(t, abs(total - 1) < 1e-9, "m=%d: marginal sums to %.12f, want 1", m, total)
		testing.expectf(t, abs(mean - f64(m) / 2) < 1e-9, "m=%d: mean East count %.10f, want %.10f", m, mean, f64(m) / 2)
	}
}

// A MIRROR-length deal (both hands the same shape per suit, here 4-3-3-3 / 4-3-3-3) has its four
// per-suit MAX trick counts summing to exactly 13, so the running total never exceeds 13 and the cap
// never bites. In that regime the tool is exact: the total is a proper distribution and — by linearity of
// expectation, which holds under the joint model too — E[tot] equals the sum of the per-suit means.
@(test)
test_mirror_deal_total_is_exact :: proc(t: ^testing.T) {
	north := norn.Hand_Summary {
		suits = {
			.Spades = mask(.Ace, .Seven, .Four, .Two),
			.Hearts = mask(.Ace, .Eight, .Three),
			.Diamonds = mask(.Ace, .Nine, .Five),
			.Clubs = mask(.Ace, .Ten, .Six),
		},
	}
	south := norn.Hand_Summary {
		suits = {
			.Spades = mask(.King, .Queen, .Nine, .Five),
			.Hearts = mask(.King, .Seven, .Four),
			.Diamonds = mask(.Queen, .Jack, .Six),
			.Clubs = mask(.King, .Eight, .Four),
		},
	}
	a := analyse_ns(north, south)

	testing.expectf(t, abs(total_mass(a.total) - 1) < 1e-9, "mirror total must stay normalised, got %.12f", total_mass(a.total))
	testing.expectf(
		t,
		abs(expected_tricks(a.total) - sum_of_suit_means(a)) < 1e-9,
		"mirror E[tot] %.10f must equal sum of per-suit means %.10f",
		expected_tricks(a.total),
		sum_of_suit_means(a),
	)
}

// The length constraint AND the trick cap, in one exactly-computable deal. North holds ALL 13 spades,
// South ALL 13 hearts; the opponents hold every diamond and club (26 cards, 13 each). So:
//   - spades give NS 13 tricks certain, hearts 13 certain  -> running total 26, CAPPED to 13;
//   - diamonds and clubs are NS voids (0 tricks), but East's lengths there must sum to 13 (d + c = 13) —
//     the joint length constraint. Independence would let (d, c) be any pair; the DP only counts d+c=13.
// Result: a point mass at 13 tricks. total[13] == 1 verifies both the cap (26 -> 13) and that the
// length-constrained counts normalise correctly (Sum_{d+c=13} C(13,d)C(13,c) = C(26,13), Vandermonde).
@(test)
test_joint_length_constraint_and_cap :: proc(t: ^testing.T) {
	north := norn.Hand_Summary{suits = {.Spades = FULL_SUIT, .Hearts = 0, .Diamonds = 0, .Clubs = 0}}
	south := norn.Hand_Summary{suits = {.Spades = 0, .Hearts = FULL_SUIT, .Diamonds = 0, .Clubs = 0}}
	a := analyse_ns(north, south)

	testing.expectf(t, abs(total_mass(a.total) - 1) < 1e-9, "total must be normalised, got %.12f", total_mass(a.total))
	testing.expectf(t, abs(a.total[RANKS] - 1) < 1e-9, "all mass must sit on 13 tricks (cap + length constraint), p[13]=%.12f", a.total[RANKS])
}

// The residual free-entry model bias, now isolated from the (fixed) length bias. A very strong NS (top
// honours in every suit) has each per-suit marginal credit near-maximum tricks, so the per-suit means sum
// to far more than 13 — impossible for one deal, a consequence of assumption 1 (free entries per suit).
// The joint convolution keeps the total a valid normalised distribution and caps it at 13; E[tot] is
// therefore < the (impossible) sum of per-suit means. This locks the remaining bias so a future
// free-entry fix has a concrete before/after.
@(test)
test_strong_deal_is_capped :: proc(t: ^testing.T) {
	north := norn.Hand_Summary {
		suits = {
			.Spades = mask(.Ace, .King, .Queen, .Jack, .Two),
			.Hearts = mask(.Ace, .King, .Three),
			.Diamonds = mask(.Ace, .King, .Four),
			.Clubs = mask(.Ace, .Five),
		},
	}
	south := norn.Hand_Summary {
		suits = {
			.Spades = mask(.Ten, .Nine),
			.Hearts = mask(.Queen, .Jack, .Ten, .Four),
			.Diamonds = mask(.Queen, .Jack, .Ten, .Five),
			.Clubs = mask(.King, .Queen, .Six),
		},
	}
	a := analyse_ns(north, south)

	suit_means := sum_of_suit_means(a)
	testing.expectf(t, suit_means > 13, "precondition: per-suit means should over-sum (got %.4f)", suit_means)
	// The joint total is a genuine probability distribution (no drop, no collapse).
	testing.expectf(t, abs(total_mass(a.total) - 1) < 1e-9, "total must stay normalised, got %.12f", total_mass(a.total))
	// Physical bound: NS never take more than 13 tricks, so E[tot] <= 13 < the over-summing per-suit means.
	testing.expectf(t, expected_tricks(a.total) <= 13 + 1e-9, "E[tot] %.6f must not exceed 13", expected_tricks(a.total))
	testing.expectf(
		t,
		expected_tricks(a.total) < suit_means - 1e-6,
		"E[tot] %.6f should be below the over-summing per-suit means %.6f (free-entry bias remains)",
		expected_tricks(a.total),
		suit_means,
	)
}
