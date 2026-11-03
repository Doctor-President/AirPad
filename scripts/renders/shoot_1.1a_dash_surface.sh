#!/bin/zsh
# 1.1-A (7) — Dashboard pane-surface candidates over the REAL Dashboard (Sample Library), light + dark, iOS 27 Simulator.
# DEBUG `-DashSurfaceCandidate 0|1|2|3` (0 = shipped .thinMaterial; see DashSurfaceCandidate in AppearancePalette.swift).
# Needs a Debug build installed on $SIM whose UITest scratch already holds the seeded sample (first run: FRESH=1).
#   SIM=<udid> scripts/renders/shoot_1.1a_dash_surface.sh <out_dir>
set -uo pipefail
OUT=${1:?out}; SIM=${SIM:?SIM udid}; APPID=com.doctorpresident.airpad; S=${S:-14}
mkdir -p $OUT
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -OpenDashboard)
[[ ${FRESH:-0} == 1 ]] && BASE+=(-UITestLibraryFresh)
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
for G in light dark; do
  xcrun simctl ui $SIM appearance $G
  for C in 0 1 2 3; do
    xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -DashSurfaceCandidate $C >/dev/null
    python3 -c "import time; time.sleep($S)"
    xcrun simctl io $SIM screenshot --type=png $OUT/dash-$G-c$C.png >/dev/null 2>&1
  done
done
xcrun simctl terminate $SIM $APPID >/dev/null 2>&1; xcrun simctl status_bar $SIM clear
ls $OUT/dash-*.png | wc -l
