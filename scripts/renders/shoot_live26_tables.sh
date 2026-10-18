#!/bin/zsh
# live-26 (3f) — the synthetic answer tables (ChatTableFixtures: 2x3 · 5x46 · 8x10 · 1col) in a Librarian answer at full,
# light + dark, iOS 27.0 Simulator.   scripts/renders/shoot_live26_tables.sh <out_dir> <label> [app]
set -uo pipefail
OUT=${1:?out}; L=${2:?label}; APP=${3:-}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
[[ -n $APP ]] && xcrun simctl install $SIM $APP
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView -gridColumnCount 2)
for m in light dark; do xcrun simctl ui $SIM appearance $m
  for t in 2x3 5x46 8x10 1col; do
    xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -RenderTableAnswer $t >/dev/null
    python3 -c "import time; time.sleep(10)"; xcrun simctl io $SIM screenshot --type=png $OUT/$L-$m-$t.png >/dev/null 2>&1
  done
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
