#!/usr/bin/env python3
"""live-25 (1) + (3c) — contrast of the transcript, the pill text and the pill GLYPHS, per preset, light + dark, measured
as in live-21 / live-24: every still is shot again with the text and glyphs hidden (-RenderHideText).
  • transcript — the answer's paragraphs (the live-21 region, the tuner handle masked); text = ChatTypography.bodyText
    against every backdrop pixel. AA 4.5.
  • Ask text — the typed text's box (found by diffing shown vs hidden); text = the ink the pill resolves to. AA 4.5.
  • glyphs (feather, ×, send; the search pill's magnifier) and the "Search" placeholder — their colour isn't one hex
    (gradients, opacity), so each element's SOLID core (pixels that changed ≥ 85% of its strongest change between the
    shown and hidden stills; anti-aliased edges left out) is compared pixel by pixel with the backdrop under it.
    Non-text UI needs 3:1 (the placeholder is reported against 4.5 too).
    contrast_live25.py <stills_dir>
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

BODY = {"light": "2A2520", "dark": "E8E6E3"}          # ChatTypography.bodyText
INK = {"light": "232A2E", "dark": "FFFFFF"}           # AppearancePalette.ink
# The pill text's side (LibrarianPillChrome.textScheme): a dense dark grade → light ink; T's light paste grade is
# off-white (dark ink stays), his dark one near-black (light ink, = the dark appearance's anyway).
PILL_INK = {("siriPill", "light"): "FFFFFF", ("siriPill", "dark"): "FFFFFF", ("both", "light"): "FFFFFF",
            ("both", "dark"): "FFFFFF", ("t1017", "light"): "232A2E", ("t1017", "dark"): "FFFFFF"}
TRANSCRIPT = (40, 480, 1280, 2060)
HANDLE = (1130, 880, 1300, 1045)
BAND = {"long": (2380, 2720), "peek": (2520, 2820)}

def diff_mask(shown, hidden, band):
    d = ImageChops.difference(shown.convert("RGB"), hidden.convert("RGB")).convert("L").crop((0, band[0], shown.width, band[1]))
    return d

def runs(d, gap=18, thr=40):
    """x-runs of changed columns (an element each), as (x0, x1, y0, y1) boxes in band coordinates."""
    w, h = d.size; p = d.load()
    cols = [any(p[x, y] > thr for y in range(0, h, 2)) for x in range(w)]
    out, x = [], 0
    while x < w:
        if not cols[x]: x += 1; continue
        x0 = x; last = x
        while x < w and (cols[x] or x - last < gap):
            if cols[x]: last = x
            x += 1
        bb = d.crop((x0, 0, last + 1, h)).point(lambda v: 255 if v > thr else 0).getbbox()
        if bb: out.append((x0, last + 1, bb[1], bb[3]))
    return out

def core_contrast(shown, hidden, box):
    s = shown.convert("RGB").crop(box); hd = hidden.convert("RGB").crop(box)
    sp, hp = px(s), px(hd)
    ds = [max(abs(a - b) for a, b in zip(x[:3], y[:3])) for x, y in zip(sp, hp)]
    m = max(ds) if ds else 0
    if m == 0: return None
    cr = sorted(ratio(lum(x), lum(y)) for x, y, dd in zip(sp, hp, ds) if dd >= 0.85 * m)
    return cr[0], cr[len(cr) // 100], cr[len(cr) // 2]

def known_contrast(hidden, box, text_hex, mask=None):
    tl = lum(hexrgb(text_hex)); im = hidden.convert("RGB").crop(box); pts = px(im)
    if mask:
        bx, by = box[0], box[1]; w = im.width
        pts = [p for i, p in enumerate(pts) if not (mask[0] <= bx + i % w < mask[2] and mask[1] <= by + i // w < mask[3])]
    cr = sorted(ratio(tl, lum(p)) for p in pts)
    return cr[0], cr[len(cr) // 100], cr[len(cr) // 2]

rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*-hidden.png"))):
    name = os.path.basename(f)[:-len("-hidden.png")]
    preset, mode, posture = name.split("-")[:3]
    hidden = Image.open(f); shown = Image.open(f.replace("-hidden.png", ".png"))
    if posture == "long":
        rows.append((name, "transcript", "text", *known_contrast(hidden, TRANSCRIPT, BODY[mode], HANDLE)))
    band = BAND[posture]
    d = diff_mask(shown, hidden, band)
    rs = runs(d)
    if not rs: continue
    absb = lambda r: (r[0], band[0] + r[2], r[1], band[0] + r[3])
    if posture == "long":
        glyphs = [("feather", r) for r in rs if r[1] <= 240]
        right = [r for r in rs if r[0] >= 1000]
        mid = [r for r in rs if r[1] > 240 and r[0] < 1000]
        names = ["×", "send"] if len(right) == 2 else ["× + send"] * len(right)
        glyphs += list(zip(names, right))
        if mid:
            box = (min(r[0] for r in mid), band[0] + min(r[2] for r in mid), max(r[1] for r in mid), band[0] + max(r[3] for r in mid))
            ink = PILL_INK.get((preset, mode), INK[mode])
            rows.append((name, f"Ask text #{ink}", "text", *known_contrast(hidden, box, ink)))
    else:
        glyphs = [("magnifier", rs[0])]
        if len(rs) > 1:
            rest = rs[1:]
            box = (min(r[0] for r in rest), max(r[1] for r in rest), min(r[2] for r in rest), max(r[3] for r in rest))   # run format
            c = core_contrast(shown, hidden, absb(box))
            if c: rows.append((name, "\"Search\" placeholder", "placeholder", *c))
    for g, r in glyphs:
        c = core_contrast(shown, hidden, absb(r))
        if c: rows.append((name, g, "glyph", *c))

print("| still | element | kind | worst | p1 | median | floor | at worst |")
print("|---|---|---|---|---|---|---|---|")
for n, el, kind, w, p1, med in rows:
    floor = 3.0 if kind == "glyph" else 4.5
    print(f"| {n} | {el} | {kind} | {w:.2f} | {p1:.2f} | {med:.2f} | {floor:g} | {'pass' if w >= floor else 'FAIL'} |")
