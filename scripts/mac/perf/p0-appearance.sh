#!/bin/zsh
# Mac perf audit P0a — the Map after appearance changes, and the soak.
#   p0-appearance.sh <isolated bench .app> <out dir> [cycles=3]
# One launch on the perf library, Map showing, Settings › Appearance open beside it. Each cycle walks every appearance
# control (theme, each Map look, background, Gravity, Fluted glass, Dashboard surface); the controls are pressed through
# Accessibility (setup; several sit below the fold), then the Map gets REAL input (map-probe.steps: drag, scroll, ⌘0) and
# 4 s of rest. The app's recorder keeps the whole session; scripts/perf/phases.py turns it into one row per change:
# frame times while the Map moves, Map frames a second at rest, memory. Enough cycles (9 ≈ 30 min) make it the soak.
set -u
ROOT=${0:A:h:h:h:h}; B=$ROOT/build/mac-perf; R=$B/rclick
C=~/Library/Containers/com.doctorpresident.airpad.macA/Data; PREF=$C/Library/Preferences/com.doctorpresident.airpad.macA
APP=${1:?app}; OUT=${2:?out}; CYCLES=${3:-3}; mkdir -p $OUT; OUT=${OUT:A}
[[ -f $C/Documents/AirPad/.k3-installed ]] || { echo "perf library not installed"; exit 1 }
[[ $($B/locked) == "locked 1"* ]] && { echo "LOCKED: not running"; exit 3 }
now() { python3 -c 'import time; print("%.3f" % time.time())' }
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
pkill -f "AirPadMacA.app/Contents/MacOS/AirPad"; sleep 1; rm -rf $C/Library/Caches/PerfRecordings
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -PerfRecorder YES -PerfRecorderSeconds $((CYCLES * 480 + 240)) -ProUnlocked YES ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 8; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 160 >/dev/null; $R winsize $P 1350 840 >/dev/null; sleep 1
[[ $($R has $P sidebar.today) == no ]] && { $R click $P toolbar.sidebar >/dev/null; sleep 1 }
$R click $P sidebar.library >/dev/null; sleep 2; $R click $P toolbar.view.Map >/dev/null; sleep 4
$R click $P sidebar.settings >/dev/null; sleep 2; $R click $P settingsRow.Appearance >/dev/null; sleep 2
echo "window $($R winpos $P) · $(git -C $ROOT rev-parse --short HEAD)$(git -C $ROOT diff --quiet || echo +dirty) · powermode $(pmset -g | awk '/powermode/ {print $2}') · cycles $CYCLES · EXTRA ${EXTRA:-}" > $OUT/setup.txt
: > $OUT/phases.tsv; : > $OUT/rperf.txt
phase() {   # phase <label> [press target…]
  local l=$1; shift
  for t in "$@"; do $R press $P "$t" >> $OUT/press.log 2>&1; sleep 0.4; done
  local t0=$(now); sleep 1.5; local t1=$(now)
  $B/rperf $P $ROOT/scripts/mac/perf/map-probe.steps >> $OUT/rperf.txt 2>&1 & local W=$!   # has stalled once at start: 30 s cap
  for i in $(seq 1 60); do kill -0 $W 2>/dev/null || break; sleep 0.5; done
  kill -0 $W 2>/dev/null && { kill $W; echo "PROBE TIMEOUT cycle $CYCLE $l" >> $OUT/setup.txt }
  local t2=$(now); sleep 4
  print -- "$CYCLE\t$l\t$t0\t$t1\t$t2\t$(now)\t$(ps -o rss= -p $P | tr -d ' ')" >> $OUT/phases.tsv
}
CYCLE=0; phase start
for CYCLE in $(seq 1 $CYCLES); do
  phase theme-dark Dark
  for l in glass aura riso gradient outline flat; do phase look-dark-$l "Dark Map" mapLook-dark-$l; done
  phase theme-light Light
  for l in glass aura riso gradient outline flat; do phase look-light-$l "Light Map" mapLook-light-$l; done
  for g in ${=GROUNDS:-}; do phase ground-$g $g; done
  phase gravity-off appearance.gravityWells; phase gravity-on appearance.gravityWells
  phase fluted-off "Fluted glass*"; phase fluted-on "Fluted glass*"
  for s in 0 2 3 1; do phase surface-$s dashSurface-$s; done
  [[ $($B/locked) == "locked 1"* ]] && { echo "LOCKED mid-run at cycle $CYCLE" >> $OUT/setup.txt; break }
done
$R press $P BackButton >> $OUT/press.log 2>&1; sleep 1; $R click $P sidebar.settings >/dev/null; sleep 2
CYCLE=end; phase settings-closed
notifyutil -p com.airpad.perf.save; sleep 6
REC=$(ls -t $C/Library/Caches/PerfRecordings/*.json 2>/dev/null | head -1)
[[ -n $REC ]] && cp $REC $OUT/recording.json || echo "NO RECORDING" >> $OUT/setup.txt
kill $P 2>/dev/null; trap - EXIT
[[ -f $OUT/recording.json ]] && python3 $ROOT/scripts/perf/phases.py $OUT/recording.json $OUT/phases.tsv --json $OUT/phases.json > $OUT/phases.txt 2>&1
cat $OUT/setup.txt; cat $OUT/phases.txt
