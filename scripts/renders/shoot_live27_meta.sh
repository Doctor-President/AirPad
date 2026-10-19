#!/bin/zsh
# live-27 (1) — the card faces' secondary text (source/time row, type-strip counts, tags, list markers, "+N more", link
# sites, document pages) on the synthetic showcase (-UITestSeedCardShowcase) + the fade fixtures, through the REAL faces:
# vertical, the carousel at full size (-CardShowcaseFull), grid 2 / 3 and the Map popover; shown and text-hidden
# (-CardHideText, the backdrops). Extra args pass through (e.g. -MetaInkLight 0.8).
#   MODES="light dark" scripts/renders/shoot_live27_meta.sh <out_dir> <label> [extra launch args...]
set -uo pipefail
OUT=${1:?out}; L=${2:?label}; shift 2; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSeedCardShowcase -UITestSeedFadeShowcase -EmbedCPUOnly -GlassFreezeTime 1 -CardContent proposal)
HIDDEN=${HIDDEN:-1}
shot() { local f=$1; shift; xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep(${WAIT:-7})"; xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1; }
pair() { local f=$1; shift; shot $L-$f "$@"; [[ $HIDDEN == 1 ]] && shot $L-$f-hidden "$@" -CardHideText YES; }
for m in ${=MODES:-light dark}; do xcrun simctl ui $SIM appearance $m
  for p in 0 1 2; do pair $m-vertical-p$p -CardShowcase vertical -CardShowcasePage $p "$@"; done
  for p in 0 2 4 6; do pair $m-carousel-p$p -CardShowcase coverflow -CardShowcaseFull YES -CardShowcasePage $p "$@"; done
  for p in 0 1; do pair $m-grid2-p$p -CardShowcase grid2 -CardShowcasePage $p "$@"; done
  pair $m-grid3-p0 -CardShowcase grid3 "$@"
  pair $m-fade-grid2 -CardShowcase grid2 -CardShowcaseSet fade "$@"
  for n in showcase-lists showcase-links fade-fluted; do WAIT=9 pair $m-map-$n -OpenMap -MapCardNode $n "$@"; done
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
