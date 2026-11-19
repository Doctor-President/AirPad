#!/usr/bin/env python3
"""Sweep 1 · 1.4 (from m4prof.py) — what the main thread does in each <label> step: Time Profiler samples inside each cards-scroll
step (step start → +WIN ms), counted by frame (inclusive, once per sample).  swprof.py <trace> <rperf.txt> <label> [WIN=1000]"""
import os, re, sys
from collections import Counter
trace, rp = sys.argv[1], sys.argv[2]; WIN = float(sys.argv[4]) if len(sys.argv) > 4 else 1000; LABS = sys.argv[3]
sys.argv = [sys.argv[0], trace, '/dev/null', '50']
exec(open(os.path.join(os.path.dirname(__file__), 'k3stalls.py')).read().split("steps = []")[0])
TOP = int(os.environ.get("TOP", "60"))
for LAB in LABS.split(","):
    wins = []
    for line in open(rp):
        m = re.match(r"(\S+) \S+ .* at (\d+)", line.strip())
        if m and m.group(1) == LAB: wins.append((float(m.group(2)) - start, float(m.group(2)) - start + WIN))
    c = Counter(); n = 0
    for a, b in wins:
        for s in ms:
            if a <= s[0] <= b:
                n += 1; seen = set()
                for f, binname in s[2]:
                    k = f'{binname[:14]} · {re.sub(r"[<(].*", "", f)[:110]}'
                    if k not in seen: seen.add(k); c[k] += 1
    total = sum(b - a for a, b in wins)
    print(f'\n===== {len(wins)} {LAB} windows, {total:.0f} ms, main-thread samples {n} ({n / max(total, 1):.0%} busy, {n / max(1, len(wins)):.0f} ms per step)')
    for k, v in c.most_common(TOP): print(f'  {v:5d} {v / max(n, 1):4.0%}  {k}')
    print('--- AirPad frames')
    for k, v in c.most_common(2000)[:TOP * 3]:
        if k.startswith('AirPad') and not re.search(r'· (main|)$', k): print(f'  {v:5d} {v / max(n, 1):4.0%}  {k}')
