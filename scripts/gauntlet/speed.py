#!/usr/bin/env python3
"""CH-A test 4 — speed + memory per store pass: read question (case 1) and broad question (S1): TTFT, total,
eval tokens (thinking + answer), thinking chars; resident size_vram + context length from ps.log."""
import json, sys, os
sys.path.insert(0, os.path.dirname(__file__))
import gauntlet as G
print("| pass | model | read: TTFT / total / eval tok / think chars | broad: TTFT / total / eval tok / think chars | resident (ctx) |")
print("|---|---|---|---|---|")
for P in sys.argv[1:]:
    v = G.load_json(os.path.join(P, "versions.json"), {}); sr = G.load_json(os.path.join(P, "store-rows.json"), {"rows": []})
    host = G.parse_host_log(os.path.join(P, "host.log")); res = G.resident_sizes(os.path.join(P, "ps.log"))
    cells = []
    for case in ("1", "S1"):
        r = next((x for x in sr["rows"] if x["case"] == case), None)
        t = G.load_json(os.path.join(P, f"turn-{r['seq']:03d}.json")) if r else None
        h = host.get(G.req_tag((t or {}).get("requestID", "")), {}) if t else {}
        cells.append(f"{h.get('ttftMs','-')} ms / {round(r['elapsedSec']) if r else '-'} s / {h.get('eval','-')} / {len((t or {}).get('thinking') or '')}" if t else "—")
    m = v.get("model", ""); size, ctx = res.get(m, (0, 0))
    print(f"| {os.path.relpath(P, 'build/gauntlet-runs')} | {m} | {cells[0]} | {cells[1]} | {size/1e9:.1f} GB ({ctx}) |" if size else f"| {os.path.relpath(P,'build/gauntlet-runs')} | {m} | {cells[0]} | {cells[1]} | — |")
