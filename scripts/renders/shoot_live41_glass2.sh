#!/bin/zsh
# live-41 — dark Map Glass stills, Sample Library (scratch), iOS 27 Simulator. ONE launch (-MapGlassCycle steps every 4 s →
# same layout + framing): today's Glass (T's Copy values when TODAY_JSON is set, else live-40 Medium) · arcs only · frost
# 0.3 / 0.6 / 0.9 · dim only · arcs + frost 0.6 · two simulated tilts at the new default response. Then the same cycle
# zoomed in: today and arcs + frost 0.6. Each snap waits for its `[MAPCYCLE] <step>` log line (+2.5 s to settle).
#   [TODAY_JSON='<mapDark or glass block>'] scripts/renders/shoot_live41_glass2.sh <out_dir> [start-seconds]
set -uo pipefail
OUT=${1:?out}; S=${2:-22}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -OpenMap -NoMapDebugHUD -AppearanceTuner YES -AppearanceTunerReset YES)
TODAY=(); [[ -n "${TODAY_JSON:-}" ]] && TODAY=(-MapGlassToday "$TODAY_JSON")
LOG=$OUT/.cycle.log
xcrun simctl ui $SIM appearance dark
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
snap() { xcrun simctl io $SIM screenshot --type=png $OUT/$1.png >/dev/null 2>&1; }
waitstep() {   # waitstep <step> <png>
  for i in {1..400}; do grep -q "\[MAPCYCLE\] $1\$" $LOG 2>/dev/null && break; python3 -c "import time; time.sleep(0.1)"; done
  python3 -c "import time; time.sleep(2.5)"; snap $2
}
run() {   # run <extra args...>
  : > $LOG
  xcrun simctl spawn $SIM log stream --style compact --predicate 'eventMessage CONTAINS "[MAPCYCLE]"' > $LOG 2>&1 &
  LP=$!
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE $TODAY "$@" -MapGlassCycle $S >/dev/null
}
run
waitstep glass-today 1-glass-today; waitstep arcs-only 2-arcs-only; waitstep frost-0.3 3-frost-0.3
waitstep frost-0.6 4-frost-0.6; waitstep frost-0.9 5-frost-0.9; waitstep dim-only 6-dim-only
waitstep arcs-frost-0.6 7-arcs-frost-0.6; waitstep tilt-left-up 8-tilt-left-up; waitstep tilt-right-down 9-tilt-right-down
kill $LP 2>/dev/null
run -MapZoom 0.45
waitstep glass-today 10-zoomed-glass-today; waitstep arcs-frost-0.6 11-zoomed-arcs-frost-0.6
kill $LP 2>/dev/null
xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
