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
		// The answers are DDS's `futureTricks`, 216 bytes each, back to back.
		solve(positions, count) {
			const out = new Uint8Array(216 * count);
			for (let i = 0; i < count; i++) {
				new Uint8Array(memory.buffer, position, 96).set(positions.subarray(96 * i, 96 * i + 96));
				const status = dds.SolveBoard(position, -1, 3, 1, future, 0);
				if (status !== 1) throw new Error("DDS could not solve a position (" + status + ")");
				out.set(new Uint8Array(memory.buffer, future, 216), 216 * i);
			}
			return out;
		},
	};
}
