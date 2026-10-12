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
for (const name of ["plain", "analysed", "par"]) {
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
