#!/usr/bin/env python3
"""Sweep 2b — per second of a recording: the Map's update calls (`map` rows) beside scroll / hover / transform inputs,
and the window's own frames. Numbers only.   map_seconds.py <recording.json> [rperf.txt]
With rperf.txt, seconds are labelled by the rperf step running then (from its "at <wall ms>" stamps)."""
import json, sys, re, collections
d = json.load(open(sys.argv[1]))
wall = d.get("wallOffset", 0)
steps = []
if len(sys.argv) > 2:
    for l in open(sys.argv[2]):
        m = re.match(r"^(\S+) (\S+) .* at (\d+)", l)
        if m: steps.append((int(m.group(3)) / 1000 - wall, m.group(1)))
def label(t):
    cur = ""
    for st, name in steps:
        if st <= t: cur = name
    return cur
inp = collections.Counter(); kinds = {3: "hover", 4: "scroll", 5: "transform"}
for r in d["inputs"]:
    inp[(int(r[0]), kinds.get(r[2], str(r[2])))] += 1
fr = collections.Counter(int(t) for t, _ in d["frames"])
print("sec   step          map-upd  max-gap  mean-ms  scroll  transform  hover  window-frames")
for row in d["map"]:
    t = row[0]; s = int(t)
    print(f"{t:9.1f} {label(t):13s} {row[1]:7d}  {row[2]:7.1f}  {row[3]:7.2f}  {inp[(s,'scroll')]:6d}  {inp[(s,'transform')]:9d}  {inp[(s,'hover')]:5d}  {fr[s]:5d}")
