# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Build the one-file shared-deals player:
uv run --script player/build_page.py <player.wasm> <odin.js> <out.html> <dds.wasm>

The page carries the gzipped module as base64 and Odin's own JS runtime inline, so it works from disk and from
any static host, and never changes: publish it once. Opened as `player.html#v1.<payload>` (a link the
workbench's `share` writes), it renders the card page the link carries and REPLACES ITSELF with it
(`document.open/write/close`), so the card page's own script runs exactly as in a generated file. The page is
shown at once, without the card-combination analysis: that costs the reader's processor (~0.1s a board on a
desktop, more on a phone), so it is worked out only when the reader asks, from the page's CCA panel - by a Web
Worker running the same module, handed to the page's `ncAddAnalysis` - together with a whole deal's
double-dummy table, from DDS compiled to wasm (`dds/`, carried gzipped beside the player's module; another
worker), which the player turns into the contract picker's exact grid (`ncAddSim`). A `Save` button beside the page's `QR`
downloads the page as a generated file holds it (the browser's own save writes the page after its script has
rebuilt it, which does not open again).
"""

import base64
import gzip
import sys
from pathlib import Path

wasm, odin_js, out, dds_wasm = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
module = base64.b64encode(gzip.compress(wasm.read_bytes(), 9, mtime=0)).decode()
dds_module = base64.b64encode(gzip.compress(dds_wasm.read_bytes(), 9, mtime=0)).decode()
dds_js = (Path(__file__).parent / "dds" / "dds.js").read_text(encoding="utf-8")

PAGE = r"""<!doctype html>
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
<script id="odin-js">/*ODIN_JS*/</script>
<script id="dds-js">/*DDS_JS*/</script>
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
		6: "This link's recorded play is damaged.",
	};
	// The module's exports, opened on the link's fragment: the page itself uses one, the worker another.
	const start = async (module, fragment) => {
		const memory = new odin.WasmMemoryInterface();
		memory.setIntSize(4);
		const imports = odin.setupDefaultImports(memory, null, memory.memory);
		const instance = await WebAssembly.instantiate(module, imports);
		const wasm = instance.exports;
		memory.setExports(wasm);
		memory.setMemory(wasm.memory);
		wasm._start();
		const bytes = new TextEncoder().encode(fragment);
		const pointer = wasm.pl_alloc(bytes.length);
		new Uint8Array(wasm.memory.buffer, pointer, bytes.length).set(bytes);
		return { wasm, boards: wasm.pl_open(pointer, bytes.length) };
	};
	// Board `i`'s analysis as html. `pl_analysis` first: it may grow memory and move the buffer.
	const analysis = (wasm, i) => {
		const length = wasm.pl_analysis(i);
		return new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_piece(), length).slice());
	};
	// THE WORKERS, a lane's (below), each answering one board at a time, whichever the page asks for next:
	// `{init}` -> `{ready}`, then `{board, ...}` -> `{board, result}`. The card-combination analysis runs this
	// same module (~0.1s a board); DDS's (`dds.js`) solves a whole deal's table (~0.15s) or every position of a
	// recorded play (~50 solves, ~1-4s).
	function comboWorker() {
		let wasm = null;
		self.onmessage = async (event) => {
			const message = event.data;
			if (message.init) {
				wasm = (await start(message.init.module, message.init.fragment)).wasm;
				self.postMessage({ ready: true });
			} else {
				self.postMessage({ board: message.board, result: analysis(wasm, message.board) });
			}
		};
	}
	function ddsWorker() {
		let dds = null;
		self.onmessage = async (event) => {
			const message = event.data;
			if (message.init) {
				dds = await ddsStart(message.init.module);
				self.postMessage({ ready: true });
			} else if (message.batch) {
				// A run of layouts (16 u32 each) for the 2-hand sampling: their tables, 20 i32 each.
				const n = message.batch.length / 16, out = new Int32Array(20 * n);
				for (let k = 0; k < n; k++) out.set(dds.table(message.batch.subarray(16 * k, 16 * k + 16)), 20 * k);
				self.postMessage({ board: message.board, result: out });
			} else {
				const result = message.cards ? dds.table(message.cards) : dds.solve(message.positions, message.count, message.playout);
				self.postMessage({ board: message.board, result });
			}
		};
	}
	const inflate = async (base64) => {
		const gz = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
		const stream = new Blob([gz]).stream().pipeThrough(new DecompressionStream("gzip"));
		return WebAssembly.compile(await new Response(stream).arrayBuffer());
	};

	try {
		const fragment = decodeURIComponent(location.hash.slice(1));
		const module = await inflate("/*MODULE*/");
		const { wasm, boards } = await start(module, fragment);
		if (boards < 0) { say(REFUSED[-boards] || "This link cannot be read."); return; }

		// THE PAGE AT ONCE (milliseconds): every board, without the card-combination analysis. It REPLACES this
		// page (`document.open/write/close`), so the card page's own script runs as in a generated file; this
		// script and its variables carry on, since the window stays the same.
		const analyse = wasm.pl_analyse() === 1;
		const plain = new Uint8Array(wasm.memory.buffer, wasm.pl_result(), wasm.pl_plain()).slice();
		const ends = Array.from({ length: boards }, (_, i) => wasm.pl_board_end(i));
		const playStarts = Array.from({ length: boards }, (_, i) => wasm.pl_play_start(i));
		const parStarts = Array.from({ length: boards }, (_, i) => wasm.pl_par_start(i));
		const html = new TextDecoder().decode(plain);
		const odinSource = document.getElementById("odin-js").textContent;

		// THE ANALYSIS ONLY WHEN THE READER ASKS FOR IT. Nothing is worked out at load: it is the reader's
		// processor and battery, spent on boards they may never look at. The card page's CCA panel offers it
		// (`ccaOffer`) and asks through `window.ncRequestAnalysis(boards)`, which must exist before the page's
		// script runs - so it is set before the page is written. Each board asked for gets its card-combination
		// analysis and, when the whole deal is known, its double-dummy table (the contract picker's exact
		// explorer; DDS in wasm, ~0.15s a board on a desktop and ~0.3s on a 2018 phone).
		//
		// A LANE is one kind of that work: Web Workers of its own (`workers` of them), started on the first request
		// (DDS's module is not even unpacked before then), each working an asked-for board out at a time, nearest
		// the board in view first, idle between requests. A browser without workers (or one refusing a worker from
		// this page) gets the same loop on the page's own thread, with a breath between boards. A small note in a
		// corner counts the boards still to do. A lane may do more than one kind of job a board (`kinds`): job
		// `k * boards + i` is board `i`'s `k`th, and the order is still the boards' - nearest the one in view first.
		//
		// A RECORDED PLAY's costs are asked for separately, from the play bar under the board
		// (`window.ncRequestPlay`): what each card cost, double dummy, is every position of the play solved
		// (~50 DDS solves, ~1s on a desktop and ~4s on a 2018 phone), and it is a different question from the CCA.
		const pieces = new Array(boards).fill(null), exacts = new Array(boards).fill(null), plays = new Array(boards).fill(null);
		const samples = new Array(boards).fill(null);
		let sampleStatus = "";
		const lanes = [];
		const note = document.createElement("div");
		note.style.cssText = "position:fixed;left:8px;bottom:8px;z-index:99;padding:2px 8px;border-radius:4px;" +
			"font:12px system-ui,sans-serif;background:rgba(0,0,0,.65);color:#fff;pointer-events:none";
		const showNote = () => {
			let left = 0;
			for (let i = 0; i < boards; i++) if (lanes.some((l) => l.pending(i))) left++;
			if (!left && !sampleStatus) { note.remove(); return; }
			note.textContent = [sampleStatus, left ? `calculating: ${left} board${left === 1 ? "" : "s"} to go` : ""]
				.filter((t) => t).join(" · ");
			if (!note.isConnected) document.body.appendChild(note);
		};
		const lane = ({ kinds = 1, workers = 1, source, init, job, here, take }) => {
			const done = new Array(kinds * boards).fill(false), wanted = new Array(kinds * boards).fill(false);
			const running = new Array(kinds * boards).fill(false); // given to a worker, its answer not back yet
			let pool = null, starting = false, busy = false, onPage = false;
			const open = (i) => {
				for (let k = 0; k < kinds; k++) {
					const id = k * boards + i;
					if (wanted[id] && !done[id] && !running[id]) return id;
				}
				return -1;
			};
			const pending = (i) => {
				for (let k = 0; k < kinds; k++) if (wanted[k * boards + i] && !done[k * boards + i]) return true;
				return false;
			};
			const next = () => {
				const at = typeof window.ncActiveBoard === "function" ? window.ncActiveBoard() : 0;
				for (let d = 0; d < boards; d++) {
					if (at + d < boards && open(at + d) >= 0) return open(at + d);
					if (at - d >= 0 && open(at - d) >= 0) return open(at - d);
				}
				return -1;
			};
			const finish = (board, result) => {
				running[board] = false;
				if (done[board]) return;
				done[board] = true;
				take(board, result);
				showNote();
			};
			const loop = async () => {
				if (busy) return;
				busy = true;
				for (let board = next(); board >= 0; board = next()) {
					await new Promise((r) => setTimeout(r, 0));
					finish(board, await here(board));
				}
				busy = false;
			};
			const fallBack = () => {
				if (pool) pool.forEach((t) => t.worker.terminate());
				pool = null;
				running.fill(false); // what the workers held is asked again, on this thread
				onPage = true;
				busy = false;
				loop();
			};
			const pump = async () => {
				if (onPage) { loop(); return; }
				if (!pool) {
					if (starting) return;
					starting = true;
					try {
						const url = URL.createObjectURL(new Blob([source()], { type: "text/javascript" }));
						const message = { init: await init() };
						const made = Array.from({ length: workers }, () => ({ worker: new Worker(url), idle: false }));
						for (const t of made) {
							t.worker.onmessage = (event) => {
								const answer = event.data;
								if (!answer.ready) finish(answer.board, answer.result);
								t.idle = true;
								pump();
							};
							t.worker.onerror = fallBack;
							t.worker.postMessage(message);
						}
						pool = made;
					} catch (error) {
						fallBack();
					}
					starting = false;
					return;
				}
				for (const t of pool) {
					if (!t.idle) continue;
					const id = next();
					if (id < 0) return;
					t.idle = false;
					running[id] = true;
					t.worker.postMessage(job(id));
				}
			};
			const it = { pending, want: (i, k = 0) => { wanted[k * boards + i] = true; }, pump };
			lanes.push(it);
			return it;
		};
		// odin.js installs itself on `window` and looks for elements by id, as in the page.
		const workerPrelude = "self.window = self;\nself.document = { getElementById: () => null };\n";
		let combosDone = 0;
		// The card-combination analysis is a board's own work (~65 ms a board in a desktop's wasm), so boards can be
		// done side by side: a worker per processor, less two (the DDS lane and the page), at most eight. Each holds
		// a copy of this module and ~9 MB of memory. 48 boards took 3.2s on one worker, 0.84s on four, 0.51s on eight.
		const comboWorkers = Math.max(1, Math.min(8, (navigator.hardwareConcurrency || 2) - 2));
		const comboLane = lane({
			workers: comboWorkers,
			source: () => workerPrelude + odinSource + "\nconst start = " + start.toString() + ";\nconst analysis = " +
				analysis.toString() + ";\n(" + comboWorker.toString() + ")();",
			init: async () => ({ module, fragment }),
			job: (board) => ({ board }),
			here: async (board) => analysis(wasm, board),
			take: (board, html) => {
				pieces[board] = new TextEncoder().encode(html);
				if (typeof window.ncAddAnalysis === "function") window.ncAddAnalysis(board, html);
				if (++combosDone === boards) window.ncAnalysing = false;
			},
		});
		// Board `i` in DDS's layout, or null when its whole deal is not known (a 2-hand board).
		const tableDeal = (i) => {
			const pointer = wasm.pl_table_deal(i);
			return pointer ? new Uint32Array(wasm.memory.buffer, pointer, 16).slice() : null;
		};
		const ddsSource = document.getElementById("dds-js").textContent;
		let ddsModule = null, ddsHere = null;
		const ddsCompiled = async () => ddsModule || (ddsModule = await inflate("/*DDS_MODULE*/"));
		// Board `i`'s recorded play as the positions DDS solves (`replay.positions`, 96 bytes each), or null.
		const playPositions = (i) => {
			const count = wasm.pl_play_positions(i);
			return count ? { positions: new Uint8Array(wasm.memory.buffer, wasm.pl_positions(), 96 * count).slice(), count,
				playout: wasm.pl_playout_wanted() === 1 } : null;
		};
		// The DDS lane's two kinds of job: a board's table (0), and its play's positions (1).
		const ddsJob = (id) => (id < boards ? { board: id, cards: tableDeal(id) } : { board: id, ...playPositions(id - boards) });
		// Board `board`'s explorer, from the trick table in `pl_tricks()`.
		const addExact = (board) => {
			const length = wasm.pl_exact(board); // first: it may move the buffer `pl_piece` points at
			const html = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_piece(), length).slice());
			exacts[board] = new TextEncoder().encode(html);
			if (typeof window.ncAddSim === "function") window.ncAddSim(board, html);
		};
		// The same for DDS: with the analysis spread over workers, a deal's table (~0.2s) was what the reader waited
		// for. A table is a bigger job than a board's analysis and DDS's instance is smaller than the player's, so
		// this pool may be twice the size: one worker per processor less two, at most eight (each holds ~50 MB).
		// Four workers took 3.4s for 48 boards with both lanes running.
		const ddsWorkers = Math.max(1, Math.min(8, (navigator.hardwareConcurrency || 2) - 2));
		const ddsLane = lane({
			kinds: 2,
			workers: ddsWorkers,
			source: () => ddsSource + "\n(" + ddsWorker.toString() + ")();",
			init: async () => ({ module: await ddsCompiled() }),
			job: ddsJob,
			here: async (id) => {
				ddsHere = ddsHere || await ddsStart(await ddsCompiled());
				const message = ddsJob(id);
				return message.cards ? ddsHere.table(message.cards) : ddsHere.solve(message.positions, message.count, message.playout);
			},
			take: (id, result) => {
				if (id >= boards) {
					// The answers, then the play-out's cards (dds.js `solve`).
					const board = id - boards, answers = 216 * wasm.pl_play_positions(board);
					new Uint8Array(wasm.memory.buffer, wasm.pl_futures(), answers).set(result.subarray(0, answers));
					const cards = result.subarray(answers);
					new Uint8Array(wasm.memory.buffer, wasm.pl_playout(), cards.length).set(cards);
					const length = wasm.pl_play(board, cards.length / 2); // first: it may move the buffer `pl_piece` points at
					if (!length) return; // answers that make no sense: the page keeps the play it has
					const html = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_piece(), length).slice());
					plays[board] = new TextEncoder().encode(html);
					if (typeof window.ncAddPlay === "function") window.ncAddPlay(board, html);
					return;
				}
				new Int32Array(wasm.memory.buffer, wasm.pl_tricks(), 20).set(result);
				addExact(id);
			},
		});
		if (analyse) {
			window.ncRequestAnalysis = (list) => {
				for (const i of list) {
					if (i < 0 || i >= boards) continue;
					comboLane.want(i);
					// A link with par carries the table already: the explorer is written now, with no solve.
					if (wasm.pl_par_tricks(i)) { if (!exacts[i]) addExact(i); }
					else if (wasm.pl_table_deal(i)) ddsLane.want(i);
				}
				showNote();
				comboLane.pump();
				ddsLane.pump();
			};
		}
		// THE 2-HAND ADVISOR'S SAMPLING, asked for from the CCA panel's verdict band (`window.ncRequestSample`): the
		// unseen 26 cards dealt to the defenders up to SAMPLE_CAP times and every layout solved double dummy - the
		// make-% for every contract, the opening-lead sub-grids and the guess tax, as the advisor's page has them.
		// It is the heavy one (~20 ms a layout on a desktop's workers, ~110 ms on a 2018 phone), so it gets a POOL
		// of DDS workers, one per processor but one (at most 8), started for the boards asked for and closed when
		// they are done (each holds ~50 MB). One board at a time, a round of `sampled.ROUND` layouts at once, split
		// over the pool; after each round the player says whether the verdict has settled (`pl_sample_round`), so
		// a lopsided board stops at 200 layouts. Without workers, the page's thread does it, a breath a layout.
		const SAMPLE_CAP = 300, SAMPLE_ROUND = 40;
		const sampleWanted = new Set();
		let sampling = false, pool = null;
		const poolSize = Math.max(1, Math.min(8, (navigator.hardwareConcurrency || 2) - 1));
		const call = (worker, message) => new Promise((resolve, reject) => {
			worker.onmessage = (event) => resolve(event.data);
			worker.onerror = (event) => reject(new Error(event.message || "a DDS worker failed"));
			worker.postMessage(message);
		});
		const openPool = async () => {
			try {
				const module = await ddsCompiled();
				const url = URL.createObjectURL(new Blob([ddsSource + "\n(" + ddsWorker.toString() + ")();"], { type: "text/javascript" }));
				const workers = Array.from({ length: poolSize }, () => new Worker(url));
				await Promise.all(workers.map((w) => call(w, { init: { module } })));
				return workers;
			} catch (error) {
				console.warn("DDS workers unavailable, sampling on the page's thread:", error);
				return [];
			}
		};
		const closePool = () => { if (pool) pool.forEach((w) => w.terminate()); pool = null; };
		// `n` layouts (16 u32 each) -> their tables (20 i32 each), over the pool, else on this thread.
		const solveLayouts = async (deals, n) => {
			const out = new Int32Array(20 * n);
			if (pool.length) {
				// One layout a message, each worker taking the next as it finishes: layouts differ several-fold in
				// how long they take, and fixed shares left most of the pool waiting for the slowest.
				let next = 0;
				await Promise.all(pool.map(async (worker) => {
					for (let k = next++; k < n; k = next++) {
						const answer = await call(worker, { board: k, batch: deals.slice(16 * k, 16 * k + 16) });
						out.set(answer.result, 20 * k);
					}
				}));
				return out;
			}
			ddsHere = ddsHere || await ddsStart(await ddsCompiled());
			for (let k = 0; k < n; k++) {
				await new Promise((r) => setTimeout(r, 0));
				out.set(ddsHere.table(deals.subarray(16 * k, 16 * k + 16)), 20 * k);
			}
			return out;
		};
		const sampleBoard = async (i) => {
			const count = wasm.pl_sample_start(i, SAMPLE_CAP);
			if (!count) return;
			for (let from = 0; from < count; ) {
				const n = Math.min(SAMPLE_ROUND, count - from);
				const deals = new Uint32Array(wasm.memory.buffer, wasm.pl_sample_deals(from, n), 16 * n).slice();
				const tables = await solveLayouts(deals, n);
				new Int32Array(wasm.memory.buffer, wasm.pl_sample_tables(), 20 * n).set(tables);
				from += n;
				const settled = wasm.pl_sample_round(n);
				sampleStatus = `sampling board ${i + 1}: ${from} of up to ${count} deals`;
				showNote();
				if (typeof window.ncSampleProgress === "function") window.ncSampleProgress(i, from, count);
				if (settled) break;
			}
			const length = wasm.pl_sample_finish(i); // first: it may move the buffer `pl_piece` points at
			if (!length) return;
			const html = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.pl_piece(), length).slice());
			samples[i] = new TextEncoder().encode(html);
			if (typeof window.ncAddSample === "function") window.ncAddSample(i, html);
		};
		const sampleLoop = async () => {
			if (sampling) return;
			sampling = true;
			try {
				while (sampleWanted.size) {
					const at = typeof window.ncActiveBoard === "function" ? window.ncActiveBoard() : 0;
					let next = -1;
					for (const i of sampleWanted) if (next < 0 || Math.abs(i - at) < Math.abs(next - at)) next = i;
					sampleWanted.delete(next);
					if (!pool) pool = typeof Worker === "function" ? await openPool() : [];
					await sampleBoard(next);
				}
			} catch (error) {
				sampleStatus = "sampling failed: " + error.message;
			} finally {
				closePool();
				sampling = false;
				if (!sampleStatus.startsWith("sampling failed")) sampleStatus = "";
				showNote();
			}
		};
		if (parStarts.some((at, i) => at !== playStarts[i])) {
			window.ncRequestSample = (list) => {
				for (const i of list) if (i >= 0 && i < boards && parStarts[i] !== playStarts[i] && !samples[i]) sampleWanted.add(i);
				sampleLoop();
			};
		}
		if (playStarts.some((at, i) => at !== ends[i])) {
			window.ncRequestPlay = (list) => {
				for (const i of list) if (i >= 0 && i < boards && playStarts[i] !== ends[i]) ddsLane.want(i, 1);
				showNote();
				ddsLane.pump();
			};
		}
		window.ncAnalysing = analyse;
		document.open();
		document.write(html);
		document.close();

		// SAVE PAGE: the page as a generated file holds it, so it opens from disk with no link and no player. The
		// browser's own "save page" writes the page as it is NOW - its carousel already built - and the card page's
		// script, running again over that on opening, finds no boards. This writes the html the script has not
		// touched yet: the plain page with each board's analysis put back where `pl_board_end` says (offsets are
		// UTF-8 bytes) - the splice `check.mjs` holds to the native page byte for byte - and each board's
		// double-dummy grid before it, where the advisor's page has it; a recorded play whose costs were worked out
		// replaces the play without them (`pl_play_start` to the board's end), and a sampled 2-hand board's `.par`
		// the one without the sampling (`pl_par_start` to `pl_play_start`). Only the boards whose analysis the
		// reader has had calculated carry it: saving works nothing out.
		const saveButton = document.createElement("button");
		saveButton.id = "nc-save";
		saveButton.textContent = "Save";
		saveButton.title = "Save these deals as a page of their own, which opens from disk with no link. " +
			"Boards whose analysis you have calculated (CCA) keep it.";
		saveButton.onclick = () => {
			const parts = [];
			let from = 0;
			for (let i = 0; i < boards; i++) {
				let cut = from;
				if (samples[i]) { parts.push(plain.subarray(cut, parStarts[i]), samples[i]); cut = playStarts[i]; }
				if (plays[i]) parts.push(plain.subarray(cut, playStarts[i]), plays[i]);
				else parts.push(plain.subarray(cut, ends[i]));
				if (exacts[i]) parts.push(exacts[i]);
				if (pieces[i]) parts.push(pieces[i]);
				from = ends[i];
			}
			parts.push(plain.subarray(from));
			const name = (document.title || "").replace(/[\/:*?"<>|]+/g, "-").replace(/\s+/g, " ").trim() || "bridge deals";
			const link = document.createElement("a");
			link.href = URL.createObjectURL(new Blob(parts, { type: "text/html" }));
			link.download = name + ".html";
			document.body.appendChild(link);
			link.click();
			link.remove();
			setTimeout(() => URL.revokeObjectURL(link.href), 60000);
		};
		const qrButton = document.getElementById("nc-qr");
		if (qrButton) qrButton.after(saveButton);
	} catch (error) {
		say("This browser could not build the deals: " + error.message);
	}
})();
</script>
</body></html>
"""

page = (PAGE.replace("/*ODIN_JS*/", odin_js.read_text(encoding="utf-8")).replace("/*DDS_JS*/", dds_js)
        .replace("/*DDS_MODULE*/", dds_module).replace("/*MODULE*/", module))
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(page, encoding="utf-8", newline="")
print(f"{out}: {out.stat().st_size:,} bytes (module {wasm.stat().st_size:,} bytes)")
