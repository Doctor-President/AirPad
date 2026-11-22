#!/usr/bin/env python3
"""Sweep 2b · 2.1 — one line per step of a 2b-map-proof run: the Map's scene updates / drawn frames per second while
input arrives (min / median), gaps (p50 / p95), what share of present gaps were a clean one or two vsyncs, the overlay
gaps on drawn frames, and the updates per second at rest. Numbers only.
  map_proof.py <recording.json> [rperf.txt]   (without rperf.txt, rows are the screens the recording passed through)"""
import json, sys, re, collections, bisect
d = json.load(open(sys.argv[1])); wall = d.get("wallOffset", 0)
steps = []
for l in (open(sys.argv[2]) if len(sys.argv) > 2 else []):   # without rperf.txt (T's ⌃⌥⌘P file): one row per screen
    m = re.match(r"^(\S+) (\S+) .* at (\d+)", l)
    if m: steps.append((int(m.group(3)) / 1000 - wall, m.group(1)))
if len(sys.argv) <= 2:
    for t, name in d.get("marks", []):
        if str(name).startswith("screen: "): steps.append((t, str(name)[8:].split(" · ")[0] + ("·" + str(name).split(" · ")[1] if " · " in str(name) else "")))
# rest steps aren't timed by rperf: a second after the last measured step's end belongs to "rest after <step>"
def label(t):
    cur = ""
    for st, name in steps:
        if st <= t: cur = name
    return cur
rows = d["probe"]
per = collections.defaultdict(lambda: collections.defaultdict(list))
for t, c, v in rows: per[int(t)][int(c)].append((t, v))
inp = collections.Counter()
for r in d["inputs"]:
    if r[2] in (1, 4, 5): inp[int(r[1])] += 1
def pct(a, p):
    a = sorted(a); return a[min(len(a) - 1, int((len(a) - 1) * p + 0.5))] if a else 0
def gaps(ts): ts = sorted(ts); return [(b - a) * 1000 for a, b in zip(ts, ts[1:])]
upd_ts = sorted(t for t, c, v in rows if int(c) == 3)
def drawn(t):
    i = bisect.bisect_left(upd_ts, t); return not (i < len(upd_ts) and upd_ts[i] - t < 0.006)
by = collections.defaultdict(list)
for s in sorted(per):
    by[label(s + 0.5)].append(s)
print(f"{'step':12s} {'secs':>4s} {'upd/s min·med':>13s} {'drawn/s min·med':>15s} {'upd gap p50/p95':>15s} {'pres gap p50/p95':>16s} "
      f"{'1-vsync%':>8s} {'2-vsync%':>8s} {'other%':>6s} {'asked':>9s} {'pill/ring gap drawn max':>22s}")
for lab, secs in by.items():
    act = [s for s in secs if inp[s] > 0 or inp[s - 1] > 0]   # seconds with input (or the one after: momentum / coast)
    if not act: continue
    U = [len(per[s][3]) for s in act]
    def shown(s):   # the Map's own drawables that reached the screen (code 32: view id + 100000 when shown)
        ids = collections.Counter(int(v) for _, v in per[s][30])
        if not ids: return [t for t, v in per[s][20] if v > 0]
        mid = ids.most_common(1)[0][0]
        return [t for t, v in per[s][32] if int(v) == mid + 100000]
    P = [len(shown(s)) for s in act]
    ug = [g for s in act for g in gaps([t for t, _ in per[s][3]])]
    pg = [g for s in act for g in gaps(shown(s))]
    one = sum(1 for g in pg if g < 11.5); two = sum(1 for g in pg if 13.5 < g < 19.5); n = max(1, len(pg))
    asks = sorted(set(int(v) for s in act for _, v in per[s][3]))
    lg = [v for s in act for t, v in per[s][34] if drawn(t)]; rg = [v for s in act for t, v in per[s][35] if drawn(t)]
    gap = f"{max(lg, default=0):.1f} / {max(rg, default=0):.1f}" if any(per[s][34] or per[s][35] for s in act) else "-"
    print(f"{lab:12s} {len(act):4d} {min(U):5d} · {sorted(U)[len(U)//2]:5d} {min(P):7d} · {sorted(P)[len(P)//2]:5d} "
          f"{pct(ug,.5):7.1f}/{pct(ug,.95):6.1f} {pct(pg,.5):8.1f}/{pct(pg,.95):6.1f} {100*one/n:8.0f} {100*two/n:8.0f} {100*(n-one-two)/n:6.0f} "
          f"{'/'.join(map(str, asks)):>9s} {gap:>22s}")
# Rest: every second (with or without probe rows) ≥ 2 s after the last input, inside each step's window.
restline = []
t0, t1 = min(per), max(per)
quiet_by = collections.defaultdict(list)
for sec in range(t0, t1 + 1):
    if inp[sec] == 0 and inp[sec - 1] == 0 and inp[sec - 2] == 0:
        quiet_by[label(sec + 0.5)].append(len(per[sec][3]) if sec in per else 0)
for lab, u in quiet_by.items():
    if lab in by and any(per[s][3] for s in by[lab]):   # Map steps only
        restline.append(f"{lab}: {sum(u)} updates in {len(u)} quiet s (max {max(u)}/s)")
print("rest (≥ 2 s after the last input):", "; ".join(restline))
