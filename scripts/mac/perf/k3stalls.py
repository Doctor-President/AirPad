#!/usr/bin/env python3
"""E fix-up 4 · K3 — main-thread stalls from an xctrace Time Profiler recording, matched to rperf's steps.

  k3stalls.py <session.trace> <rperf.txt> [min ms = 50]

The main thread is the one whose stacks hold the run loop's NSApplication/UIApplication main. A STALL is a run of its
samples (1 ms apart, gaps ≤ 3 ms) lasting ≥ min ms: the main thread busy without a break, so nothing new can be drawn.
For each: start (ms into the trace), length, the rperf step it falls in (by wall clock), and the AirPad frames that
cover most of its samples (the innermost AirPad frame of each sample, counted; then the outermost, for context).
Ends with stalls ranked by total time per step label and per top frame ("what T would feel")."""
import re, subprocess, sys, xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import datetime

trace, rperf = sys.argv[1], sys.argv[2]
MIN = float(sys.argv[3]) if len(sys.argv) > 3 else 50.0

toc = subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--toc'], capture_output=True, text=True).stdout
start = datetime.fromisoformat(re.search(r'<start-date>([^<]+)', toc).group(1)).timestamp() * 1000
xml = subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--xpath',
                      '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], capture_output=True, text=True).stdout
root = ET.fromstring(xml)
ids = {}
def resolve(e):
    if e is None: return None
    r = e.get('ref')
    if r is not None: return ids.get(r)
    if e.get('id') is not None: ids[e.get('id')] = e
    for c in e: resolve(c)
    return e
samples = []   # (ms, thread fmt, [(frame name, binary name)] innermost first)
for row in root.iter('row'):
    t = resolve(row.find('sample-time')); th = resolve(row.find('thread')); bt = row.find('tagged-backtrace') or row.find('backtrace')
    bt = resolve(bt)
    frames = []
    if bt is not None:
        for f in bt.iter('frame'):
            f = resolve(f) if f.get('ref') else f
            b = f.find('binary'); b = resolve(b) if b is not None else None
            frames.append((f.get('name') or f.get('addr') or '?', (b.get('name') if b is not None else '')))
    samples.append((int(t.text) / 1e6, th.get('fmt') if th is not None else '?', frames))

by_thread = defaultdict(list)
for s in samples: by_thread[s[1]].append(s)
def is_main(ss): return any(any('NSApplicationMain' in n or 'UIApplicationMain' in n or '[NSApplication run]' in n for n, _ in s[2]) for s in ss[:400])
mains = [t for t, ss in by_thread.items() if is_main(ss)]
main = max(mains or by_thread, key=lambda t: len(by_thread[t]))
ms = sorted(by_thread[main], key=lambda s: s[0])

steps = []   # (wall ms, label)
for line in open(rperf):
    m = re.match(r'(\S+) (\S+) visible .* at (\d+)', line.strip())
    if m: steps.append((float(m.group(3)), m.group(1)))
def step_at(wall):
    lab = '(before the script)'
    for w, l in steps:
        if w <= wall: lab = l
        else: break
    return lab

def app_frames(frames):
    a = [n for n, b in frames if b.startswith('AirPad') and not n.startswith('0x')]
    return a
runs, cur = [], [ms[0]] if ms else []
for s in ms[1:]:
    if s[0] - cur[-1][0] <= 3: cur.append(s)
    else: runs.append(cur); cur = [s]
if cur: runs.append(cur)
stalls = [r for r in runs if r[-1][0] - r[0][0] + 1 >= MIN]

print(f'main thread: {main[:70]} · {len(ms)} samples · {len(stalls)} stalls ≥ {MIN:.0f} ms\n')
per_label, per_frame = Counter(), Counter()
for r in stalls:
    d = r[-1][0] - r[0][0] + 1
    lab = step_at(start + r[0][0])
    inner, outer = Counter(), Counter()
    for s in r:
        a = app_frames(s[2])
        if a: inner[a[0][:90]] += 1; outer[a[-1][:90]] += 1
        else: inner['(no AirPad frame: ' + (s[2][0][0][:60] if s[2] else '?') + ')'] += 1
    top = inner.most_common(3)
    per_label[lab] += d
    per_frame[top[0][0] if top else '?'] += d
    print(f'{r[0][0]:9.0f} ms  {d:5.0f} ms  [{lab}]')
    for n, c in top: print(f'      {c:4d}  {n}')
    if outer: print(f'      outer: {outer.most_common(1)[0][0]}')
print('\nTotal stall time by step (ms):')
for l, d in per_label.most_common(): print(f'  {d:7.0f}  {l}')
print('\nTotal stall time by top AirPad frame (ms):')
for f, d in per_frame.most_common(15): print(f'  {d:7.0f}  {f}')

# K3 — with STACKS=<step label>: the most common 18-frame stacks (innermost first) inside that step's stalls, and the
# frame families (binary · symbol prefix) that cover most of its samples.
import os
if os.environ.get('STACKS'):
    want = os.environ['STACKS']; fam = Counter(); n = 0
    for r in stalls:
        if step_at(start + r[0][0]) != want: continue
        for s in r:
            n += 1
            seen = set()
            for name, b in s[2]:
                key = f'{b} · {re.sub(r"[<(].*", "", name)[:80]}'
                if key not in seen: seen.add(key); fam[key] += 1
    print(f'\n{want}: {n} stall samples; frames present in the most samples:')
    for k, c in fam.most_common(int(os.environ.get("TOPN", "60"))): print(f'  {c:5d} {c / max(n, 1):4.0%}  {k}')

# K3 — STALLS_JSON=<path>: every stall as {wall start ms, duration ms} for k3table.py.
if os.environ.get('STALLS_JSON'):
    import json
    json.dump([{'t': start + r[0][0], 'd': r[-1][0] - r[0][0] + 1} for r in stalls], open(os.environ['STALLS_JSON'], 'w'))
