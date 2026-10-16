#!/usr/bin/env python3
"""live-21 (1) — contrast numbers for the renders (WCAG 2 relative luminance / contrast ratio).
  contrast.py panels <dir-of-1-panels>   body text vs the backdrop behind the long answer, per still
  contrast.py fields                     card vs field (and dot vs field) per palette × F level, from the hex values
"""
import sys, os, glob
from PIL import Image, ImageFilter

def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def lum(rgb): r, g, b = rgb; return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
def ratio(a, b): a, b = max(a, b), min(a, b); return (a + 0.05) / (b + 0.05)
def hexrgb(h): return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

TEXT = {"light": "2A2520", "dark": "E8E6E3"}   # ChatTypography.bodyText
REGION = (40, 480, 1280, 2060)                   # the transcript paragraphs (1320 × 2868 px screenshots)

def backdrops(d):
    """The same long-answer stills shot with the transcript text hidden (-RenderHideText): every pixel in the region is
    backdrop, so the worst case is exact (no glyph masking)."""
    print("| still | text | worst backdrop | p1 | median | AA (4.5) at worst |")
    print("|---|---|---|---|---|---|")
    for f in sorted(glob.glob(os.path.join(d, "*-long.png"))):
        name = os.path.basename(f)[:-4]
        mode = "dark" if "-dark-" in name else "light"
        tl = lum(hexrgb(TEXT[mode]))
        im = Image.open(f).convert("RGB").crop(REGION)
        px = im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata()
        cr = sorted(ratio(tl, lum(p)) for p in px)
        worst, p1, med = cr[0], cr[len(cr) // 100], cr[len(cr) // 2]
        print(f"| {name} | #{TEXT[mode]} | {worst:.2f} | {p1:.2f} | {med:.2f} | {'pass' if worst >= 4.5 else 'FAIL'} |")

def panels(d):
    print("| still | text | worst backdrop | p1 | median | AA (4.5) worst |")
    print("|---|---|---|---|---|---|")
    for f in sorted(glob.glob(os.path.join(d, "*-long.png"))):
        name = os.path.basename(f)[:-4]
        mode = "dark" if "-dark-" in name else "light"
        tl = lum(hexrgb(TEXT[mode]))
        im = Image.open(f).convert("RGB").crop(REGION)
        px = list(im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata())
        cr = [ratio(tl, lum(p)) for p in px]
        # glyph pixels (and their anti-aliased rims) are near the text colour: mask them, then grow the mask 4 px
        mask = Image.new("L", im.size); mask.putdata([255 if c < 3.0 else 0 for c in cr])
        mask = mask.filter(ImageFilter.MaxFilter(9))
        mv = list(mask.get_flattened_data() if hasattr(mask, "get_flattened_data") else mask.getdata())
        bg = sorted(c for c, m in zip(cr, mv) if not m)
        if not bg: print(f"| {name} | — | no backdrop pixels | | | |"); continue
        worst, p1, med = bg[0], bg[len(bg) // 100], bg[len(bg) // 2]
        print(f"| {name} | #{TEXT[mode]} | {worst:.2f} | {p1:.2f} | {med:.2f} | {'pass' if worst >= 4.5 else 'FAIL'} |")

def fields():
    sys.path.insert(0, os.path.dirname(__file__))
    P = {  # mirrors RenderVariant.palettes (field F1, F2, F3, F4; card face; dot)
        "L1": (["DDDDDD", "E8E8E8", "F3F3F3", "D2D2D2"], "FFFFFA", "2E3A40"),
        "L2": (["EFECE6", "F4F2ED", "F8F6F2", "E6E2DA"], "FBF9F5", "3B362F"),
        "L3": (["ECECEA", "F1F1EF", "F6F6F4", "E3E3E0"], "FAFAF8", "33383B"),
    }
    print("| palette | F | field | card | ΔL (card − field) | card:field ratio | dot (0.523) on field: ratio |")
    print("|---|---|---|---|---|---|---|")
    for p, (fs, card, dot) in P.items():
        for i, fh in enumerate(fs):
            f, c = hexrgb(fh), hexrgb(card)
            d = hexrgb(dot); a = 0.523
            comp = tuple(round(a * d[k] + (1 - a) * f[k]) for k in range(3))
            print(f"| {p} | F{i+1} | #{fh} | #{card} | {lum(c) - lum(f):+.3f} | {ratio(lum(c), lum(f)):.2f} | {ratio(lum(comp), lum(f)):.2f} |")

if __name__ == "__main__":
    {"panels": lambda: panels(sys.argv[2]), "backdrops": lambda: backdrops(sys.argv[2])}.get(sys.argv[1], fields)()
