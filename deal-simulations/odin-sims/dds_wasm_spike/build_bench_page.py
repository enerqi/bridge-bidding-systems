# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""The spike as ONE file to open on a phone: uv run --script dds_wasm_spike/build_bench_page.py <dds.wasm> <out.html>

dds.wasm gzipped and inlined as base64, with dds_bench.js beside it, so the page needs nothing else - drop it on
Netlify (or any static host) and open it on the device to be measured. It times DDS in Web Workers there and
prints one block of text to copy back.
"""

import base64
import gzip
import sys
from pathlib import Path

here = Path(__file__).parent
wasm, out = Path(sys.argv[1]), Path(sys.argv[2])
module = base64.b64encode(gzip.compress(wasm.read_bytes(), 9, mtime=0)).decode()
bench = (here / "dds_bench.js").read_text(encoding="utf-8")

PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>DDS speed test</title>
<style>
	:root { color-scheme: light dark; }
	body { font-family: system-ui, 'Segoe UI', Roboto, sans-serif; margin: 1.5rem auto; max-width: 40rem; padding: 0 1rem; line-height: 1.45; }
	button { font: inherit; padding: 0.4rem 0.9rem; margin: 0.2rem 0.4rem 0.2rem 0; }
	pre { white-space: pre-wrap; background: rgba(127,127,127,.12); padding: 0.6rem; border-radius: 6px; font-size: 0.85rem; }
</style>
</head><body>
<h1>DDS speed test</h1>
<p>Times the double-dummy solver on this device, in this browser: a fixed set of random deals, solved in 1 and
then several background workers. It keeps the processor busy for roughly half a minute to a few minutes, so keep
the screen on. Nothing is sent anywhere; copy the result below back by hand.</p>
<button id="go">Start</button><button id="copy" disabled>Copy result</button>
<pre id="out">Not started.</pre>
<script id="bench">/*BENCH*/</script>
<script>
(() => {
	"use strict";
	const out = document.getElementById("out");
	const lines = [];
	const log = (line) => { lines.push(line); out.textContent = lines.join("\n"); };
	const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
	async function module() {
		const gz = Uint8Array.from(atob("/*MODULE*/"), (c) => c.charCodeAt(0));
		const stream = new Blob([gz]).stream().pipeThrough(new DecompressionStream("gzip"));
		return WebAssembly.compile(await new Response(stream).arrayBuffer());
	}
	// k workers, each solving `tables` full tables (and `solves` single solves); wall time for the lot.
	async function run(mod, url, k, tables, solves) {
		const t0 = performance.now();
		const results = await Promise.all(Array.from({ length: k }, () => new Promise((resolve, reject) => {
			const w = new Worker(url);
			w.onmessage = (e) => { w.terminate(); e.data.error ? reject(new Error(e.data.error)) : resolve(e.data); };
			w.onerror = (e) => { w.terminate(); reject(new Error(e.message || "worker failed")); };
			w.postMessage({ module: mod, tables, solves });
		})));
		return { wall: performance.now() - t0, results };
	}
	document.getElementById("go").onclick = async () => {
		const go = document.getElementById("go");
		go.disabled = true;
		lines.length = 0;
		try {
			const cores = navigator.hardwareConcurrency || 0;
			log(`device: ${navigator.userAgent}`);
			log(`cores reported: ${cores || "?"}; memory reported: ${navigator.deviceMemory ? navigator.deviceMemory + " GB" : "?"}`);
			if (navigator.getBattery) {
				try { const b = await navigator.getBattery(); log(`battery: ${Math.round(b.level * 100)}%, ${b.charging ? "charging" : "not charging"}`); } catch (e) {}
			}
			const mod = await module();
			const source = document.getElementById("bench").textContent +
				"\nself.onmessage = async (e) => { try { globalThis.DDS_MB = 50; " +
				"self.postMessage(await ddsBench(e.data.module, e.data.tables, e.data.solves)); } " +
				"catch (err) { self.postMessage({ error: String(err) }); } };";
			const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
			log("");
			log("1 worker: 10 full tables + 60 single solves …");
			const one = await run(mod, url, 1, 10, 60);
			const r = one.results[0];
			const table = r.table, solve = r.solve;
			lines[lines.length - 1] = `1 worker: ${table.toFixed(0)} ms a full table (20 results), ${solve.toFixed(1)} ms a single solve; ${r.memoryMB.toFixed(0)} MB`;
			out.textContent = lines.join("\n");
			const counts = [...new Set([2, 4, Math.min(cores || 4, 8)].filter((k) => k > 1 && k <= Math.max(cores, 2)))].sort((a, b) => a - b);
			let best = { k: 1, per: table };
			for (const k of counts) {
				await sleep(300);
				log(`${k} workers: ${3 * k} tables …`);
				const m = await run(mod, url, k, 3, 0);
				const per = m.wall / (3 * k);
				lines[lines.length - 1] = `${k} workers: ${per.toFixed(0)} ms a table overall (each worker ${m.results.map((x) => x.table.toFixed(0)).join("/")} ms)`;
				out.textContent = lines.join("\n");
				if (per < best.per) best = { k, per };
			}
			log("");
			log(`what that means a board (best: ${best.k} worker${best.k > 1 ? "s" : ""}):`);
			log(`  exact contract explorer / par (1 table): ${(table / 1000).toFixed(1)} s`);
			log(`  play-through costs (~52 single solves): ${(52 * solve / 1000).toFixed(1)} s`);
			for (const n of [100, 300]) log(`  2-hand make % with ${n} samples: ${(n * best.per / 1000).toFixed(0)} s`);
			log("");
			log("(the desktop this was written on, same test: 24 cores, Chrome - 129 ms a table and 30 ms a single solve on 1 worker, 19 ms a table overall on 8)");
			document.getElementById("copy").disabled = false;
		} catch (error) {
			log("FAILED: " + error.message);
		}
		go.disabled = false;
	};
	document.getElementById("copy").onclick = () => {
		navigator.clipboard.writeText(out.textContent).then(() => { document.getElementById("copy").textContent = "Copied"; },
			() => { document.getElementById("copy").textContent = "Copy failed - select the text"; });
	};
})();
</script>
</body></html>
"""

page = PAGE.replace("/*BENCH*/", bench).replace("/*MODULE*/", module)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(page, encoding="utf-8", newline="")
print(f"{out}: {out.stat().st_size:,} bytes")
