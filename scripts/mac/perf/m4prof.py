#!/usr/bin/env python3
"""E fix-up 6 · M4 — what the main thread does while Cards scrolls: Time Profiler samples inside each cards-scroll
step (step start → +WIN ms), counted by frame (inclusive, once per sample).  m4prof.py <trace> <rperf.txt> [WIN=900]"""
import os, re, sys
from collections import Counter
trace, rp = sys.argv[1], sys.argv[2]; WIN = float(sys.argv[3]) if len(sys.argv) > 3 else 900
sys.argv = [sys.argv[0], trace, '/dev/null', '50']
exec(open(os.path.join(os.path.dirname(__file__), 'k3stalls.py')).read().split("steps = []")[0])
wins = []
for line in open(rp):
    m = re.match(r'(\S+) scroll .* at (\d+)', line.strip())
    if m and m.group(1) == 'cards-scroll': wins.append((float(m.group(2)) - start, float(m.group(2)) - start + WIN))
c = Counter(); n = 0
for a, b in wins:
    for s in ms:
        if a <= s[0] <= b:
            n += 1; seen = set()
            for f, binname in s[2]:
                k = f'{binname[:14]} · {re.sub(r"[<(].*", "", f)[:90]}'
                if k not in seen: seen.add(k); c[k] += 1
total = sum(b - a for a, b in wins)
print(f'{len(wins)} cards-scroll windows, {total:.0f} ms, main-thread samples {n} ({n / max(total, 1):.0%} busy)')
for k, v in c.most_common(60): print(f'  {v:5d} {v / max(n, 1):4.0%}  {k}')
print('--- AirPad frames'); 
for k, v in c.most_common(2000):
    if k.startswith('AirPad') and not re.search(r'· (main|)$', k): print(f'  {v:5d} {v / max(n, 1):4.0%}  {k}')
