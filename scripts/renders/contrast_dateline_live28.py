#!/usr/bin/env python3
"""live-28 (A1) — the DATELINE (each card's topmost text line) over the light hero fade, from contrast_fade_live26.py: each text line of each card (shown vs -CardHideText diff), its
SOLID core (pixels that changed >= 85% of the line's strongest change) compared pixel by pixel with the backdrop under
it (the hidden still). Floor 4.5 (AA) for every line. Prints the worst line per card, and every line under 4.5.
    contrast_fade_live26.py <dir> <label>"""
import sys, os, io, contextlib, importlib.util
from PIL import Image, ImageChops
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fp", os.path.join(here, "fade_profile_live26.py"))
fp = importlib.util.module_from_spec(spec); argv = sys.argv; sys.argv = ["x", "/nonexistent", "x"]
with contextlib.redirect_stdout(io.StringIO()): spec.loader.exec_module(fp)
sys.argv = argv
def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def lum(r): return 0.2126 * lin(r[0]) + 0.7152 * lin(r[1]) + 0.0722 * lin(r[2])
def ratio(a, b): a, b = max(a, b), min(a, b); return (a + 0.05) / (b + 0.05)
d, label = sys.argv[1], sys.argv[2]
print("| face | card | mode | lines | dateline (y of card) | worst | p1 | AA 4.5 |")
print("|---|---|---|---|---|---|---|---|")
fails = []
for face in ["coverflow", "grid2", "grid3", "map-photo-busy", "map-fluted"]:
    for mode in ["dark", "light"]:
        dkp = os.path.join(d, f"{label}-dark-{face}-hidden.png")
        if not os.path.exists(dkp):   # a one-appearance sweep: the layout (and the Map card's place) is today's
            dkp = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "live26", "fade-today", f"today-dark-{face}-hidden.png")
        if not os.path.exists(os.path.join(d, f"{label}-{mode}-{face}.png")): continue
        dk = Image.open(dkp).convert("RGB")
        sh = Image.open(os.path.join(d, f"{label}-{mode}-{face}.png")).convert("RGB")
        hd = Image.open(os.path.join(d, f"{label}-{mode}-{face}-hidden.png")).convert("RGB")
        diff = ImageChops.difference(sh, hd).convert("L")
        names = ["busy photo", "landscape", "gradient art", "fluted"] if not face.startswith("map") else [face[4:]]
        for name, b in zip(names, fp.boxes(dk, face)):
            x0, y0, x1, y1 = [int(v) for v in b]; H = y1 - y0
            p = diff.load(); sp = sh.load(); hp = hd.load()
            rows = [y for y in range(y0, y1) if any(p[x, y] > 50 for x in range(x0 + 10, x1 - 10, 2))]
            lines = []; s = prev = None
            for y in rows:
                if s is None: s = y
                elif y - prev > 3: lines.append((s, prev)); s = y
                prev = y
            if s is not None: lines.append((s, prev))
            res = []
            for (a, bb) in lines:
                if bb - a < 6: continue
                pts = [(x, y) for y in range(a, bb + 1) for x in range(x0 + 6, x1 - 6)]
                m = max(p[x, y] for x, y in pts)
                core = [ratio(lum(sp[x, y]), lum(hp[x, y])) for x, y in pts if p[x, y] >= 0.85 * m]
                core.sort()
                res.append(((a - y0) / H, core[0], core[len(core) // 100]))
            if not res: continue
            w = min(res, key=lambda r: r[0])   # live-28: the topmost line = the dateline
            print(f"| {face} | {name} | {mode} | {len(res)} | {w[0]:.2f} | {w[1]:.2f} | {w[2]:.2f} | {'pass' if w[1] >= 4.5 else 'FAIL'} |")
            fails += [(face, name, mode, w)] if w[1] < 4.5 else []
if fails:
    print("\nLines under 4.5:")
    for f in fails: print(f"- {f[0]} {f[1]} {f[2]}: line at {f[3][0]:.2f} of the card, worst {f[3][1]:.2f}, p1 {f[3][2]:.2f}")
