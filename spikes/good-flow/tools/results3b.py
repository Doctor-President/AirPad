#!/usr/bin/env python3
"""Good Flow spike · step 3B tables from -Measure3b's measure.json + the equality stills.
  python3 tools/results3b.py <measure dir>   → markdown on stdout (results-3b.md's tables)"""
import json, os, sys, statistics as st
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare as C
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = sys.argv[1]; M = json.load(open(os.path.join(D, 'measure.json')))
P = print
def f(x, n=2): return '-' if x is None or x < 0 else f'{x:.{n}f}'

# GPU ms per frame per variant per case
T = M.get('timing', [])
cases = []
for r in T:
    if r['case'] not in cases: cases.append(r['case'])
P('### GPU ms per frame (M1 Max, command buffer, 10 sequential frames × 6 entries × 2 themes; p50 / p95)\n')
P('| case | px | ' + ' | '.join(v for v in ('A', 'B', 'BD75', 'BD50')) + ' |'); P('|---|---|' + '---|' * 4)
for c in cases:
    rs = {r['variant']: r for r in T if r['case'] == c}
    P(f"| {c} | {rs['A']['px'][0]}×{rs['A']['px'][1]} | " + ' | '.join(f"{f(rs[v]['gpuMsP50'])} / {f(rs[v]['gpuMsP95'])}" for v in ('A', 'B', 'BD75', 'BD50')) + ' |')
P('\nBurst per draw (10 committed back to back, span / 10), p50:\n')
P('| case | ' + ' | '.join(('A', 'B', 'BD75', 'BD50')) + ' |'); P('|---|' + '---|' * 4)
for c in cases:
    rs = {r['variant']: r for r in T if r['case'] == c}
    P(f'| {c} | ' + ' | '.join(f(rs[v]['burstPerDrawP50']) for v in ('A', 'B', 'BD75', 'BD50')) + ' |')

# equality: each variant vs A (stable hash)
P('\n### Equality of each variant against A (stable hash; mean / p99 in 8-bit steps; "near" = mean ≤ 2.0 and p99 ≤ 16)\n')
P('| variant | case | mean (avg) | mean (worst) | p99 (worst) | near |'); P('|---|---|---|---|---|---|')
for v in ('B', 'BD75', 'BD50'):
    rows = C.compare(os.path.join(D, 'v-A'), os.path.join(D, f'v-{v}'))
    ok = [r for r in rows if 'mean' in r]
    byc = {}
    for r in ok: byc.setdefault(r['case'], []).append(r)
    for c, g in byc.items():
        near = sum(1 for r in g if r['mean'] <= 2.0 and r['p99'] <= 16)
        P(f"| {v} | {c} | {st.mean(r['mean'] for r in g):.3f} | {max(r['mean'] for r in g):.3f} | {max(r['p99'] for r in g):.1f} | {near}/{len(g)} |")
    n = sum(1 for r in ok if r['mean'] <= 2.0 and r['p99'] <= 16)
    P(f"| **{v}** | all | {st.mean(r['mean'] for r in ok):.3f} | {max(r['mean'] for r in ok):.3f} | {max(r['p99'] for r in ok):.1f} | **{n}/{len(ok)}** |")

if M.get('stillFill'):
    P('\n### One still: GPU ms (light, e0–e5 median; max) and main-thread encode ms\n')
    P('| variant | case | GPU p50 | GPU max | encode p50 |'); P('|---|---|---|---|---|')
    for r in M['stillFill']: P(f"| {r['variant']} | {r['case']} | {f(r['gpuMsP50'])} | {f(r['gpuMsMax'])} | {f(r['encodeMsP50'], 3)} |")
if M.get('switches'):
    P('\n### The switches\' cost (GPU ms per frame p50, e0–e2, light)\n')
    P('| variant | case | glass + bend (default) | glass off | bend off | both off |'); P('|---|---|---|---|---|---|')
    sw = M['switches']; keys = []
    for r in sw:
        k = (r['variant'], r['case'])
        if k not in keys: keys.append(k)
    for k in keys:
        g = {(r['glass'], r['edgeBend']): r['gpuMsP50'] for r in sw if (r['variant'], r['case']) == k}
        P(f"| {k[0]} | {k[1]} | {f(g[(True, True)])} | {f(g[(False, True)])} | {f(g[(True, False)])} | {f(g[(False, False)])} |")
if M.get('map'):
    P('\n### The Map\'s 262 stills per cap (A, stable hash, light; masters = min(1.25 D × scale, cap) in 16 px steps, mipmapped)\n')
    P('| scale | cap | texture MB | footprint Δ MB | buckets (m × n) | visible orbs | visible filled ms | all filled ms | GPU per orb ms (p50) | batch GPU ms p50 / p95 / max |')
    P('|---|---|---|---|---|---|---|---|---|---|')
    for r in M['map']:
        b = ' '.join(f"{x['m']}×{x['n']}" for x in r['buckets'])
        P(f"| {r['scale']:.0f}× | {r['cap'] if r['cap'] < 4096 else 'none'} | {r['MB']:.1f} | {f(r.get('footprintDeltaMB'), 1)} | {b} | {r.get('visibleOrbs', '-')} | "
          f"{f(r['visibleFillMs'], 0)} | {f(r['allFillMs'], 0)} | {f(r['gpuPerOrbMsMedian'])} | {f(r.get('batchGpuMsP50'))} / {f(r.get('batchGpuMsP95'))} / {f(r['batchGpuMsMax'])} |")
if M.get('jump'):
    P('\n### Still ↔ live (mean / max abs difference, 8-bit steps; bar ≤ 1/255 mean = 1.0 step)\n')
    P('| variant | case | enter: first live frame vs still (worst mean / max) | leave: last live frame vs redrawn still (worst mean / max) |'); P('|---|---|---|---|')
    keys = []
    for r in M['jump']:
        k = (r['variant'], r['case'])
        if k not in keys: keys.append(k)
    for k in keys:
        g = [r for r in M['jump'] if (r['variant'], r['case']) == k]
        P(f"| {k[0]} | {k[1]} | {max(r['enterMean'] for r in g):.4f} / {max(r['enterMax'] for r in g):.0f} | {max(r['leaveMean'] for r in g):.4f} / {max(r['leaveMax'] for r in g):.0f} |")
if M.get('cards'):
    P('\n### Card stills kept (visible + one screen each way)\n')
    P('| window | columns | visible | kept | MB each | kept MB (bar ≤ 40) |'); P('|---|---|---|---|---|---|')
    for r in M['cards']:
        P(f"| {r['window'][0]:.0f} × {r['window'][1]:.0f} {r.get('device', '')} | {r.get('columns', '-')} | {r['visible']:.0f} | {r['keptOneScreenEachWay']:.0f} | {r['bytesEach'] / 1048576:.2f} | {r['keptMB']:.1f} |")
