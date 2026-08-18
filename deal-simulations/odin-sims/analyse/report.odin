package analyse

/*
	report.odin — the text report (part of package `analyse`; see analyse.odin).

	Every proc here writes to an `io.Writer` rather than to stdout, which is the whole reason this code
	left `package main`: the same report renders into a terminal, into a test's builder, and into the
	workbench window's `<plaintext>` pane. `report_board` takes the `Sink` because it emits diagnostics
	as well as report text; everything below it takes just the report writer.
*/

import "core:fmt"
import "core:io"
import "core:strings"

import "../deal_solve"
import "norn:combo"
import "norn:norn"

// Text report for a fully-known 4-hand deal: the layout, then the EXACT double-dummy verdict (par +
// NS-makeable, from deal_solve.annotate solving the actual deal — no sampling, no ceiling/achievable gap), then the
// per-partnership combo (CCA) census. Uses the temp allocator; the whole block prints at once.
report_full_deal :: proc(w: io.Writer, board: norn.Board) {
	b := strings.builder_make(context.temp_allocator)
	norn.render_deal_pretty(&b, board.deal)
	deal_solve.annotate(&b, board.deal, .Pretty)
	combo.annotate(&b, board.deal, .Pretty)
	fmt.wprintln(w, strings.to_string(b))
}

// One board's report: the combo census + SD summary, and (with --sample) the simulated verdict. A board
// that is neither a 2-hand advisor input nor a complete deal gets a diagnostic and no report.
report_board :: proc(sink: Sink, board: norn.Board, args: ^Args, contract: deal_solve.Contract, has_contract: bool) {
	a, side, ok := combo.analyse_board(board)
	if !ok {
		if board_fully_known(board) {
			report_full_deal(sink.out, board)
			return
		}
		fmt.wprintfln(
			sink.err,
			"%s: not a 2-hand advisor board — need exactly one fully-known partnership (declarer +",
			PROGRAM,
		)
		fmt.wprintln(sink.err, "             dummy), the two defenders written '-'.")
		return
	}
	sd, _, _ := combo.sd_bundle_board(board)
	advice, _, _ := combo.suit_combo_advice_board(board)
	defer for ad in advice {
		delete(ad.cands)
	}

	bs, serr := sample_board(board, side, args, contract, has_contract)
	defer board_sample_free(&bs)
	if serr != "" {
		fmt.wprintfln(sink.err, "%s: %s", PROGRAM, serr)
	}

	// If sampling ran, the whole-hand simulated E[total] is the honest cross-check for the naive
	// census — thread it into the caveat so the over-count is named right where the warning lives.
	sim_total: Maybe(f64)
	sample: deal_solve.Sample_Result
	if bs.have {
		sample = deal_solve.result_for(bs.grid, bs.contract)
		sim_total = sample.mean_tricks
	}

	print_report(sink.out, &a, &sd, advice, side, args.target, sim_total)
	if bs.have {
		print_sample_verdict(sink.out, &a, &sd, &sample, bs.auto, bs.tax, bs.tax_ok, bs.leads, side, bs.contract)
		if len(args.constraints) > 0 || len(args.held) > 0 {
			fmt.wprint(sink.out, "  (sampled only layouts where")
			first := true
			for con in args.constraints {
				fmt.wprintf(
					sink.out,
					"%s %v %s %d-%d",
					" " if first else ",",
					con.seat,
					suit_word(con.suit),
					con.min,
					con.max,
				)
				first = false
			}
			for h in args.held {
				fmt.wprintf(sink.out, "%s %v holds %s", " " if first else ",", h.seat, deal_solve.card_word(h.card))
				first = false
			}
			fmt.wprintln(sink.out, ")")
		}
	}
}

// The green "honest verdict" rung: the whole-hand simulated make-%, plus a reconciliation strip showing
// the ceiling -> blind -> simulated tax as the gap between the three E[total] numbers.
print_sample_verdict :: proc(
	w: io.Writer,
	a: ^combo.Deal_Analysis,
	sd: ^combo.Sd_Bundle,
	s: ^deal_solve.Sample_Result,
	auto_contract: bool,
	tax: deal_solve.Tax_Result,
	tax_ok: bool,
	leads: ^deal_solve.Lead_Grids,
	side: bit_set[norn.Seat],
	contract: deal_solve.Contract,
) {
	label := deal_solve.contract_label(deal_solve.Contract{level = s.level, strain = s.strain}) // temp-allocated
	fmt.wprintln(w, "\nWhole-hand (simulated) — the honest whole-deal verdict:")
	if auto_contract {
		fmt.wprintfln(w, "  (no --contract given; auto-picked %s = best expected score over the sample)", label)
	}
	fmt.wprintfln(
		w,
		"  %s makes %.0f%% (+/-%.0f%%, %d deals)   ·   E[tricks] simulated %.2f",
		label,
		s.make_pct,
		s.stderr_pct,
		s.n,
		s.mean_tricks,
	)
	// D. Worst opening lead: the defender card that beats the contract most often, over the already-sampled
	// lead sub-grids. Only surfaced when it costs something material vs the baseline (a killing lead worth
	// warning about); a rare lead's sub-sample `n` is shown so its wider ± is honest.
	if leads != nil {
		if card, wpct, wn, base_pct, ok := deal_solve.worst_lead(leads, contract, side); ok && base_pct - wpct >= 3 {
			fmt.wprintfln(
				w,
				"  Worst opening lead: %s -> %.0f%% (vs %.0f%% average, %d deals) — plan for it.",
				deal_solve.card_word(card),
				wpct,
				base_pct,
				wn,
			)
		}
	}
	// The achievable (misguess-tax) rung: the ceiling docked by the dominant blind two-way guess. Only
	// shown when the estimator ran AND found a guess to tax; a guess-free board's achievable == ceiling,
	// so the extra line would just repeat the headline.
	if tax_ok && tax.n_pivots > 0 {
		fmt.wprintfln(
			w,
			"  achievable (blind play) %.0f%%   ·   taxed %.0f pts by the %s guess",
			tax.achievable_pct,
			tax.tax_pts,
			deal_solve.card_word(tax.pivots[0].card),
		)
	}
	fmt.wprintln(w, "  reconciliation:")
	fmt.wprintfln(w, "    naive ceiling %.2f (DD census)", combo.expected_tricks(a.total))
	fmt.wprintfln(w, "    naive blind   %.2f (SD census)", combo.expected_tricks(sd.totsd))
	fmt.wprintfln(w, "    simulated     %.2f (DDS whole-hand)", s.mean_tricks)
	fmt.wprintln(w, "  (per-layout double-dummy census: a ceiling that already bakes in entries/squeezes/tempo per")
	fmt.wprintln(w, "   solve — far tighter than combo's per-suit sums; achievable docks it for the blind guess.")
	fmt.wprintln(w, "   See COMBO_ANALYSER.md Track 2.)")
}

// A. Winner/loser count + trick gap (aids plan A). Guaranteed top tricks = the sum of each suit's
// recommended-line FLOOR (`combo.sure_tricks` — the tricks every E/W split concedes); the gap to `target`
// is what must be DEVELOPED. Develop-from suits are those whose best line AVERAGES more than its floor (a
// finesse/duck that gains when it works), ranked by that surplus. Pure combo data (floor + best-line
// mean), no DDS — a canonical winner/loser teaching count layered on the census.
print_winner_count :: proc(w: io.Writer, sd: ^combo.Sd_Bundle, target: int) {
	letters := [4]string{"S", "H", "D", "C"} // Sd_Bundle order is S H D C
	floors: [4]int
	means: [4]f64
	guaranteed := 0
	for i in 0 ..< 4 {
		floors[i] = combo.sure_tricks(sd.best_marg[i].p)
		means[i] = combo.expected_tricks(sd.best_marg[i].p)
		guaranteed += floors[i]
	}

	fmt.wprintf(w, "\nTop tricks (guaranteed): %d  (", guaranteed)
	for i in 0 ..< 4 {
		fmt.wprintf(w, "%s%s%d", " " if i > 0 else "", letters[i], floors[i])
	}
	fmt.wprintln(w, ")")

	// No contract level in view (no --target / annotator) → just the count above; there is no gap to size.
	if target < 1 || target > 13 {
		return
	}
	gap := target - guaranteed
	if gap <= 0 {
		fmt.wprintfln(w, "  Need %d → already guaranteed; cash your top tricks.", target)
		return
	}

	// Rank the develop-from suits by surplus (best-line mean over its guaranteed floor), descending.
	order := [4]int{0, 1, 2, 3}
	for i in 1 ..< 4 {
		j := i
		for j > 0 && (means[order[j]] - f64(floors[order[j]])) > (means[order[j - 1]] - f64(floors[order[j - 1]])) {
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		}
	}

	fmt.wprintf(w, "  Need %d → develop %d more.", target, gap)
	any := false
	for oi in order {
		surplus := means[oi] - f64(floors[oi])
		if surplus < 0.05 {
			continue // no meaningful extra available by developing this suit
		}
		fmt.wprintf(w, "%s %s %s (+%.1f)", " Sources:" if !any else " ·", letters[oi], sd.best_name[oi], surplus)
		any = true
	}
	if !any {
		fmt.wprint(w, "  No suit develops extra tricks — the gap needs tempo/entries the naive model can't see.")
	}
	fmt.wprintln(w)
}

// B. Suit-combination odds per line (aids plan B). For each suit that carries a real DECISION (a named
// pattern, or candidate lines whose means genuinely differ), list the distinct lines with their
// decision-relevant odds: E[tricks] and the chance of REACHING the extra trick over the line's guaranteed
// floor. The pattern note (combo `combination_note`) names the standard combination and mirrors the blind
// two-way guess the misguess tax prices. Pure combo data — no DDS.
print_combination_odds :: proc(w: io.Writer, advice: [4]combo.Suit_Combo_Advice) {
	letters := [4]string{"S", "H", "D", "C"} // DISPLAY_SUITS / Sd_Bundle order
	header := false
	for i in 0 ..< 4 {
		ad := advice[i]
		if !combination_is_decision(ad) {
			continue // a solid/void suit or one with a single dominant line — nothing to weigh up
		}
		if !header {
			fmt.wprintln(w, "\nSuit combinations (per-line odds — the guess each line hinges on):")
			header = true
		}
		fmt.wprintf(w, "  %s", letters[i])
		if ad.note != "" {
			fmt.wprintf(w, "   [%s]", ad.note)
		}
		fmt.wprintln(w)

		// Emit each DISTINCT candidate once, highest mean first. Duplicate distributions (finesse ==
		// finesse-other on a one-way holding) collapse to a single line. cands is tiny (<= N_CANDIDATE_LINES),
		// so the repeated linear scans cost nothing. `pivotal` = the extra trick over this line's guaranteed
		// floor (what it is playing FOR); its reach % is the odds the line hinges on.
		done: [combo.N_CANDIDATE_LINES]bool
		emitted: [combo.N_CANDIDATE_LINES]bool
		for _ in 0 ..< len(ad.cands) {
			pick := -1
			for ls, j in ad.cands {
				if done[j] {
					continue
				}
				if pick < 0 || ls.mean > ad.cands[pick].mean {
					pick = j
				}
			}
			if pick < 0 {
				break
			}
			done[pick] = true
			ls := ad.cands[pick]
			dup := false
			for j in 0 ..< len(ad.cands) {
				if emitted[j] && abs(ad.cands[j].mean - ls.mean) < 1e-3 && ad.cands[j].floor == ls.floor {
					dup = true
					break
				}
			}
			if dup {
				continue // a near-identical line is already shown for this suit
			}
			emitted[pick] = true
			piv := ls.floor + 1
			if piv <= ls.dist.max_tricks && combo.p_reach(ls.dist.p, piv) < 0.999 {
				fmt.wprintfln(
					w,
					"      %-16s E %.2f  ·  %.0f%% to reach %d",
					ls.name,
					ls.mean,
					100 * combo.p_reach(ls.dist.p, piv),
					piv,
				)
			} else {
				fmt.wprintfln(w, "      %-16s E %.2f  ·  guaranteed %d", ls.name, ls.mean, ls.floor)
			}
		}
	}
}

// A suit is worth a combination block when it names a standard pattern OR its candidate lines' means
// genuinely differ (a real choice between lines) — not a solid runner or a void where every line coincides.
combination_is_decision :: proc(ad: combo.Suit_Combo_Advice) -> bool {
	if ad.note != "" {
		return true
	}
	lo, hi := 99.0, -1.0
	for ls in ad.cands {
		lo = min(lo, ls.mean)
		hi = max(hi, ls.mean)
	}
	return hi - lo > 0.10
}

// C. Safety play / min-variance line (aids plan C). Where a suit's best line BY MEAN differs from its best
// line BY FLOOR — the high-mean line risks tricks the safety line locks in — show the trade. C3: if the
// tricks guaranteed ELSEWHERE plus this suit's safety floor already meet `target`, say so — you don't need
// the overtrick, so take the safety line. Pure combo data.
print_safety :: proc(w: io.Writer, advice: [4]combo.Suit_Combo_Advice, target: int) {
	letters := [4]string{"S", "H", "D", "C"}
	// Total guaranteed across suits from the best-by-mean lines (same basis as the winner count).
	total_floor := 0
	for i in 0 ..< 4 {
		ad := advice[i]
		total_floor += ad.cands[ad.best_mean_idx].floor
	}
	header := false
	for i in 0 ..< 4 {
		ad := advice[i]
		mean_line := ad.cands[ad.best_mean_idx]
		floor_line := ad.cands[ad.best_floor_idx]
		if ad.best_mean_idx == ad.best_floor_idx || floor_line.floor <= mean_line.floor {
			continue // no distinct safety line, or it guarantees no more than the max-mean line
		}
		// GATE (aids plan C): the cheap candidate-line floors are pessimistic — the generic finesse plays
		// mechanically and can throw a trick optimal play would keep (e.g. AKJ98: `finesse` floors at 1,
		// but cashing A K then finessing floors at 2). That is NOT a real safety trade. Verify with the
		// OPTIMAL blind-line search: only a genuine trade when even the mean-maximising line's own floor
		// falls short of the safety floor. When the exact search overflows we can't verify, so stay silent.
		opt, exact := combo.sd_optimal_distribution(ad.north_holding, ad.south_holding)
		opt_floor := combo.sure_tricks(opt.p)
		if !exact || opt_floor >= floor_line.floor {
			continue // optimal play already secures the safety floor (or unverifiable) — no real trade
		}
		if !header {
			fmt.wprintln(w, "\nSafety plays (most tricks vs guaranteed floor):")
			header = true
		}
		fmt.wprintfln(
			w,
			"  %s  max: %s (E %.2f, but %d if it loses)  ·  safety: %s (guaranteed %d)",
			letters[i],
			mean_line.name,
			mean_line.mean,
			opt_floor, // honest downside: the best max-expectation line's guaranteed floor, not the mechanical one
			floor_line.name,
			floor_line.floor,
		)
		if target >= 1 && target <= 13 {
			elsewhere := total_floor - mean_line.floor
			if elsewhere + floor_line.floor >= target {
				fmt.wprintfln(
					w,
					"       -> %d guaranteed elsewhere + %d here = %d >= %d: take the safety line, you don't need the overtrick.",
					elsewhere,
					floor_line.floor,
					elsewhere + floor_line.floor,
					target,
				)
			}
		}
	}
}

// A cheap "where do I start" sketch (PROTOTYPE). Rank the four suits by their single-dummy expected
// tricks (trick-source strength) and tag each recommended line's role — cash / finesse-guess /
// duck-develop — then point trick 1 at the strongest suit that must be DEVELOPED, since finesses and
// ducks want to happen early (while entries and trump control hold) whereas sure winners can wait.
//
// This is a per-suit HEURISTIC built entirely from combo data (no DDS solves). It is NOT a sound
// whole-hand line: a correct blind plan is the PIMC problem — expensive, and it undershoots (Monte-
// Carlo single-dummy suffers strategy fusion; see COMBO_ANALYSER.md), so the honest whole-hand number
// stays the simulated verdict. Read this as a starting pointer, not a play engine.
print_priority_sketch :: proc(w: io.Writer, sd: ^combo.Sd_Bundle) {
	letters := [4]string{"S", "H", "D", "C"} // Sd_Bundle order is S H D C
	means: [4]f64
	for i in 0 ..< 4 {
		means[i] = combo.expected_tricks(sd.best_marg[i].p)
	}
	// Order the suit indices by expected tricks, descending (insertion sort; only four elements).
	order := [4]int{0, 1, 2, 3}
	for i in 1 ..< 4 {
		j := i
		for j > 0 && means[order[j]] > means[order[j - 1]] {
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		}
	}

	fmt.wprintln(w, "\nSuit-priority sketch (naive heuristic — where to start, not a whole-hand plan):")
	develop_best := -1
	develop_best_mean := -1.0
	for oi in order {
		role, develop := line_role(sd.best_name[oi])
		fmt.wprintfln(w, "  %s  ~%.1f tricks   %-17s (%s)", letters[oi], means[oi], role, sd.best_name[oi])
		if develop && means[oi] > develop_best_mean {
			develop_best, develop_best_mean = oi, means[oi]
		}
	}
	if develop_best >= 0 {
		fmt.wprintfln(
			w,
			"  Trick 1: start %s — it must be developed (finesse/duck), so do it early while entries hold;",
			letters[develop_best],
		)
		fmt.wprintln(w, "           cash your solid winners later.")
	} else {
		fmt.wprintln(w, "  Trick 1: cash your winners top-down — no suit needs an early guess.")
	}
	fmt.wprintln(w, "  (Naive per-suit ordering; the honest whole-hand number is the simulated verdict.)")
}

// Classify a combo single-dummy line name into a human role phrase and whether it needs DEVELOPING
// (a finesse to guess or a duck to concede — do early) vs a solid cash (can wait).
line_role :: proc(name: string) -> (role: string, develop: bool) {
	switch {
	case strings.has_prefix(name, "finesse"):
		return "finesse - guess", true
	case strings.has_prefix(name, "duck"), name == "ducking":
		return "develop by duck", true
	case name == "top-down":
		return "cash top winners", false
	}
	return name, false
}

// F. Entry / timing warnings (LEARNER_AIDS_PLAN.md F) — a CRUDE, clearly-flagged heuristic. The naive
// model assumes FREE ENTRIES; this partly walks that back by warning when a suit's recommended finesse
// must be led from one hand more than once (a REPEATED finesse) but that hand has too few outside
// entries to get back there for each attempt. It is NOT a real entry analysis (that needs the whole-hand
// play): the entry count under-reads (high cards only, no ruffing/long-card entries), so the check is
// conservative and printed under a loud HEURISTIC banner. Combo geometry only — no DDS.
print_entry_warnings :: proc(
	w: io.Writer,
	sd: ^combo.Sd_Bundle,
	advice: [4]combo.Suit_Combo_Advice,
	side: bit_set[norn.Seat],
) {
	letters := [4]string{"S", "H", "D", "C"} // Sd_Bundle / advice order is S H D C
	ns := side == combo.NS_SIDE
	seat_name := [2]string{ns ? "North" : "East", ns ? "South" : "West"} // [SEAT_N slot, SEAT_S slot]
	north_suits, south_suits: [4]u16
	for i in 0 ..< 4 {
		north_suits[i] = advice[i].north_holding
		south_suits[i] = advice[i].south_holding
	}

	header := false
	for i in 0 ..< 4 {
		if !strings.has_prefix(sd.best_name[i], "finesse") {
			continue // only a finesse creates a repeated-lead entry demand; cashes lead from anywhere
		}
		n, s := advice[i].north_holding, advice[i].south_holding
		needed := combo.finesse_leads_needed(n, s)
		if needed < 2 {
			continue // a single finesse rarely has an entry problem; only flag a REPEATED finesse
		}
		lead_seat := combo.finesse_leading_seat(n, s)
		hand_suits := north_suits if lead_seat == combo.SEAT_N else south_suits
		entries := combo.sure_side_entries(hand_suits, i)
		if entries >= needed - 1 {
			continue // enough outside entries to return to the leading hand for each repeat
		}
		if !header {
			fmt.wprintln(w, "\nEntry / timing check (HEURISTIC — the naive model assumes free entries):")
			header = true
		}
		who := seat_name[0] if lead_seat == combo.SEAT_N else seat_name[1]
		fmt.wprintfln(
			w,
			"  %s  the finesse is led from %s and wants ~%d leads there, but %s has only %d outside entr%s — repeating it may fail (an entry problem the free-entry model ignores).",
			letters[i],
			who,
			needed,
			who,
			entries,
			"y" if entries == 1 else "ies",
		)
	}
}

// Print the census table plus a single-dummy summary for the analysed partnership. When `sim_total`
// is set (sampling ran), the caveat names the whole-hand simulated E[total] as the honest cross-check
// and the gap below the naive blind sum — instead of the "no DDS par to cross-check" wording, which
// only holds when sampling is off.
print_report :: proc(
	w: io.Writer,
	a: ^combo.Deal_Analysis,
	sd: ^combo.Sd_Bundle,
	advice: [4]combo.Suit_Combo_Advice,
	side: bit_set[norn.Seat],
	target: int,
	sim_total: Maybe(f64) = nil,
) {
	side_name := side == combo.NS_SIDE ? "N/S" : "E/W"
	fmt.wprintfln(w, "Card-combination analysis for %s (declarer + dummy); defenders unknown.\n", side_name)

	// Double-dummy census table (the trick ceiling). format_analysis allocates from context.allocator.
	table := combo.format_analysis(a, target)
	defer delete(table)
	fmt.wprintln(w, "Double-dummy census (naive per-suit ceiling):")
	fmt.wprintln(w, table)

	// Headline make chances at the target, DD ceiling vs SD achievable.
	dd_make := combo.p_at_least(a.total, target)
	sd_make := sd.atl[clamp(target, 0, len(sd.atl) - 1)]
	fmt.wprintfln(
		w,
		"\nP(>= %d tricks):  DD ceiling %.1f%%   ·   SD achievable %.1f%%",
		target,
		dd_make * 100,
		sd_make * 100,
	)
	fmt.wprintfln(
		w,
		"E[total tricks]:  DD %.2f   ·   SD %.2f",
		combo.expected_tricks(a.total),
		combo.expected_tricks(sd.totsd),
	)

	// Per-suit recommended single-dummy line (best-by-mean) + its expected tricks.
	fmt.wprintln(w, "\nRecommended single-dummy line, per suit:")
	suits := [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs} // Sd_Bundle order is S H D C
	letters := [4]string{"S", "H", "D", "C"}
	for suit, idx in suits {
		fmt.wprintfln(
			w,
			"  %s  %-14s  E[tricks] DD %.2f · SD %.2f",
			letters[idx],
			sd.best_name[idx],
			combo.expected_tricks(a.suits[suit].p),
			combo.expected_tricks(sd.best_marg[idx].p),
		)
	}
	print_winner_count(w, sd, target)
	print_combination_odds(w, advice)
	print_safety(w, advice, target)
	print_priority_sketch(w, sd)
	print_entry_warnings(w, sd, advice, side)

	fmt.wprintln(w, "\nNote: the naive model assumes free entries and independent suits, so totals are an upper")
	if st, ok := sim_total.?; ok {
		blind := combo.expected_tricks(sd.totsd)
		fmt.wprintln(w, "bound (no tempo race, no squeezes/endplays). The whole-hand DDS simulation below is the")
		fmt.wprintfln(
			w,
			"honest cross-check: %.2f tricks vs this naive %.2f blind sum — the %.2f-trick gap is the over-count.",
			st,
			blind,
			blind - st,
		)
	} else {
		fmt.wprintln(w, "bound (no tempo race, no squeezes/endplays). With only two hands there is no DDS par to")
		fmt.wprintln(w, "cross-check it against. See COMBO_ANALYSER.md.")
	}
}
