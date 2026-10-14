// The spike's wasm harness, for node (bench.mjs) and a browser (bench.html) alike: instantiate dds.wasm with
// do-nothing WASI imports (DDS writes no files and reads no input while solving), then time CalcDDtable and
// SolveBoard over the deals deals.h describes. The checksums must equal bench_native's.
async function ddsBench(wasmBytes, tables, solves) {
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
		proc_exit: (code) => { throw new Error("DDS exited: " + code); },
	};
	const t0 = performance.now();
	const imports = { wasi_snapshot_preview1: wasi };
	const instance = wasmBytes instanceof WebAssembly.Module
		? await WebAssembly.instantiate(wasmBytes, imports)
		: (await WebAssembly.instantiate(wasmBytes, imports)).instance;
	const dds = instance.exports;
	memory = dds.memory;
	dds._initialize();
	dds.SetResources(globalThis.DDS_MB ?? 200, 1);
	const tInit = performance.now() - t0;

	let rng = 0;
	const next = () => { rng ^= rng << 13; rng >>>= 0; rng ^= rng >>> 17; rng ^= rng << 5; rng >>>= 0; return rng; };
	const dealInto = (pointer) => { // unsigned cards[4][4], at `pointer`
		const deck = Array.from({ length: 52 }, (_, i) => i);
		for (let i = 51; i > 0; i--) { const j = next() % (i + 1); [deck[i], deck[j]] = [deck[j], deck[i]]; }
		const cards = new Uint32Array(16);
		for (let i = 0; i < 52; i++) cards[Math.floor(i / 13) * 4 + Math.floor(deck[i] / 13)] |= 1 << (deck[i] % 13 + 2);
		new Uint32Array(memory.buffer, pointer, 16).set(cards);
	};

	const table = dds.malloc(64), results = dds.malloc(80);
	rng = 12345;
	let sum = 0;
	const t1 = performance.now();
	for (let k = 0; k < tables; k++) {
		dealInto(table);
		const status = dds.CalcDDtable(table, results); // a struct by value is passed by pointer on wasm32
		if (status !== 1) throw new Error("CalcDDtable failed: " + status);
		const r = new Int32Array(memory.buffer, results, 20);
		for (let s = 0; s < 5; s++) for (let h = 0; h < 4; h++) sum += r[s * 4 + h] * (s * 4 + h + 1);
	}
	const t2 = performance.now();
	const dl = dds.malloc(96), future = dds.malloc(216);
	rng = 777;
	let sum2 = 0;
	for (let k = 0; k < solves; k++) {
		new Int32Array(memory.buffer, dl, 8).set([4, 3, 0, 0, 0, 0, 0, 0]); // notrump, West leads, no trick started
		dealInto(dl + 32);
		const status = dds.SolveBoard(dl, -1, 1, 1, future, 0);
		if (status !== 1) throw new Error("SolveBoard failed: " + status);
		sum2 += new Int32Array(memory.buffer, future, 54)[2 + 13 * 3]; // score[0]
	}
	const t3 = performance.now();
	return {
		init: tInit,
		table: (t2 - t1) / tables, tables, sum,
		solve: (t3 - t2) / solves, solves, sum2,
		memoryMB: memory.buffer.byteLength / 1048576,
		text: `wasm: init ${tInit.toFixed(0)} ms; CalcDDtable ${((t2 - t1) / tables).toFixed(2)} ms each (${tables}, checksum ${sum}); ` +
			`SolveBoard ${((t3 - t2) / solves).toFixed(3)} ms each (${solves}, checksum ${sum2}); memory ${(memory.buffer.byteLength / 1048576).toFixed(0)} MB`,
	};
}
if (typeof module !== "undefined") module.exports = { ddsBench };
