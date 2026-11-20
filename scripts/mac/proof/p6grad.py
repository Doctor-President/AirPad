# p6grad.py <a.png> <b.png> <x0 y0 x1 y1 (window pts)> … — mean abs RGB diff (0–255) per region, 2x stills
import sys
from PIL import Image, ImageChops, ImageStat
a = Image.open(sys.argv[1]).convert('RGB'); b = Image.open(sys.argv[2]).convert('RGB'); s = a.size[0] / 1350
r = list(map(int, sys.argv[3:]))
for i in range(0, len(r), 4):
    box = tuple(int(v * s) for v in r[i:i + 4]); d = ImageStat.Stat(ImageChops.difference(a.crop(box), b.crop(box))).mean
    print(f"{r[i:i+4]}: {sum(d) / 3:.2f}")
