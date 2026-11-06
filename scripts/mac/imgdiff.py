#!/usr/bin/env python3
"""imgdiff.py <dir> <tagA> <tagB> [screens…] — mean |A−B| over RGB per screen, in /255 units, + max-channel share."""
import sys, os
from PIL import Image, ImageChops, ImageStat
d, a, b = sys.argv[1:4]; screens = sys.argv[4:] or ["dashboard", "map", "list", "cards", "entry", "chats"]
worst = 0
for s in screens:
    A = Image.open(os.path.join(d, f"{a}-{s}.png")).convert("RGB"); B = Image.open(os.path.join(d, f"{b}-{s}.png")).convert("RGB")
    if A.size != B.size: print(f"{s:10s} SIZE {A.size} vs {B.size}"); worst = 999; continue
    diff = ImageChops.difference(A, B); m = sum(ImageStat.Stat(diff).mean) / 3
    px = sum(1 for p in diff.getdata() if max(p) > 8) / (A.size[0] * A.size[1])
    worst = max(worst, m); print(f"{s:10s} mean {m:.3f}/255  pixels>8: {px*100:.2f}%")
print(f"worst mean {worst:.3f}/255 → {'PASS' if worst <= 1.0 else 'FAIL'} (≤ 1/255)")
