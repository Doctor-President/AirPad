#!/usr/bin/env python3
"""Good Flow spike · picture equality (design §2): port stills vs the bench reference.

  python3 tools/compare.py [--ref build/reference] [--port build/port] [--sheet build/compare-sheet.png]
                           [--sample N] [--json out.json] [--uniforms]

Per still: mean absolute difference per channel in 8-bit steps (over R, G, B and every pixel) and its 99th percentile.
Bar (faithful port A): mean <= 1.0 and p99 <= 8 on every still. "Near" (variants): mean <= 2.0 and p99 <= 16.
Only the reference's names are compared (`<case>__<entry>__<theme>.png`; the *-fillvariant orbs are skipped).
--uniforms also checks <port>/uniforms.json against <ref>/manifest.json (float32 tolerance).
"""
import argparse, json, os, re, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
NAME = re.compile(r'^(?P<case>[a-z0-9@-]+?)__(?P<entry>e\d)__(?P<theme>light|dark)\.png$')


def load(p):
    return np.asarray(Image.open(p).convert('RGB'), dtype=np.int16)


def diff(a, b):
    if a.shape != b.shape:
        return None
    d = np.abs(a - b).astype(np.float64)
    return d


def compare(ref_dir, port_dir):
    rows = []
    for f in sorted(os.listdir(ref_dir)):
        m = NAME.match(f)
        if not m or 'fillvariant' in f:
            continue
        pp = os.path.join(port_dir, f)
        if not os.path.exists(pp):
            rows.append(dict(file=f, **m.groupdict(), missing=True)); continue
        a, b = load(os.path.join(ref_dir, f)), load(pp)
        d = diff(a, b)
        if d is None:
            rows.append(dict(file=f, **m.groupdict(), shape=[a.shape, b.shape])); continue
        rows.append(dict(file=f, **m.groupdict(), mean=float(d.mean()), p99=float(np.percentile(d, 99)), max=float(d.max()),
                         over8=float((d > 8).mean()), meanSigned=float((b - a).mean())))
    return rows


def verdict(r, mean_bar=1.0, p99_bar=8.0):
    return 'mean' in r and r['mean'] <= mean_bar and r['p99'] <= p99_bar


def table(rows, title, mean_bar=1.0, p99_bar=8.0):
    out = [f'## {title}', '', f'Bar: mean <= {mean_bar}, p99 <= {p99_bar} (8-bit steps, per channel).', '',
           '| case | theme | n | mean (avg) | mean (worst) | p99 (worst) | max | pass |', '|---|---|---|---|---|---|---|---|']
    bad = [r for r in rows if 'mean' not in r]
    ok = [r for r in rows if 'mean' in r]
    cases = []
    for r in ok:
        if r['case'] not in cases:
            cases.append(r['case'])
    for c in cases:
        for th in ('light', 'dark'):
            g = [r for r in ok if r['case'] == c and r['theme'] == th]
            if not g:
                continue
            p = sum(verdict(r, mean_bar, p99_bar) for r in g)
            out.append(f"| {c} | {th} | {len(g)} | {np.mean([r['mean'] for r in g]):.3f} | {max(r['mean'] for r in g):.3f} | "
                       f"{max(r['p99'] for r in g):.1f} | {max(r['max'] for r in g):.0f} | {p}/{len(g)} |")
    n_pass = sum(verdict(r, mean_bar, p99_bar) for r in ok)
    out.append('')
    out.append(f'**{n_pass}/{len(rows)} pass**' + (f'; {len(bad)} missing or wrong size: {[r["file"] for r in bad][:6]}' if bad else ''))
    if ok:
        w = max(ok, key=lambda r: (r['p99'], r['mean']))
        wm = max(ok, key=lambda r: r['mean'])
        out.append(f"worst by p99: {w['file']} mean {w['mean']:.3f} p99 {w['p99']:.1f} max {w['max']:.0f}; "
                   f"worst by mean: {wm['file']} mean {wm['mean']:.3f} p99 {wm['p99']:.1f}")
    return '\n'.join(out)


def sheet(ref_dir, port_dir, files, out, amp=8, cell=360):
    tiles = []
    for f in files:
        a, b = load(os.path.join(ref_dir, f)), load(os.path.join(port_dir, f))
        d = np.clip(np.abs(a - b) * amp, 0, 255).astype(np.uint8)
        ims = [Image.fromarray(a.astype(np.uint8)), Image.fromarray(b.astype(np.uint8)), Image.fromarray(d)]
        s = cell / max(a.shape[0], a.shape[1] / 1.6)
        ims = [i.resize((max(1, int(i.width * s)), max(1, int(i.height * s))), Image.LANCZOS) for i in ims]
        tiles.append((f, ims))
    W = max(sum(i.width for i in ims) + 40 for _, ims in tiles)
    H = sum(max(i.height for i in ims) + 24 for _, ims in tiles) + 10
    S = Image.new('RGB', (W, H), (128, 128, 128))
    from PIL import ImageDraw
    dr = ImageDraw.Draw(S)
    y = 5
    for f, ims in tiles:
        dr.text((8, y), f'{f}   reference | port | {amp}x |diff|', fill=(255, 255, 255))
        x = 8
        for i in ims:
            S.paste(i, (x, y + 16)); x += i.width + 10
        y += max(i.height for i in ims) + 24
    S.save(out)


def check_uniforms(ref_dir, port_dir):
    man = json.load(open(os.path.join(ref_dir, 'manifest.json')))
    pu = json.load(open(os.path.join(port_dir, 'uniforms.json')))
    probs, n = [], 0
    for s in man['stills']:
        if s['file'] not in pu:
            continue
        n += 1
        ru, qu = s['uniforms'], pu[s['file']]
        for k, v in qu.items():
            if k not in ru:
                probs.append((s['file'], k, 'not in reference')); continue
            a = np.atleast_1d(np.array(ru[k], dtype=np.float64)).astype(np.float32)
            b = np.atleast_1d(np.array(v, dtype=np.float64)).astype(np.float32)
            if a.shape != b.shape or not np.array_equal(a, b):
                probs.append((s['file'], k, ru[k], v))
        # reference uniforms the Flow path reads but the port does not carry
        for k in ru:
            if k not in qu and k not in ('uMerge', 'uMotion', 'uTransl', 'uCore', 'uBand', 'uRange', 'uRound', 'uForm',
                                         'uFront', 'uDist', 'uDeep', 'uDrift', 'uOrg', 'uThick', 'uCoil', 'uRun'):
                probs.append((s['file'], k, 'not carried by the port'))
    return n, probs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ref', default=os.path.join(ROOT, 'build/reference'))
    ap.add_argument('--port', default=os.path.join(ROOT, 'build/port'))
    ap.add_argument('--title', default=None)
    ap.add_argument('--sheet', default=None)
    ap.add_argument('--sample', type=int, default=8)
    ap.add_argument('--json', default=None)
    ap.add_argument('--uniforms', action='store_true')
    ap.add_argument('--near', action='store_true', help='judge against the "near" bar (2.0 / 16)')
    a = ap.parse_args()
    rows = compare(a.ref, a.port)
    mb, pb = (2.0, 16.0) if a.near else (1.0, 8.0)
    print(table(rows, a.title or f'{os.path.relpath(a.port, ROOT)} vs {os.path.relpath(a.ref, ROOT)}', mb, pb))
    if a.uniforms:
        n, probs = check_uniforms(a.ref, a.port)
        print(f'\nuniforms: {n} stills checked against manifest.json, {len(probs)} differences')
        for p in probs[:20]:
            print('  ', p)
    if a.json:
        json.dump(rows, open(a.json, 'w'), indent=1)
    if a.sheet:
        ok = [r for r in rows if 'mean' in r]
        worst = sorted(ok, key=lambda r: -r['p99'])[:max(1, a.sample // 2)]
        pick = [r['file'] for r in worst]
        for c in ('detail-iphone', 'card-mac', 'orb-90-@2', 'detail-mac'):
            for r in ok:
                if r['case'] == c and r['file'] not in pick and r['entry'] in ('e0', 'e4'):
                    pick.append(r['file']); break
        sheet(a.ref, a.port, pick[:a.sample], a.sheet)
        print(f'sheet: {a.sheet} ({len(pick[:a.sample])} stills)')
    sys.exit(0)


if __name__ == '__main__':
    main()
