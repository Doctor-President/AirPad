#!/usr/bin/env python3
"""Good Flow spike · summarise a GFRecorder recording (design §1 / §3 rows).

  python3 tools/frames.py <recording.json> [--surface NAME] [--rest-after S] [--json]

  cadence    share of present-to-present gaps that are one display vsync (1/maxFPS, ±25 %) and, separately, one LINK
             period (the rate the link asked for: 1/30 for a live-30 surface), counted inside awake runs only (a gap
             > 0.25 s is a pause, not a missed frame). Falls back to link timestamps when no present time came back.
  input      frames per input second (median / min over the whole seconds of an input run)
  main, GPU  p50 / p95 ms, all frames and per wake
  wakes      frames per wake reason ("input", "live", "oneshot:<why>")
  rest       ticks and frames after the last input frame + --rest-after s (default 0.5), and in the recording's last
             10 s; CPU %, footprint, thermal from the 1 Hz samples
"""
import argparse, json, statistics as st, sys
from collections import Counter, defaultdict


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None and x >= 0)
    if not xs:
        return float('nan')
    k = (len(xs) - 1) * p / 100
    f = int(k); c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def cadence(frames, period, tol=0.25):
    ts = [f['presentT'] if f['presentT'] > 0 else f['targetT'] for f in frames]
    gaps = [b - a for a, b in zip(ts, ts[1:]) if 0 < b - a < 0.25]
    if not gaps:
        return 0, float('nan')
    one = sum(1 for g in gaps if abs(g - period) <= tol * period)
    return len(gaps), one / len(gaps)


def per_second(frames):
    """Frames per whole second of each input run (a run ends at a > 0.5 s gap)."""
    runs, cur = [], []
    for f in frames:
        if cur and f['linkT'] - cur[-1]['linkT'] > 0.5:
            runs.append(cur); cur = []
        cur.append(f)
    if cur:
        runs.append(cur)
    counts = []
    for r in runs:
        t0 = r[0]['linkT']; n = int(r[-1]['linkT'] - t0)
        for s in range(n):
            counts.append(sum(1 for f in r if t0 + s <= f['linkT'] < t0 + s + 1))
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rec'); ap.add_argument('--surface'); ap.add_argument('--rest-after', type=float, default=0.5)
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    R = json.load(open(a.rec))
    meta, frames, ticks, samples = R['meta'], R['frames'], R.get('ticks', []), R.get('samples', [])
    if a.surface:
        frames = [f for f in frames if f['surface'] == a.surface]; ticks = [t for t in ticks if t['surface'] == a.surface]
    frames.sort(key=lambda f: f['linkT'])
    vs = 1.0 / meta.get('maxFPS', 120)
    out = {'file': a.rec, 'meta': meta, 'frames': len(frames), 'ticks': len(ticks)}
    wakes = Counter('oneshot' if f['wake'].startswith('oneshot') else f['wake'] for f in frames)
    out['wakes'] = dict(Counter(f['wake'] for f in frames))
    rows = []
    for w in ['input', 'live', 'oneshot', 'all']:
        fs = frames if w == 'all' else [f for f in frames if (f['wake'].startswith('oneshot') if w == 'oneshot' else f['wake'] == w)]
        if not fs:
            continue
        n_gap, one_vs = cadence(fs, vs)
        rates = [f.get('rate', 0) for f in fs if f.get('rate', 0) > 0]
        linkp = 1.0 / st.median(rates) if rates else st.median(f['vsync'] for f in fs)
        _, one_link = cadence(fs, linkp)
        rows.append(dict(wake=w, frames=len(fs), gaps=n_gap, oneVsync=one_vs, linkPeriodMs=linkp * 1000, oneLinkPeriod=one_link,
                         mainP50=pct([f['mainMs'] for f in fs], 50), mainP95=pct([f['mainMs'] for f in fs], 95),
                         gpuP50=pct([f['gpuMs'] for f in fs], 50), gpuP95=pct([f['gpuMs'] for f in fs], 95),
                         presented=sum(1 for f in fs if f['presentT'] > 0) / len(fs)))
    out['byWake'] = rows
    inp = [f for f in frames if f['wake'] == 'input']
    pcs = per_second(inp)
    out['inputFramesPerSecond'] = dict(median=st.median(pcs) if pcs else None, min=min(pcs) if pcs else None, seconds=len(pcs))
    end = R['meta'].get('savedT', max([t['t'] for t in ticks] + [0]))
    rest_from = (inp[-1]['linkT'] + a.rest_after) if inp else None
    if rest_from:
        out['afterInput'] = dict(fromT=rest_from, seconds=end - rest_from,
                                 ticks=sum(1 for t in ticks if t['t'] >= rest_from),
                                 frames=dict(Counter(f['wake'] for f in frames if f['linkT'] >= rest_from)))
    lastTick = max([t['t'] for t in ticks], default=None)
    out['idleTail'] = dict(seconds=(end - lastTick) if lastTick else None)   # time since the link last ticked
    out['last10s'] = dict(ticks=sum(1 for t in ticks if t['t'] >= end - 10), frames=dict(Counter(f['wake'] for f in frames if f['linkT'] >= end - 10)))
    if samples:
        cpu = [s['cpuPct'] for s in samples if s['cpuPct'] >= 0]
        last = [s['cpuPct'] for s in samples if s['t'] >= end - 10 and s['cpuPct'] >= 0]
        out['samples'] = dict(n=len(samples), cpuMedian=st.median(cpu) if cpu else None, cpuLast10sMedian=st.median(last) if last else None,
                              footprintMBMax=max(s['footprintMB'] for s in samples), thermalMax=max(s['thermal'] for s in samples),
                              lowPowerEver=any(s['lowPower'] for s in samples))
    if a.json:
        print(json.dumps(out, indent=1)); return
    print(f"{a.rec}\n  {meta.get('screen','')} mode={meta.get('mode','')} maxFPS={meta.get('maxFPS')} frames={len(frames)} ticks={len(ticks)} wakes={out['wakes']}")
    print('  | wake | frames | gaps | one vsync | link ms | one link period | main p50/p95 ms | GPU p50/p95 ms | presented |')
    print('  |---|---|---|---|---|---|---|---|---|')
    for r in rows:
        print(f"  | {r['wake']} | {r['frames']} | {r['gaps']} | {r['oneVsync']*100:.1f} % | {r['linkPeriodMs']:.2f} | {r['oneLinkPeriod']*100:.1f} % | "
              f"{r['mainP50']:.3f} / {r['mainP95']:.3f} | {r['gpuP50']:.2f} / {r['gpuP95']:.2f} | {r['presented']*100:.0f} % |")
    fps = out['inputFramesPerSecond']
    if fps['seconds']:
        print(f"  input frames per second: median {fps['median']} min {fps['min']} over {fps['seconds']} s")
    if 'afterInput' in out:
        x = out['afterInput']; print(f"  after input (+{a.rest_after}s, {x['seconds']:.1f} s): ticks {x['ticks']}, frames {x['frames']}")
    if out['idleTail']['seconds'] is not None:
        print(f"  idle tail: the link last ticked {out['idleTail']['seconds']:.2f} s before the save (0 ticks since)")
    for m in R.get('marks', []):
        print(f"  mark {m['t'] - R['meta']['t0']:7.2f} s  {m['what']}   ticks after it: {sum(1 for t in ticks if t['t'] > m['t'])}")
    print(f"  last 10 s: ticks {out['last10s']['ticks']}, frames {out['last10s']['frames']}")
    if samples:
        s = out['samples']; print(f"  samples {s['n']}: CPU median {s['cpuMedian']:.1f} % (last 10 s {s['cpuLast10sMedian']}), footprint max {s['footprintMBMax']:.1f} MB, thermal max {s['thermalMax']}, low power {s['lowPowerEver']}")


if __name__ == '__main__':
    main()
