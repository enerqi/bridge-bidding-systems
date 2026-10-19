// DDS in the player: the solver's wasm module (build.py) opened with do-nothing WASI imports, and the two calls
// the player makes of it - a whole deal's double-dummy trick table, and every position of a recorded play
// solved card by card (`solve`). Plain script, no module syntax: the
// player inlines it into its page and into its DDS worker, and check.mjs evaluates it in node.
//
// `cards` is DDS's `ddTableDeal`: 16 u32, [hand N,E,S,W][suit S,H,D,C], rank r (2..14) as bit r. The result is
// DDS's `ddTableResults.resTable`: 20 i32, [strain S,H,D,C,NT][hand N,E,S,W], tricks for that declarer.
async function ddsStart(module) {
	let memory = null;
	const view = () => new DataView(memory.buffer);
	const wasi = {
		fd_write: (fd, iovs, count, written) => {
			let n = 0;
			for (let i = 0; i < count; i++) n += view().getUint32(iovs + 8 * i + 4, true);
			view().setUint32(written, n, true);
			return 0;
		},
		environ_sizes_get: (count, size) => { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return 0; },
		environ_get: () => 0,
		fd_close: () => 0, fd_fdstat_get: () => 8, fd_read: () => 8, fd_seek: () => 8,
		proc_exit: (code) => { throw new Error("DDS stopped (" + code + ")"); },
	};
	const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi });
	const dds = instance.exports;
	memory = dds.memory;
	dds._initialize();
	// One thread, and DDS's small transposition table (~25-48 MB in all): the large one measured no faster on
	// whole tables. Below ~23 MB DDS gives itself no thread at all.
	dds.SetResources(50, 1);
	const deal = dds.malloc(64), results = dds.malloc(80);
	const position = dds.malloc(96), future = dds.malloc(216);
	return {
		table(cards) {
			new Uint32Array(memory.buffer, deal, 16).set(cards);
			const status = dds.CalcDDtable(deal, results); // a struct by value is passed by pointer on wasm32
			if (status !== 1) throw new Error("DDS could not solve the deal (" + status + ")");
			return new Int32Array(memory.buffer, results, 20).slice();
		},
		// `count` positions, each DDS's `deal` struct (96 bytes, back to back in `positions`), solved for every
		// legal card with its score (`SolveBoard` target -1, solutions 3, mode 1: `replay`'s DDS_* constants).
		// The answers are DDS's `futureTricks`, 216 bytes each, back to back. With `playout` (the record stops
		// before the last card, and the last position is the one after it), the play then goes on to the last
		// card double dummy, one solve a card - `replay.playout_play`'s steps - and its cards follow the answers,
		// two bytes each (DDS's suit 0-3 and rank 2-14).
		solve(positions, count, playout) {
			const answers = new Uint8Array(216 * count), cards = [];
			const ask = () => {
				const status = dds.SolveBoard(position, -1, 3, 1, future, 0);
				if (status !== 1) throw new Error("DDS could not solve a position (" + status + ")");
			};
			for (let i = 0; i < count; i++) {
				new Uint8Array(memory.buffer, position, 96).set(positions.subarray(96 * i, 96 * i + 96));
				ask();
				answers.set(new Uint8Array(memory.buffer, future, 216), 216 * i);
			}
			if (playout && count > 0) {
				// `position` still holds the last position and `future` its answer.
				for (;;) {
					const [suit, rank] = playoutCard(new Int32Array(memory.buffer, future, 54));
					if (suit < 0) break;
					cards.push(suit, rank);
					if (!playCard(new Int32Array(memory.buffer, position, 24), suit, rank)) break;
					ask();
				}
			}
			const out = new Uint8Array(answers.length + cards.length);
			out.set(answers);
			out.set(cards, answers.length);
			return out;
		},
	};
}

// The card the play-out plays where DDS answered `f` (`futureTricks` as 54 i32: nodes, cards, suit[13],
// rank[13], equals[13], score[13]): among the best-scored cards the first suit in DDS's order and its highest
// card - `replay.playout_card`'s rule. [-1, 0] when there is none.
function playoutCard(f) {
	const n = Math.max(0, Math.min(13, f[1])), SUIT = 2, RANK = 15, SCORE = 41;
	let max = -1, best = -1;
	for (let i = 0; i < n; i++) max = Math.max(max, f[SCORE + i]);
	if (max < 0) return [-1, 0];
	for (let i = 0; i < n; i++) {
		const suit = f[SUIT + i], rank = f[RANK + i];
		if (f[SCORE + i] !== max || suit < 0 || suit > 3 || rank < 2 || rank > 14) continue;
		if (best < 0 || suit < f[SUIT + best] || (suit === f[SUIT + best] && rank > f[RANK + best])) best = i;
	}
	return best < 0 ? [-1, 0] : [f[SUIT + best], f[RANK + best]];
}

// Play DDS's card (suit 0-3, rank 2-14) at the position `d` (DDS's `deal` as 24 i32: trump, first,
// currentTrickSuit[3], currentTrickRank[3], remainCards[hand][suit]) by the hand on play: the card leaves the
// hand, joins the trick, and a fourth card gives the trick to its winner, who leads next. False once no card
// is left (the play-out is over: nothing more to solve).
function playCard(d, suit, rank) {
	const TRUMP = 0, FIRST = 1, TSUIT = 2, TRANK = 5, REMAIN = 8;
	let k = 0;
	while (k < 3 && d[TRANK + k] !== 0) k++;
	const hand = (d[FIRST] + k) % 4;
	d[REMAIN + 4 * hand + suit] &= ~(1 << rank);
	if (k < 3) {
		d[TSUIT + k] = suit;
		d[TRANK + k] = rank;
	} else {
		const suits = [d[TSUIT], d[TSUIT + 1], d[TSUIT + 2], suit], ranks = [d[TRANK], d[TRANK + 1], d[TRANK + 2], rank];
		let win = 0;
		for (let j = 1; j < 4; j++) {
			const trumps = suits[j] === d[TRUMP], winTrumps = suits[win] === d[TRUMP];
			if ((trumps && !winTrumps) || (suits[j] === suits[win] && ranks[j] > ranks[win])) win = j;
		}
		d[FIRST] = (d[FIRST] + win) % 4;
		for (let j = 0; j < 3; j++) d[TSUIT + j] = d[TRANK + j] = 0;
	}
	for (let i = 0; i < 16; i++) if (d[REMAIN + i] !== 0) return true;
	return false;
}
