#!/bin/zsh
# live-20 (3) — stills of the eight `Text + Text` surfaces (DEBUG `-Screen textruns-<page>`), light + dark, on one Simulator.
#   scripts/textruns/shoot.sh <out_dir> [sim]   (install the Debug app first)
set -uo pipefail
OUT=${1:?out}; SIM=${2:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; mkdir -p $OUT
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
for mode in light dark; do
  xcrun simctl ui $SIM appearance $mode
  for page in recents reviewqueue quarantine entrycard offer transcript table overlay; do
    extra=(); [[ $page == offer ]] && extra=(-OpenSeededChat YES)
    xcrun simctl launch --terminate-running-process $SIM com.doctorpresident.airpad -Screen textruns-$page $extra >/dev/null
    sleep 6
    xcrun simctl io $SIM screenshot --type=png $OUT/$page-$mode.png >/dev/null 2>&1
  done
done
xcrun simctl terminate $SIM com.doctorpresident.airpad; xcrun simctl ui $SIM appearance light; xcrun simctl status_bar $SIM clear
ls $OUT | wc -l
