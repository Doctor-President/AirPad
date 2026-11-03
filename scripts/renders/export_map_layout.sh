#!/bin/bash
# 1.1-B ground study — export the Sample Library Map AS DRAWN (DEBUG `-ExportMapLayout`) and screenshot the same frame,
# dark + light, with and without titles. The export and the stills come from ONE run (the Sample layout differs per fresh
# install). Output: <out>/maplayout-<tag>-{dark,light}.json + <out>/sim-<tag>-{dark,light}-{titles,notitles}.png.
# The study's data blob is built from the two JSONs (Ops/reference/ground-study.html; see design-refs/1.1b-ground-study).
# Usage: export_map_layout.sh <sim-udid> <out-dir> [tag]   (Debug build installed; Simulator booted, appearance dark)
set -euo pipefail
UDID=$1; OUT=$2; TAG=${3:-ref}; BID=com.doctorpresident.airpad
mkdir -p "$OUT"
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl terminate "$UDID" $BID 2>/dev/null || true
xcrun simctl launch --console-pty "$UDID" $BID -UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -OpenMap -NoMapDebugHUD \
  -MapFrameOrbs 20 -ExportMapLayout "$TAG" -com.airpad.callouts.view.buttons YES -com.airpad.callouts.map.intro YES \
  > "$OUT/console-$TAG.log" 2>&1 &
LP=$!
for step in dark-titles dark-notitles light-titles light-notitles; do
  for _ in $(seq 1 240); do grep -q "\[EXPORTMAP\] ready $step" "$OUT/console-$TAG.log" && break; sleep 0.5; done
  sleep 1.5
  xcrun simctl io "$UDID" screenshot "$OUT/sim-$TAG-$step.png" >/dev/null 2>&1 && echo "shot $step"
done
for _ in $(seq 1 60); do grep -q "\[EXPORTMAP\] done" "$OUT/console-$TAG.log" && break; sleep 0.5; done
C=$(xcrun simctl get_app_container "$UDID" $BID data)
cp "$C"/Library/Caches/maplayout-"$TAG"-*.json "$OUT/"
kill $LP 2>/dev/null || true
grep "EXPORTMAP\|MAPFRAME" "$OUT/console-$TAG.log"
