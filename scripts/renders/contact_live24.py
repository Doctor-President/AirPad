#!/usr/bin/env python3
"""live-24 (5) — contact sheets from shoot_live24.sh: per appearance, one row per preset (peek · long answer), and a
Reduce Transparency sheet (every preset, long). Stills halved, then halved again on the sheet. Labels are text only.
    contact_live24.py <stills_dir> <out_dir>
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont
src, out = sys.argv[1:3]
os.makedirs(out, exist_ok=True)
PRESETS = [("shipped", "Shipped (live-23 frost)"), ("glass", "Liquid Glass mode, defaults"), ("siriPill", "Siri-style pill"),
           ("gradedPanel", "Graded panel"), ("both", "Both")]
try: font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 30)
except OSError: font = ImageFont.load_default()
def load(name):
    p = os.path.join(src, name + ".png")
    if not os.path.exists(p): return None
    im = Image.open(p).convert("RGB"); return im.resize((im.width // 3, im.height // 3))
def sheet(cells, cols, path, title):
    W, H = 440, 956; pad, lab = 12, 44
    rows = (len(cells) + cols - 1) // cols
    s = Image.new("RGB", (cols * (W + pad) + pad, 60 + rows * (H + lab + pad)), (128, 128, 128))
    d = ImageDraw.Draw(s); d.text((pad, 14), title, fill=(255, 255, 255), font=font)
    for i, (label, im) in enumerate(cells):
        x = pad + (i % cols) * (W + pad); y = 60 + (i // cols) * (H + lab + pad)
        d.text((x, y + 6), label, fill=(255, 255, 255), font=font)
        if im: s.paste(im, (x, y + lab))
    s.save(path, quality=82); print(path)
for m in ("light", "dark"):
    cells = []
    for key, label in PRESETS:
        cells += [(f"{label} · peek", load(f"{key}-{m}-peek")), (f"{label} · long answer", load(f"{key}-{m}-long"))]
    sheet(cells, 4, os.path.join(out, f"presets-{m}.jpg"), f"live-24 · Librarian glass presets · {m} · Card grid 2-col (Sample Library) · iOS 27.0 Simulator")
cells = [(f"{label} · {m}", load(f"RT-{key}-{m}-long")) for m in ("light", "dark") for key, label in PRESETS]
sheet(cells, 5, os.path.join(out, "reduce-transparency.jpg"), "live-24 · Reduce Transparency ON · long answer")
cells = [(f"Both · Increase Contrast · {m}", load(f"IC-both-{m}-long")) for m in ("light", "dark")]
sheet(cells, 2, os.path.join(out, "increase-contrast.jpg"), "live-24 · Increase Contrast ON · Both")
