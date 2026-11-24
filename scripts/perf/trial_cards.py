#!/usr/bin/env python3
"""Sweep 2b · 2.3 — the renderer trial's Cards rows (scene 2), per run. Numbers only.
  trial_cards.py <recording.json> <rperf.txt>
Per step group (cards-scroll, cards-scrollmv, cards-hand, cards-sidebar): the app's frames (the recorder's display link:
fps and % late = gaps > 12.5 ms, as steps.py), main-thread CPU per frame (vitals, seconds fully inside the group),
and the one-pass layer's rows (arm c): offset changes (43), passes (40) by reason (45), coalesced offsets (48), pass ms
p50 / p95, drawable wait (44), GPU ms (41), presented passes (42) and their gaps, cards drawn (46) / own path (47);
arm d: pictures rendered (49) and their ms. Rest: from 0.5 s after the last input, 10 s: passes, presents, drift ticks,
field redraws (BlobFieldTick bodies), gradient / tile rebuilds (Perf.body), recorder frames, process / main CPU."""
import json, sys, os, collections, re, bisect
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import explain as E
import steps as S

d = E.load(sys.argv[1]); rows = S.read_steps(sys.argv[2])
P = d.get("probe", [])
by = collections.defaultdict(list)
for t, c, v in P: by[int(c)].append((t, v))
def pct(a, p):
    a = sorted(a); return a[min(len(a) - 1, int((len(a) - 1) * p + 0.5))] if a else float("nan")
def inwin(code, t0, t1): return [(t, v) for t, v in by[code] if t0 <= t < t1]
arm = next((m[1].split("arm ")[-1] for m in d["marks"] if "cards trial arm" in m[1]), "off")
off = d["wallOffset"]
for i, r in enumerate(rows):
    r["t0"] = r["wall"] - off
    r["t1"] = min(rows[i + 1]["wall"] - off if i + 1 < len(rows) else d["now"], r["t0"] + 12)
vit = {int(v[0]): v for v in d.get("vitals", [])}
frames = d["frames"]
print(f"arm {arm} · window {d['device'].get('windowPt')} · display {d['device'].get('maxFPS')} Hz · lowPower {d['device'].get('lowPower')}")
groups = []
for r in rows:
    if r["label"] not in groups and r["label"].startswith("cards-") and r["label"] != "cards-rest": groups.append(r["label"])
print("| group | n | fps | % late (>12.5 ms) | frame p95 ms | longest stall ms | main CPU / frame ms (median s) | offsets | passes (scroll / layout) | coalesced | pass ms p50 / p95 / max | drawable wait p95 | GPU ms p50 / p95 | presented | present gaps 1-vsync % / >12.5 | cards drawn mean / own path mean | pictures (ms p50 / max) |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for gname in groups:
    g = [r for r in rows if r["label"] == gname]
    fps, late, p95, stall = [], [], [], 0
    for r in g:
        s = E.summarise(E.window(d, r["t0"] - 0.02, r["t1"]))
        if s.get("fps"): fps.append(s["fps"]); late.append(s["frames_late_pct"]); p95.append(s["frame_p95"])
        stall = max(stall, s.get("hang_max", 0) or 0)
    secs = set()
    for r in g:
        for sec in range(int(r["t0"]) + 1, int(r["t1"])): secs.add(sec)
    perf = collections.Counter(int(f[0]) for f in frames)
    mc = [vit[sec][3] * 10 / perf[sec] for sec in secs if sec in vit and perf[sec] >= 30]
    W = lambda code: [x for r in g for x in inwin(code, r["t0"], r["t1"])]
    offs, passes, reasons = W(43), W(40), W(45)
    rs = collections.Counter(int(v) for t, v in reasons)
    pres = sorted(t for t, v in W(42) if v > 0)
    gaps = [(b - a) * 1000 for a, b in zip(pres, pres[1:]) if b - a < 0.2]
    pics = [v for t, v in W(49)]
    drawn = [v for t, v in W(46)]; own = [v for t, v in W(47)]
    f = lambda x: "-" if x != x else f"{x:.2f}"
    print(f"| {gname} | {len(g)} | {sum(fps)/max(1,len(fps)):.0f} | {sum(late)/max(1,len(late)):.1f} | {max(p95, default=0):.1f} | {stall:.0f} | {f(pct(mc,.5))} |"
          f" {len(offs)} | {len(passes)} ({rs.get(1,0)} / {rs.get(2,0)}) | {len(W(48))} | {f(pct([v for t,v in passes],.5))} / {f(pct([v for t,v in passes],.95))} / {f(max([v for t,v in passes], default=float('nan')))} |"
          f" {f(pct([v for t,v in W(44)],.95))} | {f(pct([v for t,v in W(41)],.5))} / {f(pct([v for t,v in W(41)],.95))} | {len(pres)} |"
          f" {(100*sum(1 for x in gaps if x < 11.5)/max(1,len(gaps))):.1f} / {sum(1 for x in gaps if x > 12.5)} |"
          f" {f(sum(drawn)/max(1,len(drawn)) if drawn else float('nan'))} / {f(sum(own)/max(1,len(own)) if own else float('nan'))} |"
          f" {len(pics)} ({f(pct(pics,.5))} / {f(max(pics, default=float('nan')))}) |")
# all scrolling together (scroll + scrollmv + hand)
sc = [r for r in rows if r["label"] in ("cards-scroll", "cards-scrollmv", "cards-hand")]
if sc:
    W = lambda code: [x for r in sc for x in inwin(code, r["t0"], r["t1"])]
    o, p = len(W(43)), len(W(40))
    print(f"scrolling, all: offset changes {o} · passes {p} (by reason {dict(collections.Counter(int(v) for t, v in W(45)))}) · coalesced {len(W(48))}"
          f" · pass ms p50 {pct([v for t,v in W(40)],.5):.2f} p95 {pct([v for t,v in W(40)],.95):.2f} · GPU p95 {pct([v for t,v in W(41)],.95):.2f}")
# rest
inp = sorted(x[0] for x in d["inputs"])
if inp:
    t0 = inp[-1] + 0.5; t1 = t0 + 10
    def cnt(code): return len(inwin(code, t0, t1))
    pres = [t for t, v in inwin(42, t0, t1) if v > 0]
    bod = collections.Counter()
    for b in d.get("bodies", []):
        if t0 <= b[0] < t1:
            for k, v in b[1].items(): bod[k.split("<")[0]] += v
    fr = [f for f in frames if t0 <= f[0] < t1]
    cpu = [vit[s][2] for s in range(int(t0) + 1, int(t1)) if s in vit]; mcpu = [vit[s][3] for s in range(int(t0) + 1, int(t1)) if s in vit]
    reasons = collections.Counter(int(v) for t, v in inwin(45, t0, t1))
    print(f"rest {t1-t0:.0f} s from last input + 0.5 s: passes {cnt(40)} (by reason {dict(reasons)}) · presents {len(pres)} · drift ticks {reasons.get(5,0)}"
          f" · field redraws (BlobFieldTick) {bod.get('BlobFieldTick',0)} · NodeGradientLayer bodies {bod.get('NodeGradientLayer',0)}"
          f" · NodeGridTile bodies {bod.get('NodeGridTile',0)} · MacCardCellContent bodies {bod.get('MacCardCellContent',0)} · pictures {cnt(49)}"
          f" · recorder frames {len(fr)} · process CPU % mean {sum(cpu)/max(1,len(cpu)):.2f} · main {sum(mcpu)/max(1,len(mcpu)):.2f} (recorder on)")
    other = {k: v for k, v in bod.most_common(8)}
    print(f"rest bodies (top): {other}")
# whole run, arm c
if by[40]:
    allp = [v for t, v in by[40]]
    print(f"whole run: passes {len(allp)} by reason {dict(collections.Counter(int(v) for t, v in by[45]))} · offsets {len(by[43])} · coalesced {len(by[48])}"
          f" · presented {sum(1 for t, v in by[42] if v > 0)} dropped {sum(1 for t, v in by[42] if v == 0)} · pass ms p95 {pct(allp,.95):.2f} max {max(allp):.2f}"
          f" · own-path cards per pass max {max((v for t, v in by[47]), default=0):.0f}")
if by[49]:
    pv = [v for t, v in by[49]]
    print(f"whole run: pictures {len(pv)} · ms p50 {pct(pv,.5):.1f} p95 {pct(pv,.95):.1f} max {max(pv):.1f} · total {sum(pv):.0f} ms")
