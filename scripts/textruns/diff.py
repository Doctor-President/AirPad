#!/usr/bin/env python3
"""live-20 (3) — pixel diff of two still sets (same names). Prints changed-pixel count + bounding box per still."""
import sys, os
from PIL import Image, ImageChops
a, b = sys.argv[1], sys.argv[2]
for f in sorted(os.listdir(a)):
    if not f.endswith(".png"): continue
    x, y = Image.open(os.path.join(a, f)).convert("RGB"), Image.open(os.path.join(b, f)).convert("RGB")
    d = ImageChops.difference(x, y).convert("L").point(lambda v: 255 if v > 8 else 0)
    n = sum(1 for v in d.getdata() if v)
    print(f"{f:24s} changed={n:7d} bbox={d.getbbox()}")
