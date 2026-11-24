#!/usr/bin/env python3
"""Sweep 2b · step 5 re-proof of 2.1's pacer (dec5a265): Map update gaps (probe code 3, value = asked rate) in vsyncs, per
asked rate. A clean 60 on 120 Hz = 2 vsyncs, 8 = 15 vsyncs. Numbers only.  pacer_steps.py <recording.json>..."""
import json, sys, collections
for f in sys.argv[1:]:
    P = json.load(open(f))["probe"]; up = sorted((t, v) for t, c, v in P if int(c) == 3)
    out = []
    for rate in (120, 60, 30, 8):
        ts = [t for t, v in up if v == rate]
        g = [(b - a) * 1000 for a, b in zip(ts, ts[1:]) if b - a < 0.5]
        if not g: continue
        c = collections.Counter(round(x / 8.333) for x in g)
        top = ", ".join(f"{k}v {100 * n / len(g):.0f}%" for k, n in c.most_common(3))
        out.append(f"asked {rate}: {len(ts)} updates, gaps {top}")
    print(f.split("/")[-2], "·", " · ".join(out))
