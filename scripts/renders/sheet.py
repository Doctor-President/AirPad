#!/usr/bin/env python3
"""live-21 (1) — contact sheet: sheet.py <out.png> <cols> <scale> <label:file> ... (labels drawn above each still)."""
import sys
from PIL import Image, ImageDraw, ImageFont
out, cols, scale = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
items = [a.split(":", 1) for a in sys.argv[4:]]
ims = [(l, Image.open(f).convert("RGB")) for l, f in items]
w, h = int(ims[0][1].width * scale), int(ims[0][1].height * scale)
lab = 44
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (w + 12) + 12, rows * (h + lab + 12) + 12), (255, 255, 255))
d = ImageDraw.Draw(sheet)
try: font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 28)
except Exception: font = ImageFont.load_default()
for i, (l, im) in enumerate(ims):
    x, y = 12 + (i % cols) * (w + 12), 12 + (i // cols) * (h + lab + 12)
    d.text((x, y + 6), l, fill=(0, 0, 0), font=font)
    sheet.paste(im.resize((w, h)), (x, y + lab))
sheet.save(out, optimize=True)
