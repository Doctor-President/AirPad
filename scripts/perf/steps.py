#!/usr/bin/env python3
"""steps.py — one table per run: each scripted step (rperf on the Mac, the UI test on the iPhone Simulator) joined to
the app's own recording over the same seconds.

  steps.py <recording.json> <rperf.txt | steps.tsv> [--json out.json] [--detail label]

Per action (label): what the screen showed (Mac only: input → first changed frame, → settled), what the app measured
(input → main thread free again = the work before it could draw; the longest stall; frames while the step ran) and
where the stalled time went. A steps.tsv line is: <label>\t<verb>\t<wall ms at input>.
"""
import sys, re, json, collections, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import explain as E

SCROLLS = ("scroll", "scrollmove", "drag", "move", "swipe")


def read_steps(path):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"(\S+) (\S+) visible (\S+) settled (\S+) frames (\d+) at (\d+)(?: · interval p50 (\S+) p95 (\S+) ms)?", line)
        if m:
            f = lambda x: None if x in ("-", None) else float(x)
            rows.append(dict(label=m[1], verb=m[2], visible=f(m[3]), settled=f(m[4]), wall=float(m[6]) / 1000, iv50=f(m[7]), iv95=f(m[8])))
            continue
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3 and p[2].replace(".", "").isdigit():
            rows.append(dict(label=p[0], verb=p[1], visible=None, settled=None, wall=float(p[2]) / 1000, iv50=None, iv95=None))
    return rows


def analyse(d, rows):
    off = d["wallOffset"]
    out = []
    for i, r in enumerate(rows):
        t0 = r["wall"] - off
        t1 = rows[i + 1]["wall"] - off if i + 1 < len(rows) else d["now"]
        t1 = min(t1, t0 + 8)
        w = E.window(d, t0 - 0.02, t1)
        s = E.summarise(w)
        spans = w["spans"]
        # The app's own response: from the step's first discrete input to the end of the work it set off.
        discrete = [x for x in w["inputs"] if (x[2] == 1 and x[3] in (1, 3)) or (x[2] == 2 and x[3] == 1)]
        resp = settled = None
        if discrete and r["verb"] not in SCROLLS:
            # A click acts on mouse-up / touch-up; a key on key-down.
            acts = [x for x in discrete if not (x[2] == 1 and x[3] == 1)] or discrete
            a = acts[0]
            after = [sp for sp in spans if sp[0] + sp[1] / 1000 >= a[1] - 0.002]
            if after:
                end = after[0][0] + after[0][1] / 1000
                # Chain: work that follows within 12 ms belongs to the same response.
                for sp in after[1:]:
                    if sp[0] - end <= 0.012: end = max(end, sp[0] + sp[1] / 1000)
                    else: break
                resp = (end - a[0]) * 1000
                last = end
                for sp in after:
                    if sp[1] >= 8 and sp[0] - last <= 0.3: last = max(last, sp[0] + sp[1] / 1000)
                settled = (last - a[0]) * 1000
            else:
                resp = (a[1] - a[0]) * 1000
        r2 = dict(r); r2.update(resp=resp, app_settled=settled, s=s, t0=t0, t1=t1)
        out.append(r2)
    return out


def table(rows):
    order = []
    for r in rows:
        if r["label"] not in order: order.append(r["label"])
    lines = ["| action | n | screen: visible p50 / p95 | settled p50 / p95 | app: input → free p50 / p95 | longest stall | stalls ≥ 50 / ≥ 100 | frames while it ran | where the stalled time went |",
             "|---|---|---|---|---|---|---|---|---|"]
    agg = {}
    for l in order:
        g = [r for r in rows if r["label"] == l]
        def pp(key):
            v = [r[key] for r in g if r[key] is not None]
            return (E.pct(v, 0.5), E.pct(v, 0.95)) if v else (None, None)
        f = lambda x: "-" if x is None else f"{x:.0f}"
        vis, st, rs = pp("visible"), pp("settled"), pp("resp")
        hang_max = max(r["s"]["hang_max"] for r in g)
        h50 = sum(r["s"]["hangs_50"] for r in g); h100 = sum(r["s"]["hangs_100"] for r in g)
        fam = collections.Counter()
        for r in g:
            n = r["s"]["samples"]
            for k, v in r["s"]["families"]: fam[k] += v * n / 100.0
        tot = sum(fam.values())
        fams = ", ".join(f"{k} {100 * v / tot:.0f}%" for k, v in fam.most_common(3)) if tot else "-"
        frames = "-"
        if g[0]["verb"] in SCROLLS:
            fr = [x for r in g for x in [r["s"].get("fps")] if x]
            late = [r["s"].get("frames_late_pct") for r in g if r["s"].get("frames_late_pct") is not None]
            p95 = [r["s"].get("frame_p95") for r in g if r["s"].get("frame_p95") is not None]
            if fr: frames = f"{sum(fr) / len(fr):.0f} fps, p95 {max(p95):.0f} ms, {sum(late) / len(late):.0f}% late"
        lines.append(f"| {l} | {len(g)} | {f(vis[0])} / {f(vis[1])} | {f(st[0])} / {f(st[1])} | {f(rs[0])} / {f(rs[1])} | {hang_max:.0f} | {h50} / {h100} | {frames} | {fams} |")
        agg[l] = dict(n=len(g), visible_p50=vis[0], visible_p95=vis[1], settled_p50=st[0], settled_p95=st[1], resp_p50=rs[0], resp_p95=rs[1],
                      hang_max=hang_max, hangs_50=h50, hangs_100=h100, frames=frames, families=fams, verb=g[0]["verb"],
                      fps=(sum(x for r in g for x in [r["s"].get("fps")] if x) / max(1, len([1 for r in g if r["s"].get("fps")]))) if g[0]["verb"] in SCROLLS else None,
                      late_pct=(sum(r["s"].get("frames_late_pct") or 0 for r in g) / len(g)) if g[0]["verb"] in SCROLLS else None)
    return "\n".join(lines), agg


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) < 2:
        print(__doc__); sys.exit(2)
    d = E.load(a[0])
    rows = analyse(d, read_steps(a[1]))
    whole = E.summarise(d)
    print(E.sentence(d, whole)); print()
    t, agg = table(rows)
    print(t); print()
    print(E.detail(d, whole, top=10))
    if "--detail" in a:
        lab = a[a.index("--detail") + 1]
        for r in rows:
            if r["label"] == lab:
                w = E.window(d, r["t0"] - 0.02, r["t1"])
                print(f"\n== {lab} at {r['t0']:.2f}"); print(E.detail(w, r["s"], top=8))
    if "--json" in a:
        json.dump(dict(actions=agg, whole={k: v for k, v in whole.items() if k not in ("app_frames",)}, device=d["device"]), open(a[a.index("--json") + 1], "w"), indent=1)
