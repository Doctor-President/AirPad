#!/usr/bin/env python3
# Sweep 2b · 2.3a — per-cmdbuf GPU time (all channels summed) for a process: p50/p95/max, and per-second GPU ms. gpudist.py <gpu.xml> <proc>
import sys, xml.etree.ElementTree as ET, collections
path, want = sys.argv[1], sys.argv[2]
ids = {}; cols = None
cb = collections.defaultdict(int); cbstart = {}; persec = collections.defaultdict(int)
def val(e):
    if e is None: return None
    r = e.get('ref')
    if r is not None: return ids.get(r)
    v = (e.get('fmt'), e.text, e)
    if e.get('id'): ids[e.get('id')] = v
    for c in e.iter():
        if c is not e and c.get('id'): ids[c.get('id')] = (c.get('fmt'), c.text, c)
    return v
for ev, el in ET.iterparse(path, events=('end',)):
    if el.tag == 'schema': cols = [c.findtext('mnemonic') for c in el.findall('col')]
    elif el.tag == 'row':
        row = dict(zip(cols, [val(c) for c in list(el)]))
        p = row.get('process'); pn = p[0] if p else ''
        if want in (pn or ''):
            d = int(row['duration'][1]); s = int(row['start'][1]); k = row.get('cmdbuffer-id'); k = k[1] if k else None
            cb[k] += d; cbstart.setdefault(k, s); persec[s // 10**9] += d
        el.clear()
v = sorted(x / 1e6 for x in cb.values())
def pct(p): return v[min(len(v) - 1, int((len(v) - 1) * p + 0.5))]
print(f"{want}: {len(v)} cmdbufs, GPU ms per cmdbuf p50 {pct(.5):.2f} p95 {pct(.95):.2f} max {v[-1]:.2f}")
print("GPU ms per second:", " ".join(f"{persec[s]/1e6:.0f}" for s in sorted(persec)))
n = collections.Counter(cbstart[k] // 10**9 for k in cbstart)
print("cmdbufs per second:", " ".join(str(n[s]) for s in sorted(n)))
