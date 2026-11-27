#!/usr/bin/env python3
"""Good Flow spike · step 3B side-by-side sheets (synthetic entries e0–e5 only).

  python3 tools/sheet3b.py <measure dir with v-A, v-BD50> [--out build]

Per theme one sheet, build/side-by-side-<theme>.png: for each case (detail-iphone, card-iphone, orb-90-@2) and entry,
four columns: the bench as Chrome draws it (its own sin hash) | the bench with the stable hash | the port, A, stable hash
| the port, BD50. Columns 2 and 3 should be identical (the equality result); 1 shows where the bench's own hash puts the
pools on this machine; 4 is the cheapest variant.
"""
import argparse, os
from PIL import Image, ImageDraw
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
ap = argparse.ArgumentParser(); ap.add_argument('measure'); ap.add_argument('--out', default=os.path.join(ROOT, 'build')); a = ap.parse_args()
cols = [('bench (sin hash, Chrome)', os.path.join(ROOT, 'build/reference')), ('bench, stable hash', os.path.join(ROOT, 'build/reference-stable')),
        ('port A, stable hash', os.path.join(a.measure, 'v-A')), ('port BD50 (two-pass, 0.5x)', os.path.join(a.measure, 'v-BD50'))]
cases = [('detail-iphone', 300), ('card-iphone', 230), ('orb-90-@2', 200)]
for th in ('light', 'dark'):
    tiles = []
    for c, H in cases:
        for e in range(6):
            name = f'{c}__e{e}__{th}.png'
            ims = []
            for _, d in cols:
                im = Image.open(os.path.join(d, name)).convert('RGB')
                s = H / im.height; ims.append(im.resize((int(im.width * s), H), Image.LANCZOS))
            tiles.append((name, ims))
    W = max(sum(i.width for i in ims) + 10 * len(ims) + 10 for _, ims in tiles)
    Ht = sum(i[1][0].height + 22 for i in tiles) + 40
    S = Image.new('RGB', (W, Ht), (110, 110, 110) if th == 'light' else (40, 40, 40)); dr = ImageDraw.Draw(S)
    x = 8
    for (lbl, _), im in zip(cols, tiles[0][1]):
        dr.text((x, 8), lbl, fill=(255, 255, 255)); x += im.width + 10
    y = 30
    for name, ims in tiles:
        dr.text((8, y), name.replace('.png', '') + '   (synthetic entry)', fill=(255, 255, 255)); x = 8
        for im in ims:
            S.paste(im, (x, y + 14)); x += im.width + 10
        y += ims[0].height + 22
    out = os.path.join(a.out, f'side-by-side-{th}.png'); S.save(out); print('wrote', out, S.size)
