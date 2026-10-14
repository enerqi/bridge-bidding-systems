// The player, held to the native pages: node player/check.mjs <player.wasm> <odin.js> <dir> [<golden_links.txt>]
// (`just sims test-player` runs it with everything).
//
// `<dir>` holds what `native` wrote: plain, analysed and par (.html / .txt), each page with
// the link fragment read back out of it. The wasm player renders each fragment, stepping board by board as
// the page does, and the result must be the page. Then every golden link must open (see the end).
import fs from "node:fs";
import path from "node:path";

const [wasmPath, odinJsPath, dir, goldenPath] = process.argv.slice(2);

// odin.js is written for a browser window and installs itself as `window.odin`.
globalThis.window = globalThis;
globalThis.document = { getElementById: () => null };
(0, eval)(fs.readFileSync(odinJsPath, "utf8"));

const memory = new odin.WasmMemoryInterface();
memory.setIntSize(4);
const imports = odin.setupDefaultImports(memory, null, memory.memory);
const { instance } = await WebAssembly.instantiate(fs.readFileSync(wasmPath), imports);
const wasm = instance.exports;
memory.setExports(wasm);
memory.setMemory(wasm.memory);
wasm._start();

const play = (fragment) => {
	const bytes = new TextEncoder().encode(fragment);
	const pointer = wasm.pl_alloc(bytes.length);
	new Uint8Array(wasm.memory.buffer, pointer, bytes.length).set(bytes);
	const boards = wasm.pl_open(pointer, bytes.length);
	if (boards < 0) return { error: -boards };
	while (wasm.pl_step() > 0);
	const length = wasm.pl_finish();
	return { boards, page: new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_result(), length).slice()) };
};

let failures = 0;
for (const name of ["plain", "analysed", "par", "played", "twohand"]) {
	const fragment = fs.readFileSync(path.join(dir, `${name}.txt`), "utf8");
	const want = fs.readFileSync(path.join(dir, `${name}.html`), "utf8");
	const t0 = performance.now();
	const got = play(fragment);
	const ms = performance.now() - t0;
	if (got.page === want) {
		console.log(`ok    ${name}: the link rebuilds the page (${got.boards} boards, ${fragment.length}-character link, ${ms.toFixed(0)}ms)`);
	} else {
		failures++;
		let i = 0;
		const page = got.page ?? "";
		while (i < Math.min(page.length, want.length) && page[i] === want[i]) i++;
		console.log(`FAIL  ${name}: differs at ${i} (error ${got.error ?? "-"})\n  wasm:   ${JSON.stringify(page.slice(i - 60, i + 60))}\n  native: ${JSON.stringify(want.slice(i - 60, i + 60))}`);
	}
}
// THE PAGE AT ONCE, ANALYSIS AFTER: what the published player does. The page without the analysis, plus each
// board's analysis put in where `pl_board_end` says, must be the same page byte for byte - so what the reader
// ends up with is what a generated file holds. (Bytes, not a string: offsets are UTF-8.)
const bytesOf = (pointer, length) => new Uint8Array(wasm.memory.buffer, pointer, length).slice();
for (const name of ["plain", "analysed", "par", "played", "twohand"]) {
	const fragment = new TextEncoder().encode(fs.readFileSync(path.join(dir, `${name}.txt`), "utf8"));
	const want = fs.readFileSync(path.join(dir, `${name}.html`));
	const pointer = wasm.pl_alloc(fragment.length);
	new Uint8Array(wasm.memory.buffer, pointer, fragment.length).set(fragment);
	const boards = wasm.pl_open(pointer, fragment.length);
	const t0 = performance.now();
	const plain = bytesOf(wasm.pl_result(), wasm.pl_plain());
	const shown = performance.now() - t0;
	const parts = [];
	let from = 0, pieces = 0;
	for (let i = 0; i < boards; i++) {
		const end = wasm.pl_board_end(i);
		const length = wasm.pl_analysis(i); // first: it may move the buffer `pl_piece` points at
		const piece = bytesOf(wasm.pl_piece(), length);
		if (piece.length) pieces++;
		parts.push(plain.subarray(from, end), piece);
		from = end;
	}
	parts.push(plain.subarray(from));
	const got = Buffer.concat(parts);
	if (got.equals(want)) {
		console.log(`ok    ${name}: shown at once (${shown.toFixed(0)}ms), then ${pieces} boards' analysis added - the same page`);
	} else {
		failures++;
		let i = 0;
		while (i < Math.min(got.length, want.length) && got[i] === want[i]) i++;
		console.log(`FAIL  ${name} (page first): differs at byte ${i}\n  lazy:   ${JSON.stringify(got.subarray(i - 60, i + 60).toString())}\n  native: ${JSON.stringify(want.subarray(i - 60, i + 60).toString())}`);
	}
}
// THE DOUBLE-DUMMY EXPLORER: every whole deal of the par page solved by DDS in WASM (`dds/`, through dds.js as
// the page uses it) and written by the player (`pl_table_deal` -> DDS -> `pl_tricks` -> `pl_exact`) must be the
// `.sim-exact` element the native advisor writes for that deal (`exact.txt`, native DDS). That holds the wasm
// solver to the native one AND the player's card layout to deal_solve's.
{
	(0, eval)(fs.readFileSync(new URL("./dds/dds.js", import.meta.url), "utf8"));
	const dds = await ddsStart(await WebAssembly.compile(fs.readFileSync(path.join(dir, "dds.wasm"))));
	const want = fs.readFileSync(path.join(dir, "exact.txt"), "utf8").split("\n");
	const fragment = new TextEncoder().encode(fs.readFileSync(path.join(dir, "par.txt"), "utf8"));
	const pointer = wasm.pl_alloc(fragment.length);
	new Uint8Array(wasm.memory.buffer, pointer, fragment.length).set(fragment);
	const boards = wasm.pl_open(pointer, fragment.length);
	let same = 0, ms = 0;
	for (let i = 0; i < boards; i++) {
		const deal = wasm.pl_table_deal(i);
		const t0 = performance.now();
		const tricks = dds.table(new Uint32Array(wasm.memory.buffer, deal, 16).slice());
		ms += performance.now() - t0;
		new Int32Array(wasm.memory.buffer, wasm.pl_tricks(), 20).set(tricks);
		const length = wasm.pl_exact(i); // first: it may move the buffer `pl_piece` points at
		const got = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_piece(), length).slice());
		if (got === want[i]) same++;
		else if (same + 1 > i) { failures++; console.log(`FAIL  board ${i + 1}'s exact grid:\n  wasm:   ${got.slice(0, 160)}\n  native: ${want[i].slice(0, 160)}`); }
	}
	if (same === boards) console.log(`ok    the double-dummy explorer: ${boards} whole deals solved by DDS in wasm (${(ms / boards).toFixed(0)}ms each) - the advisor's grids`);
	else { failures++; console.log(`FAIL  the double-dummy explorer: ${same} of ${boards} boards match`); }

	// RECORDED PLAY (`played`, a `v2.` link): the page at once with each play unsolved, then what every card cost -
	// each position solved by DDS in wasm one `SolveBoard` at a time (`pl_play_positions` -> DDS -> `pl_futures` ->
	// `pl_play`) - must be the `.play` element the native advisor writes from one batched native solve
	// (`play.txt`). The explorer on a played board names the contract played (`played-exact.txt`).
	const playFragment = new TextEncoder().encode(fs.readFileSync(path.join(dir, "played.txt"), "utf8"));
	const wantPlays = fs.readFileSync(path.join(dir, "play.txt"), "utf8").split("\n");
	const wantExacts = fs.readFileSync(path.join(dir, "played-exact.txt"), "utf8").split("\n");
	const at = wasm.pl_alloc(playFragment.length);
	new Uint8Array(wasm.memory.buffer, at, playFragment.length).set(playFragment);
	const played = wasm.pl_open(at, playFragment.length);
	let plays = 0, playsSame = 0, exactsSame = 0, positions = 0, playMs = 0;
	for (let i = 0; i < played; i++) {
		const count = wasm.pl_play_positions(i);
		if (count > 0) {
			plays++;
			positions += count;
			const t0 = performance.now();
			const futures = dds.solve(new Uint8Array(wasm.memory.buffer, wasm.pl_positions(), 96 * count).slice(), count);
			playMs += performance.now() - t0;
			new Uint8Array(wasm.memory.buffer, wasm.pl_futures(), futures.length).set(futures);
			const length = wasm.pl_play(i);
			const got = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_piece(), length).slice());
			if (got === wantPlays[i]) playsSame++;
			else if (playsSame + 1 >= plays) console.log(`FAIL  board ${i + 1}'s play costs:\n  wasm:   ${got.slice(0, 300)}\n  native: ${wantPlays[i].slice(0, 300)}`);
		} else if (wantPlays[i] !== "") {
			console.log(`FAIL  board ${i + 1} has a play natively and none in the link`);
		}
		const tricks = dds.table(new Uint32Array(wasm.memory.buffer, wasm.pl_table_deal(i), 16).slice());
		new Int32Array(wasm.memory.buffer, wasm.pl_tricks(), 20).set(tricks);
		const length = wasm.pl_exact(i);
		if (new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_piece(), length).slice()) === wantExacts[i]) exactsSame++;
	}
	if (plays > 0 && playsSame === plays) console.log(`ok    the play-through costs: ${plays} recorded plays, ${positions} positions solved by DDS in wasm (${(playMs / plays).toFixed(0)}ms a play) - the advisor's`);
	else { failures++; console.log(`FAIL  the play-through costs: ${playsSame} of ${plays} plays match`); }
	if (exactsSame === played) console.log(`ok    the explorer on played boards names the contract played (${played} boards)`);
	else { failures++; console.log(`FAIL  the explorer on played boards: ${exactsSame} of ${played} match`); }

	// THE 2-HAND ADVISOR'S SAMPLING (`twohand`): given the layouts the native advisor sampled (`layouts.txt`),
	// each solved by DDS in wasm a round at a time (`pl_sample_load` -> `pl_sample_deals` -> DDS ->
	// `pl_sample_tables` -> `pl_sample_round` until it resolves -> `pl_sample_finish`), the player must write the
	// advisor's `.par` element (`sampled.txt`): the same grid, lead sub-grids, guess tax and stopping point.
	const twoFragment = new TextEncoder().encode(fs.readFileSync(path.join(dir, "twohand.txt"), "utf8"));
	const wantPars = fs.readFileSync(path.join(dir, "sampled.txt"), "utf8").split("\0");
	const layoutLines = fs.readFileSync(path.join(dir, "layouts.txt"), "utf8").split("\n").filter((l) => l);
	const twoAt = wasm.pl_alloc(twoFragment.length);
	new Uint8Array(wasm.memory.buffer, twoAt, twoFragment.length).set(twoFragment);
	const twoBoards = wasm.pl_open(twoAt, twoFragment.length);
	const solveBoard = (i, count) => {
		let solved = 0, ms = 0;
		for (let from = 0; from < count; ) {
			const n = Math.min(40, count - from);
			const deals = new Uint32Array(wasm.memory.buffer, wasm.pl_sample_deals(from, n), 16 * n).slice();
			const t0 = performance.now();
			const tables = new Int32Array(20 * n);
			for (let k = 0; k < n; k++) tables.set(dds.table(deals.subarray(16 * k, 16 * k + 16)), 20 * k);
			ms += performance.now() - t0;
			new Int32Array(wasm.memory.buffer, wasm.pl_sample_tables(), 20 * n).set(tables);
			solved += n;
			from += n;
			if (wasm.pl_sample_round(n)) break;
		}
		const length = wasm.pl_sample_finish(i);
		return { html: new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_piece(), length).slice()), solved, ms };
	};
	let parsSame = 0, layoutsSolved = 0, sampleMs = 0;
	for (let i = 0; i < twoBoards; i++) {
		const [cap, packed] = layoutLines[i].split(" ");
		const bytes = Buffer.from(packed, "base64url");
		const at = wasm.pl_alloc(bytes.length);
		new Uint8Array(wasm.memory.buffer, at, bytes.length).set(bytes);
		const count = wasm.pl_sample_load(i, at, bytes.length / 13, +cap);
		const got = solveBoard(i, count);
		layoutsSolved += got.solved;
		sampleMs += got.ms;
		if (got.html === wantPars[i]) parsSame++;
		else if (parsSame + 1 > i) console.log(`FAIL  board ${i + 1}'s sampling:\n  wasm:   ${got.html.slice(0, 240)}\n  native: ${wantPars[i].slice(0, 240)}`);
	}
	if (twoBoards > 0 && parsSame === twoBoards) console.log(`ok    the 2-hand sampling: ${twoBoards} boards, ${layoutsSolved} layouts solved by DDS in wasm (${(sampleMs / layoutsSolved).toFixed(0)}ms each) - the advisor's grids, lead grids and tax`);
	else { failures++; console.log(`FAIL  the 2-hand sampling: ${parsSame} of ${twoBoards} boards match`); }
	// Two of those boards in three name their contract and some carry defender inferences (a `v3.` link), and the
	// sampling must read them: the grids above match only if every layout held them.
	const named = wantPars.filter((p) => p.includes("data-contract=")).length;
	const held = wantPars.filter((p) => p.includes("data-held=")).length;
	const shaped = wantPars.filter((p) => p.includes("data-shape=")).length;
	if (new TextDecoder().decode(twoFragment).startsWith("v3.") && named > 0 && held > 0 && shaped > 0) console.log(`ok    the 2-hand link names ${named} boards' contracts, ${held} held cards' boards and ${shaped} suit lengths' (v3.)`);
	else { failures++; console.log(`FAIL  the 2-hand link: ${new TextDecoder().decode(twoFragment).slice(0, 3)}, ${named} contracts, ${held} held, ${shaped} lengths`); }

	// And the player's own draw: layouts dealt in wasm around the known hands, sampled to a verdict.
	const drawn = wasm.pl_sample_start(0, 40);
	const own = drawn ? solveBoard(0, drawn) : { html: "" };
	if (drawn === 40 && own.html.includes(`data-sim='{"n":40,`) && own.html.includes("data-sim-leads=")) console.log(`ok    the player draws its own layouts and samples a board (${own.solved} layouts)`);
	else { failures++; console.log(`FAIL  the player's own sampling: ${drawn} layouts, ${own.html.slice(0, 120)}`); }
}
// The decoder's refusals reach the page as numbers it can name (share.Decode_Error).
for (const [fragment, want, what] of [["", 1, "no fragment"], ["v9.AAAA", 1, "another version"], ["v1.%%", 2, "not base64url"]]) {
	const got = play(fragment);
	if (got.error === want) console.log(`ok    ${what} is refused (${want})`);
	else { failures++; console.log(`FAIL  ${what}: ${JSON.stringify(got).slice(0, 80)}`); }
}
// THE GOLDEN LINKS (share/testdata/golden_links.txt): links already handed out must open in this player -
// whatever the card page has become since. `share_test.odin` checks what they decode to; this checks the
// module that is actually published reads them and builds a page.
if (goldenPath) {
	const golden = fs.readFileSync(goldenPath, "utf8").split(/\r?\n/).filter((l) => l.trim() && !l.startsWith("#"));
	for (const line of golden) {
		const [name, fragment] = line.trim().split(/\s+/);
		const got = play(fragment);
		if (got.page && got.boards > 0 && got.page.includes('class="compass"')) console.log(`ok    golden link "${name}" opens (${got.boards} boards)`);
		else { failures++; console.log(`FAIL  golden link "${name}": ${got.error ? "refused (" + got.error + ")" : "no page"}`); }
	}
}
process.exit(failures ? 1 : 0);
