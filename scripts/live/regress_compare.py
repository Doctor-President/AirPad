#!/usr/bin/env python3
"""live-36 (3) — the baseline across tiers from regress.py's grades: tier × category (retrieval recall · strict ·
relaxed), every strict failure split into RETRIEVAL (the gold never reached the model — with the stage it was lost at)
vs MODEL (the gold was in what it received), and where retrieval loses facts, per tier.
    regress_compare.py <tier_dir> [<tier_dir> …] > baseline.md        (each dir holds grades.json + summary.md)
"""
import json, os, sys, re
from collections import Counter, OrderedDict
tiers = OrderedDict()
for d in sys.argv[1:]:
    head = open(os.path.join(d, "summary.md")).readline().strip("# \n").replace(" — summary", "")
    tiers[head] = json.load(open(os.path.join(d, "grades.json")))
cats = []
for gs in tiers.values():
    for g in gs:
        if g["cat"] not in cats: cats.append(g["cat"])
def frac(xs):
    xs = [x for x in xs if x is not None]
    return f"{sum(xs)}/{len(xs)}" if xs else "–"
print("## Baseline: tier × category (retrieval recall · strict · relaxed)\n")
print("| category | n | " + " | ".join(tiers) + " |"); print("|---|---|" + "---|" * len(tiers))
for k in cats + ["ALL"]:
    cells = []
    for gs in tiers.values():
        s = [g for g in gs if k == "ALL" or g["cat"] == k]
        cells.append(f"{frac([g.get('retrieval') for g in s])} · {frac([g['strict'] for g in s])} · {frac([g['relaxed'] for g in s])}")
    n = len([g for g in next(iter(tiers.values())) if k == "ALL" or g["cat"] == k])
    print(f"| {'**ALL**' if k == 'ALL' else k} | {n} | " + " | ".join(cells) + " |")

def stage(v):
    v = re.sub(r"\(best [\d.]+\)", "", v).strip()
    return v
print("\n## Strict failures: retrieval vs model\n")
print("| tier | strict fails | retrieval (gold never reached the model) | model (gold was in what it got) | n/a (not searched / no gold) |")
print("|---|---|---|---|---|")
loss = {}
for t, gs in tiers.items():
    f = [g for g in gs if not g["strict"]]
    r = [g for g in f if g.get("retrieval") is False]; m = [g for g in f if g.get("retrieval") is True]; na = [g for g in f if g.get("retrieval") is None]
    print(f"| {t} | {len(f)} | {len(r)} | {len(m)} | {len(na)} |")
    loss[t] = Counter(stage(v) for g in gs for v in (g.get("lost") or {}).values())
print("\n## Where retrieval lost the gold (per missing fact group)\n")
stages = sorted({s for c in loss.values() for s in c})
print("| stage | " + " | ".join(tiers) + " |"); print("|---|" + "---|" * len(tiers))
for s in stages: print(f"| {s} | " + " | ".join(str(loss[t][s]) for t in tiers) + " |")

print("\n## Every case, every tier (R = retrieval, S = strict, L = relaxed; y/n/–)\n")
ids = [g["id"] for g in next(iter(tiers.values()))]
by = {t: {g["id"]: g for g in gs} for t, gs in tiers.items()}
print("| id | " + " | ".join(tiers) + " |"); print("|---|" + "---|" * len(tiers))
yn = lambda v: "–" if v is None else ("y" if v else "n")
for i in ids:
    print(f"| {i}{' ★' if by[next(iter(tiers))][i].get('tFailure') else ''} | " + " | ".join(
        (lambda g: f"R{yn(g.get('retrieval'))} S{yn(g['strict'])} L{yn(g['relaxed'])}")(by[t][i]) if i in by[t] else "–" for t in tiers) + " |")
