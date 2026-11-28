#!/usr/bin/env python3
"""Good Flow spike · summarise a GFRecorder recording (design §1 / §3 rows).

  python3 tools/frames.py <recording.json> [--surface NAME] [--rest-after S] [--json]
  python3 tools/frames.py <recording.json> --design       the design §1 rows for one recording (step 3B)
  python3 tools/frames.py --summary <run dir | recording.json> …   one line per run + per-group medians, flat arms beside

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




# ── step 3B: the design §1 rows ────────────────────────────────────────────────────────────────────────────────────
MOVING = ('input', 'coast')


def design(R):
    """Every row design §1 asks for that one recording can answer."""
    meta, frames, ticks, samples, stills = R['meta'], R['frames'], R.get('ticks', []), R.get('samples', []), R.get('stills', [])
    marks = R.get('marks', [])
    vs = 1.0 / meta.get('maxFPS', 120)
    frames = sorted(frames, key=lambda f: f['linkT'])
    mov = [f for f in frames if f['wake'] in MOVING]
    d = {'screen': meta.get('screen', '?'), 'settings': meta.get('settings', {}), 'input': meta.get('input') or ('real or scripted' if any(f['wake'] in MOVING for f in frames) else 'no'),
         'maxFPS': meta.get('maxFPS'), 'frames': len(frames), 'presentedShare': (sum(1 for f in frames if f['presentT'] > 0) / len(frames)) if frames else None}
    # moving: per surface
    surf = {}
    for name in sorted(set(f['surface'] for f in mov)):
        fs = [f for f in mov if f['surface'] == name]
        n, one = cadence(fs, vs)
        surf[name] = dict(frames=len(fs), gaps=n, oneVsync=one, mainP95=pct([f['mainMs'] for f in fs], 95),
                          mainExWaitP95=pct([f['mainMs'] - f.get('waitMs', 0) for f in fs], 95), waitP95=pct([f.get('waitMs', 0) for f in fs], 95),
                          gpuP95=pct([f['gpuMs'] for f in fs], 95), gpuP50=pct([f['gpuMs'] for f in fs], 50))
    d['moving'] = surf
    if mov:
        t0, t1 = mov[0]['linkT'], mov[-1]['linkT']
        inwin = [s for s in stills if t0 <= s['t'] <= t1]
        d['stillsWhileMoving'] = dict(redrawn=sum(1 for s in inwin if s['reason'] not in ('fill', 'liveEnded')),
                                      fill=sum(1 for s in inwin if s['reason'] == 'fill'), liveEnded=sum(1 for s in inwin if s['reason'] == 'liveEnded'),
                                      fillGpuMsMax=max([s['gpuMs'] for s in inwin if s['reason'] == 'fill'], default=None))
        rs = t1 + 0.5
        d['rest'] = dict(fromT=rs, ticks=sum(1 for t in ticks if rs <= t['t'] < rs + 10),
                         frames=dict(Counter(f"{f['surface']}:{f['wake'].split(':')[0]}" for f in frames if rs <= f['linkT'] < rs + 10)),
                         cpuMedian=st.median([s['cpuPct'] for s in samples if rs <= s['t'] < rs + 10 and s['cpuPct'] >= 0] or [float('nan')]))
    live = [f for f in frames if f['wake'] == 'live']
    lv = {}
    for name in sorted(set(f['surface'] for f in live)):
        fs = [f for f in live if f['surface'] == name]
        span = fs[-1]['linkT'] - fs[0]['linkT'] if len(fs) > 1 else 0
        lv[name] = dict(frames=len(fs), perSecond=(len(fs) - 1) / span if span > 0 else None, gpuP95=pct([f['gpuMs'] for f in fs], 95),
                        mainExWaitP95=pct([f['mainMs'] - f.get('waitMs', 0) for f in fs], 95),
                        gpuP50=pct([f['gpuMs'] for f in fs], 50), mainP95=pct([f['mainMs'] for f in fs], 95),
                        gpuBusyAt30=(pct([f['gpuMs'] for f in fs], 50) * 30 / 10) if fs else None)
    d['live'] = lv
    # Round 2 (outcome 4; fable-read-device §1 "How to read"): ON-SCREEN figures per surface. Only frames drawn while the
    # surface was on screen (`vis`, recorded since round 2), cadence only between frames that came back with a present time
    # (no link-target fallback), the live surface judged against its OWN period (1/30 s), and the frames drawn off screen
    # counted apart (round 1 redrew the band on every scroll frame: 72 % of Detail's frames were never shown).
    onsc = {}
    for name in sorted(set(f['surface'] for f in frames if f['surface'] != 'host')):
        fs = [f for f in frames if f['surface'] == name]
        vis = [f for f in fs if f.get('vis', True)]
        pres = [f for f in vis if f['presentT'] > 0]
        ts = [f['presentT'] for f in pres]
        gaps = [b - a for a, b in zip(ts, ts[1:]) if 0 < b - a < 0.25]
        rates = [f.get('rate', 0) for f in vis if f['wake'] == 'live' and f.get('rate', 0) > 0]
        per = 1 / st.median(rates) if rates else vs
        onsc[name] = dict(drawn=len(fs), offScreen=len(fs) - len(vis), onScreen=len(vis), presented=len(pres),
                          gaps=len(gaps), oneVsync=(sum(1 for g in gaps if abs(g - vs) <= .25 * vs) / len(gaps)) if gaps else None,
                          oneOwnPeriod=(sum(1 for g in gaps if abs(g - per) <= .25 * per) / len(gaps)) if gaps else None, ownPeriodMs=per * 1000,
                          gpuP50=pct([f['gpuMs'] for f in vis], 50), gpuP95=pct([f['gpuMs'] for f in vis], 95),
                          liveGpuP50=pct([f['gpuMs'] for f in vis if f['wake'] == 'live'], 50), liveGpuP95=pct([f['gpuMs'] for f in vis if f['wake'] == 'live'], 95),
                          px=st.median([f['px'] for f in fs]) if fs else 0)
    d['onScreen'] = onsc
    host = [f for f in frames if f['surface'] == 'host']
    if host:   # the page's own scroll cadence: the main thread's link callbacks while input is recent (no present times)
        ts = [f['linkT'] for f in host]; gaps = [b - a for a, b in zip(ts, ts[1:]) if 0 < b - a < 0.25]
        d['hostCadence'] = dict(frames=len(host), oneVsync=(sum(1 for g in gaps if abs(g - vs) <= .25 * vs) / len(gaps)) if gaps else None)
    if samples:
        cpu = [s['cpuPct'] for s in samples if s['cpuPct'] >= 0]
        d['samples'] = dict(cpuMedian=st.median(cpu) if cpu else None, footprintMBMax=max(s['footprintMB'] for s in samples),
                            thermalStart=samples[0]['thermal'], thermalMax=max(s['thermal'] for s in samples), lowPower=any(s['lowPower'] for s in samples))
    d['marks'] = [m['what'] for m in marks if any(k in m['what'] for k in ('filled', 'jump', 'live ended', 'map stills', 'bench'))]
    d['metaExtra'] = {k: meta[k] for k in ('stills', 'stillBytes', 'stillsKept', 'budgetTruncated', 'visibleFillMs', 'liveBlockedBy', 'jump') if k in meta}
    return d


def print_design(d, name=''):
    S = d['settings']
    print(f"## {name or d['screen']}  ({d['input']} input · {S.get('case')} {S.get('theme')} variant {S.get('variant')} hash {S.get('hash')} "
          f"live {S.get('live')}@{S.get('liveRate')} flat {S.get('flat')} glass {S.get('glass')} bend {S.get('edgeBend')})")
    print(f"frames {d['frames']} · presented {('%.0f %%' % (100 * d['presentedShare'])) if d['presentedShare'] is not None else '-'} "
          f"(0 % = presentation times missing: a locked screen; cadence then reads link targets, not the screen)")
    print('| moving surface | frames | one vsync (bar ≥ 95 %) | main p95 ms (≤ 2.0) | main p95 without the drawable wait | GPU p50 / p95 ms (≤ 4.0) |\n|---|---|---|---|---|---|')
    for k, v in d['moving'].items():
        print(f"| {k} | {v['frames']} | {v['oneVsync'] * 100:.1f} % | {v['mainP95']:.3f} | {v['mainExWaitP95']:.3f} (wait p95 {v['waitP95']:.2f}) | {v['gpuP50']:.2f} / {v['gpuP95']:.2f} |")
    if 'stillsWhileMoving' in d:
        s = d['stillsWhileMoving']; print(f"stills while moving: redrawn {s['redrawn']} (bar 0) · fill {s['fill']} (max GPU {s['fillGpuMsMax']} ms a batch, bar 2.0) · live-ended {s['liveEnded']}")
    if 'rest' in d:
        r = d['rest']; print(f"rest (10 s from 0.5 s after the last input): ticks {r['ticks']}, frames {r['frames'] or 0}, CPU median {r['cpuMedian']:.2f} %")
    for k, v in d['live'].items():
        print(f"live {k}: {v['frames']} frames, {v['perSecond'] and round(v['perSecond'], 2)} a second (bar 30), GPU p50 / p95 {v['gpuP50']:.2f} / {v['gpuP95']:.2f} ms "
              f"(Mac ≤ 4.0, iPhone ≤ 5.0), main p95 {v['mainP95']:.3f} ms (≤ 1.0; {v['mainExWaitP95']:.3f} without the drawable wait)")
    if d.get('onScreen'):
        print('| on screen (round 2) | drawn | off screen | presented | one vsync | own period | GPU p50 / p95 (live) | px |\n|---|---|---|---|---|---|---|---|')
        for k, v in d['onScreen'].items():
            f = lambda x: '-' if x is None else '%.1f %%' % (100 * x)
            print(f"| {k} | {v['drawn']} | {v['offScreen']} | {v['presented']} | {f(v['oneVsync'])} | {f(v['oneOwnPeriod'])} @ {v['ownPeriodMs']:.1f} ms | "
                  f"{v['gpuP50']:.2f} / {v['gpuP95']:.2f} ({v['liveGpuP50']:.2f} / {v['liveGpuP95']:.2f}) | {v['px']:.0f} |")
    if d.get('hostCadence'):
        h = d['hostCadence']; print(f"page scroll cadence (host link, main thread): {h['frames']} callbacks, one vsync {('%.1f %%' % (100 * h['oneVsync'])) if h['oneVsync'] is not None else '-'}")
    if 'samples' in d:
        s = d['samples']; print(f"samples: CPU median {s['cpuMedian']:.2f} % · footprint max {s['footprintMBMax']:.1f} MB · thermal {s['thermalStart']} → max {s['thermalMax']} · low power {s['lowPower']}")
    for m in d['marks']:
        print('  ·', m)
    if d['metaExtra']:
        print('  meta:', json.dumps(d['metaExtra'])[:600])


def summary(paths):
    import os
    rows = []
    for p in paths:
        f = os.path.join(p, 'recording.json') if os.path.isdir(p) else p
        if not os.path.exists(f):
            continue
        d = design(json.load(open(f)))
        rows.append((os.path.basename(p.rstrip('/')), d))
    print('| run | moving surface | one vsync | main p95 | GPU p95 | rest ticks | rest frames | live/s | live GPU p95 | CPU rest |\n|---|---|---|---|---|---|---|---|---|---|')
    for name, d in rows:
        mv = d['moving'] or {'-': None}
        for k, v in mv.items():
            lv = next(iter(d['live'].values()), None)
            r = d.get('rest', {})
            print(f"| {name} | {k} | {v and '%.1f %%' % (100 * v['oneVsync'])} | {v and '%.3f' % v['mainP95']} | {v and '%.2f' % v['gpuP95']} | "
                  f"{r.get('ticks', '-')} | {sum((r.get('frames') or {}).values()) if r else '-'} | {lv and lv['perSecond'] and round(lv['perSecond'], 1)} | "
                  f"{lv and '%.2f' % lv['gpuP95']} | {('%.2f' % r['cpuMedian']) if r else ('%.2f (whole run)' % d['samples']['cpuMedian'] if d.get('samples') else '-')} |")
    # per group (tag without -r<n>), median one-vsync per surface; flat arm beside its look arm
    import re
    groups = {}
    for name, d in rows:
        g = re.sub(r'-r\d+$', '', name)
        for k, v in d['moving'].items():
            groups.setdefault((g, k), []).append(v['oneVsync'])
    print('\n| group | surface | runs | one vsync (median) | vs flat control (points) |\n|---|---|---|---|---|')
    for (g, k), xs in sorted(groups.items()):
        fl = groups.get((g.replace('-flat', '') if '-flat' in g else re.sub(r'-(detail|cards)-', r'-\1-flat-', g), k))
        diff = '' if '-flat' in g or not fl else f"{100 * (st.median(xs) - st.median(fl)):+.1f} (bar: within 1)"
        print(f"| {g} | {k} | {len(xs)} | {100 * st.median(xs):.1f} % | {diff} |")


if __name__ == '__main__' and len(sys.argv) > 1 and sys.argv[1] == '--summary':
    summary(sys.argv[2:]); sys.exit(0)
if __name__ == '__main__' and '--design' in sys.argv:
    p = [a for a in sys.argv[1:] if not a.startswith('--')][0]
    print_design(design(json.load(open(p))), p); sys.exit(0)


if __name__ == '__main__':
    main()
