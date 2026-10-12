# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Build the one-file shared-deals player: uv run --script player/build_page.py <player.wasm> <odin.js> <out.html>

The page carries the gzipped module as base64 and Odin's own JS runtime inline, so it works from disk and from
any static host, and never changes: publish it once. Opened as `player.html#v1.<payload>` (a link the
workbench's `share` writes), it renders the card page the link carries and REPLACES ITSELF with it
(`document.open/write/close`), so the card page's own script runs exactly as in a generated file.
"""

import base64
import gzip
import sys
from pathlib import Path

wasm, odin_js, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
module = base64.b64encode(gzip.compress(wasm.read_bytes(), 9, mtime=0)).decode()

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shared bridge deals</title>
<style>
	:root { color-scheme: light dark; }
	body { font-family: system-ui, 'Segoe UI', Roboto, sans-serif; margin: 3rem auto; max-width: 34rem; padding: 0 1rem; line-height: 1.5; }
	progress { width: 100%; }
</style>
</head><body>
<p id="say">Loading the deals…</p>
<progress id="bar" hidden></progress>
<noscript>This page builds the deals in your browser, and needs JavaScript to do it.</noscript>
<script>/*ODIN_JS*/</script>
<script>
(async () => {
	"use strict";
	const say = (text) => { document.getElementById("say").textContent = text; };
	// share.Decode_Error, in words.
	const REFUSED = {
		1: "This page shows bridge deals carried in its link, and this link carries none - or was made by a newer version of the program.",
		2: "This link's deals are damaged: part of it was probably lost when it was copied.",
		3: "This link stops part-way through a deal: it was probably cut short when it was copied.",
		4: "This link's deals are damaged: a hand does not have 13 cards.",
		5: "This link's deals are damaged.",
	};
	try {
		const fragment = decodeURIComponent(location.hash.slice(1));
		const gz = Uint8Array.from(atob("/*MODULE*/"), (c) => c.charCodeAt(0));
		const stream = new Blob([gz]).stream().pipeThrough(new DecompressionStream("gzip"));
		const memory = new odin.WasmMemoryInterface();
		memory.setIntSize(4);
		const imports = odin.setupDefaultImports(memory, null, memory.memory);
		const { instance } = await WebAssembly.instantiate(await new Response(stream).arrayBuffer(), imports);
		const wasm = instance.exports;
		memory.setExports(wasm);
		memory.setMemory(wasm.memory);
		wasm._start();

		const bytes = new TextEncoder().encode(fragment);
		const pointer = wasm.pl_alloc(bytes.length);
		new Uint8Array(wasm.memory.buffer, pointer, bytes.length).set(bytes);
		const boards = wasm.pl_open(pointer, bytes.length);
		if (boards < 0) { say(REFUSED[-boards] || "This link cannot be read."); return; }

		// The card-combination analysis is ~0.1s a board, so it gets a bar, and the page breathes between
		// boards; without it the whole set renders in milliseconds.
		const analyse = wasm.pl_analyse() === 1;
		const bar = document.getElementById("bar");
		if (analyse) { bar.max = boards; bar.value = 0; bar.hidden = false; }
		for (let left = boards, done = 0; left > 0; done++) {
			if (analyse) {
				say(`Analysing board ${done + 1} of ${boards}…`);
				bar.value = done;
				await new Promise((r) => setTimeout(r, 0));
			}
			left = wasm.pl_step();
		}
		const length = wasm.pl_finish();
		const html = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_result(), length).slice());
		document.open();
		document.write(html);
		document.close();
	} catch (error) {
		say("This browser could not build the deals: " + error.message);
	}
})();
</script>
</body></html>
"""

page = PAGE.replace("/*ODIN_JS*/", odin_js.read_text(encoding="utf-8")).replace("/*MODULE*/", module)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(page, encoding="utf-8", newline="")
print(f"{out}: {out.stat().st_size:,} bytes (module {wasm.stat().st_size:,} bytes)")
