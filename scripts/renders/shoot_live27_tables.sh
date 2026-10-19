#!/bin/zsh
# live-27 (4c) — the synthetic presidents-shaped 5 × 46 answer table (-RenderTableAnswer 5x46) and the 2 × 3 one in the
# Librarian and in the Chat view (-RenderInChatView), light + dark; plus the grid scrolled sideways (a swipe).
#   scripts/renders/shoot_live27_tables.sh <out_dir> <label>
set -uo pipefail
OUT=${1:?out}; L=${2:?label}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -OpenCardView -gridColumnCount 2 -GlassFreezeTime 1)
shot() { local f=$1; shift; xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep(9)"; xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1; }
for m in light dark; do xcrun simctl ui $SIM appearance $m
  for t in 5x46 2x3 wrap; do
    shot $L-$m-librarian-$t -RenderTableAnswer $t
    shot $L-$m-chatview-$t -RenderTableAnswer $t -RenderInChatView YES
  done
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
