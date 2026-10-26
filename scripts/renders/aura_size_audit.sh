#!/bin/zsh
# live-44 — Aura orb-size audit on a large library (the fixture clone of T's corpus, ~434 entries), iOS 27 Simulator.
# One launch on Aura runs `-AuraSizeScript`: launch · zoom out · zoom in · pan · Aura→Flat→Aura · softest (largest extent) · →Aura defaults ·
# add an entry · zoom mid · background/foreground (done HERE, at `bgReady`) · →Glass · →Outline · →Flat. After each step
# the app logs `[AURASIZE] … bad>1px=… maxErrPx=…` and writes tmp/aurasize/<n>-<step>.csv; this script snaps a still.
#   scripts/renders/aura_size_audit.sh <out_dir> <tag> <dark|light> [rings] [extra args…]
set -uo pipefail
OUT=${1:?out}; TAG=${2:?tag}; GROUND=${3:?ground}; shift 3
RINGS=(); [[ "${1:-}" == rings ]] && { RINGS=(-AuraLayoutRings); shift; }
SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
FIXTURE=${FIXTURE:-$HOME/Developer/fixtures/tom-corpus-2026-09-21}; S=${S:-20}
mkdir -p $OUT
BASE=(-CorpusFixture $FIXTURE -CorpusFixtureFresh -EmbedCPUOnly -OpenMap -NoMapDebugHUD -AppearanceTuner YES -AppearanceTunerReset YES
      -MapLookSet aura -AuraSizeScript $S)
LOG=$OUT/.audit-$TAG-$GROUND.log
xcrun simctl ui $SIM appearance $GROUND
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
snap() { xcrun simctl io $SIM screenshot --type=png $OUT/$1.png >/dev/null 2>&1; }
nap() { python3 -c "import time; time.sleep($1)"; }
: > $LOG
xcrun simctl terminate $SIM $APPID >/dev/null 2>&1
xcrun simctl launch --console-pty $SIM $APPID $BASE $RINGS "$@" > $LOG 2>&1 &
LP=$!
STEPS=(launch zoomOut zoomIn pan toFlat toAura softer backToAura addEntry zoomMid bgReady toGlass toOutline toFlatEnd)
n=0
for st in $STEPS; do
  n=$((n+1))
  for i in {1..900}; do grep -q "\[AURASIZE\] step=$st " $LOG 2>/dev/null && break; nap 0.1; done
  snap $(printf "%s-%s-%02d-%s" $TAG $GROUND $n $st)
  if [[ $st == bgReady ]]; then
    xcrun simctl launch $SIM com.apple.Preferences >/dev/null 2>&1; nap 3
    xcrun simctl launch $SIM $APPID >/dev/null 2>&1
    for i in {1..300}; do grep -q "\[AURASIZE\] step=foreground " $LOG 2>/dev/null && break; nap 0.1; done
    snap $(printf "%s-%s-%02db-foreground" $TAG $GROUND $n)
  fi
done
D=$(xcrun simctl get_app_container $SIM $APPID data 2>/dev/null)
rm -rf $OUT/csv-$TAG-$GROUND; cp -R $D/tmp/aurasize $OUT/csv-$TAG-$GROUND 2>/dev/null
kill $LP 2>/dev/null; xcrun simctl terminate $SIM $APPID >/dev/null 2>&1
xcrun simctl status_bar $SIM clear
grep "\[AURASIZE\]" $LOG | sed 's/.*\[AURASIZE\]/[AURASIZE]/' | sort -u -k2,2 | sort -t= -k1,1 >/dev/null
grep "\[AURASIZE\] step" $LOG | sed 's/.*\[AURASIZE\]/[AURASIZE]/' | awk '!seen[$0]++'
