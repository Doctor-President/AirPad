#!/usr/bin/env python3
"""Sweep 1 · 1.4 — what runs UNDER a frame: Time Profiler samples in each <label> step (input → +WIN ms) whose stack holds
a frame matching <regex>; counts the frames below it (inclusive, once per sample).
  under.py <trace> <rperf.txt> <label[,label…]> <regex> [WIN=1000]"""
import os, re, sys
from collections import Counter
trace, rp, LABS, RX = sys.argv[1], sys.argv[2], sys.argv[3], re.compile(sys.argv[4])
WIN = float(sys.argv[5]) if len(sys.argv) > 5 else 1000
sys.argv = [sys.argv[0], trace, '/dev/null', '50']
exec(open(os.path.join(os.path.dirname(__file__), 'k3stalls.py')).read().split("steps = []")[0])
TOP = int(os.environ.get("TOP", "50"))
for LAB in LABS.split(","):
    wins = []
    for line in open(rp):
        m = re.match(r"(\S+) \S+ .* at (\d+)", line.strip())
        if m and m.group(1) == LAB: wins.append((float(m.group(2)) - start, float(m.group(2)) - start + WIN))
    c = Counter(); n = 0; hit = 0
    for a, b in wins:
        for s in ms:
            if not (a <= s[0] <= b): continue
            n += 1
            fr = s[2]   # innermost first
            idx = next((i for i, (f, _) in enumerate(fr) if RX.search(f)), None)
            if idx is None: continue
            hit += 1; seen = set()
            for f, binname in fr[:idx]:
                k = f'{binname[:14]} · {re.sub(r"[<(].*", "", f)[:110]}'
                if k not in seen: seen.add(k); c[k] += 1
    print(f'\n===== {LAB}: {hit} of {n} main-thread samples under /{RX.pattern}/ ({hit / max(1, len(wins)):.0f} ms per step)')
    for k, v in c.most_common(TOP): print(f'  {v:5d} {v / max(hit, 1):4.0%}  {k}')
