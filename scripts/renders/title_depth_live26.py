#!/usr/bin/env python3
"""live-26 (3c) — where each card's title block ends, in units of its hero zone: the text lines (shown vs -CardHideText
diff) below the source/time row, the title = the run of tall lines after it. Faces' zones: carousel / Map 0.40, grid 2
0.43, grid 3 0.52 (0.40 for a 3-col card without a photo)."""
import sys, os
from PIL import Image, ImageChops
sys.path.insert(0, os.path.dirname(__file__))
from fade_profile_live26 import boxes  # noqa
d, label = sys.argv[1], sys.argv[2]
Z = {"coverflow": 0.40, "grid2": 0.43, "grid3": 0.52, "map-photo-busy": 0.40, "map-fluted": 0.40}
for face in Z:
    for mode in ["dark"]:
        sh = Image.open(os.path.join(d, f"{label}-{mode}-{face}.png")).convert("RGB")
        hd = Image.open(os.path.join(d, f"{label}-{mode}-{face}-hidden.png")).convert("RGB")
        diff = ImageChops.difference(sh, hd).convert("L").point(lambda v: 255 if v > 50 else 0)
        names = ["busy photo", "landscape", "gradient art", "fluted"] if not face.startswith("map") else [face[4:]]
        for name, b in zip(names, boxes(hd, face)):
            x0, y0, x1, y1 = [int(v) for v in b]; H = y1 - y0
            p = diff.load()
            rows = [y for y in range(y0, y1) if any(p[x, y] for x in range(x0 + 10, x1 - 10, 2))]
            lines = []; s = prev = None
            for y in rows:
                if s is None: s = y
                elif y - prev > 3: lines.append((s, prev)); s = y
                prev = y
            if s is not None: lines.append((s, prev))
            lines = [l for l in lines if l[1] - l[0] > 4]
            hs = [l[1] - l[0] for l in lines]
            if len(lines) < 3: print(face, name, "lines?", lines); continue
            src = hs[0]; title = []
            for l, h in zip(lines[1:], hs[1:]):
                if h > src * 1.3: title.append(l)
                elif title: break
            z = Z[face] if not (face == "grid3" and name == "fluted") else 0.40
            if title:
                bot = (title[-1][1] - y0) / H
                print(f"{face:15s} {name:13s} title bottom {bot:.3f} of card = {bot / z:.2f} zones ({len(title)} lines)")
