#!/usr/bin/env bash
# Re-bake the SHIPPING MSDF atlases (Brief BD2).
#
# Until BD, no atlas-generation script was checked in — the only record was a comment in
# MSDFLabel.swift documenting the Fraunces bake. That made the atlases unreproducible, which
# is how the ASCII-only charset survived into V1 (see Ops/reports/glyph-coverage-bc0-2026-09).
#
# The charset MUST stay wide: an atlas that lacks a character silently drops it on the Map.
# ASCII 32-126 + Latin-1 Supplement (accents, ¿ ¡) + Latin Extended-A + the punctuation the
# app actually produces (en/em dash, curly quotes, bullet, ellipsis).
#
# ★ Settings are load-bearing: size 48 / pxrange 4 / yorigin bottom must match what
# MSDFLabel's shader + applyLOD assume (screenPxRange derives from distanceRange/atlasSize).
# Changing them silently mis-scales glyph antialiasing.
#
# Requires: msdf-atlas-gen (brew install msdf-atlas-gen)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/AirPad/Resources/MSDF"
CHARSET="$REPO/tools/fonts/msdf-charset.txt"

command -v msdf-atlas-gen >/dev/null || { echo "msdf-atlas-gen not found (brew install msdf-atlas-gen)"; exit 1; }
[ -f "$CHARSET" ] || { echo "missing charset: $CHARSET"; exit 1; }

bake() {  # $1 = atlas name (no _msdf suffix)   $2 = source .ttf
  local name="$1" font="$2"
  [ -f "$font" ] || { echo "SKIP $name — no source font at $font"; return; }
  echo "==> $name  <-  $(basename "$font")"
  msdf-atlas-gen -font "$font" -charset "$CHARSET" \
    -type msdf -format png -size 48 -pxrange 4 -yorigin bottom \
    -imageout "$OUT/${name}_msdf.png" -json "$OUT/${name}_msdf.json"
}

# The two atlases actually reachable from code: MSDFFont.orbTitle and MSDFFont.shared (fallback).
bake spacegroteskbold "$REPO/tools/fonts/SpaceGrotesk-Bold.ttf"
bake fraunces         "$REPO/AirPad/Resources/Fonts/Fraunces/Fraunces_72pt-Bold.ttf"

echo
echo "Re-baked. VERIFY before committing: ASCII advances must be unchanged, or every"
echo "existing Map title re-wraps. Compare old vs new JSON advances over U+0020..U+007E."
