#!/usr/bin/env python3
"""live-21 (1) — preview sheet for the layered export: each pass over a checkerboard, the passes recomposited
(field + shadow at today's 0.262 + cards), and the real L2 · S1 · F1 render for comparison."""
import sys
from PIL import Image, ImageDraw, ImageFont
R, out = sys.argv[1], sys.argv[2]
L = lambda n: Image.open(f"{R}/3-layers/L2-vertical-{n}.png").convert("RGBA")
names = ["1-field-with-dots", "2-card-bodies", "3-shadow-pass-full-strength", "4-hairline-pass"]
layers = [L(n) for n in names]
W, H = layers[0].size
chk = Image.new("RGBA", (W, H)); px = chk.load()
for y in range(H):
    for x in range(W): px[x, y] = (205, 205, 205, 255) if ((x // 24) + (y // 24)) % 2 else (255, 255, 255, 255)
tiles = []
for n, im in zip(names, layers):
    t = chk.copy(); t.alpha_composite(im); tiles.append((n, t.convert("RGB")))
sh = layers[2].copy(); sh.putalpha(sh.getchannel("A").point(lambda v: round(v * 0.262)))
comp = layers[0].copy(); comp.alpha_composite(sh); comp.alpha_composite(layers[1])
tiles.append(("recomposite (shadow @0.262)", comp.convert("RGB")))
tiles.append(("real render L2·S1·F1", Image.open(f"{R}/3-shadows/L2-S1-F1-vertical.png").convert("RGB")))
s = 0.25; w, h = int(W * s), int(H * s)
sheet = Image.new("RGB", (len(tiles) * (w + 12) + 12, h + 56), "white"); d = ImageDraw.Draw(sheet)
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
for i, (n, t) in enumerate(tiles):
    x = 12 + i * (w + 12); d.text((x, 12), n, fill=(0, 0, 0), font=font); sheet.paste(t.resize((w, h)), (x, 44))
sheet.save(out, optimize=True)
