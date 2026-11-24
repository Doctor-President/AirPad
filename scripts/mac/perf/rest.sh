#!/bin/zsh
# Mac perf audit — what the app does when NOTHING is happening, per screen.
#   rest.sh <isolated bench .app> <out dir>
# Goes to each screen with a real click, leaves the pointer parked over the window's title bar, waits 3 s, then
# records 5 s of rest. scripts/perf/rest.py reads the recording: CPU, how busy the main thread was, what it was
# doing, which views rebuilt, Map frames. A screen at rest should cost ~0. LIBRARIAN=closed closes the Librarian.
# HEAVY / LIGHT = the entries opened (default: the synthetic perf library's); WIN="w h" / WINY = the window (default 1350 840 at y 160).
set -u
ROOT=${0:A:h:h:h:h}; B=$ROOT/build/mac-perf; R=$B/rclick
C=~/Library/Containers/com.doctorpresident.airpad.macA/Data; PREF=$C/Library/Preferences/com.doctorpresident.airpad.macA
APP=${1:?app}; OUT=${2:?out}; mkdir -p $OUT; OUT=${OUT:A}
HEAVY=${HEAVY:-9E9F1000-0000-4000-8000-000000000001}; LIGHT=${LIGHT:-9E9F1000-0000-4000-8000-000000000007}
[[ -f $C/Documents/AirPad/.k3-installed ]] || { echo "perf library not installed"; exit 1 }
[[ $($B/locked) == "locked 1"* ]] && { echo "LOCKED: not running"; exit 3 }
now() { python3 -c 'import time; print("%.3f" % time.time())' }
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
pkill -f "AirPadMacA.app/Contents/MacOS/AirPad"; sleep 1; rm -rf $C/Library/Caches/PerfRecordings
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -PerfRecorder YES -PerfRecorderSeconds 400 -PerfSampleAfter 3 -ProUnlocked YES ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 8; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 ${WINY:-160} >/dev/null; $R winsize $P ${=WIN:-1350 840} >/dev/null; sleep 1
[[ $($R has $P sidebar.today) == no ]] && { $R click $P toolbar.sidebar >/dev/null; sleep 1 }
LIB=$($R get $P toolbar.librarian AXValue)
[[ ${LIBRARIAN:-open} == open && $LIB != Open ]] && { $R click $P toolbar.librarian >/dev/null; sleep 1 }
[[ ${LIBRARIAN:-open} == closed && $LIB == Open ]] && { $R click $P toolbar.librarian >/dev/null; sleep 1 }
echo "window $($R winpos $P) · $(git -C $ROOT rev-parse --short HEAD)$(git -C $ROOT diff --quiet || echo +dirty) · powermode $(pmset -g | awk '/powermode/ {print $2}') · librarian ${LIBRARIAN:-open} · EXTRA ${EXTRA:-}" > $OUT/setup.txt
: > $OUT/phases.tsv
rest() {   # rest <label> <click target…>
  local l=$1; shift
  for t in "$@"; do $R click $P "$t" >/dev/null 2>&1; sleep 1.2; done
  $R hover $P toolbar.title >/dev/null 2>&1; sleep 3
  local t0=$(now); sleep 5
  print -- "$l\t$t0\t$(now)" >> $OUT/phases.tsv
}
rest today sidebar.today
rest recents sidebar.recents
rest library-map sidebar.library toolbar.view.Map
rest library-list toolbar.view.List
rest entry-heavy listRow-$HEAVY
rest entry-light toolbar.back listRow-$LIGHT
rest library-cards toolbar.back toolbar.view.Cards
rest chats sidebar.chats
rest journal sidebar.journal
rest settings sidebar.library toolbar.view.List sidebar.settings
notifyutil -p com.airpad.perf.save; sleep 5
REC=$(ls -t $C/Library/Caches/PerfRecordings/*.json 2>/dev/null | head -1)
[[ -n $REC ]] && cp $REC $OUT/recording.json || echo "NO RECORDING" >> $OUT/setup.txt
kill $P 2>/dev/null; trap - EXIT
[[ -f $OUT/recording.json ]] && python3 $ROOT/scripts/perf/rest.py $OUT/recording.json $OUT/phases.tsv --json $OUT/rest.json > $OUT/rest.txt 2>&1
cat $OUT/setup.txt; cat $OUT/rest.txt
