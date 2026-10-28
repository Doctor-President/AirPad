#!/bin/zsh
# live-45 — Map look stills, iOS 27 Simulator. ONE launch per framing + ground (-MapLookCycle steps every 4 s → same
# layout + framing): Flat · Glass · Aura · Eclipse · Outline · Wash Subtle / Medium / Strong (STEPS picks; live-47). Each snap waits for its
# `[MAPCYCLE] <look>` line (+2.5 s to settle). LIB=fixture (default; the clone of T's corpus — its stills stay LOCAL) or
# LIB=sample (the Sample Library — the only stills that get committed).
#   [LIB=sample] scripts/renders/shoot_live45_looks.sh <out_dir> <tag> <dark|light> [extra args… e.g. -MapZoom 0.5]
set -uo pipefail
OUT=${1:?out}; TAG=${2:?tag}; GROUND=${3:?ground}; shift 3
S=${S:-22}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
FIXTURE=${FIXTURE:-$HOME/Developer/fixtures/tom-corpus-2026-09-21}
mkdir -p $OUT
if [[ ${LIB:-fixture} == sample ]]; then LIBARGS=(-UITestLibrary -UITestSampleLibrary)
else LIBARGS=(-CorpusFixture $FIXTURE -CorpusFixtureFresh); fi
BASE=($LIBARGS -EmbedCPUOnly -OpenMap -NoMapDebugHUD -AppearanceTuner YES -AppearanceTunerReset YES)
LOG=$OUT/.cycle-$TAG-$GROUND.log
xcrun simctl ui $SIM appearance $GROUND
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
snap() { xcrun simctl io $SIM screenshot --type=png $OUT/$1.png >/dev/null 2>&1; }
waitstep() {   # waitstep <step> <png>
  for i in {1..600}; do grep -q "\[MAPCYCLE\] $1[[:space:]]*$" $LOG 2>/dev/null && break; python3 -c "import time; time.sleep(0.1)"; done
  python3 -c "import time; time.sleep(2.5)"; snap $2
}
: > $LOG
xcrun simctl terminate $SIM $APPID >/dev/null 2>&1
xcrun simctl launch --console-pty $SIM $APPID $BASE "$@" -MapLookCycle $S > $LOG 2>&1 &
LP=$!
STEPS=(${=STEPS:-flat aura eclipse})
n=0; for st in $STEPS; do n=$((n+1)); waitstep $st $TAG-$GROUND-$n-$st; done
kill $LP 2>/dev/null; xcrun simctl terminate $SIM $APPID >/dev/null 2>&1
xcrun simctl status_bar $SIM clear
grep -h "SKShader failed\|\[AURAINK\]" $LOG | sed 's/.*\[AURAINK\]/[AURAINK]/' | awk '!seen[$0]++' | head -5
ls $OUT/$TAG-$GROUND-*.png | wc -l
