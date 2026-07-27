# /// script
# requires-python = ">=3.11"
# dependencies = ["beautifulsoup4"]
# ///
"""
Parse the BridgeHands suit-combination tables (html/sc_0..sc_9.html) into structured rows, and emit
    - suitcomb.json          : clean structured corpus (canonical, reconstructed holdings)
    - zz_book_diff_test.odin : a package-combo test that diffs the book's P(>=k) against our engine.

Robustness strategy (see COMBO_ANALYSER handoff): the raw HTML reliably carries the NAMED HONOURS and the
`Decl` "n-m" hand lengths, but the trailing 'x' spot runs are lossy (long runs / ellipsis collapse). So we
DISCARD parsed spot positions and RECONSTRUCT each hand deterministically = named honours + enough of the
LOWEST unused ranks to reach the decl length (the suit-combination convention: an 'x' is a card below the
action, and the opponents hold the higher middle cards). The section header ("2 HCP - The Queen") names the
honours the OPPONENTS hold, which cross-checks the honour split (an opp honour must not appear in NS).
"""
import glob
import json
import os
import re
import sys
from bs4 import BeautifulSoup

# rank char -> combo bit index (2=0 .. 9=7, T=8, J=9, Q=10, K=11, A=12), matching combo.odin's encoding.
HON_BIT = {"A": 12, "K": 11, "Q": 10, "J": 9, "T": 8,
           "9": 7, "8": 6, "7": 5, "6": 4, "5": 3, "4": 2, "3": 1, "2": 0}
HONOURS = set("AKQJT")
RANK_RE = re.compile(r"^(?:[AKQJ]|10|[2-9]|x)$", re.I)
HERE = os.path.dirname(os.path.abspath(__file__))


def cell_lines(td):
    return [ln.strip() for ln in td.get_text(separator="\n").split("\n") if ln.strip()]


BR_RE = re.compile(r"<br\s*/?>", re.I)


def br_segments(td):
    """Split a cell on <br/> (the ROW separator) not on soft newlines, so per-target rows stay aligned.
    Each of Decl/Need/%/Remarks stacks one sub-line per target row via <br/>; splitting on get_text()'s
    '\\n' also breaks intra-row soft-wraps (e.g. 'Play Q ... finesse\\n 9'), mis-aligning the columns."""
    parts = BR_RE.split(td.decode_contents())
    return [" ".join(BeautifulSoup(p, "html.parser").get_text().split()) for p in parts]


def modal_line(target_lines):
    """Representative single line for the whole holding = the most frequent per-target line (the workhorse
    play the book repeats across trick targets); ties broken by the highest-trick (first) occurrence."""
    seen = {}
    for ln in target_lines:
        if ln:
            seen[ln] = seen.get(ln, 0) + 1
    if not seen:
        return ""
    best, best_ct = "", -1
    for ln in target_lines:  # iterate in table order (highest trick target first) for a stable tiebreak
        if ln and seen[ln] > best_ct:
            best, best_ct = ln, seen[ln]
    return best


def parse_holding(tokens):
    out = []
    for t in tokens.split():
        t = t.replace("\xa0", "").strip()
        if RANK_RE.match(t):
            out.append("T" if t == "10" else t.upper())
    return out


def opp_honours(section):
    """Honours the opponents hold, from the section title tail (e.g. 'The King and Jack' -> {K,J})."""
    if not section:
        return set()
    tail = section.split("-", 1)[-1]
    names = {"ace": "A", "king": "K", "queen": "Q", "jack": "J", "ten": "T"}
    return {v for k, v in names.items() if k in tail.lower()}


def raw_rows():
    rows = []
    section = None
    for path in sorted(glob.glob(f"{HERE}/html/sc_*.html")):
        soup = BeautifulSoup(open(path, encoding="latin-1").read(), "html.parser")
        for tr in soup.find_all("tr"):
            tds = tr.find_all("td")
            if len(tds) == 1 and "held by" in tds[0].get_text():
                section = " ".join(tds[0].get_text().split())
                continue
            if len(tds) < 6:
                continue
            case = " ".join(tds[0].get_text().split())
            decl = " ".join(tds[1].get_text().split())
            hold_lines = cell_lines(tds[2])
            if case.lower() == "case" or not hold_lines:
                continue
            hands = [parse_holding(h) for h in hold_lines]
            hands = [h for h in hands if h]
            if not hands:
                continue
            # <br/>-aligned per-target rows: Need / % / Remarks stack one sub-line per target trick count.
            need_seg = br_segments(tds[3])
            pct_seg = br_segments(tds[4])
            rem_seg = br_segments(tds[5])
            # % is the authoritative column (never front-dropped). Keep its digit rows; align the remark at
            # the same index. Need sometimes drops the higher digit -> front-pad to the % length.
            pct_idx = [i for i, p in enumerate(pct_seg) if p.isdigit()]
            pcts_i = [int(pct_seg[i]) for i in pct_idx]
            rem_lines = [rem_seg[i] if i < len(rem_seg) else "" for i in pct_idx]
            needs_i = [int(n) for n in need_seg if n.isdigit()]
            while needs_i and len(needs_i) < len(pcts_i):
                needs_i.insert(0, needs_i[0] + 1)
            while len(needs_i) < len(pcts_i):
                needs_i.append(0)  # unknown need (no digit parsed); target still carries its % + line
            targets = [{"need": needs_i[i], "pct": pcts_i[i], "line": rem_lines[i]}
                       for i in range(len(pcts_i))]
            rows.append({"section": section, "case": case, "decl": decl, "hands": hands,
                         "targets": targets, "remarks": modal_line(rem_lines)})
    return rows


def reconstruct(row):
    """Return (n_bits, s_bits, flags) rebuilding hands from named honours + decl lengths + lowest spots."""
    flags = []
    m = re.match(r"^(\d+)-(\d+)$", row["decl"])
    if not m:
        return None, None, ["bad-decl"]
    lens = [int(m.group(1)), int(m.group(2))]
    honour_hands = [[c for c in h if c in HON_BIT] for h in row["hands"]]
    # pad to two hands (void second hand for n-0 splits)
    while len(honour_hands) < 2:
        honour_hands.append([])
    if len(honour_hands) > 2:
        # stray <br> split a hand; merge extras into preceding hands greedily by length fit later
        flags.append("multi-split")
    # cross-check: an opponent honour must not be in NS
    opp = opp_honours(row["section"])
    ns_hon = {c for hh in honour_hands for c in hh}
    if opp & ns_hon:
        flags.append("opp-honour-in-ns")
    # assign lowest unused bits as NS spots
    used = {HON_BIT[c] for hh in honour_hands for c in hh}
    pool = [b for b in range(13) if b not in used]  # ascending = lowest first
    hand_bits = []
    ok = True
    for i in range(2):
        hon = honour_hands[i] if i < len(honour_hands) else []
        need_spots = lens[i] - len(hon)
        if need_spots < 0:
            ok = False
            break
        bits = [HON_BIT[c] for c in hon]
        for _ in range(need_spots):
            if not pool:
                ok = False
                break
            bits.append(pool.pop(0))
        hand_bits.append(sum(1 << b for b in bits))
    if not ok:
        flags.append("length-honour-mismatch")
        return None, None, flags
    return hand_bits[0], hand_bits[1], flags


def main():
    rows = raw_rows()
    clean, anomalies = [], 0
    for r in rows:
        n, s, flags = reconstruct(r)
        r["n_bits"], r["s_bits"], r["flags"] = n, s, flags
        if n is None or ("opp-honour-in-ns" in flags):
            anomalies += 1
            continue
        clean.append(r)
    json.dump([{k: v for k, v in r.items()} for r in clean], open(f"{HERE}/suitcomb.json", "w", encoding="utf-8"), indent=1)
    print(f"raw rows={len(rows)}  clean(usable)={len(clean)}  dropped(anomalies)={anomalies}")

    # emit the diff test
    emit_odin(clean)
    print(f"emitted zz_book_diff_test.odin with {len(clean)} cases")


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def emit_odin(clean):
    lines = []
    for r in clean:
        ts = [(t["need"], t["pct"]) for t in r["targets"] if t["pct"] is not None]
        if not ts:
            continue
        padded = list(ts[:6]) + [(0, 0)] * (6 - len(ts[:6]))
        tlit = ", ".join(f"{{{need},{pct}}}" for need, pct in padded)
        lines.append(
            f'\t{{0x{r["n_bits"]:04x}, 0x{r["s_bits"]:04x}, "{esc(r["decl"])}", '
            f'"{esc(r["remarks"])[:60]}", {len(ts)}, {{{tlit}}}}},'
        )
    body = "\n".join(lines)
    src = f'''package combo

// GENERATED by encyclopedia/parse_suitcomb.py — do not edit by hand.
// Diffs the BridgeHands published suit-combination percentages against our engine's P(>=k).

import "core:fmt"
import "core:testing"

Book_Tgt :: struct {{ need, pct: int }}
Book_Case :: struct {{
\tn, s:    u16,
\tdecl:    string,
\tline:    string,
\tnt:      int,
\ttargets: [6]Book_Tgt,
}}

book_cases := []Book_Case{{
{body}
}}

@(test)
zz_book_diff :: proc(t: ^testing.T) {{
\tbuckets := [5]int{{}} // |d|<=3, <=8, <=15, ours<<book(>15 low), ours>>book(>15 high)
\tline_gap := 0    // ours << book by >15 BUT our double-dummy ceiling reaches book (headroom exists = wrong line)
\tmodel_limit := 0 // ours << book by >15 AND ceiling also below book (our isolated model cannot represent it)
\tover := 0        // ours >> book by >15 (engine over-claims vs best-defence book)
\tgaps: [dynamic]string; defer delete(gaps)
\tovers: [dynamic]string; defer delete(overs)
\tn_pts := 0
\tsum_abs := 0.0
\tfor c in book_cases {{
\t\tbl := best_line_by_mean(c.n, c.s)
\t\tcen := suit_trick_distribution(c.n, c.s)
\t\tfor i in 0 ..< c.nt {{
\t\t\ttg := c.targets[i]
\t\t\tours := 100 * p_at_least(bl.dist.p, tg.need)
\t\t\tceil := 100 * p_at_least(cen.p, tg.need)
\t\t\td := ours - f64(tg.pct)
\t\t\tad := abs(d)
\t\t\tsum_abs += ad
\t\t\tn_pts += 1
\t\t\tswitch {{
\t\t\tcase ad <= 3:  buckets[0] += 1
\t\t\tcase ad <= 8:  buckets[1] += 1
\t\t\tcase ad <= 15: buckets[2] += 1
\t\t\tcase d < 0:    buckets[3] += 1
\t\t\tcase:          buckets[4] += 1
\t\t\t}}
\t\t\tif d < -15 {{
\t\t\t\tif ceil >= f64(tg.pct) - 5 {{
\t\t\t\t\tline_gap += 1
\t\t\t\t\tif len(gaps) < 45 {{
\t\t\t\t\t\tappend(&gaps, fmt.tprintf("  %-6s need%d book=%d%% ours=%.0f%% ceil=%.0f%% best=%-14s | %s",
\t\t\t\t\t\t\tc.decl, tg.need, tg.pct, ours, ceil, bl.name, c.line))
\t\t\t\t\t}}
\t\t\t\t}} else {{ model_limit += 1 }}
\t\t\t}}
\t\t\tif d > 15 {{
\t\t\t\tover += 1
\t\t\t\tif len(overs) < 20 {{
\t\t\t\t\tappend(&overs, fmt.tprintf("  %-6s need%d book=%d%% ours=%.0f%% ceil=%.0f%% best=%-14s | %s",
\t\t\t\t\t\tc.decl, tg.need, tg.pct, ours, ceil, bl.name, c.line))
\t\t\t\t}}
\t\t\t}}
\t\t}}
\t}}
\tfmt.printfln("BOOK DIFF: %d cases, %d target-points, mean|delta|=%.1f%%", len(book_cases), n_pts, sum_abs/f64(max(n_pts,1)))
\tfmt.printfln("  |d|<=3:%d  <=8:%d  <=15:%d  ours<<book:%d  ours>>book:%d", buckets[0],buckets[1],buckets[2],buckets[3],buckets[4])
\tfmt.printfln("  of the %d 'ours<<book': LINE-GAP(ceiling reaches book, wrong line)=%d  MODEL-LIMIT(ceiling also short)=%d ; OVER=%d", buckets[3], line_gap, model_limit, over)
\tfmt.println("  --- LINE-GAP offenders (headroom exists, our line underperforms) ---")
\tfor w in gaps {{ fmt.println(w) }}
\tfmt.println("  --- OVER (engine claims MORE than best-defence book) ---")
\tfor w in overs {{ fmt.println(w) }}
\ttesting.expect(t, len(book_cases) > 0)
}}
'''
    open(f"{os.path.dirname(HERE)}/zz_book_diff_test.odin", "w", encoding="utf-8").write(src)


if __name__ == "__main__":
    main()
