#!/usr/bin/env python3
"""live-24 (3) — body-text and pill-text contrast for each glass preset, measured as in live-21: every still is shot a
second time with the text hidden (-RenderHideText), and the text colour is compared with EVERY backdrop pixel behind it
(WCAG 2 contrast; AA = 4.5).
  • transcript — the answer's paragraphs (the live-21 region), text = ChatTypography.bodyText;
    The tuner's own floating handle (it sits over the transcript's right edge) is masked out.
  • Ask text / pill text — the box where the text actually draws (found by diffing the shown and hidden stills), text =
    the ink the pill uses (light text on the Siri-style near-black grade, else the appearance's ink).
    contrast_live24.py <stills_dir>
"""
import sys, os, glob
from PIL import Image, ImageChops

def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def lum(rgb): r, g, b = rgb[:3]; return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
def ratio(a, b): a, b = max(a, b), min(a, b); return (a + 0.05) / (b + 0.05)
def hexrgb(h): return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def px(im): return list(im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata())

BODY = {"light": "2A2520", "dark": "E8E6E3"}          # ChatTypography.bodyText
INK = {"light": "232A2E", "dark": "FFFFFF"}           # AppearancePalette.ink
FLIPS = {"siriPill", "both"}                          # the near-black pill grade → light text (FFFFFF)
TRANSCRIPT = (40, 480, 1280, 2060)                    # 1320 × 2868 px stills (as live-21)
HANDLE = (1130, 880, 1300, 1045)                      # the tuner's floating handle (TestFlight UI, not the panel): masked
ASK_TEXT_X = 200                                      # the Ask bar's feather icon ends here; the typed text starts after

def text_box(shown, hidden, band_top, left=0):
    """The box the text draws in: where the shown and hidden stills differ (glyph ascender → descender)."""
    d = ImageChops.difference(shown.convert("RGB"), hidden.convert("RGB")).convert("L")
    d = d.crop((left, band_top, d.width, d.height)).point(lambda v: 255 if v > 40 else 0)
    bb = d.getbbox()
    if not bb: return None
    x0, y0, x1, y1 = bb
    return (x0 + left, y0 + band_top, x1 + left, y1 + band_top)

def measure(hidden, box, text_hex, mask=None):
    tl = lum(hexrgb(text_hex))
    im = hidden.convert("RGB").crop(box)
    pts = px(im)
    if mask:   # drop pixels inside `mask` (absolute coords)
        bx, by = box[0], box[1]; w = im.width
        pts = [p for i, p in enumerate(pts) if not (mask[0] <= bx + i % w < mask[2] and mask[1] <= by + i // w < mask[3])]
    cr = sorted(ratio(tl, lum(p)) for p in pts)
    return cr[0], cr[len(cr) // 100], cr[len(cr) // 2]

rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*-hidden.png"))):
    name = os.path.basename(f)[:-len("-hidden.png")]
    parts = name.split("-")
    ic = parts[0] == "IC"
    preset, mode, posture = (parts[1:4] if ic else parts[0:3])
    hidden = Image.open(f)
    shown_path = f.replace("-hidden.png", ".png")
    shown = Image.open(shown_path) if os.path.exists(shown_path) else None
    if posture == "long":
        rows.append((name, "transcript", BODY[mode], *measure(hidden, TRANSCRIPT, BODY[mode], HANDLE)))
    pill_ink = "FFFFFF" if preset in FLIPS else INK[mode]
    if shown is not None:
        box = text_box(shown, hidden, 2300, ASK_TEXT_X if posture == "long" else 0)
        if box:
            rows.append((name, "Ask text" if posture == "long" else "search pill", pill_ink, *measure(hidden, box, pill_ink)))

print("| still | where | text | worst backdrop | p1 | median | AA (4.5) at worst |")
print("|---|---|---|---|---|---|---|")
for n, where, t, w, p1, med in rows:
    print(f"| {n} | {where} | #{t} | {w:.2f} | {p1:.2f} | {med:.2f} | {'pass' if w >= 4.5 else 'FAIL'} |")
