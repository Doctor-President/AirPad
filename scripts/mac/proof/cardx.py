# cardx.py <window still (2x)> <row y in window points> — the Map card's left/right border (pt) on that row, dark mode:
# the card's 1-pt border is (43,43,43) with the card fill (14,14,14) just inside. Prints "left right centre" or "none".
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB'); y = int(float(sys.argv[2]) * 2); w = im.width
border = lambda p: all(abs(c - 43) <= 4 for c in p)
fill = lambda p: all(abs(c - 14) <= 3 for c in p)
xs = [x for x in range(2, w - 4) if border(im.getpixel((x, y))) and (fill(im.getpixel((x + 2, y))) or fill(im.getpixel((x - 2, y))))]
if len(xs) < 2: print("none"); sys.exit()
l, r = min(xs) / 2, (max(xs) + 1) / 2
print(f"{l:.0f} {r:.0f} {(l + r) / 2:.1f}")
