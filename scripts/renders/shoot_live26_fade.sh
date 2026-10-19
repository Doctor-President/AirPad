#!/bin/zsh
# live-26 (3c) — the hero-fade fixtures (-UITestSeedFadeShowcase: busy photo · landscape · gradient art · fluted) on the
# carousel (-CardShowcase coverflow), grid 2 / 3 faces and the Map popover, light + dark, shown and with the card text
# hidden (-CardHideText, for the luminance profiles and the contrast backdrops). Extra args (e.g. a fade) pass through.
#   scripts/renders/shoot_live26_fade.sh <out_dir> <label> [extra launch args...]
set -uo pipefail
OUT=${1:?out}; L=${2:?label}; shift 2; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSeedFadeShowcase -EmbedCPUOnly -GlassFreezeTime 1)
shot() { local f=$1 wait=$2; shift 2; xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep($wait)"; xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1; }
for m in ${=MODES:-light dark}; do xcrun simctl ui $SIM appearance $m
  for face in coverflow grid2 grid3; do
    shot $L-$m-$face 8 -CardShowcase $face -CardShowcaseSet fade "$@"
    shot $L-$m-$face-hidden 8 -CardShowcase $face -CardShowcaseSet fade -CardHideText YES "$@"
  done
  for n in fade-photo-busy fade-fluted; do
    shot $L-$m-map-${n#fade-} 9 -OpenMap -MapCardNode $n "$@"
    shot $L-$m-map-${n#fade-}-hidden 9 -OpenMap -MapCardNode $n -CardHideText YES "$@"
  done
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
