#!/bin/zsh
# live-26 (3b) — the markup fixtures (-UITestSeedMarkupShowcase) through the REAL card faces (-CardShowcase vertical ·
# coverflow (carousel) · grid2 · grid3, Card content Proposal) and the Map popover (-OpenMap -MapCardNode), light + dark.
#   scripts/renders/shoot_live26_markup.sh <out_dir> <label> [app path]
set -uo pipefail
OUT=${1:?out}; L=${2:?label}; APP=${3:-}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
[[ -n $APP ]] && xcrun simctl install $SIM $APP
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSeedMarkupShowcase -EmbedCPUOnly -CardContent proposal)
shot() { local f=$1 wait=$2; shift 2; xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep($wait)"; xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1; }
for m in light dark; do xcrun simctl ui $SIM appearance $m
  shot $L-$m-vertical-p0 8 -CardShowcase vertical -CardShowcaseSet markup
  shot $L-$m-vertical-p1 8 -CardShowcase vertical -CardShowcaseSet markup -CardShowcasePage 1
  shot $L-$m-carousel-p0 8 -CardShowcase coverflow -CardShowcaseSet markup
  shot $L-$m-carousel-p1 8 -CardShowcase coverflow -CardShowcaseSet markup -CardShowcasePage 1
  shot $L-$m-grid2 8 -CardShowcase grid2 -CardShowcaseSet markup
  shot $L-$m-grid3 8 -CardShowcase grid3 -CardShowcaseSet markup
  for n in markup-checklist-editor markup-checklist-raw markup-html markup-list-styled; do
    shot $L-$m-map-${n#markup-} 9 -OpenMap -MapCardNode $n
  done
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
