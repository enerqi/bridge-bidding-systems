package combo

/*
	aposteriori_test.odin — the constrained (vacant-space / a-posteriori) re-weighting engine.

	What these pin down:

	  * PARITY — with NO constraints (all-zero minimums, full length ranges) the constrained census
	    reproduces the unconstrained `marginal_from_table` + `joint_total` numbers. The constrained path is
	    a strict generalisation; it must agree on the a-priori 13-13 baseline (`test_*_unconstrained_*`).

	  * COLLAPSE — forcing the `a`-side defender to hold the WHOLE suit (`lo = m`, i.e. the other defender
	    void) collapses that suit's length axis to a single split; its marginal becomes exactly that split's
	    census row, renormalised (`test_*_void_collapse`).

	  * FEASIBILITY — minimums that cannot both be met (`lo + hi > m`) are reported infeasible so the caller
	    can fall back rather than divide by zero (`test_*_infeasible`).

	  * LINE MEAN — `constrained_line_mean` under the a-priori context equals the line's ordinary mean
	    (`expected_tricks` of its marginal), so the SD re-pick reduces correctly when nothing is known
	    (`test_*_line_mean_parity`).
*/

import "core:math"
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

// A valid 13-13 NS partnership (each hand 13 cards, the two disjoint) so `joint_total`'s "East holds
// exactly 13" normalisation is well-defined. Spades/Hearts/Diamonds = AKQ opposite 432; Clubs = AKQJ
// opposite T987.
@(private = "file")
sample_tables :: proc() -> (tables: [norn.Suit]Suit_Joint_Table) {
	n_top := mask(.Ace, .King, .Queen)
	s_low := mask(.Four, .Three, .Two)
	tables[.Spades] = suit_joint_table(n_top, s_low)
	tables[.Hearts] = suit_joint_table(n_top, s_low)
	tables[.Diamonds] = suit_joint_table(n_top, s_low)
	tables[.Clubs] = suit_joint_table(mask(.Ace, .King, .Queen, .Jack), mask(.Ten, .Nine, .Eight, .Seven))
	return
}

@(private = "file")
close :: proc(a, b: f64) -> bool {
	return math.abs(a - b) <= 1e-9 + 1e-6 * math.abs(b)
}

// Unconstrained: the constrained census must match the isolated marginal + joint total exactly (to fp).
@(test)
test_aposteriori_unconstrained_matches_baseline :: proc(t: ^testing.T) {
	tables := sample_tables()

	oc: Opp_Constraints // all-zero => full ranges
	ctx := constraint_ctx(tables, oc)
	testing.expect(t, ctx.feasible, "a-priori model must be feasible")
	out := constrained_census(tables, &ctx)

	// Per-suit marginals match `marginal_from_table`.
	for suit in norn.Suit {
		ref := marginal_from_table(tables[suit])
		for k in 0 ..= RANKS {
			testing.expectf(
				t,
				close(out.suits[suit].p[k], ref.p[k]),
				"suit %v p[%d]: constrained %.10f vs baseline %.10f",
				suit,
				k,
				out.suits[suit].p[k],
				ref.p[k],
			)
		}
	}

	// Combined total matches `joint_total`.
	ref_total := joint_total(tables)
	for k in 0 ..= RANKS {
		testing.expectf(
			t,
			close(out.total[k], ref_total[k]),
			"total[%d]: constrained %.10f vs baseline %.10f",
			k,
			out.total[k],
			ref_total[k],
		)
	}
}

// lo = m in one suit forces the `a`-side defender to hold every missing card there (the other is void):
// only the a==m split survives, and the suit marginal is that census row renormalised.
@(test)
test_aposteriori_void_collapse :: proc(t: ^testing.T) {
	tables := sample_tables()
	m_sp := tables[.Spades].m

	oc: Opp_Constraints
	oc.active = true
	oc.lo[.Spades] = m_sp // a-side defender holds all m spades => other side void

	ctx := constraint_ctx(tables, oc)
	testing.expect(t, ctx.feasible, "void-in-one-defender must be feasible")
	out := constrained_census(tables, &ctx)

	// The surviving spade split is exactly a == m: reconstruct its normalised trick row directly.
	denom: f64
	for k in 0 ..= RANKS {
		denom += tables[.Spades].count[m_sp][k]
	}
	testing.expect(t, denom > 0, "the a==m split must carry weight")
	for k in 0 ..= RANKS {
		want := tables[.Spades].count[m_sp][k] / denom
		testing.expectf(
			t,
			close(out.suits[.Spades].p[k], want),
			"collapsed spade p[%d]: %.10f vs %.10f",
			k,
			out.suits[.Spades].p[k],
			want,
		)
	}

	// Every suit marginal and the total must still be proper distributions.
	for suit in norn.Suit {
		s: f64
		for k in 0 ..= RANKS {s += out.suits[suit].p[k]}
		testing.expectf(t, close(s, 1), "suit %v marginal sums to %.10f", suit, s)
	}
	st: f64
	for k in 0 ..= RANKS {st += out.total[k]}
	testing.expectf(t, close(st, 1), "total sums to %.10f", st)
}

// Minimums that cannot both hold (lo + hi > m) leave no legal split -> infeasible, not a divide-by-zero.
@(test)
test_aposteriori_infeasible :: proc(t: ^testing.T) {
	tables := sample_tables()
	m_sp := tables[.Spades].m

	oc: Opp_Constraints
	oc.active = true
	oc.lo[.Spades] = m_sp
	oc.hi[.Spades] = 1 // needs m+1 cards in the suit; impossible

	ctx := constraint_ctx(tables, oc)
	testing.expect(t, !ctx.feasible, "contradictory minimums must be infeasible")
}

// Under the a-priori context, a line's constrained mean equals its ordinary mean (expected tricks of its
// isolated marginal). Anchors the SD re-pick machinery to the known unconstrained number.
//
// The coupling identity behind it: with full ranges, `others[.Spades][13-a]` is the length convolution of
// the OTHER three suits = C(26-m_s, 13-a) by Vandermonde, and D = C(26,13) — EXACTLY the isolated
// hypergeometric weight `marginal_from_table` applies. That identity holds only for a real 13-13 deal
// (m_h+m_d+m_c = 26-m_s), so the spade finesse holding sits in a genuine full deal here.
@(test)
test_aposteriori_line_mean_parity :: proc(t: ^testing.T) {
	// A valid 13-13 deal whose SPADE suit is a finesse holding (AQ opposite 32, m=9):
	//   H,D = AKQ/432 (m=7 each);  C = AKQJT/98765 (m=3).  m_h+m_d+m_c = 17 = 26 - 9.
	tt: [norn.Suit]Suit_Joint_Table
	tt[.Spades] = suit_joint_table(mask(.Ace, .Queen), mask(.Three, .Two))
	tt[.Hearts] = suit_joint_table(mask(.Ace, .King, .Queen), mask(.Four, .Three, .Two))
	tt[.Diamonds] = suit_joint_table(mask(.Ace, .King, .Queen), mask(.Four, .Three, .Two))
	tt[.Clubs] = suit_joint_table(mask(.Ace, .King, .Queen, .Jack, .Ten), mask(.Nine, .Eight, .Seven, .Six, .Five))

	oc: Opp_Constraints // a-priori
	cx := constraint_ctx(tt, oc)
	testing.expect(t, cx.feasible)

	fin := sd_line_joint_table(mask(.Ace, .Queen), mask(.Three, .Two), line_finesse)
	got := constrained_line_mean(&cx, .Spades, fin)
	want := expected_tricks(marginal_from_table(fin).p)
	testing.expectf(t, close(got, want), "line mean: constrained %.10f vs marginal %.10f", got, want)
}

// THE HEADLINE: known opponent shape re-weights vacant space and flips the preferred line. A symmetric
// two-way finesse (AJ opposite KT, either way for the Q) is a coin-flip a-priori; telling the engine one
// defender is loaded in ANOTHER suit shrinks that defender's spade vacancy, so the Q is likelier with the
// other defender and one finesse direction overtakes the other.
@(test)
test_aposteriori_coupling_breaks_two_way :: proc(t: ^testing.T) {
	// Valid 13-13 deal, spades = AJ opposite KT (m=9, a two-way for the Q):
	//   H,D = AKQ/432 (m=7);  C = AKQJT/98765 (m=3).
	tables: [norn.Suit]Suit_Joint_Table
	tables[.Spades] = suit_joint_table(mask(.Ace, .Jack), mask(.King, .Ten))
	tables[.Hearts] = suit_joint_table(mask(.Ace, .King, .Queen), mask(.Four, .Three, .Two))
	tables[.Diamonds] = suit_joint_table(mask(.Ace, .King, .Queen), mask(.Four, .Three, .Two))
	tables[.Clubs] = suit_joint_table(mask(.Ace, .King, .Queen, .Jack, .Ten), mask(.Nine, .Eight, .Seven, .Six, .Five))

	fin := sd_line_joint_table(mask(.Ace, .Jack), mask(.King, .Ten), line_finesse)
	oth := sd_line_joint_table(mask(.Ace, .Jack), mask(.King, .Ten), line_finesse_other)

	// `delta = mean(finesse) - mean(finesse-other)`: which finesse direction the vacant-space model prefers.
	spade_delta :: proc(
		tables: [norn.Suit]Suit_Joint_Table,
		oc: Opp_Constraints,
		fin, oth: Suit_Joint_Table,
		t: ^testing.T,
	) -> f64 {
		cx := constraint_ctx(tables, oc)
		testing.expect(t, cx.feasible)
		return constrained_line_mean(&cx, .Spades, fin) - constrained_line_mean(&cx, .Spades, oth)
	}

	// A-priori (no knowledge): a near-symmetric two-way, so the two directions are within a whisker.
	d0 := spade_delta(tables, Opp_Constraints{}, fin, oth, t)

	// Load defender `hi` with all seven hearts (the `a`-side goes void there, gaining spade vacancy)...
	oc_a: Opp_Constraints
	oc_a.active = true
	oc_a.hi[.Hearts] = 7
	d_a := spade_delta(tables, oc_a, fin, oth, t)

	// ...vs loading the OTHER defender (`lo`) instead. The mirror skew must push the finesse preference the
	// OPPOSITE way relative to a-priori — proof that vacant space controls the direction, not a fixed bias.
	oc_b: Opp_Constraints
	oc_b.active = true
	oc_b.lo[.Hearts] = 7
	d_b := spade_delta(tables, oc_b, fin, oth, t)

	testing.expectf(
		t,
		(d_a - d0) * (d_b - d0) < 0,
		"mirror skews must move the finesse preference oppositely: d0=%.6f d_a=%.6f d_b=%.6f",
		d0,
		d_a,
		d_b,
	)
	testing.expectf(
		t,
		math.abs(d_a - d0) > 1e-3 && math.abs(d_b - d0) > 1e-3,
		"each skew must move the preference by a real margin: d0=%.6f d_a=%.6f d_b=%.6f",
		d0,
		d_a,
		d_b,
	)
}
