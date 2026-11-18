#!/usr/bin/env python3
"""E fix-up 6 · M7 — entry open / close: rperf's visible (input → first changed frame) and settled (→ last change)
per action, p50 / p95, for several runs side by side.   m7open.py <label=rperf.txt> …"""
import re, sys
def pct(v, p): s = sorted(v); return s[min(len(s) - 1, max(0, int(round(len(s) * p + 0.5)) - 1))] if s else float('nan')
print('| action | ' + ' | '.join(a.split('=')[0] + ' visible p50/p95 · settled p50/p95 ms' for a in sys.argv[1:]) + ' |')
rows = {}
for a in sys.argv[1:]:
    lab, f = a.split('=')
    for line in open(f):
        m = re.match(r'(\S+) (\S+) visible (\S+) settled (\S+) frames', line.strip())
        if m and m.group(1).startswith(('open-', 'close-')):
            v = float(m.group(3)) if m.group(3) not in ('-', 'none') else None
            st = float(m.group(4)) if m.group(4) not in ('-', 'none') else None
            rows.setdefault(m.group(1), {}).setdefault(lab, []).append((v, st))
for act, d in rows.items():
    cells = []
    for a in sys.argv[1:]:
        lab = a.split('=')[0]; xs = d.get(lab, [])
        vis = [x for x, _ in xs if x is not None]; st = [y for _, y in xs if y is not None]
        cells.append(f'{pct(vis,.5):.0f}/{pct(vis,.95):.0f} · {pct(st,.5):.0f}/{pct(st,.95):.0f} (n {len(xs)})')
    print(f'| {act} | ' + ' | '.join(cells) + ' |')
