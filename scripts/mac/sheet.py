#!/usr/bin/env python3
"""sheet.py <out.png> <cols> <img…> — labelled contact sheet (filename under each tile), tiles 512 px wide."""
import sys, os
from PIL import Image, ImageDraw, ImageFont
out, cols, imgs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
W = 512; tiles = []
for p in imgs:
    im = Image.open(p).convert("RGB"); h = int(im.height * W / im.width); tiles.append((os.path.basename(p)[:-4], im.resize((W, h))))
th = max(t[1].height for t in tiles) + 28; rows = (len(tiles) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (W + 8) + 8, rows * (th + 8) + 8), (128, 128, 128)); d = ImageDraw.Draw(sheet)
try: f = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 18)
except Exception: f = ImageFont.load_default()
for i, (name, im) in enumerate(tiles):
    x = 8 + (i % cols) * (W + 8); y = 8 + (i // cols) * (th + 8)
    sheet.paste(im, (x, y)); d.text((x + 4, y + im.height + 4), name, fill=(255, 255, 255), font=f)
sheet.save(out); print(out, sheet.size)
