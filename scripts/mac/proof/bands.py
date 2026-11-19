# bands.py <window still (2x)> <x0> <x1> [y0 y1 in window points] — per horizontal band of the Map area: the median
# background brightness (unsaturated pixels) and the median saturation of orb pixels (saturated), top → bottom. A
# darkened / desaturated top or bottom band shows as lower numbers in the first / last rows.
import sys, statistics as st
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB'); x0, x1 = int(float(sys.argv[2]) * 2), int(float(sys.argv[3]) * 2)
y0 = int(float(sys.argv[4]) * 2) if len(sys.argv) > 4 else 104; y1 = int(float(sys.argv[5]) * 2) if len(sys.argv) > 5 else im.height
bands = 10; h = (y1 - y0) // bands
for b in range(bands):
    bg, orb = [], []
    for y in range(y0 + b * h, y0 + (b + 1) * h, 3):
        for x in range(x0, x1, 3):
            p = im.getpixel((x, y)); s = max(p) - min(p)
            (orb if s > 110 else bg).append(s if s > 110 else sum(p) / 3)
    print(f"band {b} y {(y0 + b*h)//2:4d}-{(y0 + (b+1)*h)//2:4d}  bg median {st.median(bg):6.1f}  orb px {len(orb):5d}  orb sat median {st.median(orb) if orb else 0:6.1f}")
