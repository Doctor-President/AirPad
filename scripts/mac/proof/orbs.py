# orbs.py <window still (2x)> <x0> <x1> <cx> <cy> — candidate orb centres (window points) between x0..x1, nearest (cx,cy)
# first: a solid saturated disc (max-min > 110 on a 7×7 pt patch), so tag labels (text on a dark pill) are skipped.
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB'); x0, x1, cx, cy = map(float, sys.argv[2:6]); W, H = im.size
sat = lambda p: max(p) - min(p) > 110
out = []
for y in range(110, H - 120, 6):
    for x in range(int(x0 * 2) + 10, int(x1 * 2) - 10, 6):
        if not sat(im.getpixel((x, y))): continue
        if all(sat(im.getpixel((x + dx, y + dy))) for dx in (-6, 0, 6) for dy in (-6, 0, 6)): out.append((x / 2, y / 2))
out.sort(key=lambda p: (p[0] - cx) ** 2 + (p[1] - cy) ** 2)
seen = []
for p in out:
    if all((p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 > 400 for q in seen): seen.append(p)
for p in seen[:6]: print(int(p[0]), int(p[1]))
