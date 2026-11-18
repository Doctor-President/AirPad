#!/usr/bin/env python3
"""E fix-up 5 · L2 — what the main thread does during the open morphs: Time Profiler samples inside each open morph's
window (from -MacMorphLog's start to its settle), counted by frame (inclusive, once per sample), AirPad + a few
framework phases.  l2prof.py <morph.trace> <morph.txt>"""
import os, re, sys
from collections import Counter
trace, mt = sys.argv[1], sys.argv[2]
sys.argv = [sys.argv[0], trace, '/dev/null', '50']
src = open(os.path.join(os.path.dirname(__file__), 'k3stalls.py')).read().split("steps = []")[0]
exec(src)
wins = []
for line in open(mt):
    m = re.search(r'\[MorphLog\] \w+ start t=(\d+) target=1 (.*) frames', line)
    if m:
        dur = sum(float(r.split(':')[0]) for r in m.group(2).split())
        wins.append((int(m.group(1)) - start, int(m.group(1)) - start + dur))
c = Counter(); n = 0; busy = 0; total = 0
for a, b in wins:
    total += b - a
    for s in ms:
        if a <= s[0] <= b:
            n += 1; seen = set()
            for f, binname in s[2]:
                k = f'{binname[:12]} · {re.sub(r"[<(].*", "", f)[:80]}'
                if k not in seen: seen.add(k); c[k] += 1
print(f'{len(wins)} open morphs, {total:.0f} ms, main-thread samples {n} ({n / max(total, 1):.0%} busy)')
for k, v in c.most_common(400):
    if ('AirPad' in k and '$main' not in k and k.split(' · ')[1] not in ('main', '')) or re.search(r'Transaction::commit|updateGraph|render|layoutSubviews|sizeThatFits|SKView|SKScene|Typesetter', k):
        print(f'  {v:5d} {v / max(n, 1):4.0%}  {k}')
