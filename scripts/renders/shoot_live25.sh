#!/bin/zsh
# live-25 (1) + (3c) — the Ask bar / search pill glyphs and T's 2026-10-17 values, over a busy Card grid (Sample Library,
# 2-col), light + dark, iOS 27.0 Simulator: shipped · siriPill · gradedPanel · both · t1017 (T's paste, loaded with
# -AppearanceTunerImportFile through the tuner brief's migration — assessment only, not a default). Postures: peek (the
# search pill) and long (a synthetic four-paragraph answer + typed Ask text, so the × and send show); each shot again
# with the text AND glyphs hidden (-RenderHideText) for the contrast numbers.
#   scripts/renders/shoot_live25.sh <out_dir> <t1017.json>
set -uo pipefail
OUT=${1:?out}; PASTE=${2:?paste json}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView -gridColumnCount 2
      -AppearanceTuner YES -AppearanceTunerReset YES)
LONG=(-RenderLongAnswer YES -AskPrefill "Which note should I read first")
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
cp $PASTE "$(xcrun simctl get_app_container $SIM $APPID data)/Documents/t1017.json"
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
shot() {   # shot <file> <preset> <args...>
  local f=$1 p=$2; shift 2
  local P=()
  case $p in shipped) ;; t1017) P=(-AppearanceTunerImportFile t1017.json) ;; *) P=(-GlassPresetRender $p) ;; esac
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE $P "$@" >/dev/null
  python3 -c "import time; time.sleep(10)"
  xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1
}
for m in light dark; do xcrun simctl ui $SIM appearance $m
  for p in shipped siriPill gradedPanel both t1017; do
    shot $p-$m-peek $p
    shot $p-$m-peek-hidden $p -RenderHideText YES
    shot $p-$m-long $p $LONG
    shot $p-$m-long-hidden $p $LONG -RenderHideText YES
  done
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
