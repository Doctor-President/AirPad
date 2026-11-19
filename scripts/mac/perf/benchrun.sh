#!/bin/zsh
# Sweep 1 · 1.4 (sheet C) — the in-app switch bench (`-MacSwitchBench <rounds>`, PANBENCH builds): no real events, so it
# runs with the screen locked too. For WHERE a switch's main-thread time goes (busy ms, families, views rebuilt, symbols),
# not for what the screen shows (that is run.sh … switch.steps with real clicks).
#   benchrun.sh <bench .app> <out dir> [rounds=4]      EXTRA="-MacPerfAB x" adds launch arguments; PROFILE=1 adds xctrace.
set -u
ROOT=${0:A:h:h:h:h}
C=~/Library/Containers/com.doctorpresident.airpad.macA/Data
APP=${1:?app}; OUT=${2:?out}; N=${3:-4}; mkdir -p $OUT; OUT=${OUT:A}
[[ -f $C/Documents/AirPad/.k3-installed ]] || { echo "perf library not installed"; exit 1 }
PREF=$C/Library/Preferences/com.doctorpresident.airpad.macA
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
pkill -f "AirPadMacA.app/Contents/MacOS/AirPad"; sleep 1
rm -rf $C/Library/Caches/PerfRecordings; rm -f $C/Library/Caches/switch-bench.tsv
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -PerfRecorder YES -PerfRecorderSeconds 900 -ProUnlocked YES -MacSwitchBench $N ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
echo "bench $N rounds · $(git -C $ROOT rev-parse --short HEAD)$(git -C $ROOT diff --quiet || echo +dirty) · powermode $(pmset -g | awk '/powermode/ {print $2}') · $(${ROOT}/build/kit/locked) · EXTRA ${EXTRA:-}" > $OUT/setup.txt
X=
if [[ -n ${PROFILE:-} ]]; then
  sleep 3
  xcrun xctrace record --template 'Time Profiler' --instrument 'Hangs' --time-limit ${TL:-400}s --attach $P --output $OUT/session.trace --no-prompt > $OUT/xctrace.log 2>&1 & X=$!
fi
for i in $(seq 1 600); do [[ -f $C/Library/Caches/switch-bench.tsv ]] && break; sleep 1; done
sleep 1; cp $C/Library/Caches/switch-bench.tsv $OUT/steps.tsv
notifyutil -p com.airpad.perf.save; sleep 4
REC=$(ls -t $C/Library/Caches/PerfRecordings/*.json 2>/dev/null | head -1)
[[ -n $REC ]] && cp $REC $OUT/recording.json || echo "NO RECORDING" >> $OUT/setup.txt
[[ -n $X ]] && { kill -INT $X 2>/dev/null; wait $X 2>/dev/null }
kill $P 2>/dev/null; trap - EXIT
python3 $ROOT/scripts/perf/busy.py $OUT/recording.json $OUT/steps.tsv > $OUT/busy.txt 2>&1
cat $OUT/setup.txt $OUT/busy.txt
