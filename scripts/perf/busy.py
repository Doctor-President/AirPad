#!/usr/bin/env python3
"""busy.py — per-label p50 / p95 of a scripted run, with the main thread's BUSY time in the first second after each step's
input (steps.py's table leaves it out; the first second keeps a place's own work at rest, e.g. Cards' gradients, out): screen visible / settled (rperf), app input → free, busy ms, longest stall, plus every trial.

  busy.py <recording.json> <rperf.txt> [label …] [--trials] [--views label]   (sweep 1 · 1.4, sheet C)
--views <label>: the views rebuilt most in that label's windows, summed over its trials.
"""
import sys, os, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import explain as E, steps as S

a = sys.argv[1:]
d = E.load(a[0]); rows = S.analyse(d, S.read_steps(a[1]))
want = [x for x in a[2:] if not x.startswith("--") and (a.index(x) == 0 or a[a.index(x) - 1] != "--views")]
order = []
for r in rows:
    if r["label"] != "rest" and r["label"] not in order and (not want or r["label"] in want): order.append(r["label"])
f = lambda x: "-" if x is None else f"{x:.0f}"
print("| action | n | visible p50/p95 | settled p50/p95 | input→free p50/p95 | busy ms in 1 s p50/p95 | longest stall p50/max |")
print("|---|---|---|---|---|---|---|")
for l in order:
    g = [r for r in rows if r["label"] == l]
    def pp(v):
        v = [x for x in v if x is not None]
        return (E.pct(v, 0.5), E.pct(v, 0.95)) if v else (None, None)
    vis = pp([r["visible"] for r in g]); st = pp([r["settled"] for r in g]); rs = pp([r["resp"] for r in g])
    b1 = lambda r: E.summarise(E.window(d, r["t0"] - 0.02, min(r["t1"], r["t0"] + 1.0)))["busy_ms"]
    bz = pp([b1(r) for r in g]); hm = pp([r["s"]["hang_max"] for r in g])
    print(f"| {l} | {len(g)} | {f(vis[0])} / {f(vis[1])} | {f(st[0])} / {f(st[1])} | {f(rs[0])} / {f(rs[1])} | {f(bz[0])} / {f(bz[1])} | {f(hm[0])} / {f(max(r['s']['hang_max'] for r in g))} |")
    if "--trials" in a:
        for r in g:
            print(f"    t={r['t0']:.1f} vis {f(r['visible'])} set {f(r['settled'])} resp {f(r['resp'])} busy1s {b1(r)} stall {r['s']['hang_max']:.0f}")
if "--views" in a:
    lab = a[a.index("--views") + 1]
    c = collections.Counter()
    for r in rows:
        if r["label"] != lab: continue
        w = E.window(d, r["t0"] - 0.02, r["t1"])
        for b in w["bodies"]:
            for k, v in b[1].items(): c[k] += v
    print(f"\nviews rebuilt in {lab}: " + ", ".join(f"{k} ×{v}" for k, v in c.most_common(25)))
