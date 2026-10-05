#!/usr/bin/env python3
"""CH-A — one line per store pass + the red rows. `summarize.py <pass_dir>...`"""
import json, sys, os, statistics
for P in sys.argv[1:]:
    g = json.load(open(os.path.join(P, "grades.json")))
    sr = json.load(open(os.path.join(P, "store-rows.json")))
    rows = list(g.values())
    bad = {r: v for r, v in g.items() if v["status"] in ("FAIL", "INVALID")}
    st = [v["stats"] for v in rows]
    ttft = [s["ttftMs"] for s in st if s.get("ttftMs")]
    ev = [s["evalTokens"] for s in st if s.get("evalTokens")]
    th = [s["thinkingChars"] for s in st if s.get("thinkingChars") is not None]
    print(f"== {P}  think={'on' if sr['think'] else 'off'}  rows={len(rows)}  grader-red={len(bad)}  "
          f"TTFT med={statistics.median(ttft) if ttft else '-'}ms  eval med={statistics.median(ev) if ev else '-'}  "
          f"think-chars med={statistics.median(th) if th else '-'}  wall={round(sum(r.get('elapsedSec',0) for r in sr['rows']))}s")
    for r, v in sorted(bad.items()):
        reds = [f"{k}:{d[:90]}" for k, (s, d) in v["results"].items() if s in ("FAIL", "ABORT")]
        print(f"   {r:16s} {'; '.join(reds)[:300]}")
