#!/usr/bin/env python3
"""Good Flow spike · summarise a -RenderStills timings.json: GPU ms per still, per case.
  python3 tools/timings.py [build/port/timings.json]"""
import json, sys, statistics as st
t = json.load(open(sys.argv[1] if len(sys.argv) > 1 else 'build/port/timings.json'))
print(f"{t['device']} · variant {t['variant']} · {t['repeats']} isolated draws + a burst of 10 per still")
print('| case | px | GPU ms isolated (median; range) | GPU ms per draw in a burst of 10 (median; range) | CPU encode ms |')
print('|---|---|---|---|---|')
by = {}
for s in t['stills']:
    by.setdefault(s['case'], []).append(s)
for c, ss in by.items():
    iso = [s['gpuMsMedian'] for s in ss]; bu = [s.get('gpuMsBurstPerDraw', -1) for s in ss]; enc = [s['encodeMsMedian'] for s in ss]
    print(f"| {c} | {ss[0]['px'][0]}×{ss[0]['px'][1]} | {st.median(iso):.2f} ({min(iso):.2f}–{max(iso):.2f}) | "
          f"{st.median(bu):.2f} ({min(bu):.2f}–{max(bu):.2f}) | {st.median(enc):.3f} |")
