#!/usr/bin/env python3
"""live-32 (3) — one line per live run: pass / names / cites / stale / thinking, and the time per turn (median, max),
the follow-up turn's time (T1.2), the first token's median, the reasoning the model streamed.
   compare.py <run_dir>…"""
import json, sys, os, re, statistics as st
print("| run | pass | names | cites | stale | thinking aloud | turn s (median / max) | T1 follow-up s | first token s (median) | reasoning ch (sum) |")
print("|---|---|---|---|---|---|---|---|---|---|")
for d in sys.argv[1:]:
    g = os.path.join(d, "grades.json")
    if not os.path.exists(g): print(f"| {os.path.basename(d)} | (no grades) |"); continue
    gs = json.load(open(g))
    tr = [json.loads(l) for l in open(os.path.join(d, "webtrace.jsonl"))] if os.path.exists(os.path.join(d, "webtrace.jsonl")) else []
    totals = [x["stages"]["total_s"] for x in gs if x["stages"].get("total_s")]
    fu = next((x["stages"]["total_s"] for x in gs if x["id"] == "T1.2"), None)
    firsts = [(r["firstContentMs"] - r["startMs"]) / 1000 for r in tr if r["kind"] == "step" and r["firstContentMs"] >= 0 and not r.get("toolCalls")]
    reas = sum(r.get("reasoningChars", 0) for r in tr if r["kind"] == "step")
    n = len(gs)
    print(f'| {os.path.basename(d)} | {sum(x["pass"] for x in gs)}/{n} | {sum(x["names"] for x in gs)} | {sum(x["cites"] for x in gs)} | '
          f'{sum(bool(x["stale"]) for x in gs)} | {sum(bool(x["thinking"]) for x in gs)} | '
          f'{st.median(totals):.1f} / {max(totals):.1f} | {fu if fu is not None else "-"} | {st.median(firsts):.1f} | {reas} |' if totals and firsts else
          f'| {os.path.basename(d)} | {sum(x["pass"] for x in gs)}/{n} | {sum(x["names"] for x in gs)} | {sum(x["cites"] for x in gs)} | {sum(bool(x["stale"]) for x in gs)} | {sum(bool(x["thinking"]) for x in gs)} | {st.median(totals) if totals else "-"} | {fu} | - | {reas} |')
