#!/usr/bin/env python3
"""Sweep 2b · 2.1 — the Map pacing probe, per second: display ticks the SKView offered (its delegate), scene updates,
frames that reached the screen (the Map layer's drawables, `presentedTime`), how long `nextDrawable` blocked, the asked
rate and who wrote it (scene vs anyone: SwiftUI's SpriteView), pauses and wakes, scroll / pinch phases (and `.changed`
while paused), camera writes outside update, run-loop mode at the scroll callbacks. Numbers only.

  map_probe.py <recording.json> [rperf.txt] [--steps a,b] [--hist] [--all]
--steps keeps only seconds whose rperf step is listed; --hist prints the gap histograms (ticks, updates, presents) over
the kept seconds; --all also prints seconds with no Map activity."""
import json, sys, re, collections

argv = sys.argv[1:]
want = None
if "--steps" in argv:
    i = argv.index("--steps"); want = set(argv[i + 1].split(",")); del argv[i:i + 2]
flags = [a for a in argv if a.startswith("--")]
args = [a for a in argv if not a.startswith("--")]
d = json.load(open(args[0]))
wall = d.get("wallOffset", 0)
steps = []
if len(args) > 1:
    for l in open(args[1]):
        m = re.match(r"^(\S+) (\S+) .* at (\d+)", l)
        if m: steps.append((int(m.group(3)) / 1000 - wall, m.group(1)))
def label(t):
    cur = ""
    for st, name in steps:
        if st <= t: cur = name
    return cur

C = dict(tick=1, upd=3, early=4, fin=5, ask=6, pause=7, wake=8, sb=9, sc=10, se=11, scp=12, pb=13, pc=14, pe=15, pcp=16,
         cam=17, mode=18, wait=19, pres=20, skvrate=21, skvpause=22, flag=23, tb=24, tm=25, te=26, hover=27, pend=28, skip=29,
         updv=30, drawv=31, presv=32, updhid=33, lgap=34, rgap=35, coast=36)
N = {v: k for k, v in C.items()}
rows = d.get("probe", [])
if not rows:
    print("no probe rows in this recording (a build before sweep 2b 2.1, or the recorder was off)"); sys.exit(1)
per = collections.defaultdict(lambda: collections.defaultdict(list))
for t, code, v in rows:
    per[int(t)][N.get(int(code), str(code))].append((t, v))
inputs = collections.Counter()
for r in d.get("inputs", []):
    inputs[(int(r[0]), {3: "hover", 4: "scroll", 5: "transform", 1: "touch"}.get(int(r[2]), "other"))] += 1

def gaps(ts):
    ts = sorted(ts); return [(b - a) * 1000 for a, b in zip(ts, ts[1:])]
def pct(a, p):
    a = sorted(a)
    return a[min(len(a) - 1, int((len(a) - 1) * p + 0.5))] if a else 0

hdr = ("sec      step           tick  upd  pres drop  early ask    skvW ext  pz wk  scr(b/c/e/cP)  pin(b/c/e/cP) cam "
       "mode(d/t/o) wait-max  upd-gap p50/p95/max   pres-gap p50/p95/max  in:scr/xf/hov")
print(hdr)
kept = []
for s in sorted(per):
    e = per[s]
    lab = label(s + 0.5)
    if want and lab not in want: continue
    active = any(e[k] for k in ("upd", "pres", "sc", "pc", "tick"))
    if not active and "--all" not in flags: continue
    kept.append(s)
    asks = sorted(set(int(v) for _, v in e["upd"]))
    ask = "/".join(str(a) for a in asks) if asks else "-"
    pres = [t for t, v in e["pres"] if v > 0]; drop = sum(1 for _, v in e["pres"] if v == 0)
    ext = len(e["skvrate"]) - len(e["ask"])
    modes = collections.Counter(int(v) for _, v in e["mode"])
    ug = gaps([t for t, _ in e["upd"]]); pg = gaps(pres)
    wmax = max((v for _, v in e["wait"]), default=0)
    print(f"{s:<8d} {lab[:13]:13s} {len(e['tick']):5d} {len(e['upd']):4d} {len(pres):5d} {drop:4d} {len(e['early']):6d} {ask:6s} "
          f"{len(e['skvrate']):4d} {ext:3d} {len(e['pause']):3d} {len(e['wake']):2d}  "
          f"{len(e['sb']):2d}/{len(e['sc']):3d}/{len(e['se']):2d}/{len(e['scp']):2d}    "
          f"{len(e['pb']):2d}/{len(e['pc']):3d}/{len(e['pe']):2d}/{len(e['pcp']):2d}  {len(e['cam']):3d} "
          f"{modes[0]:3d}/{modes[1]:3d}/{modes[2]:2d}  {wmax:7.1f}  "
          f"{pct(ug,.5):5.1f}/{pct(ug,.95):5.1f}/{max(ug, default=0):6.1f}   {pct(pg,.5):5.1f}/{pct(pg,.95):5.1f}/{max(pg, default=0):6.1f}"
          f"   {inputs[(s,'scroll')]:3d}/{inputs[(s,'transform')]:3d}/{inputs[(s,'hover')]:3d}"
          + (("  | upd-views " + " ".join(f"{k}:{c}" for k, c in collections.Counter(int(v) for _, v in e["updv"]).most_common())
              + "  pres-views " + " ".join(f"{k % 100000}{'s' if k >= 100000 else 'd'}:{c}" for k, c in collections.Counter(int(v) for _, v in e["presv"]).most_common())
              + (f"  hidden-upd {len(e['updhid'])}" if e["updhid"] else "")) if "--views" in flags else ""))

marks = [m for m in d.get("marks", []) if str(m[1]).startswith(("map ", "recorder", "screen"))]
wakes = collections.Counter(m[1] for m in marks if str(m[1]).startswith("map wake") and (not want or label(m[0]) in want))
if wakes: print("wakes:", dict(wakes))
for m in marks:
    if "--marks" in flags and str(m[1]).startswith("map view"): print(f"{m[0]:.1f} {m[1]}")

# Overlay gaps a DRAWN frame showed: a gap measured at a tick counts only if no `update` ran before that tick's frame
# (an update re-publishes the pills and re-places the ring for the camera it draws with).
upd_ts = sorted(t for t, code, v in rows if int(code) == 3)
import bisect
def drawn(t):
    i = bisect.bisect_left(upd_ts, t)
    return not (i < len(upd_ts) and upd_ts[i] - t < 0.006)
if any(int(c) in (34, 35) for _, c, _ in rows):
    ks = set(kept)
    for code, name in ((34, "pill-to-orbs"), (35, "ring-to-orb")):
        g = [(t, v) for t, c, v in rows if int(c) == code and int(t) in ks]
        dg = [v for t, v in g if drawn(t)]
        print(f"{name} gap at ticks (pt): n={len(g)} raw max {max((v for _, v in g), default=0):.1f} p95 {pct([v for _, v in g], .95):.1f}"
              f" | on frames drawn WITHOUT an update: n={len(dg)} max {max(dg, default=0):.1f} p95 {pct(dg, .95):.1f}")
coasts = [v for t, c, v in rows if int(c) == 36 and int(t) in set(kept)]
if coasts: print(f"coasts seeded at scroll lift: {len(coasts)} (speed pt/frame@60 median {pct(coasts, .5):.1f})")

if "--hist" in flags and kept:
    ks = set(kept)
    for key, name in (("tick", "tick"), ("upd", "update"), ("pres", "present"), ("skip", "skipped")):
        ts = sorted(t for t, code, v in rows if N.get(int(code)) == key and int(t) in ks and (key != "pres" or v > 0))
        g = [x for x in gaps(ts) if x < 200]
        bins = collections.Counter()
        for x in g:
            b = "≤9.5" if x <= 9.5 else "9.5–13" if x <= 13 else "13–18" if x <= 18 else "18–21" if x <= 21 else "21–30" if x <= 30 else "30–50" if x <= 50 else ">50"
            bins[b] += 1
        order = ["≤9.5", "9.5–13", "13–18", "18–21", "21–30", "30–50", ">50"]
        tot = max(1, sum(bins.values()))
        print(f"{name:8s} gaps n={len(g):5d}  " + "  ".join(f"{b}:{bins[b]} ({100*bins[b]/tot:.0f}%)" for b in order))
