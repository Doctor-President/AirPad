#!/usr/bin/env python3
"""live-26 (3c) — the hero's fade into the card body, measured: for each card in a text-hidden still (-CardHideText), the
art's presence down the card = the mean colour distance of a row (middle 70% of the card's width) from the card body's
own colour (its bottom rows), normalised to the art's presence over the top third of the card. 1 = full art, 0 = body.
Cards are found on the dark still (body #000-ish vs the #1A1A1A field); the same boxes serve the light still.
    fade_profile_live26.py <dir> <label>      (files <label>-<light|dark>-<face>-hidden.png)
Prints, per face and card, the presence at fractions of the card height, and where it crosses 50% / 20% / 5%."""
import sys, os
from PIL import Image

def px(im): return im.load()
def runs_along(vals, field, tol=5, minlen=150):
    out, i, n = [], 0, len(vals)
    while i < n:
        if all(abs(vals[i][k] - field[k]) <= tol for k in range(3)): i += 1; continue
        j = i
        while j < n and not all(abs(vals[j][k] - field[k]) <= tol for k in range(3)): j += 1
        if j - i >= minlen: out.append((i, j))
        i = j
    return out

def boxes(dark, face):
    """Gallery faces: the boxes from `CardShowcaseGallery`'s own layout (440 pt screen, @3x; content from y = 130 pt;
    10 pt gaps; coverflow = 0.79 W cells at 0.6, 534 pt tall). Map: the card's black body (darker than the #111115 map)
    as the largest dark component, its top found by scanning up its centre column to the map colour."""
    S = 3
    if face == "coverflow":
        cw, ch = 0.79 * 440 * 0.6, 533.9 * 0.6
        return [((6.44 + c * (cw + 10)) * S, (130 + r * (ch + 10)) * S, (6.44 + c * (cw + 10) + cw) * S, (130 + r * (ch + 10) + ch) * S)
                for r in range(2) for c in range(2)]
    if face in ("grid2", "grid3"):
        cols = 2 if face == "grid2" else 3
        cw = (440 - 10 * (cols + 1)) / cols; ch = cw * 7 / 5
        return [((10 + c * (cw + 10)) * S, (130 + r * (ch + 10)) * S, (10 + c * (cw + 10) + cw) * S, (130 + r * (ch + 10) + ch) * S)
                for r in range(2) for c in range(cols)][:4]
    im = dark.convert("RGB"); w, h = im.size; p = im.load()
    dark_ = lambda c: sum(c) < 40          # the body, under the #111115 map (sum 55)
    yb = int(h * 0.55); xc = w // 2
    x0 = xc
    while x0 > 0 and (dark_(p[x0, yb]) or dark_(p[x0 - 3, yb])): x0 -= 1
    x1 = xc
    while x1 < w - 1 and (dark_(p[x1, yb]) or dark_(p[x1 + 3, yb])): x1 += 1
    y1 = yb
    while y1 < h - 1 and (dark_(p[xc, y1]) or dark_(p[xc, y1 + 3])): y1 += 1
    # the sides, on a body row just above the bottom edge (art never reaches it); the Map card is 5:7 (h = 1.4 w)
    yr = y1 - 130   # above the 30 pt corner
    x0 = xc
    while x0 > 0 and (dark_(p[x0, yr]) or dark_(p[x0 - 3, yr])): x0 -= 1
    x1 = xc
    while x1 < w - 1 and (dark_(p[x1, yr]) or dark_(p[x1 + 3, yr])): x1 += 1
    return [(x0, y1 - 1.4 * (x1 - x0), x1, y1)]

def profile(im, box, top):
    x0, _, x1, y1 = [int(v) for v in box]; top = int(top); p = im.load()
    xa, xb = x0 + (x1 - x0) * 0.15, x0 + (x1 - x0) * 0.85
    body = [p[int(x), y] for y in range(int(y1 - (y1 - top) * 0.06), int(y1 - (y1 - top) * 0.02)) for x in range(int(xa), int(xb), 3)]
    br = [sum(c[i] for c in body) / len(body) for i in range(3)]
    rows = []
    for y in range(top, y1):
        d = [sum(abs(p[int(x), y][i] - br[i]) for i in range(3)) for x in range(int(xa), int(xb), 3)]
        rows.append(sum(d) / len(d))
    n = len(rows); ref = sum(rows[: n // 3]) / (n // 3) or 1
    return [r / ref for r in rows]

def find_top(im, box):
    """The card's top edge: scan up from the body box's top along its centre column until the field colour returns."""
    p = im.load(); x = (box[0] + box[2]) // 2; y = box[1]
    field = p[box[0] - 12 if box[0] > 20 else box[2] + 12, box[1]]
    while y > 60:
        c = p[x, y]
        if all(abs(c[i] - field[i]) < 4 for i in range(3)) and all(abs(p[x, y - k][i] - field[i]) < 4 for k in (1, 2, 3) for i in range(3)):
            return y + 1
        y -= 1
    return y

d, label = sys.argv[1], sys.argv[2]
FR = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]
print("| face | card | mode | " + " | ".join(f"{f:.2f}" for f in FR) + " | 50% at | 20% at | 5% at |")
print("|---|---|---|" + "---|" * (len(FR) + 3))
for face in ["coverflow", "grid2", "grid3", "map-photo-busy", "map-fluted"]:
    dk = os.path.join(d, f"{label}-dark-{face}-hidden.png")
    if not os.path.exists(dk): continue
    darkim = Image.open(dk).convert("RGB")
    bs = boxes(darkim, face)
    for mode in ["dark", "light"]:
        im = Image.open(os.path.join(d, f"{label}-{mode}-{face}-hidden.png")).convert("RGB")
        names = ["busy photo", "landscape", "gradient art", "fluted"] if not face.startswith("map") else [face[4:]]
        if mode == "dark": print(f"<!-- {face} boxes {bs} -->")
        for name, b in zip(names, bs):
            pr = profile(im, b, b[1]); n = len(pr)
            at = lambda f: pr[min(int(f * n), n - 1)]
            def cross(v):
                for i in range(n // 4, n):
                    if pr[i] < v: return f"{i / n:.2f}"
                return "—"
            print(f"| {face} | {name} | {mode} | " + " | ".join(f"{at(f):.2f}" for f in FR) + f" | {cross(0.5)} | {cross(0.2)} | {cross(0.05)} |")
