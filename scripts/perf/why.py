#!/usr/bin/env python3
"""why.py — one action from a measured run, in depth: which AirPad code and which system work was on the main
thread's stack while it was busy, and which views rebuilt (Mac perf audit P2).

  why.py <recording.json> <rperf.txt | steps.tsv> <label> [top=14]

Inclusive: a symbol counts once per stack sample it appears anywhere in, so a caller shows the time of everything
it sets off. AirPad's own symbols first (the code a fix can change), then the system frames nearest the leaf.
"""
import sys, collections, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import explain as E, steps as S


def main(a):
    d = E.load(a[0]); rows = S.analyse(d, S.read_steps(a[1])); label = a[2]; top = int(a[3]) if len(a) > 3 else 14
    syms = d["symbols"]; app_img = None
    inc, leaf, n, busy_ms = collections.Counter(), collections.Counter(), 0, 0
    bodies = collections.Counter(); wins = 0
    for r in rows:
        if r["label"] != label: continue
        wins += 1
        w = E.window(d, r["t0"] - 0.02, r["t1"])
        busy_ms += sum(s[1] for s in w["spans"])
        for b in w["bodies"]:
            for k, v in b[1].items(): bodies[k] += v
        for smp in d["samples"]:
            if not (r["t0"] - 0.02 <= smp["t"] <= r["t1"]): continue
            n += 1
            seen = set()
            for i in smp["f"]:
                e = syms[i]; name = E.short(e.get("s") or "?") if hasattr(E, "short") else e.get("s")
                key = (e.get("i") or "?", name)
                if key not in seen: seen.add(key); inc[key] += 1
            if smp["f"]:
                e = syms[smp["f"][0]]; leaf[(e.get("i") or "?", E.short(e.get("s") or "?"))] += 1
    if not n: print(f"{label}: no busy samples in {wins} window(s)"); return
    print(f"{label}: {wins} window(s), main thread busy {busy_ms:.0f} ms, {n} stack samples of a busy main thread")
    print("AirPad code (inclusive):")
    k = 0
    for (img, name), c in inc.most_common():
        if img != "AirPad" or E.NOISE.search(name): continue
        print(f"  {100 * c / n:4.0f}%  {name[:150]}"); k += 1
        if k >= top: break
    print("system work (innermost frame):")
    for (img, name), c in leaf.most_common(top):
        print(f"  {100 * c / n:4.0f}%  {img}: {name[:120]}")
    print("system work (inclusive, selected):")
    k = 0
    for (img, name), c in inc.most_common(400):
        if img == "AirPad" or c / n > 0.85: continue
        print(f"  {100 * c / n:4.0f}%  {img}: {name[:120]}"); k += 1
        if k >= top + 10: break
    print("views rebuilt: " + ", ".join(f"{k} ×{v}" for k, v in bodies.most_common(14)))


if __name__ == "__main__":
    if len(sys.argv) < 4: print(__doc__); sys.exit(2)
    main(sys.argv[1:])
