#!/usr/bin/env python3
"""incl.py — INCLUSIVE main-thread samples per symbol for one action of a scripted run, summed over its trials (the first
second after each input): which of AirPad's functions (or SwiftUI's) a switch's time sits under. Sweep 1 · 1.4 (sheet C).

  incl.py <recording.json> <rperf.txt | steps.tsv> <label[,label…]> [--all] [--top N] [--secs S]
Default: AirPad's own symbols (images AirPad / AirPadMacA); --all = every symbol.
"""
import sys, os, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import explain as E, steps as S

a = sys.argv[1:]
d = E.load(a[0]); rows = S.analyse(d, S.read_steps(a[1]))
top = int(a[a.index("--top") + 1]) if "--top" in a else 40
secs = float(a[a.index("--secs") + 1]) if "--secs" in a else 1.0
syms = d["symbols"]
for lab in a[2].split(","):
  c = collections.Counter(); n = 0
  for r in rows:
    if r["label"] != lab: continue
    w = E.window(d, r["t0"] - 0.02, min(r["t1"], r["t0"] + secs))
    for smp in w["samples"]:
        n += 1
        seen = set()
        for i in smp["f"]:
            e = syms[i]; name = e.get("s") or "?"; img = e.get("i") or ""
            if "--all" not in a and not any(x in img for x in E.APP_IMAGES): continue
            if name in seen: continue
            seen.add(name); c[name] += 1
  print(f"\n{lab}: {n} main-thread samples (~{n * 10} ms busy) in {sum(1 for r in rows if r['label'] == lab)} trials")
  for k, v in c.most_common(top):
    print(f"{100 * v / max(1, n):5.1f}%  {v:4d}  {k[:150]}")
