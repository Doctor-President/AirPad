#!/usr/bin/env python3
# Sweep 2b · 2.3a — splits the main thread's busy samples in an rperf step's windows into SpriteKit scene update (AirPad's update code),
# other SpriteKit (render / draw pass), SwiftUI (incl. AttributeGraph; the label layer), Core Animation commit (not
# SwiftUI), other. Also busy ms per Map update in those windows (spans >= 4 ms; samples start 1 ms into a busy period).
#   map_split.py <recording.json> <rperf.txt> <label>   — a run with -PerfSampleAfter 1 (dense samples; the default
#   samples only stalls over 40 ms). Only seconds with >= 30 Map updates count; ms/frame = the vitals' main-thread CPU per
#   Map update × each category's share of the samples (samples start 1 ms into a busy period: the first ms is unseen).
import json, sys, re, collections, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import explain as E
d = E.load(sys.argv[1]); wall = d.get("wallOffset", 0); lab = sys.argv[3]
st = []
for l in open(sys.argv[2]):
    m = re.match(r"^(\S+) (\S+) .* at (\d+)", l)
    if m: st.append((int(m.group(3)) / 1000 - wall, m.group(1)))
st.append((1e18, "end"))
wins = [(a[0], b[0]) for a, b in zip(st, st[1:]) if a[1] == lab]
inw0 = lambda t: any(a <= t < b for a, b in wins)
act = {s for s, k in collections.Counter(int(t) for t, c, v in d["probe"] if int(c) == 3 and inw0(t)).items() if k >= 30}
inw = lambda t: inw0(t) and int(t) in act   # only seconds of the step with >= 30 Map updates
S = d["symbols"]
cat = collections.Counter(); inc = collections.Counter(); n = 0
for s in d["samples"]:
    if not inw(s["t"]): continue
    n += 1
    names = [S[i].get("s") or "" for i in s["f"]]; imgs = [S[i].get("i") or "" for i in s["f"]]
    k = next((x for x, nm in enumerate(names) if "CFRunLoopRun" in nm or "CFRunLoopDo" in nm), len(names))   # only the frames above the run loop
    names, imgs = names[:k], imgs[:k]
    j = " | ".join(names)
    if "-[SKScene _update:]" in j: c = "SpriteKit: scene update (AirPad code)"
    elif "SKView" in j or any(i == "SpriteKit" for i in imgs): c = "SpriteKit: render / draw pass (not update)"
    elif "CA::Transaction::commit" in j or "CA::Transaction::flush" in j:
        c = "Core Animation commit: SwiftUI layout inside it" if any(i in ("SwiftUI", "SwiftUICore", "AttributeGraph") for i in imgs) else "Core Animation commit: CA's own work"
    elif any(i in ("SwiftUI", "SwiftUICore", "AttributeGraph") for i in imgs) or "TerritoryLabelLayer" in j: c = "SwiftUI outside the commit (label layer updates)"
    else: c = "other"
    cat[c] += 1
    for tag, hit in (("incl: CA::Transaction commit/flush", "CA::Transaction::commit" in j or "CA::Transaction::flush" in j),
                     ("incl: any SwiftUI/AttributeGraph frame", any(i in ("SwiftUI", "SwiftUICore", "AttributeGraph") for i in imgs)),
                     ("incl: TerritoryLabelLayer", "TerritoryLabelLayer" in j), ("incl: MSDFLabel (orb titles)", "MSDFLabel" in j),
                     ("incl: SKView render callback", "SKView" in j)):
        if hit: inc[tag] += 1
upd = sum(1 for t, c, v in d["probe"] if int(c) == 3 and inw(t))
busy = sum(ms for t, ms in d["spans"] if inw(t))
vit = [v for v in d["vitals"] if int(v[0] - 0.5) in act and inw0(v[0] - 0.5)]
secs = collections.Counter(int(t) for t, c, v in d["probe"] if int(c) == 3 and inw(t))
cpu_ms = sum(v[3] * 10 for v in vit); upd_v = sum(secs[int(v[0] - 0.5)] for v in vit)
print(f"main-thread CPU (vitals) {cpu_ms / max(1, upd_v):.2f} ms per Map update over {len(vit)} s")
print(f"{lab}: {len(wins)} windows, {n} samples, {upd} Map updates, spans>=4ms busy {busy:.0f} ms = {busy / max(1, upd):.2f} ms per update")
pf = cpu_ms / max(1, upd_v)
for k, v in cat.most_common(): print(f"  {v / n:5.0%}  ~{pf * v / n:4.2f} ms/frame (of {pf:.2f})  {k}")
for k, v in inc.most_common(): print(f"  {v / n:5.0%}  {k}")
