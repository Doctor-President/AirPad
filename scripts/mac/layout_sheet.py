#!/usr/bin/env python3
"""Mac batch D — layout_sheet.py <stills dir> <out dir>: one contact sheet per window width from
<stills>/<W>-lib<open|closed>-side<on|off>/<view>-<look>.png. Rows = view × look, columns = Librarian × sidebar."""
import sys, os, glob
from PIL import Image, ImageDraw, ImageFont
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
try: f = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 16)
except Exception: f = ImageFont.load_default()
combos = [("open", "on"), ("open", "off"), ("closed", "on"), ("closed", "off")]
views = ["dashboard", "map", "list", "cards", "entry"]
for w in sorted({os.path.basename(d).split("-lib")[0] for d in glob.glob(f"{src}/*-lib*")}):
    TW = 440
    cells = []
    for v in views:
        for look in ["light", "dark"]:
            row = []
            for lib, side in combos:
                p = f"{src}/{w}-lib{lib}-side{side}/{v}-{look}.png"
                row.append((f"{v} {look} · Librarian {lib} · sidebar {side}", Image.open(p).convert("RGB") if os.path.exists(p) else None))
            cells.append(row)
    th = max(int(im.height * TW / im.width) for r in cells for _, im in r if im) + 24
    sheet = Image.new("RGB", (len(combos) * (TW + 8) + 8, len(cells) * (th + 8) + 8), (120, 120, 120))
    d = ImageDraw.Draw(sheet)
    for r, row in enumerate(cells):
        for c, (label, im) in enumerate(row):
            x, y = 8 + c * (TW + 8), 8 + r * (th + 8)
            if im: sheet.paste(im.resize((TW, int(im.height * TW / im.width))), (x, y + 22))
            d.text((x, y + 2), label, fill=(255, 255, 255), font=f)
    sheet.save(f"{out}/contact-{w}.jpg", quality=82)
    print(f"{out}/contact-{w}.jpg", sheet.size)
