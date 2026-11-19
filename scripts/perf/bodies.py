#!/usr/bin/env python3
"""bodies.py — the views whose body ran in each action's first second (the recorder's 0.2 s buckets), per trial on
average: what a switch rebuilds, outgoing views included. Sweep 1 · 1.4 (sheet C).
  bodies.py <recording.json> <rperf.txt | steps.tsv> <label[,label…]> [--secs S]"""
import sys, os, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import steps as S
a = sys.argv[1:]
import explain as E
d = E.load(a[0], symbolicate=False); rows = S.analyse(d, S.read_steps(a[1]))
secs = float(a[a.index("--secs") + 1]) if "--secs" in a else 1.0
for lab in a[2].split(","):
    g = [r for r in rows if r["label"] == lab]
    c = collections.Counter()
    for r in g:
        for b in d["bodies"]:
            if r["t0"] - 0.02 <= b[0] < r["t0"] + secs:
                for k, v in b[1].items(): c[k] += v
    print(f"{lab} ({len(g)} trials, per trial): " + ", ".join(f"{k.split('<')[0]} {v / max(1, len(g)):.0f}" for k, v in c.most_common(30)))
