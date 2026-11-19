#!/usr/bin/env python3
"""phases.py — the Map after each appearance change, from one recording (Mac perf audit P0a + the soak).

  phases.py <recording.json> <phases.tsv> [--json out.json]

phases.tsv (scripts/mac/perf/p0-appearance.sh): cycle, label, wall time of the change, of the probe's start, of its
end, of the end of the rest, the process's resident memory (KB). Per row: frame times while the Map was being moved
(the main thread's display-rate ticks: p50 / p95 / share later than 1.5 frames), the longest main-thread stall, the Map's
own work per frame, how many frames the Map still drew each second in the last 2 s of the rest (0 = it went to rest),
and memory. Then cycle 1 against the last cycle (the leak / build-up question), and the soak line the gate reads.
"""
import json, sys


def pct(xs, p):
    if not xs: return None
    xs = sorted(xs); return xs[min(len(xs) - 1, int(p / 100 * len(xs)))]


def main(a):
    d = json.load(open(a[0])); off = d["wallOffset"]
    hz = d["device"].get("maxFPS", 60) if not d["device"].get("lowPower") else 60
    hz = d["device"].get("maxFPS", 60)
    frames, spans, mp, vit = d["frames"], d["spans"], d.get("map", []), d.get("vitals", [])
    rows = []
    for line in open(a[1]):
        c = line.rstrip("\n").split("\t")
        if len(c) < 7: continue
        cyc, label = c[0], c[1]
        t0, t1, t2, t3 = (float(x) - off for x in c[2:6])
        dts = [f[1] for f in frames if t1 <= f[0] <= t2]
        # the display's own interval, from the data (Low Power Mode halves it)
        base = pct(dts, 50) or 1000 / hz
        late = sum(1 for x in dts if x > 1.5 * base)
        stall = max([s[1] for s in spans if t0 <= s[0] <= t2] or [0])
        mprobe = [m for m in mp if t1 <= m[0] <= t2 and m[1] > 0]
        upd = sum(m[2] for m in mprobe) / max(1, sum(m[1] for m in mprobe))
        mfps = sum(m[1] for m in mprobe) / max(1, len(mprobe))
        rest = [m[1] for m in mp if t3 - 2.0 <= m[0] <= t3]
        v = [x for x in vit if t2 <= x[0] <= t3]
        rows.append(dict(cycle=cyc, label=label, n=len(dts), p50=pct(dts, 50), p95=pct(dts, 95), p99=pct(dts, 99),
                         late_pct=100 * late / max(1, len(dts)), stall=stall, map_update=upd, map_fps=mfps,
                         rest_fps=(sum(rest) / max(1, len(rest))) if rest else 0.0,
                         mem=(v[-1][1] if v else None), rss=int(c[6]) / 1024 if c[6] else None,
                         cpu_rest=(sum(x[2] for x in v[-2:]) / max(1, len(v[-2:])) if v else None)))
    f = lambda x, n=1: "-" if x is None else f"{x:.{n}f}"
    print(f"{'cycle':>5} {'change':<22} {'p50':>5} {'p95':>6} {'p99':>6} {'late%':>6} {'stall':>6} {'Map ms':>7} {'Map fps':>8} {'rest fps':>9} {'rest cpu%':>9} {'mem MB':>7}")
    for r in rows:
        print(f"{r['cycle']:>5} {r['label']:<22} {f(r['p50']):>5} {f(r['p95']):>6} {f(r['p99']):>6} {f(r['late_pct']):>6} {f(r['stall'], 0):>6} {f(r['map_update'], 2):>7} {f(r['map_fps'], 0):>8} {f(r['rest_fps']):>9} {f(r['cpu_rest']):>9} {f(r['mem'], 0):>7}")
    cycles = [c for c in dict.fromkeys(r["cycle"] for r in rows) if c.isdigit() and c != "0"]
    out = {"rows": rows}
    if cycles:
        def agg(c):
            rs = [r for r in rows if r["cycle"] == c]
            return dict(p95=sum(r["p95"] or 0 for r in rs) / len(rs), late=sum(r["late_pct"] for r in rs) / len(rs),
                        upd=sum(r["map_update"] for r in rs) / len(rs), mem=rs[-1]["mem"], rest=max(r["rest_fps"] for r in rs),
                        not_rest=[r["label"] for r in rs if r["rest_fps"] > 0])
        first, last = agg(cycles[0]), agg(cycles[-1])
        print()
        for c in cycles:
            g = agg(c)
            print(f"cycle {c}: frame p95 {g['p95']:.1f} ms · late {g['late']:.1f}% · Map work {g['upd']:.2f} ms a frame · memory {f(g['mem'], 0)} MB · not at rest after: {', '.join(g['not_rest']) or 'none'}")
        minutes = (float(open(a[1]).read().strip().split("\n")[-1].split("\t")[5]) - float(open(a[1]).readline().split("\t")[2])) / 60
        soak = dict(minutes=minutes, mem_first=round(first["mem"] or 0), mem_last=round(last["mem"] or 0),
                    mem_growth_pct=100 * ((last["mem"] or 0) - (first["mem"] or 0)) / max(1, first["mem"] or 1),
                    p95_first=first["p95"], p95_last=last["p95"], p95_growth_pct=100 * (last["p95"] - first["p95"]) / max(0.1, first["p95"]))
        out["soak"] = soak; out["rest"] = {r["label"]: r["rest_fps"] for r in rows if r["cycle"] == cycles[-1]}
        print(f"\nfirst → last cycle over {minutes:.0f} min: memory {soak['mem_first']} → {soak['mem_last']} MB ({soak['mem_growth_pct']:+.0f}%), frame p95 {soak['p95_first']:.1f} → {soak['p95_last']:.1f} ms ({soak['p95_growth_pct']:+.0f}%)")
    if "--json" in a: json.dump(out, open(a[a.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    main(sys.argv[1:])
