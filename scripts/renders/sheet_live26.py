#!/usr/bin/env python3
"""live-26 — before/after contact sheets: crops of the same region from two still sets, labelled, side by side.
    sheet_live26.py <out.jpg> <title> <crop x0,y0,x1,y1> <scale> <label=path> [<label=path> ...]   (rows of pairs: before, after)
Each argument after the scale is one cell; cells fill rows of two."""
import sys
from PIL import Image, ImageDraw, ImageFont
out, title, crop, scale = sys.argv[1], sys.argv[2], tuple(int(v) for v in sys.argv[3].split(",")), float(sys.argv[4])
cells = [a.split("=", 1) for a in sys.argv[5:]]
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 26); tfont = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 30)
except OSError:
    font = tfont = ImageFont.load_default()
ims = [(l, Image.open(p).convert("RGB").crop(crop)) for l, p in cells]
ims = [(l, im.resize((int(im.width * scale), int(im.height * scale)))) for l, im in ims]
cw, ch = ims[0][1].size; pad, lab, head = 16, 40, 60
cols = 2; rows = (len(ims) + 1) // 2
sheet = Image.new("RGB", (cols * (cw + pad) + pad, head + rows * (ch + lab + pad) + pad), "#FFFFFF")
d = ImageDraw.Draw(sheet); d.text((pad, 16), title, fill="#000000", font=tfont)
for i, (l, im) in enumerate(ims):
    x = pad + (i % cols) * (cw + pad); y = head + (i // cols) * (ch + lab + pad)
    d.text((x, y + 6), l, fill="#000000", font=font); sheet.paste(im, (x, y + lab))
sheet.save(out, quality=88)
print(out, sheet.size)
