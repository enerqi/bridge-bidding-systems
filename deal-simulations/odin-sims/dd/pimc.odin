package dd

/*
	pimc.odin — SPIKE: an achievable single-dummy make-% for the 2-hand advisor, via PIMC play-out.

	Purpose (COMBO_ANALYSER.md "★ 2-hand advisor", NOT-DONE #1). sample.odin's make-% is a per-layout
	DOUBLE-DUMMY census: every sampled layout is solved with declarer PEEKING at the defenders, so the
	aggregate is a CEILING. The honest achievable number is lower — declarer must play ONE blind policy
	across all layouts (a whole-deal POMDP). The industry-standard estimator of that is PIMC (Perfect-
	Information Monte-Carlo, what GIB/Jack do): at each of declarer's own decisions, sample K layouts
	consistent with what declarer can see, double-dummy-solve each, and vote the card with the best mean
	outcome. Defenders here play DOUBLE-DUMMY in the true world (they "peek") — a conservative LOWER bound
	on declarer's achievable, the agreed first cut. Real defenders misdefend too, so the true achievable
	sits between this and the ceiling.

	THIS IS A SPIKE, not the shipped path. It exists to MEASURE two things before committing the
	production engine + bake + UI (see the decision the doc calls for):
	  1. cost — wall-time per board (PIMC is ~N*(13K+13) solves/board; sample.odin's ceiling is 1/layout),
	  2. gap — how far the PIMC make-% drops below the DDS ceiling (is the honesty worth the cost?).
	`pimc_test.odin` runs one representative board and logs both, next to sample.odin's ceiling.

	Model / conventions reused from dd.odin + sample.odin:
	  - DDS `SolveBoard` scores the side ON LEAD (`first`): `score` = tricks for the leader's side from the
	    current (possibly mid-trick) position to the end (see `declarer_makes`). So the player to move wants
	    to MAXIMISE `score` iff it is on the leader's side, else MINIMISE it (`want_max` below).
	  - solutions=.All returns one representative per equivalence class with `equals` (the tied ranks); we
	    fan a class's score onto every one of the mover's cards it covers, so every legal card gets a value.
	  - suit/rank mappings: dds.Suit = 3 - norn.Suit; dds rank value = int(norn.Rank) + 2 (deuce=2..ace=14).

	Single-threaded, like every DDS call here (DDS shares process-global transposition tables).
*/

import "core:math"
import "core:math/rand"

import dds "dds:."
import "norn:norn"

// A set of cards by their 0..51 encoding — the per-seat "remaining in hand" during a play-out.
Card_Set :: bit_set[0 ..< norn.DECK_SIZE;u64]

// The result of a PIMC play-out sweep: `n` completed play-outs (outer true worlds), how many made the
// contract, the make-%, its binomial ± , the mean declarer tricks, and `solves` (total SolveBoard calls
// — the cost knob the spike is measuring).
Pimc_Result :: struct {
	n:           int,
	make_count:  int,
	make_pct:    f64,
	stderr_pct:  f64,
	mean_tricks: f64,
	solves:      int,
}

// One card played to the current trick, tagged with its player (needed to score/lead the next trick).
Play :: struct {
	seat: norn.Seat,
	card: norn.Card,
}

@(private = "file")
hand_to_set :: proc(h: norn.Hand) -> (s: Card_Set) {
	for c in h {
		s += {int(c)}
	}
	return
}

@(private = "file")
set_count :: proc(s: Card_Set) -> (n: int) {
	for i in 0 ..< norn.DECK_SIZE {
		if i in s {
			n += 1
		}
	}
	return
}

// Build the DDS `Deal` for the position: trump, the trick leader, the cards already played to the current
// trick (removed from `rem`), and every seat's remaining holding. Mirrors to_table_deal's encoding but from
// a live Card_Set rather than a full norn.Deal.
@(private = "file")
build_deal :: proc(
	trump: dds.Strain,
	leader: norn.Seat,
	trick: []Play,
	rem: [norn.Seat]Card_Set,
) -> dds.Deal {
	dl: dds.Deal
	dl.trump = trump
	dl.first = dds.Hand(int(leader))
	for p, i in trick {
		dl.currentTrickSuit[i] = dds.Suit(3 - int(norn.card_suit(p.card)))
		dl.currentTrickRank[i] = i32(int(norn.card_rank(p.card)) + 2)
	}
	masks: [norn.Seat][norn.Suit]u32
	for seat in norn.Seat {
		for i in 0 ..< norn.DECK_SIZE {
			if i not_in rem[seat] {
				continue
			}
			card := norn.Card(i)
			masks[seat][norn.card_suit(card)] |= u32(1) << u32(int(norn.card_rank(card)) + 2)
		}
	}
	for seat in norn.Seat {
		for suit in norn.Suit {
			dl.remainCards[dds.Hand(int(seat))][dds.Suit(3 - int(suit))] = transmute(dds.Holding)masks[seat][suit]
		}
	}
	return dl
}

// True iff `seat` and `leader` are the same partnership — the mover then wants to MAXIMISE the solved
// `score` (leader-side tricks), otherwise minimise it.
@(private = "file")
same_side :: proc(a, b: norn.Seat) -> bool {
	ab := bit_set[norn.Seat]{a, b}
	return ab == {.North, .South} || ab == {.East, .West} || a == b
}

// The mover's legal cards from `hand`: must follow `led` if it holds any of that suit, else anything.
@(private = "file")
legal_cards :: proc(hand: Card_Set, led: norn.Suit, has_led: bool) -> (out: [dynamic]norn.Card) {
	if has_led {
		any_of_led := false
		for i in 0 ..< norn.DECK_SIZE {
			if i in hand && norn.card_suit(norn.Card(i)) == led {
				any_of_led = true
				break
			}
		}
		if any_of_led {
			for i in 0 ..< norn.DECK_SIZE {
				if i in hand && norn.card_suit(norn.Card(i)) == led {
					append(&out, norn.Card(i))
				}
			}
			return
		}
	}
	for i in 0 ..< norn.DECK_SIZE {
		if i in hand {
			append(&out, norn.Card(i))
		}
	}
	return
}

// True iff `s` is the trump suit of `trump` (never for NT). dds.Suit = 3 - norn.Suit.
@(private = "file")
is_trump :: proc(trump: dds.Strain, s: norn.Suit) -> bool {
	return int(trump) < 4 && int(dds.Suit(3 - int(s))) == int(trump)
}

// The trick winner given trump and the four (or fewer) plays. Highest trump if any trump played, else
// highest card of the led suit.
@(private = "file")
trick_winner :: proc(trump: dds.Strain, trick: []Play) -> norn.Seat {
	led := norn.card_suit(trick[0].card)
	best := trick[0]
	for p in trick[1:] {
		bs, ps := norn.card_suit(best.card), norn.card_suit(p.card)
		if is_trump(trump, ps) && !is_trump(trump, bs) {
			best = p
		} else if ps == bs {
			if int(norn.card_rank(p.card)) > int(norn.card_rank(best.card)) {
				best = p
			}
		} else if ps == led && bs != led && !is_trump(trump, bs) {
			best = p
		}
	}
	return best.seat
}

// Deal the two defenders' pooled unknown cards into a random split consistent with declarer's public
// information: each defender's remaining COUNT is known (card-counting), and any suit a defender has shown
// out of is a void it cannot receive. Reject-samples a valid split. ok=false if none found in budget
// (should not happen for reachable positions).
@(private = "file")
sample_defenders :: proc(
	pool: Card_Set,
	d0, d1: norn.Seat,
	n0, n1: int,
	void: [norn.Seat][norn.Suit]bool,
) -> (
	s0, s1: Card_Set,
	ok: bool,
) {
	cards: [dynamic]norn.Card
	defer delete(cards)
	for i in 0 ..< norn.DECK_SIZE {
		if i in pool {
			append(&cards, norn.Card(i))
		}
	}
	if len(cards) != n0 + n1 {
		return {}, {}, false
	}
	REJECT_BUDGET :: 400
	for _ in 0 ..< REJECT_BUDGET {
		rand.shuffle(cards[:])
		a, b: Card_Set
		ca, cb := 0, 0
		bad := false
		for card in cards {
			suit := norn.card_suit(card)
			// Place in d0 while it has room and is not void in the suit; else d1; else this shuffle fails.
			if ca < n0 && !void[d0][suit] {
				a += {int(card)}
				ca += 1
			} else if cb < n1 && !void[d1][suit] {
				b += {int(card)}
				cb += 1
			} else {
				bad = true
				break
			}
		}
		if !bad && ca == n0 && cb == n1 {
			return a, b, true
		}
	}
	return {}, {}, false
}

// Add one class's score to a single card of `hand` (ignoring ranks outside 2..14 or cards not held).
@(private = "file")
add_rank :: proc(
	suit: norn.Suit,
	rankval: int,
	hand: Card_Set,
	score: f64,
	acc: ^[norn.DECK_SIZE]f64,
	cnt: ^[norn.DECK_SIZE]int,
) {
	r := rankval - 2
	if r < 0 || r > 12 {
		return
	}
	card := norn.make_card(suit, norn.Rank(r))
	if int(card) in hand {
		acc[int(card)] += score
		cnt[int(card)] += 1
	}
}

// Score every legal card of the mover from one solved position, fanning each equivalence class's score
// onto all of the mover's cards it covers. `acc`/`cnt` are indexed by the card's 0..51 encoding.
@(private = "file")
accumulate :: proc(fut: dds.Future_Tricks, hand: Card_Set, acc: ^[norn.DECK_SIZE]f64, cnt: ^[norn.DECK_SIZE]int) {
	for j in 0 ..< int(fut.cards) {
		suit := norn.Suit(3 - int(fut.suit[j]))
		score := f64(fut.score[j])
		add_rank(suit, int(fut.rank[j]), hand, score, acc, cnt)
		eq := transmute(u32)fut.equals[j]
		for rv in 2 ..= 14 {
			if eq & (u32(1) << u32(rv)) != 0 {
				add_rank(suit, rv, hand, score, acc, cnt)
			}
		}
	}
}

// PIMC-choose the mover's card. Samples `k` defender worlds consistent with `void` + counts, solves each,
// and picks the mover's card with the best MEAN leader-side score (max if the mover is on the leader's
// side, else min). Returns the chosen card and the number of solves spent. Falls back to the sole legal
// card (0 solves) when there is no choice.
@(private = "file")
pimc_choose :: proc(
	trump: dds.Strain,
	leader: norn.Seat,
	trick: []Play,
	rem: [norn.Seat]Card_Set,
	mover: norn.Seat,
	defenders: [2]norn.Seat,
	void: [norn.Seat][norn.Suit]bool,
	legal: []norn.Card,
	k: int,
) -> (
	choice: norn.Card,
	solves: int,
) {
	if len(legal) == 1 {
		return legal[0], 0
	}
	pool := rem[defenders[0]] + rem[defenders[1]]
	n0, n1 := set_count(rem[defenders[0]]), set_count(rem[defenders[1]])
	want_max := same_side(mover, leader)

	acc: [norn.DECK_SIZE]f64
	cnt: [norn.DECK_SIZE]int
	for _ in 0 ..< k {
		s0, s1, ok := sample_defenders(pool, defenders[0], defenders[1], n0, n1, void)
		if !ok {
			continue
		}
		world := rem
		world[defenders[0]] = s0
		world[defenders[1]] = s1
		dl := build_deal(trump, leader, trick, world)
		fut: dds.Future_Tricks
		if dds.SolveBoard(dl, dds.TARGET_FIND_MAX, .All, .Auto, &fut) != .NO_FAULT {
			continue
		}
		solves += 1
		accumulate(fut, rem[mover], &acc, &cnt)
	}

	// Pick the best mean leader-side score. NB naive PIMC gives every DD-equivalent line the SAME value,
	// so a cashing winner and a passive concede tie — the blind declarer then procrastinates and bleeds
	// tricks (measured: a cold slam reads ~80%, not 100%). A trustworthy achievable needs a context-aware
	// play heuristic to break these ties (cash when cashing, duck when ducking); a single global tie-break
	// helps trump cash-outs but hurts NT, so it is NOT done here — this spike measures the PESSIMISTIC
	// floor and the cost, deliberately without that heuristic. See COMBO_ANALYSER.md for the finding.
	choice = legal[0]
	best := f64(0)
	have := false
	for card in legal {
		if cnt[int(card)] == 0 {
			continue
		}
		mean := acc[int(card)] / f64(cnt[int(card)])
		if !have || (want_max ? mean > best : mean < best) {
			best = mean
			choice = card
			have = true
		}
	}
	return choice, solves
}

// Double-dummy choice for a defender in the TRUE world: solve once, pick the defender's card that
// minimises declarer tricks (= min leader-side score if the leader is declarer, else max — `want_max`).
@(private = "file")
dd_choose :: proc(
	trump: dds.Strain,
	leader: norn.Seat,
	trick: []Play,
	rem: [norn.Seat]Card_Set,
	mover: norn.Seat,
	legal: []norn.Card,
) -> (
	choice: norn.Card,
	solves: int,
) {
	if len(legal) == 1 {
		return legal[0], 0
	}
	want_max := same_side(mover, leader)
	dl := build_deal(trump, leader, trick, rem)
	fut: dds.Future_Tricks
	if dds.SolveBoard(dl, dds.TARGET_FIND_MAX, .All, .Auto, &fut) != .NO_FAULT || fut.cards == 0 {
		return legal[0], 0
	}
	acc: [norn.DECK_SIZE]f64
	cnt: [norn.DECK_SIZE]int
	accumulate(fut, rem[mover], &acc, &cnt)
	choice = legal[0]
	best := f64(0)
	have := false
	for card in legal {
		if cnt[int(card)] == 0 {
			continue
		}
		v := acc[int(card)]
		if !have || (want_max ? v > best : v < best) {
			best = v
			choice = card
			have = true
		}
	}
	return choice, 1
}

// Play ONE outer true world to the end: PIMC declarer (declarer+dummy) vs double-dummy defenders. Returns
// the declaring side's trick count and the solves spent. `deal` is the full 52-card true world.
@(private = "file")
play_out :: proc(
	deal: norn.Deal,
	trump: dds.Strain,
	declarer: norn.Seat,
	side: bit_set[norn.Seat],
	k: int,
) -> (
	declarer_tricks: int,
	solves: int,
) {
	rem: [norn.Seat]Card_Set
	for seat in norn.Seat {
		rem[seat] = hand_to_set(deal[seat])
	}
	defs: [2]norn.Seat
	{
		i := 0
		for seat in norn.Seat {
			if seat not_in side {
				defs[i] = seat
				i += 1
			}
		}
	}
	void: [norn.Seat][norn.Suit]bool
	leader := norn.Seat((int(declarer) + 1) % 4) // opening leader = declarer's LHO

	for _ in 0 ..< 13 {
		trick: [dynamic]Play
		led: norn.Suit
		for i in 0 ..< 4 {
			mover := norn.Seat((int(leader) + i) % 4)
			has_led := i > 0
			if has_led {
				led = norn.card_suit(trick[0].card)
			}
			legal := legal_cards(rem[mover], led, has_led)
			card: norn.Card
			s: int
			if mover in side {
				card, s = pimc_choose(trump, leader, trick[:], rem, mover, defs, void, legal[:], k)
			} else {
				card, s = dd_choose(trump, leader, trick[:], rem, mover, legal[:])
			}
			solves += s
			// Record a show-out as a void for future PIMC sampling.
			if has_led && norn.card_suit(card) != led {
				void[mover][led] = true
			}
			rem[mover] -= {int(card)}
			append(&trick, Play{mover, card})
			delete(legal)
		}
		w := trick_winner(trump, trick[:])
		if w in side {
			declarer_tricks += 1
		}
		leader = w
		delete(trick)
	}
	return declarer_tricks, solves
}

// PIMC make-% for `contract` played by the known partnership `side`, over `n_outer` sampled true worlds
// (the unknown 26 dealt to the defenders, constrained to the known hands), each played out with a blind
// PIMC declarer (K worlds per decision) against double-dummy defenders. This is the achievable LOWER
// bound the spike measures against sample.odin's double-dummy ceiling. Call `init()` first.
pimc_make :: proc(
	board: norn.Parsed_Board,
	side: bit_set[norn.Seat],
	contract: Contract,
	n_outer: int,
	k_inner: int,
	seed: u64 = 0,
) -> (
	result: Pimc_Result,
	ok: bool,
) {
	a, b: norn.Seat
	if .North in side {
		a, b = .North, .South
	} else if .East in side {
		a, b = .East, .West
	} else {
		return {}, false
	}
	if (board.known & side) != side || n_outer <= 0 || k_inner <= 0 {
		return {}, false
	}

	pd: norn.Predeal
	for seat in ([2]norn.Seat{a, b}) {
		for i in 0 ..< norn.HAND_SIZE {
			norn.predeal_add(&pd, seat, board.deal[seat][i])
		}
	}
	if valid, _ := norn.predeal_validate(pd); !valid {
		return {}, false
	}

	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)

	// Declarer = the pair member who is stronger... the spike simply declares from `a` (North/East). The
	// picked declarer only sets the opening leader; best-of-pair declarer selection is a shipped-path
	// concern, not a cost/gap question.
	declarer := a
	need := contract.level + 6

	total_tricks := 0
	for _ in 0 ..< n_outer {
		world := norn.deal_board_predealt(pd)
		tricks, s := play_out(world, contract.strain, declarer, side, k_inner)
		result.solves += s
		total_tricks += tricks
		if tricks >= need {
			result.make_count += 1
		}
	}
	result.n = n_outer
	p := f64(result.make_count) / f64(n_outer)
	result.make_pct = p * 100
	result.stderr_pct = 100 * math.sqrt(p * (1 - p) / f64(n_outer))
	result.mean_tricks = f64(total_tricks) / f64(n_outer)
	return result, true
}
