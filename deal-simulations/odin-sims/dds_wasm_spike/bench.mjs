// node dds_wasm_spike/bench.mjs [dds.wasm] [tables] [solves]
import fs from "node:fs";
import { createRequire } from "node:module";
const { ddsBench } = createRequire(import.meta.url)("./dds_bench.js");
const [file = new URL("../target/player/dds.wasm", import.meta.url), tables = "50", solves = "200"] = process.argv.slice(2);
console.log("node " + (await ddsBench(fs.readFileSync(file), +tables, +solves)).text);
