#!/usr/bin/env python3
"""live-21 (1) — layered export: each pass rendered over white and over black → one RGBA PNG (difference matting:
alpha = 1 − (W − B)/255, colour = B / alpha). Exact for any normally-composited layer.
  matte.py <raw_dir> <out_dir> <prefix>   (expects <prefix>-<layer>-on-white.png / -on-black.png)
The top band (status bar + Dynamic Island, which the Simulator draws on every frame) is cleared on the card / shadow /
hairline passes so only the field carries it."""
import sys, os
from PIL import Image
raw, out, prefix = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
TOP = 170   # px (≈ 57 pt) — the status-bar band
names = {"field": "1-field-with-dots", "cards": "2-card-bodies", "shadow": "3-shadow-pass-full-strength", "hairline": "4-hairline-pass"}
for layer, label in names.items():
    w = Image.open(os.path.join(raw, f"{prefix}-{layer}-on-white.png")).convert("RGB")
    b = Image.open(os.path.join(raw, f"{prefix}-{layer}-on-black.png")).convert("RGB")
    o = Image.new("RGBA", w.size)
    wp, bp = w.load(), b.load(); op = o.load()
    W, H = w.size
    for y in range(H):
        for x in range(W):
            if layer != "field" and y < TOP:
                op[x, y] = (0, 0, 0, 0); continue
            pw, pb = wp[x, y], bp[x, y]
            a = 1 - sum(pw[k] - pb[k] for k in range(3)) / (3 * 255)
            a = min(1, max(0, a))
            if a < 1 / 255:
                op[x, y] = (0, 0, 0, 0)
            else:
                op[x, y] = tuple(min(255, round(pb[k] / a)) for k in range(3)) + (round(a * 255),)
    o.save(os.path.join(out, f"{prefix}-{label}.png"), optimize=True)
    print(label, "done")
