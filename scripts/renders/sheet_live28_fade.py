#!/usr/bin/env python3
"""live-28 (A1) — a contact sheet: columns = configs (label=dir:prefix:mode), rows = faces (coverflow, grid2, map-photo-busy).
    sheet_live28_fade.py <out.jpg> "Today light=dir:today:light" "A light=dir:band-…:light" ..."""
import sys, os
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]; cols = [a.split("=", 1) for a in sys.argv[2:]]
faces = ["coverflow", "grid2", "map-photo-busy"]
W = 440; H = int(2868 * W / 1320); pad = 16; head = 44
sheet = Image.new("RGB", (pad + len(cols) * (W + pad), head + len(faces) * (H + pad) + pad), (128, 128, 128))
d = ImageDraw.Draw(sheet)
try: font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 22)
except Exception: font = ImageFont.load_default()
for c, (label, spec) in enumerate(cols):
    dr, prefix, mode = spec.split(":")
    x = pad + c * (W + pad)
    d.text((x, 12), label, fill=(255, 255, 255), font=font)
    for r, f in enumerate(faces):
        p = os.path.join(dr, f"{prefix}-{mode}-{f}.png")
        if not os.path.exists(p): continue
        im = Image.open(p).convert("RGB").resize((W, H), Image.LANCZOS)
        sheet.paste(im, (x, head + r * (H + pad)))
sheet.save(out, quality=88); print(out, sheet.size)
