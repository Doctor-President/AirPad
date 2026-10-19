#!/usr/bin/env python3
"""live-26 (2) — contrast of the Librarian's glyphs, pill text and placeholders on T's baked values, measured as in
live-25 (contrast_live25.py): every still is shot again with the text + glyphs hidden (-RenderHideText); an element's
SOLID core (pixels that changed >= 85% of its strongest change) is compared pixel by pixel with the backdrop under it.
The lowest passing ink opacities were found by sweeping them on real renders (sweep_live26.sh); a model that mixes the
ink into the backdrop over-estimates thin text, whose core pixels are rarely full coverage.
    contrast_live26.py <stills_dir>     (files <label>-<light|dark>-<peek|search|long>[-hidden].png)
"""
import sys, os, glob
from PIL import Image, ImageChops

def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def lum(rgb): r, g, b = rgb[:3]; return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
def ratio(a, b): a, b = max(a, b), min(a, b); return (a + 0.05) / (b + 0.05)
def hexrgb(h): return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def px(im): return list(im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata())
INK = {"light": "232A2E", "dark": "FFFFFF"}

def bands(shown, hidden, y0, y1, thr=40):
    d = ImageChops.difference(shown.convert("RGB"), hidden.convert("RGB")).convert("L")
    w = d.width; p = d.load(); out = []; s = prev = None
    for y in range(y0, y1):
        if any(p[x, y] > thr for x in range(0, w, 3)):
            if s is None: s = y
            elif y - prev > 6: out.append((s, prev + 1)); s = y
            prev = y
    if s is not None: out.append((s, prev + 1))
    return d, out

def runs(d, band, gap=18, thr=40):
    sub = d.crop((0, band[0], d.width, band[1])); w, h = sub.size; p = sub.load()
    cols = [any(p[x, y] > thr for y in range(0, h, 2)) for x in range(w)]
    out, x = [], 0
    while x < w:
        if not cols[x]: x += 1; continue
        x0 = x; last = x
        while x < w and (cols[x] or x - last < gap):
            if cols[x]: last = x
            x += 1
        bb = sub.crop((x0, 0, last + 1, h)).point(lambda v: 255 if v > thr else 0).getbbox()
        if bb: out.append((x0, band[0] + bb[1], last + 1, band[0] + bb[3]))
    return out

def core(shown, hidden, box):
    sp, hp = px(shown.convert("RGB").crop(box)), px(hidden.convert("RGB").crop(box))
    ds = [max(abs(a - b) for a, b in zip(x[:3], y[:3])) for x, y in zip(sp, hp)]
    m = max(ds) if ds else 0
    return [(x, y) for x, y, dd in zip(sp, hp, ds) if m and dd >= 0.85 * m]

def stats(pairs):
    cr = sorted(ratio(lum(x), lum(y)) for x, y in pairs)
    return cr[0], cr[len(cr) // 100], cr[len(cr) // 2]

def needed_alpha(pairs, ink, floor):
    ink = hexrgb(ink); backs = [y for _, y in pairs]
    def worst(a): return min(ratio(lum(tuple(b[i] + (ink[i] - b[i]) * a for i in range(3))), lum(b)) for b in backs)
    if worst(1.0) < floor: return None
    lo, hi = 0.0, 1.0
    for _ in range(30):
        mid = (lo + hi) / 2
        if worst(mid) >= floor: hi = mid
        else: lo = mid
    return hi

def names_for(posture, where, n):
    if posture == "peek": return ["magnifier", "\"Search\" placeholder"] + ["?"] * (n - 2)
    if posture == "long": return ["feather", "Ask text", "×", "send"] if n == 4 else ["?"] * n
    if where == "top": return ["magnifier", "search text", "×"] if n == 3 else ["?"] * n
    return ["feather", "\"Ask\" placeholder", "mic"] if n == 3 else ["?"] * n

KIND = {"magnifier": "glyph", "×": "glyph", "send": "glyph", "feather": "glyph", "mic": "glyph",
        "\"Search\" placeholder": "text", "\"Ask\" placeholder": "text", "Ask text": "text", "search text": "text"}
INKY = {"×", "\"Search\" placeholder", "\"Ask\" placeholder", "magnifier@peek"}

rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*-hidden.png"))):
    name = os.path.basename(f)[:-len("-hidden.png")]
    label, mode, posture = name.split("-")[:3]
    hidden = Image.open(f); shown = Image.open(f.replace("-hidden.png", ".png"))
    d, bs = bands(shown, hidden, 380 if posture != "long" else 2300, shown.height - 60)
    groups = [("top", b) for b in bs if b[0] < 1000] + [("bottom", b) for b in bs if b[0] > 2300]
    for where, band in groups:
        rs = runs(d, band)
        if posture in ("long", "search") and where == "bottom" or posture == "search" and where == "top":
            # merge the middle runs (the text) into one
            if len(rs) > 3:
                mid = rs[1:-1] if posture != "long" else rs[1:-2]
                m = (min(r[0] for r in mid), min(r[1] for r in mid), max(r[2] for r in mid), max(r[3] for r in mid))
                rs = [rs[0], m] + (rs[-1:] if posture != "long" else rs[-2:])
        if posture == "peek" and len(rs) > 2:
            m = (min(r[0] for r in rs[1:]), min(r[1] for r in rs[1:]), max(r[2] for r in rs[1:]), max(r[3] for r in rs[1:]))
            rs = [rs[0], m]
        for el, box in zip(names_for(posture, where, len(rs)), rs):
            pairs = core(shown, hidden, box)
            if not pairs: continue
            w, p1, med = stats(pairs)
            kind = KIND.get(el, "glyph"); floor = 3.0 if kind == "glyph" else 4.5
            key = "magnifier@peek" if (el == "magnifier" and posture == "peek") else el
            rows.append((name, el, kind, w, p1, med, floor))

print("| still | element | kind | worst | p1 | median | floor | at worst |")
print("|---|---|---|---|---|---|---|---|")
for n, el, kind, w, p1, med, floor in rows:
    print(f"| {n} | {el} | {kind} | {w:.2f} | {p1:.2f} | {med:.2f} | {floor:g} | {'pass' if w >= floor else 'FAIL'} |")
