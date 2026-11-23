#!/usr/bin/env python3
"""Sweep 2b · 2.3 — the renderer trial's Map rows, per run. Numbers only.
  trial_frames.py <recording.json> [rperf.txt]
Input seconds = seconds with a scroll / transform / touch input (or the second after). For those: presented frames a second
(code 32 shown), present gaps p50 / p95 / max, share one vsync (< 11.5 ms), gaps > 12.5 and > 25 ms, main-thread ms per frame
from the link's callback to commit (code 37) p50 / p95, GPU ms per command buffer (code 38) p50 / p95, main-thread CPU per
frame from the vitals (the baseline's "main thread per Map update"), pan / pinch changes that arrived while the link was paused
(12 / 16) and how long until the next presented frame. Rest: from 0.5 s after the last input, the next 10 s: ticks (1),
updates (3), presents (32) and process / main CPU."""
import json, sys, re, collections, bisect
d = json.load(open(sys.argv[1])); P = d["probe"]
def pct(a, p):
    a = sorted(a); return a[min(len(a) - 1, int((len(a) - 1) * p + 0.5))] if a else float("nan")
by = collections.defaultdict(list)
for t, c, v in P: by[int(c)].append((t, v))
inp = sorted(r[1] for r in d["inputs"] if r[2] in (1, 4, 5))
insec = set()
for t in inp: insec.add(int(t)); insec.add(int(t) + 1)
vid = collections.Counter(int(v) for t, v in by[30]).most_common(1)
vid = vid[0][0] if vid else None
shown = sorted(t for t, v in by[32] if vid is not None and int(v) == vid + 100000)
dropped = sum(1 for t, v in by[32] if vid is not None and int(v) == vid)
def gaps(ts): return [(b - a) * 1000 for a, b in zip(ts, ts[1:])]
act = sorted(insec & set(int(t) for t in shown))
per = collections.Counter(int(t) for t in shown)
g = [x for x in gaps(shown) if int(shown[0]) >= 0]  # all gaps; keep those whose end lies in an input second
g_in = [(b - a) * 1000 for a, b in zip(shown, shown[1:]) if int(b) in insec and int(a) in insec]
main = [v for t, v in by[37] if int(t) in insec]
gpu = [v for t, v in by[38] if int(t) in insec]
vit = {int(v[0]): v[3] for v in d.get("vitals", [])}
mc = [vit[s] * 10 / per[s] for s in act if s in vit and per[s] >= 30]   # % of a second → ms, per frame
print(f"view {vid} · input seconds {len(act)} · presented frames {len(shown)} (dropped {dropped})")
if act:
    F = [per[s] for s in act]
    print(f"presented/s  min {min(F)}  p10 {pct(F,.1)}  median {pct(F,.5)}  max {max(F)}")
    print("per second:", " ".join(str(per[s]) for s in act))
    n = max(1, len(g_in))
    print(f"present gap p50 {pct(g_in,.5):.2f}  p95 {pct(g_in,.95):.2f}  max {max(g_in, default=0):.1f} ms · one-vsync {100*sum(1 for x in g_in if x < 11.5)/n:.1f} %"
          f" · two-vsync {100*sum(1 for x in g_in if 13.5 < x < 19.5)/n:.1f} % · >12.5 ms {sum(1 for x in g_in if x > 12.5)} · >25 ms {sum(1 for x in g_in if x > 25)}"
          f" · gaps {len(g_in)}")
    print(f"main thread per frame (callback→commit, code 37): p50 {pct(main,.5):.2f}  p95 {pct(main,.95):.2f}  max {max(main, default=0):.2f} ms (n {len(main)})")
    print(f"GPU per command buffer (code 38): p50 {pct(gpu,.5):.2f}  p95 {pct(gpu,.95):.2f}  max {max(gpu, default=0):.2f} ms (n {len(gpu)})")
    print(f"main-thread CPU per presented frame (vitals, seconds ≥ 30 frames): median {pct(mc,.5):.2f}  p95 {pct(mc,.95):.2f} ms (n {len(mc)} s)")
# Full awake seconds: the link ran the whole second (no pause / wake inside it, awake at its start) and input arrived in
# it. This is the "every pan second" row: per-second totals above also hold the rests between rperf steps (link paused).
ev = sorted([(t, 0) for t, v in by[7]] + [(t, 1) for t, v in by[8]])
def awake_at(x):
    st = 1
    for t, k in ev:
        if t > x: break
        st = k
    return st
evs = collections.Counter(int(t) for t, k in ev)
full = [s for s in act if evs[s] == 0 and awake_at(s) == 1 and per[s] > 0]
if full:
    Ff = [per[s] for s in full]
    print(f"full awake input seconds {len(full)}: presented/s min {min(Ff)} p10 {pct(Ff,.1)} median {pct(Ff,.5)} · seconds < 118: {sum(1 for x in Ff if x < 118)}"
          f" · per second: {' '.join(str(x) for x in Ff)}")
wt = [v for t, v in by[19] if int(t) in insec]
if wt: print(f"drawable wait (inside code 37): p50 {pct(wt,.5):.2f}  p95 {pct(wt,.95):.2f}  max {max(wt):.2f} ms")
# changes that arrived while paused → time to the next shown frame
for code, name in ((12, "pan"), (16, "pinch")):
    ev = [t for t, v in by[code]]
    lat = []
    for t in ev:
        i = bisect.bisect_left(shown, t)
        if i < len(shown): lat.append((shown[i] - t) * 1000)
    print(f"{name} changes while paused: {len(ev)}" + (f" · next shown frame after p50 {pct(lat,.5):.1f}  max {max(lat):.1f} ms" if lat else ""))
print(f"pauses {len(by[7])} · wakes {len(by[8])} by reason {dict(collections.Counter(int(v) for t, v in by[8]))}")
# rest: 0.5 s after the last input, 10 s
if inp:
    t0 = inp[-1] + 0.5; t1 = t0 + 10
    def cnt(c): return sum(1 for t, v in by[c] if t0 <= t < t1)
    rs = [vit[s] for s in range(int(t0) + 1, int(t1)) if s in vit]
    pc = {int(v[0]): v[2] for v in d.get("vitals", [])}; ps = [pc[s] for s in range(int(t0) + 1, int(t1)) if s in pc]
    print(f"rest {t1 - t0:.0f} s from last input + 0.5 s: ticks {cnt(1)} · updates {cnt(3)} · presented {sum(1 for t in shown if t0 <= t < t1)} · main CPU % mean {sum(rs)/max(1,len(rs)):.2f} · process CPU % mean {sum(ps)/max(1,len(ps)):.2f} (recorder on)")
snap = by[39]
if snap: print(f"snapshots {len(snap)} · ms {', '.join(f'{v:.1f}' for t, v in snap)}")
