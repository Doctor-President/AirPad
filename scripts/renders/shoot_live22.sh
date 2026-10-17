#!/bin/zsh
# live-22 (1) — before/after stills of T's light picks (L2 · F2 · 0.5 pt hairline · quarter shadow): light + dark ×
# Card (coverflow, vertical, grid) / List / Map / entry detail, Sample Library in a scratch library, iOS 27.0 Simulator.
#   scripts/renders/shoot_live22.sh <out_dir> [extra launch args…]
set -uo pipefail
OUT=${1:?out}; shift; EXTRA=("$@"); SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly)
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
shot() {   # shot <file> <wait-seconds> <args...>
  local f=$1 w=$2; shift 2
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" "${EXTRA[@]}" >/dev/null
  python3 -c "import time; time.sleep($w)"
  xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1
}
for m in light dark; do xcrun simctl ui $SIM appearance $m
  shot $m-card-coverflow 9 -OpenCardView -gridColumnCount 1
  shot $m-card-vertical 9 -OpenCardView -gridColumnCount 4
  shot $m-card-grid 9 -OpenCardView -gridColumnCount 2
  shot $m-list 9 -OpenListView
  shot $m-map 14 -OpenMap
  shot $m-entry 12 -OpenCardView -OpenFirstGradientEntry
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
