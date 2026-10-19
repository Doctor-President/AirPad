#!/usr/bin/env python3
"""live-26 (4) — pixel diff per view, App Store configuration vs TestFlight (T's 10-18 values at the tuner defaults):
changed pixels (any channel > 24) over the whole still, and outside the regions that SHOULD differ — the tuner handle
(TestFlight only) and the floating "+" / view switcher (TestFlight's tuner starts on Glass, the App Store build stays
Today: (3d)). Bounding boxes of what's left. Also writes a diff image per view (changed pixels in #E8820A).
    appstore_diff_live26.py <dir>"""
import sys, os
from PIL import Image, ImageChops
d = sys.argv[1]
print("| view | mode | changed (whole) | changed outside handle + floating buttons | where (outside) |")
print("|---|---|---|---|---|")
for view in ["dashboard", "card", "list", "map", "librarian"]:
    for mode in ["light", "dark"]:
        a, b = os.path.join(d, f"appstore-{mode}-{view}.png"), os.path.join(d, f"tf-{mode}-{view}.png")
        if not (os.path.exists(a) and os.path.exists(b)): print(f"| {view} | {mode} | missing | | |"); continue
        A, B = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
        diff = ImageChops.difference(A, B).convert("L").point(lambda v: 255 if v > 24 else 0)
        # the 9:41 status bar is overridden; the tuner handle sits on the right edge (live-22's handle box, ±);
        # the floating pair bottom-right above the peek pill
        masks = [(1080, 760, 1320, 1180), (1060, 1900, 1320, 2620)]
        m = diff.copy(); px = m.load()
        for x0, y0, x1, y1 in masks:
            for y in range(y0, min(y1, m.height)):
                for x in range(x0, min(x1, m.width)): px[x, y] = 0
        tot = A.width * A.height
        whole = sum(1 for v in diff.get_flattened_data() if v) if hasattr(diff, "get_flattened_data") else sum(1 for v in diff.getdata() if v)
        out = sum(1 for v in m.get_flattened_data() if v)
        bb = m.getbbox()
        print(f"| {view} | {mode} | {whole / tot * 100:.2f}% | {out / tot * 100:.3f}% ({out} px) | {bb if bb else '—'} |")
        vis = A.copy(); vp = vis.load(); dp = diff.load()
        for y in range(0, A.height):
            for x in range(0, A.width):
                if dp[x, y]: vp[x, y] = (0xE8, 0x82, 0x0A)
        vis.resize((A.width // 3, A.height // 3)).save(os.path.join(d, f"diff-{mode}-{view}.jpg"), quality=80)
