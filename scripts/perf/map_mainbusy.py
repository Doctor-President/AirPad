#!/usr/bin/env python3
# Sweep 2b · 2.3a — per second with Map updates: updates, asked rates, main-thread run-loop spans >= 4 ms (count, p50, p95, share > 8.3 ms,
# sum = busy ms), vitals main-thread CPU %, update gaps > 12.5 ms. Numbers only.  mainbusy.py <recording.json> [from_s to_s]
import json, sys, collections
d = json.load(open(sys.argv[1]))
P = d["probe"]; t0 = min(t for t, c, v in P if int(c) == 3)
lo = float(sys.argv[2]) if len(sys.argv) > 3 else -1e9; hi = float(sys.argv[3]) if len(sys.argv) > 3 else 1e9
upd = collections.defaultdict(list); ask = collections.defaultdict(set)
for t, c, v in P:
    if int(c) == 3: upd[int(t)].append(t)
    if int(c) == 6: ask[int(t)].add(int(v))
sp = collections.defaultdict(list)
for t, ms in d["spans"]: sp[int(t)].append(ms)
vit = {int(v[0]): v[3] for v in d["vitals"]}
def pct(a, p): a = sorted(a); return a[min(len(a) - 1, int((len(a) - 1) * p + 0.5))] if a else 0
allsp = []; tot = collections.Counter()
print("sec  upd  asked     spans p50  p95  >8.3ms  busy-ms mainCPU%  updgap>12.5")
for s in sorted(upd):
    rel = s - int(t0)
    if not (lo <= rel <= hi): continue
    u = sorted(upd[s]); g = [(b - a) * 1000 for a, b in zip(u, u[1:])]
    x = sp[s]; allsp += x if len(u) >= 30 else []
    print(f"{rel:3d} {len(u):4d}  {'/'.join(map(str, sorted(ask[s]))) or '-':8s} {len(x):5d} {pct(x,.5):4.1f} {pct(x,.95):5.1f} {sum(1 for y in x if y > 8.3):6d} {sum(x):8.0f} {vit.get(s, 0):7.0f} {sum(1 for y in g if y > 12.5):8d}")
print(f"seconds with >=30 updates: spans {len(allsp)}, p50 {pct(allsp,.5):.1f} p95 {pct(allsp,.95):.1f} ms, share > 8.3 ms {sum(1 for y in allsp if y > 8.3) / max(1, len(allsp)):.0%}")
