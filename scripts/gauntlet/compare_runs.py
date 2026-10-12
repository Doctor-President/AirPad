#!/usr/bin/env python3
"""Brief CJ — compare two graded gauntlet run dirs row by row: every grader's verdict, the on-screen capture the
graders read, and wall-clock. Used to prove a harness/driver/parallelism change keeps the bar (same verdicts).

    compare_runs.py <before_dir> <after_dir> [--fields-only-for-replay]

Verdict differences are listed per row and grader. Capture fields are compared exactly (they must match on a
replay A/B; on live runs answers differ by sampling, so only verdicts are meaningful there).
"""
import glob, json, os, sys

FIELDS = ["onScreenAnswer", "onScreenChips", "sourcesUnreachable", "sourcesHeader", "answerBubbleCount", "errorBanner",
          "thoughtHeaderPresent", "onScreenThought", "thoughtUnreachable", "turnCompleted", "driverNote", "keyboardUpAtCapture"]

def load(d):
    g = json.load(open(os.path.join(d, "grades.json")))
    ui = {os.path.basename(p)[3:-5]: json.load(open(p)) for p in glob.glob(os.path.join(d, "ui-*.json"))}
    return g, ui

def wall(d):
    for l in open(os.path.join(d, "run.log"), errors="replace"):
        if "UI drive wall" in l:
            return int(l.split("UI drive wall")[1].split("s")[0])
    return None

a, b = sys.argv[1], sys.argv[2]
ga, ua = load(a); gb, ub = load(b)
rows = sorted(set(ga) | set(gb))
vdiff, fdiff = [], []
for r in rows:
    ra, rb = (ga.get(r) or {}).get("results", {}), (gb.get(r) or {}).get("results", {})
    for k in sorted(set(ra) | set(rb)):
        va, vb = (ra.get(k) or ["—"])[0], (rb.get(k) or ["—"])[0]
        if va != vb:
            vdiff.append((r, k, va, vb, (rb.get(k) or ["", ""])[1][:90]))
    for f in FIELDS:
        x, y = ua.get(r, {}).get(f), ub.get(r, {}).get(f)
        if x != y:
            fdiff.append((r, f, str(x)[:70], str(y)[:70]))
sa = sum(u.get("wallSec", 0) for u in ua.values()); sb = sum(u.get("wallSec", 0) for u in ub.values())
print(f"rows: {len(ga)} vs {len(gb)} · UI drive wall: {wall(a)} s vs {wall(b)} s · sum of row wallSec {sa:.0f} vs {sb:.0f}")
print(f"verdict differences: {len(vdiff)}")
for r, k, va, vb, why in vdiff:
    print(f"  {r:16} {k:5} {va:5} → {vb:5}  {why}")
print(f"capture-field differences: {len(fdiff)}")
for r, f, x, y in fdiff[:40]:
    print(f"  {r:16} {f:20} {x!r} → {y!r}")
