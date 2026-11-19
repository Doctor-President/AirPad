#!/usr/bin/env python3
"""rest.py — what the app does while nothing happens, per screen (Mac perf audit; scripts/mac/perf/rest.sh).

  rest.py <recording.json> <phases.tsv: label, wall start, wall end> [--json out.json] [--detail]

Per screen: CPU (whole app / main thread, % of one core), the share of the time the main thread was busy, how many
times a second it woke to work, Map frames a second, the share of its busy samples spent waiting for the system's
render server (SwiftUI's drawn layers being put on screen), which views rebuilt, and AirPad's own code on the stack.
"""
import sys, os, json, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import explain as E


def main(a):
    d = E.load(a[0]); off = d["wallOffset"]; sy = d["symbols"]; out = {}
    print(f"{'screen':<14} {'cpu%':>5} {'main%':>6} {'busy%':>6} {'wakes/s':>8} {'Map fps':>8} {'wait%':>6}  views rebuilt a second · AirPad code")
    for line in open(a[1]):
        c = line.rstrip("\n").split("\t")
        if len(c) < 3: continue
        t0, t1 = float(c[1]) - off, float(c[2]) - off; dur = t1 - t0
        sp = [s for s in d["spans"] if t0 <= s[0] <= t1]
        vit = [v for v in d["vitals"] if t0 <= v[0] <= t1]
        mp = [m[1] for m in d.get("map", []) if t0 <= m[0] <= t1]
        bodies = collections.Counter()
        for b in d["bodies"]:
            if t0 <= b[0] <= t1:
                for k, v in b[1].items(): bodies[k.split("<")[0]] += v
        smp = [s for s in d["samples"] if t0 <= s["t"] <= t1]
        wait = sum(1 for s in smp if any("waitForCommitId" in (sy[i].get("s") or "") for i in s["f"]))
        app = collections.Counter()
        for s in smp:
            seen = set()
            for i in s["f"]:
                e = sy[i]
                if e.get("i") == "AirPad":
                    n = E.short(e.get("s") or "?")
                    if not E.NOISE.search(n) and n not in seen: seen.add(n); app[n] += 1
        dr = collections.Counter()
        for x in d.get("draws", []):
            if t0 <= x[0] <= t1:
                for k, v in x[1].items(): dr[k] += v
        r = dict(draws={k: round(v / dur, 1) for k, v in dr.most_common(8)}, cpu=sum(v[2] for v in vit) / max(1, len(vit)), main=sum(v[3] for v in vit) / max(1, len(vit)),
                 busy=100 * sum(s[1] for s in sp) / 1000 / dur, wakes=len(sp) / dur, map_fps=sum(mp) / max(1, len(mp)),
                 wait=100 * wait / max(1, len(smp)), bodies={k: round(v / dur, 1) for k, v in bodies.most_common(6)},
                 app=[(k, round(100 * v / max(1, len(smp)))) for k, v in app.most_common(5)])
        out[c[0]] = r
        print(f"{c[0]:<14} {r['cpu']:>5.0f} {r['main']:>6.0f} {r['busy']:>6.0f} {r['wakes']:>8.0f} {r['map_fps']:>8.0f} {r['wait']:>6.0f}  "
              + ", ".join(f"{k} {v}" for k, v in r["bodies"].items()) + " · " + "; ".join(f"{k[:60]} {v}%" for k, v in r["app"][:3]))
    print("\nlayers redrawn a second at rest (rectangle in the window, points):")
    for k, r in out.items():
        if r["draws"]: print(f"  {k:<14} " + " · ".join(f"[{q}] {v}" for q, v in r["draws"].items()))
    if "--json" in a: json.dump(out, open(a[a.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    main(sys.argv[1:])
