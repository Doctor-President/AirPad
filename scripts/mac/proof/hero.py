# hero.py <window still (2x)> <x0> <x1> <y0> <y1> <ground x> <ground y>  (window points) — columns of the hero band, every
# 8 pt: mean brightness, mean saturation (max−min) and mean distance from the ground colour (sampled at the ground point).
# Prints the columns, then where the colour starts (first column ≥ 25 from the ground) and ends (last such column).
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB'); a = [float(v) for v in sys.argv[2:9]]
x0, x1, y0, y1, gx, gy = [int(v * 2) for v in a[:4]] + [int(a[4] * 2), int(a[5] * 2)]
g = im.getpixel((gx, gy)); print("ground", g)
cols = []
for x in range(x0, x1, 16):
    px = [im.getpixel((x + dx, y)) for y in range(y0, y1, 4) for dx in (0, 4, 8, 12) if x + dx < im.width]
    br = sum(sum(p) / 3 for p in px) / len(px); sat = sum(max(p) - min(p) for p in px) / len(px)
    d = sum(sum(abs(p[i] - g[i]) for i in range(3)) / 3 for p in px) / len(px)
    cols.append((x // 2, br, sat, d))
print(" ".join(f"{x}:{d:.0f}" for x, br, sat, d in cols))
on = [x for x, br, sat, d in cols if d >= 25]
print(f"colour (≥25 from ground) first x {on[0] if on else None} last x {on[-1] if on else None}; left edge {cols[0][0]} d={cols[0][3]:.0f} sat={cols[0][2]:.0f}; right edge {cols[-1][0]} d={cols[-1][3]:.0f}")
