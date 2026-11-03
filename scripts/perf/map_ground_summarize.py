#!/usr/bin/env python3
"""1.1-A (6) — summarise a map_ground_trace.sh run: per case fps / CPU / thermal (from the app's [MapHeat] lines) and GPU
ms per frame + % busy per channel (Metal System Trace, AirPad process), then the pass costs by difference.
How to read: 'Fragment ms/frame' = the GPU fragment work per rendered frame (busy% / fps is the cross-check).
  grid  = a-all − a-gridOff        wells = a-all − a-wellsOff      ripple = a-all − a-rippleOff
  dots  = a-all − a-dotsOff        titles = a-all − a-titlesOff    orbs   = a-titlesOff − a-orbsOff
  budget for a new full-screen pass (sheen) = frame budget (16.7 ms @60, 8.3 ms @120) − Fragment ms/frame of the base case.
  120 Hz: b-all fps (does it reach 120?) and GPU busy % × fps = GPU-ms per second (battery proxy) vs a-all."""
import sys, re, glob, os, statistics as S
E = sys.argv[1]
rows = {}
for f in sorted(glob.glob(f'{E}/*.console')):
    n = os.path.basename(f)[:-8]
    if n == 'seed': continue
    L = [l for l in open(f, errors='ignore') if '[MapHeat]' in l]
    if not L: print(f'{n:20} no [MapHeat] lines'); continue
    fps = [int(re.search(r'rendered=(\d+)', l).group(1)) for l in L]
    cpu = [float(re.search(r'CPU=(\d+)', l).group(1)) for l in L]
    th = ' → '.join(dict.fromkeys(re.search(r'thermal=(\w+)', l).group(1) for l in L))
    frag = None; busy = None; gtxt = ''
    g = f'{E}/{n}.gpu.txt'
    if os.path.exists(g):
        out = open(g).read()
        for ch, ms, pct in re.findall(r'(\S+)\s+busy .*?-> ([\d.]+) ms/cmdbuf, ([\d.]+)% busy', out):
            gtxt += f'  {ch} {ms} ms/frame {pct}%'
            if ch.lower().startswith('frag'): frag, busy = float(ms), float(pct)
    if busy is not None and S.median(fps) > 0:
        frag = busy * 10 / S.median(fps)   # ms per rendered frame from % busy (robust to >1 command buffer per frame)
        gtxt += f'  → Fragment {frag:.2f} ms/frame (busy%/fps)'
    rows[n] = (S.median(fps), S.median(cpu), frag, busy)
    print(f'{n:16} fps med {S.median(fps):5.0f} (max {max(fps)})  CPU {S.median(cpu):4.0f}%  thermal {th}{gtxt}')
def d(a, b):
    if a in rows and b in rows and rows[a][2] is not None and rows[b][2] is not None:
        return f'{rows[a][2] - rows[b][2]:6.2f} ms/frame'
    return '   n/a'
print('\nPass costs (Fragment ms/frame by difference, A = 60 Hz build):')
for name, a, b in [('grid (whole ground)', 'a-all', 'a-gridOff'), ('gravity wells', 'a-all', 'a-wellsOff'),
                   ('ripple', 'a-all', 'a-rippleOff'), ('wells + ripple', 'a-all', 'a-wellsRippleOff'),
                   ('dots', 'a-all', 'a-dotsOff'), ('titles', 'a-all', 'a-titlesOff'), ('orbs', 'a-titlesOff', 'a-orbsOff')]:
    print(f'  {name:20} {d(a, b)}')
for base in ['a-all', 'a-wellsOff', 'b-all', 'b-wellsOff']:
    if base in rows and rows[base][2] is not None:
        fps, cpu, frag, busy = rows[base]
        print(f'  {base:12} sheen budget @60 {16.7 - frag:5.2f} ms · @120 {8.3 - frag:5.2f} ms · GPU-ms/s {frag * fps:6.0f} · CPU {cpu:.0f}%')
