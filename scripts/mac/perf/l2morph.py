#!/usr/bin/env python3
"""E fix-up 5 · L2 — summarise -MacMorphLog lines: per morph (open = target 1, close = target 0) the frames, the time to
50 / 90 / 99 % on the wall clock, the frame intervals (p50 / max) and how many frames were late (> 1.5 × the median).
  l2morph.py <morph.txt>"""
import re, sys, statistics
for line in open(sys.argv[1]):
    m = re.search(r'\[MorphLog\] (\w+) start t=(\d+) target=(\d) (.*) frames=(\d+)', line)
    if not m: continue
    why, t0, target, rows = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4).split()
    dts = [float(r.split(':')[0]) for r in rows]; ps = [float(r.split(':')[1]) for r in rows]
    t, marks = 0.0, {}
    for dt, p in zip(dts, ps):
        t += dt
        done = p if target else 1 - p
        for k in (0.5, 0.9, 0.99):
            if done >= k and k not in marks: marks[k] = t
    med = statistics.median(dts[1:]) if len(dts) > 2 else 0
    late = sum(1 for d in dts[1:] if med and d > 1.5 * med)
    print(f"{'open ' if target else 'close'} {why:8s} frames {len(dts):3d} · 50% {marks.get(0.5, float('nan')):5.0f} ms · 90% {marks.get(0.9, float('nan')):5.0f} · 99% {marks.get(0.99, float('nan')):5.0f} · dt p50 {med:4.1f} max {max(dts[1:] or [0]):5.1f} · late {late}")
