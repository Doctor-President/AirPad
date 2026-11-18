#!/bin/zsh
# E fix-up 4 · K3 — the performance pass: the isolated Release copy on a library of T's size (the synthetic perf library,
# seeded by a Debug copy with -UITestSeedPerfLibrary), T's window size, real events (rperf), Time Profiler + Hangs.
#   k3.sh <isolated Release .app> <out dir> [rounds=3]
#   The container's own library is moved aside to AirPad.k3-backup the first time and put back by `k3.sh restore`.
set -u
H=${0:A:h:h}/realclick; B=${0:A:h:h:h:h}/build/mac-e/fixup4
C=~/Library/Containers/com.doctorpresident.airpad.macA/Data
if [[ ${1:-} == restore ]]; then
  [[ -d $C/Documents/AirPad.k3-backup ]] && { rm -rf $C/Documents/AirPad; mv $C/Documents/AirPad.k3-backup $C/Documents/AirPad; echo restored; }; exit
fi
APP=${1:?app}; OUT=${2:?out}; ROUNDS=${3:-3}; mkdir -p $OUT; OUT=${OUT:A}   # xctrace can't save to a relative path
SEED=$C/Library/Caches/AirPadUITestScratch
[[ -f $SEED/perf-library.done ]] || { echo "no perf library at $SEED (run the Debug copy with -UITestLibrary -UITestLibraryFresh -UITestSeedPerfLibrary)"; exit 1 }
[[ -d $C/Documents/AirPad.k3-backup ]] || mv $C/Documents/AirPad $C/Documents/AirPad.k3-backup
if [[ ! -f $C/Documents/AirPad/.k3-installed ]]; then
  # Installed once, then warmed up (cards, vectors, layout) by one launch left idle WARM s (default 180), so every
  # measured run sees a processed library, as T's is.
  rm -rf $C/Documents/AirPad; ditto $SEED $C/Documents/AirPad; rm -f $C/Documents/AirPad/perf-library.done
  $APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES > $OUT/warmup.log 2>&1 & W=$!
  sleep ${WARM:-180}; kill $W; sleep 2; touch $C/Documents/AirPad/.k3-installed
fi
for t in rclick rperf; do [[ $B/$t -nt $H/$t.swift ]] || swiftc -O -o $B/$t $H/$t.swift 2>/dev/null; done; R=$B/rclick
PREF=$C/Library/Preferences/com.doctorpresident.airpad.macA
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
caffeinate -d -u -w $$ &
# E fix-up 5 — the display sleeps between runs and the session then reads as locked (no window, every click NOT FOUND):
# wake it and refuse to run locked.
caffeinate -u -t 2; L=${0:A:h:h:h:h}/build/mac-e/fixup5/locked
[[ -x $L ]] && [[ $($L) == "locked 1"* ]] && { echo "LOCKED: not running" | tee $OUT/setup.txt; exit 3 }
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
# E fix-up 5 — wait for the window (a fixed 15 s once found none: "window (0,0 0×0)" and an empty run).
sleep 10; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 160 >/dev/null; $R winsize $P 1350 840 >/dev/null; sleep 1
[[ $($R has $P sidebar.today) == no ]] && { $R click $P toolbar.sidebar >/dev/null; sleep 1 }
[[ $($R get $P toolbar.librarian AXValue) != Open ]] && { $R click $P toolbar.librarian >/dev/null; sleep 1 }
$R click $P sidebar.library >/dev/null; sleep 3   # first Map build (not measured)
echo "nodes $(ls $C/Documents/AirPad/nodes | wc -l | tr -d ' ') · window $($R winpos $P)" > $OUT/setup.txt
# MODE=profile (default): the session under Time Profiler + Hangs. MODE=hitches: scroll.steps under Animation Hitches.
# MODE=frames: scroll.steps with no recording (a Debug copy with EXTRA="-MacClickTrace YES -MacFrameLog YES" logs its
# display-link intervals; k3frames.py reads them). Animation Hitches is not used: on this Mac its kernel trace grew
# ~25 GB a minute and its tables came back empty.
if [[ ${MODE:-profile} == frames ]]; then
  sleep 1 & STEPS=${0:A:h}/scroll.steps
elif [[ ${MODE} == plain ]]; then   # E fix-up 6 — STEPS with no recording (rperf's visible / settled times only)
  sleep 1 & STEPS=${STEPS:?STEPS}
else
  xcrun xctrace record --template 'Time Profiler' --instrument 'Hangs' --time-limit ${TL:-400}s --attach $P --output $OUT/session.trace --no-prompt > $OUT/xctrace.log 2>&1 &
  STEPS=${STEPS:-${0:A:h}/session.steps}   # E fix-up 5: STEPS=<file> for a focused bench (entry.steps)
fi
X=$!
# Disk guard: an Instruments kernel trace that failed to stop grew to 31 GB in ~6 min (fix-up 4) — stop the recording
# below 15 GB free.
( while kill -0 $X 2>/dev/null; do (( $(df -g / | awk 'NR==2 {print $4}') < 15 )) && { echo "DISK GUARD: stopping xctrace" >> $OUT/setup.txt; kill -9 $X; pkill -9 -f DTServiceHub; }; sleep 2; done ) &
sleep 4
: > $OUT/steps-all.steps; for i in $(seq 1 $ROUNDS); do grep -v '^#' $STEPS >> $OUT/steps-all.steps; done
T0=$(date +%s)
RPERF_CSV=$OUT/steps.csv $B/rperf $P $OUT/steps-all.steps > $OUT/rperf.txt 2>&1
echo "session $(( $(date +%s) - T0 )) s" >> $OUT/setup.txt
wait $X 2>/dev/null   # xctrace stops at its time limit (Ctrl-C left ktrace running: an empty trace)
ps -o %cpu= -p $P >> $OUT/setup.txt
tail -25 $OUT/rperf.txt
