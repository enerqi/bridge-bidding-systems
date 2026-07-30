# /// script
# requires-python = ">=3.11"
# ///
"""Canonical-key collision analysis for the suit-combination table (reads suitcomb.json)."""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def rle_key(n, s):
    """Top-down (rank 12->0) ownership run-length key over {N,S,o}, made N<->S swap invariant."""
    def seq(a, b):
        syms = []
        for r in range(12, -1, -1):
            bit = 1 << r
            syms.append("N" if a & bit else "S" if b & bit else "o")
        # run-length encode
        rle = []
        i = 0
        while i < len(syms):
            j = i
            while j < len(syms) and syms[j] == syms[i]:
                j += 1
            rle.append(f"{syms[i]}{j - i}")
            i = j
        return "".join(rle)
    k1 = seq(n, s)
    # swap N/S labels
    k2 = seq(s, n).replace("N", "X").replace("S", "N").replace("X", "S")
    return min(k1, k2)


def main():
    rows = json.load(open(f"{HERE}/suitcomb.json", encoding="utf-8"))
    keymap = {}
    collisions = 0
    conflict_samples = []
    for r in rows:
        k = rle_key(r["n_bits"], r["s_bits"])
        tgt = tuple((n, p) for n, p in r["targets"] if p is not None)
        if k in keymap:
            prev = keymap[k]
            # conflict only if the odds differ materially
            if dict(prev["tgt"]) != dict(tgt):
                collisions += 1
                if len(conflict_samples) < 15:
                    conflict_samples.append((k, prev["decl"], dict(prev["tgt"]), r["decl"], dict(tgt),
                                             prev["remarks"][:28], r["remarks"][:28]))
        else:
            keymap[k] = {"tgt": tgt, "decl": r["decl"], "remarks": r["remarks"]}
    print(f"rows={len(rows)}  distinct keys={len(keymap)}  conflicting-collisions={collisions}")
    print("--- sample conflicts (same key, different odds) ---")
    for c in conflict_samples:
        print(f"  key={c[0]}")
        print(f"     A {c[1]:5} {c[2]} [{c[5]}]")
        print(f"     B {c[3]:5} {c[4]} [{c[6]}]")


if __name__ == "__main__":
    main()
