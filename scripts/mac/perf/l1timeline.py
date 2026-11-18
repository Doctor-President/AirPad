#!/usr/bin/env python3
"""E fix-up 5 · L1 — one stall as a timeline: per 10 ms of main-thread samples, the most telling frames (the innermost
AirPad view body or our code, else the innermost UIKit/SwiftUI method that names a phase).
  l1timeline.py <session.trace> <rperf.txt> <label> [which = 0]"""
import os, re, sys
from collections import Counter
want, which = sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 0
sys.argv = sys.argv[:3] + ['50']
src = open(os.path.join(os.path.dirname(__file__), 'k3stalls.py')).read().split("print(f'main thread:")[0]
exec(src)
mine = [r for r in stalls if step_at(start + r[0][0]) == want]
r = mine[which]; t0 = r[0][0]
print(f'{want} #{which}: {r[-1][0] - t0 + 1:.0f} ms from {t0:.0f}')
KEY = re.compile(r'(body\.getter|\.getter|init|layoutSubviews|sizeThatFits|commit|Transition|Menu|updateGraph|render|Typesetter|_UIHostingView|UIHostingController|viewWill|viewDid|removeFromSuperview|didMoveTo|deinit|destroy)')
buckets = {}
for s in r:
    b = int((s[0] - t0) // 10)
    for name, binname in s[2]:
        if binname.startswith('AirPad') and name not in ('main',) and 'AirPadApp.$main' not in name and not name.startswith('0x') and name.strip():
            buckets.setdefault(b, Counter())['A ' + re.sub(r'\(.*', '', name)[:70]] += 1; break
    else:
        for name, binname in s[2]:
            if binname in ('UIKitCore', 'SwiftUI', 'SwiftUICore', 'QuartzCore', 'UIFoundation') and KEY.search(name):
                buckets.setdefault(b, Counter())[f'{binname[:6]} ' + re.sub(r'\(.*', '', name)[:70]] += 1; break
for b in sorted(buckets):
    top = buckets[b].most_common(2)
    print(f'  {b*10:4d}  ' + ' | '.join(f'{n} ×{c}' for n, c in top))
