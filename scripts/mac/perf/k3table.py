#!/usr/bin/env python3
"""E fix-up 4 · K3 — the before/after table, one row per action of the session script.
  k3table.py <before dir> <after dir>   (each: rperf.txt + stalls.json from k3stalls.py with STALLS_JSON)
visible = input → the first changed frame (rperf). settled = input → the last change, extended to the end of any
main-thread stall overlapping the step (a stalled main thread draws nothing, which a screen watch reads as "still").
longest stall = the longest main-thread stall starting inside the step (Time Profiler, ≥ 50 ms)."""
import json, re, sys
def load(d):
    steps = []
    for line in open(f'{d}/rperf.txt'):
        m = re.match(r'(\S+) (\S+) visible (\S+) settled (\S+) frames \d+ at (\d+)', line.strip())
        if m: steps.append([m.group(1), m.group(2), None if m.group(3) == '-' else float(m.group(3)),
                            None if m.group(4) == '-' else float(m.group(4)), float(m.group(5))])
    stalls = json.load(open(f'{d}/stalls.json'))
    out = {}
    for i, (lab, verb, vis, sett, t) in enumerate(steps):
        nxt = steps[i + 1][4] if i + 1 < len(steps) else t + 4000
        s_in = [s for s in stalls if t - 20 <= s['t'] < nxt]
        end = max([s['t'] + s['d'] - t for s in s_in], default=0)
        settled = max(sett or 0, end if end < 4000 else 0) or None
        longest = max([s['d'] for s in s_in], default=0)
        out.setdefault(lab, []).append((vis, settled, longest))
    return out
def pct(v, p):
    v = sorted(x for x in v if x is not None)
    return v[min(len(v) - 1, max(0, int(round(len(v) * p + 0.5)) - 1))] if v else None
b, a = load(sys.argv[1]), load(sys.argv[2])
f = lambda x: '-' if x is None else f'{x:.0f}'
print('| action | n | visible p50 / p95 ms (before → after) | settled p50 / p95 ms | longest stall ms |')
print('|---|---|---|---|---|')
for lab in b:
    if lab not in a: continue
    B, A = b[lab], a[lab]
    print(f'| {lab} | {len(A)} | {f(pct([x[0] for x in B], .5))} / {f(pct([x[0] for x in B], .95))} → {f(pct([x[0] for x in A], .5))} / {f(pct([x[0] for x in A], .95))}'
          f' | {f(pct([x[1] for x in B], .5))} / {f(pct([x[1] for x in B], .95))} → {f(pct([x[1] for x in A], .5))} / {f(pct([x[1] for x in A], .95))}'
          f' | {f(max(x[2] for x in B))} → {f(max(x[2] for x in A))} |')
