#!/usr/bin/env python3
"""live-37 (4) — retrieval-only smoke runs side by side: recall per run, every case per run, and each case that got WORSE
from one run to the next (and from the first to the last), with where the gold was lost.
    smoke_steps.py <run_dir> [<run_dir> …]        (each holds grades.json + summary.md + run.txt from smoke.sh --retrieval)
"""
import json, os, sys, re
runs = []
for d in sys.argv[1:]:
    g = {x["id"]: x for x in json.load(open(os.path.join(d, "grades.json")))}
    wall = re.search(r"wall (\d+) s", open(os.path.join(d, "run.txt")).read() if os.path.exists(os.path.join(d, "run.txt")) else "")
    runs.append((os.path.basename(d.rstrip("/")), g, wall.group(1) if wall else "?"))
ids = list(runs[0][1])
yn = lambda v: "–" if v is None else ("y" if v else "**n**")
def recall(g): xs = [x.get("retrieval") for x in g.values() if x.get("retrieval") is not None]; return f"{sum(xs)}/{len(xs)}"
print("| run | recall | wall |"); print("|---|---|---|")
for n, g, w in runs: print(f"| {n} | {recall(g)} | {w} s |")
print("\n| case | " + " | ".join(n for n, _, _ in runs) + " |"); print("|---|" + "---|" * len(runs))
for i in ids:
    print(f"| {i}{' ★' if runs[0][1][i].get('tFailure') else ''} | " + " | ".join(yn(g[i].get("retrieval")) if i in g else "–" for _, g, _ in runs) + " |")
print("\n**Worse from one run to the next:**")
worse = 0
for (a, ga, _), (b, gb, _) in list(zip(runs, runs[1:])) + ([(runs[0], runs[-1])] if len(runs) > 2 else []):
    for i in ids:
        if ga.get(i, {}).get("retrieval") is True and gb.get(i, {}).get("retrieval") is False:
            worse += 1
            print(f"- {i}: {a} y → {b} n — {'; '.join(f'{k}: {v}' for k, v in (gb[i].get('lost') or {}).items())} · query {gb[i].get('query')!r} ({gb[i].get('how')})")
if not worse: print("- none")
