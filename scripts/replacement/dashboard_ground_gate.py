#!/usr/bin/env python3
"""1.0r fix-up F1 gate: the Dashboard ignores the Pro custom background.

Reads the stills `shoot_1.0r_fixup_ground.sh` writes (<tag>-<view>-<light|dark>-<plain|custom>.png) and prints, for each
view and appearance, how many pixels differ between "no custom background" and "custom gradient set" (any channel off
by more than TOL/255; the status bar is masked).
PASS = the AFTER Dashboard differs in 0 pixels in light and dark, AND the positive controls change: the AFTER List and
Card views differ (they still use the background) and, when BEFORE stills are given, the BEFORE Dashboard differs (the
probe can see a background change on the Dashboard). Also checks the source: no Dashboard file reads the custom ground.
  dashboard_ground_gate.py <stills_dir> <after_tag> [before_tag]
"""
import sys, pathlib, re
import numpy as np
from PIL import Image

TOL = 2          # per-channel tolerance (Liquid Glass sampling noise between launches)
STATUS_BAR = 0.06  # top fraction masked (the clock and battery)

def diff(a, b):
    x = np.asarray(Image.open(a).convert("RGB"), dtype=np.int16)
    y = np.asarray(Image.open(b).convert("RGB"), dtype=np.int16)
    assert x.shape == y.shape, (a, b)
    top = int(x.shape[0] * STATUS_BAR)
    d = np.abs(x[top:] - y[top:]).max(axis=2)
    return int((d > TOL).sum()), int(d.max()), d.size

def row(d, tag, view, g):
    n, mx, total = diff(d / f"{tag}-{view}-{g}-plain.png", d / f"{tag}-{view}-{g}-custom.png")
    print(f"| {tag} | {view} | {g} | {n} of {total} ({100 * n / total:.2f}%) | {mx} |")
    return n

d = pathlib.Path(sys.argv[1]); after = sys.argv[2]; before = sys.argv[3] if len(sys.argv) > 3 else None
print(f"| build | view | appearance | pixels differing, plain vs custom (> {TOL}/255) | max channel diff |")
print("|---|---|---|---|---|")
ok = True
for g in ("light", "dark"):
    ok &= row(d, after, "dashboard", g) == 0
for v in ("list", "cards"):
    for g in ("light", "dark"):
        ok &= row(d, after, v, g) > 0            # control: these views still use the background
if before:
    for g in ("light", "dark"):
        ok &= row(d, before, "dashboard", g) > 0  # control: the probe sees the old Dashboard change
# source: nothing under Views/Dashboard reads the custom ground or its text rules
root = pathlib.Path(__file__).resolve().parents[2] / "AirPad/Views/Dashboard"
pat = re.compile(r"MapGround|CustomGroundView|onCustomGround|groundInkFloor|groundInk\(|libraryBackground|overLibraryGround: true")
hits = [f"{p.name}:{i}" for p in root.glob("*.swift") for i, l in enumerate(p.read_text().splitlines(), 1)
        if pat.search(l) and not l.lstrip().startswith("//")]
print(f"\nsource: Dashboard reads of the custom ground: {len(hits)} {hits}")
ok &= not hits
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
