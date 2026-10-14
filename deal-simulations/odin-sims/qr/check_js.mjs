// The card page's QR encoder (norn's `html_cards_qr.js`, a port of qr.odin) held to the same golden matrices
// as qr.odin: node qr/check_js.mjs <html_cards_qr.js> <goldens.txt>   (`just sims test-qr-js`)
//
// Each golden is qrcodegen's matrix, scanned back by zxing-cpp when it was recorded (testdata/make_goldens.py).
import fs from "node:fs";

const [encoderPath, goldensPath] = process.argv.slice(2);
(0, eval)(fs.readFileSync(encoderPath, "utf8") + "\nglobalThis.NcQr = NcQr;");

const lines = fs.readFileSync(goldensPath, "utf8").split(/\r?\n/);
let cases = 0, failures = 0;
for (let i = 0; i < lines.length; i++) {
	if (!lines[i].startsWith("case ")) continue;
	const fields = lines[i].split(" ");
	const [ecc, version, mask] = fields.slice(1, 4);
	const text = fields.slice(4).join(" ");
	let chose = [+version || 0, mask === "auto" ? -1 : +mask];
	if (lines[i + 1].startsWith("chose ")) {
		i++;
		chose = lines[i].split(" ").slice(1, 3).map(Number);
	}
	const size = lines[i + 1].length;
	const rows = lines.slice(i + 1, i + 1 + size);
	i += size;
	cases++;

	const v = version === "auto" ? 0 : +version;
	const code = NcQr.encode(text, {
		ecc, boostEcc: false, minVersion: v || 1, maxVersion: v || 40, mask: mask === "auto" ? -1 : +mask,
	});
	const what = `case ${cases} (${ecc} ${version} ${mask} ${JSON.stringify(text.slice(0, 30))})`;
	if (!code) { failures++; console.log(`FAIL  ${what}: did not encode`); continue; }
	if (code.version !== chose[0] || code.mask !== chose[1] || code.size !== size) {
		failures++;
		console.log(`FAIL  ${what}: v${code.version} mask ${code.mask} size ${code.size}, reference v${chose[0]} mask ${chose[1]} size ${size}`);
		continue;
	}
	let wrong = 0;
	for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (code.dark[y * size + x] !== (rows[y][x] === "1")) wrong++;
	if (wrong) { failures++; console.log(`FAIL  ${what}: ${wrong} modules differ`); }
}
// The capacities the panel's rule reads, and the refusal.
const expect = (ok, what) => { if (!ok) { failures++; console.log(`FAIL  ${what}`); } };
expect(NcQr.byteCapacity(40, "L") === 2953 && NcQr.byteCapacity(40, "H") === 1273 && NcQr.byteCapacity(10, "M") === 213, "byte capacities");
expect(NcQr.encode("x".repeat(2954), { ecc: "L" }) === null, "too long for version 40 is refused");
expect(NcQr.encode("HELLO WORLD", { ecc: "L" }).ecc === "Q", "boosted while the version holds");
expect(/^<svg [^>]*viewBox="0 0 29 29"/.test(NcQr.svg(NcQr.encode("HELLO WORLD"))), "the svg has a 4-module quiet zone");

console.log(failures ? `${failures} FAILED of ${cases} goldens + 4 checks` : `ok    ${cases} golden matrices match, and 4 checks`);
process.exit(failures ? 1 : 0);
