#!/usr/bin/env python3
"""E fix-up 4 · K3 — main-thread frame intervals during each scroll / pan step.
  k3frames.py <app.log with [FrameLog] lines> <rperf.txt> [window ms = 900]
Each rperf step line ends "at <wall ms>"; the app logs its display-link intervals as "[FrameLog] t=<wall ms> dt=a,b,…"
(one line per 120 frames, t = the first frame's wall time). For each scroll/drag step: the intervals inside
[step, step + window], their p50 / p95 / max, the share over 8.4 ms (a missed 120 Hz frame) and over 16.8 ms."""
import re, sys
log, rperf = sys.argv[1], sys.argv[2]
WIN = float(sys.argv[3]) if len(sys.argv) > 3 else 900
frames = []   # (wall ms at the END of the interval, dt)
for line in open(log, errors='ignore'):
    m = re.search(r'\[FrameLog\] t=(\d+) dt=([\d.,]+)', line)
    if not m: continue
    t = float(m.group(1))
    for d in m.group(2).split(','):
        d = float(d); t += d; frames.append((t, d))
mx = re.search(r'screen max (\d+) fps', open(log, errors='ignore').read())
print(f'screen max {mx.group(1) if mx else "?"} fps · {len(frames)} intervals logged')
def pct(v, p): s = sorted(v); return s[min(len(s) - 1, max(0, int(round(len(s) * p + 0.5)) - 1))] if s else float('nan')
rows = {}
for line in open(rperf):
    m = re.match(r'(\S+) (scroll|drag) .* at (\d+)', line.strip())
    if not m: continue
    t0 = float(m.group(3))
    dts = [d for t, d in frames if t0 <= t <= t0 + WIN]
    rows.setdefault(m.group(1), []).extend(dts)
for lab, dts in rows.items():
    if not dts: print(f'{lab:14} no frames'); continue
    over8 = sum(d > 8.4 for d in dts) / len(dts); over16 = sum(d > 16.8 for d in dts) / len(dts)
    print(f'{lab:14} n {len(dts):4d} · p50 {pct(dts, .5):5.1f} · p95 {pct(dts, .95):5.1f} · max {max(dts):6.1f} ms · '
          f'>8.4 ms {over8:4.0%} · >16.8 ms {over16:4.0%} · ≈ {1000 / (sum(dts) / len(dts)):.0f} fps')
