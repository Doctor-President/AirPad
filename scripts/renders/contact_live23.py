#!/usr/bin/env python3
"""live-23 — contact sheets from the showcase stills: for each view × mode, row A over row B (pages side by side),
each still cropped to the content area and halved. Labels are text only (no colour words).

    contact_live23.py <showcase_dir> <out_dir> <tagA> <tagB> <name>
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

src, out, A, B, name = sys.argv[1:6]
os.makedirs(out, exist_ok=True)
PAGES = {"coverflow": 3, "vertical": 3, "grid2": 2, "grid3": 1}
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 34)
except OSError:
    font = ImageFont.load_default()

def crop(p):
    im = Image.open(p).convert("RGB")
    w, h = im.size
    im = im.crop((0, int(h * 0.12), w, int(h * 0.88)))   # drop the status bar and the search pill band
    return im.resize((im.width // 2, im.height // 2))

for mode in ("light", "dark"):
    for view, pages in PAGES.items():
        rows = []
        for tag in (A, B):
            ims = [crop(os.path.join(src, f"{tag}-{mode}-{view}-p{p}.png")) for p in range(pages)
                   if os.path.exists(os.path.join(src, f"{tag}-{mode}-{view}-p{p}.png"))]
            if not ims:
                continue
            w = sum(i.width for i in ims) + 12 * (len(ims) - 1)
            row = Image.new("RGB", (w, ims[0].height + 56), (128, 128, 128))
            ImageDraw.Draw(row).text((10, 8), f"{tag.upper()} · {view} · {mode}", fill=(255, 255, 255), font=font)
            x = 0
            for i in ims:
                row.paste(i, (x, 56)); x += i.width + 12
            rows.append(row)
        if len(rows) != 2:
            continue
        W = max(r.width for r in rows)
        sheet = Image.new("RGB", (W, sum(r.height for r in rows) + 16), (128, 128, 128))
        sheet.paste(rows[0], (0, 0)); sheet.paste(rows[1], (0, rows[0].height + 16))
        sheet.save(os.path.join(out, f"{name}-{view}-{mode}.jpg"), quality=82)
        print(os.path.join(out, f"{name}-{view}-{mode}.jpg"))
