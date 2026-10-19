#!/usr/bin/env python3
"""live-27 (1) — the contrast of every text run on a card face's PLAIN body (shown vs -CardHideText still). A run is a
band of rows that changed, split into runs at horizontal gaps of 8 pt; its SOLID core (pixels that changed >= 85% of the
run's strongest change) is compared pixel by pixel with the backdrop under it. Plain body = the backdrop under the run is
flat (luminance spread < 0.02). Runs over a photo / art are listed apart (the fade's business, not the ink's).
    meta_ink_live27.py <dir> <label> [mode]   → a markdown table per still + the worst per face"""
import sys, os, glob
import numpy as np
from PIL import Image
d, label = sys.argv[1], sys.argv[2]; mode = sys.argv[3] if len(sys.argv) > 3 else "light"
def lin(a):
    a = a / 255.0
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
def lum(img): l = lin(img.astype(np.float64)); return 0.2126 * l[..., 0] + 0.7152 * l[..., 1] + 0.0722 * l[..., 2]
S = 3
BODY = {"light": (251, 249, 245), "dark": (10, 10, 10)}   # the plain card body (measured on the grid stills)
rows_out = []; worst_face = {}
for shown in sorted(glob.glob(os.path.join(d, f"{label}-{mode}-*.png"))):
    if shown.endswith("-hidden.png"): continue
    face = os.path.basename(shown)[len(f"{label}-{mode}-"):-4]
    hidden = shown[:-4] + "-hidden.png"
    if not os.path.exists(hidden):   # a sweep shoots only the shown stills: the backdrops are the baseline's
        hidden = glob.glob(os.path.join(os.path.dirname(d), "*", f"*-{mode}-{face}-hidden.png"))
        if not hidden: continue
        hidden = hidden[0]
    a = np.asarray(Image.open(shown).convert("RGB")).astype(np.int16)
    b = np.asarray(Image.open(hidden).convert("RGB")).astype(np.int16)
    diff = np.abs(a - b).sum(axis=2)
    diff[: 62 * S] = 0                        # the status bar
    if face.startswith("map"):
        # The Map lays out afresh each launch, so the card lands elsewhere in the hidden still: judge the shown still
        # alone, against the card's plain body colour, inside the rows where that body spans the card.
        body = np.array(BODY[mode])
        bm = np.abs(a - body).sum(axis=2) <= 6
        xs = np.where(bm.sum(axis=0) > 300)[0]
        ys = np.where(bm[:, xs.min():xs.max() + 1].mean(axis=1) > 0.6)[0] if len(xs) else []
        if len(ys):                              # the card's own block: the longest run of body rows (gaps <= 40 px)
            blocks = np.split(ys, np.where(np.diff(ys) > 40)[0] + 1); ys = max(blocks, key=len)
        b = np.broadcast_to(body, a.shape).astype(np.int16)
        diff = np.abs(a - b).sum(axis=2)
        keep = np.zeros_like(diff, dtype=bool)
        if len(ys): keep[ys.min():ys.max() + 1, xs.min() + 30:xs.max() - 30] = True
        keep &= np.isin(np.arange(diff.shape[0]), ys)[:, None]
        diff[~keep] = 0
    La, Lb = lum(a), lum(b)
    on = diff > 60
    band_rows = np.where(on.any(axis=1))[0]
    bands = []
    if len(band_rows):
        s = p = band_rows[0]
        for y in band_rows[1:]:
            if y - p > 3: bands.append((s, p)); s = y
            p = y
        bands.append((s, p))
    for (y0, y1) in bands:
        if y1 - y0 < 5: continue
        cols = np.where(on[y0:y1 + 1].any(axis=0))[0]
        runs = []; s = p = cols[0]
        for x in cols[1:]:
            if x - p > 8 * S: runs.append((s, p)); s = x
            p = x
        runs.append((s, p))
        for (x0, x1) in runs:
            if x1 - x0 < 6: continue
            D = diff[y0:y1 + 1, x0:x1 + 1]; m = D.max()
            core = D >= 0.85 * m
            la, lb = La[y0:y1 + 1, x0:x1 + 1][core], Lb[y0:y1 + 1, x0:x1 + 1][core]
            r = (np.maximum(la, lb) + 0.05) / (np.minimum(la, lb) + 0.05)
            back = Lb[y0:y1 + 1, x0:x1 + 1]
            plain = (back.max() - back.min()) < 0.02
            if face.startswith("map") and ((y1 - y0 + 1) / S < 5 or r.min() < 2):
                continue                         # the body hairlines / a sliver of the art's tail, not text
            rows_out.append((face, x0 // S, y0 // S, (y1 - y0 + 1) / S, float(r.min()), float(np.percentile(r, 1)), plain,
                             float(back.mean())))
print(f"| still | x pt | y pt | height pt | worst | p1 | backdrop | AA 4.5 |")
print("|---|---|---|---|---|---|---|---|")
for f, x, y, h, w, p1, plain, bm in rows_out:
    if not plain: continue
    print(f"| {f} | {x} | {y} | {h:.1f} | {w:.2f} | {p1:.2f} | plain | {'pass' if w >= 4.5 else 'FAIL'} |")
    k = f.split("-p")[0]; worst_face[k] = min(worst_face.get(k, 99), w)
fails = [r for r in rows_out if r[6] and r[4] < 4.5]
print(f"\nplain-body runs: {sum(1 for r in rows_out if r[6])} · under 4.5: {len(fails)} · over art/photo (not judged): {sum(1 for r in rows_out if not r[6])}")
print("worst per face: " + " · ".join(f"{k} {v:.2f}" for k, v in sorted(worst_face.items())))
