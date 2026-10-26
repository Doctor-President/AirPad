#!/bin/zsh
# live-43 — Map look stills, Sample Library (scratch), iOS 27 Simulator. ONE launch per framing + ground (-MapLookCycle
# steps every 4 s → same layout + framing): Flat · Glass (no refraction; T's values A via TODAY_JSON) · Aura · Eclipse ·
# Outline. Each snap waits for its `[MAPCYCLE] <look>` line (print → --console-pty; +2.5 s to settle).
#   [TODAY_JSON='json:{Copy values}'] scripts/renders/shoot_live43_looks.sh <out_dir> <tag> <dark|light> [extra args…]
set -uo pipefail
OUT=${1:?out}; TAG=${2:?tag}; GROUND=${3:?ground}; shift 3
S=${S:-22}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -OpenMap -NoMapDebugHUD -AppearanceTuner YES -AppearanceTunerReset YES)
TODAY=(); [[ -n "${TODAY_JSON:-}" ]] && TODAY=(-MapGlassToday "$TODAY_JSON")
LOG=$OUT/.cycle-$TAG.log
xcrun simctl ui $SIM appearance $GROUND
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
snap() { xcrun simctl io $SIM screenshot --type=png $OUT/$1.png >/dev/null 2>&1; }
waitstep() {   # waitstep <step> <png>
  for i in {1..600}; do grep -q "\[MAPCYCLE\] $1" $LOG 2>/dev/null && break; python3 -c "import time; time.sleep(0.1)"; done
  python3 -c "import time; time.sleep(2.5)"; snap $2
}
: > $LOG
xcrun simctl terminate $SIM $APPID >/dev/null 2>&1
xcrun simctl launch --console-pty $SIM $APPID $BASE $TODAY "$@" -MapLookCycle $S > $LOG 2>&1 &
LP=$!
waitstep flat $TAG-$GROUND-1-flat; waitstep glass $TAG-$GROUND-2-glass; waitstep aura $TAG-$GROUND-3-aura
waitstep eclipse $TAG-$GROUND-4-eclipse; waitstep outline $TAG-$GROUND-5-outline
kill $LP 2>/dev/null; xcrun simctl terminate $SIM $APPID >/dev/null 2>&1
xcrun simctl status_bar $SIM clear
ls $OUT/$TAG-$GROUND-*.png | wc -l
