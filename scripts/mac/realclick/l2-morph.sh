#!/bin/zsh
# E fix-up 5 · L2 — the orb → card morph with REAL clicks on the Sample Library Map (fix-up 4's K7 orb, "GRAIN" near
# the middle), N rounds: click the orb, wait, Esc. A PERFLOG / Debug copy logs each morph frame by frame (-MacMorphLog:
# wall clock, dt, progress) and the display link's frame intervals (-MacFrameLog); REC=1 records the window at 60 fps.
#   l2-morph.sh <isolated .app> <out> [rounds=6] [timing iphone|mac]
set -u
B=${0:A:h:h:h}/../build/mac-e; B=${B:A}; R=$B/fixup4/rclick
APP=${1:?app}; OUT=${2:?out}; N=${3:-6}; TM=${4:-iphone}; mkdir -p $OUT; OUT=${OUT:A}
caffeinate -u -t 2; [[ $($B/fixup5/locked) == "locked 1"* ]] && { echo LOCKED; exit 3 }
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -MacMorphLog -MacFrameLog -mac.cardMorph.timing $TM > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 10; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null
[[ $($R has $P sidebar.today) == no ]] && $R click $P toolbar.sidebar >/dev/null
$R click $P sidebar.sample >/dev/null; sleep 1.5; $R click $P toolbar.view.Map >/dev/null; sleep 5
RP=; [[ ${REC:-0} == 1 ]] && { $B/fixup5/rrec $P $(( N * 4 + 2 )) $OUT/morph-$TM.mov > $OUT/rec.txt 2>&1 & RP=$! }
sleep 1
XP=; [[ ${PROFILE:-0} == 1 ]] && { xcrun xctrace record --template 'Time Profiler' --time-limit $(( N * 4 + 4 ))s --attach $P --output $OUT/morph.trace --no-prompt > $OUT/xctrace.log 2>&1 & XP=$!; sleep 3 }
X=616; Y=362
for i in $(seq 1 $N); do
  $R hover $P toolbar.title >/dev/null; sleep 0.8
  echo "click $i $(python3 -c 'import time;print(int(time.time()*1000))')" >> $OUT/clicks.txt
  $R clickat $P $X $Y >/dev/null; sleep 1.6
  $R hover $P toolbar.title >/dev/null; sleep 0.2; $R key $P 53 >/dev/null; sleep 1.2
  X=611; Y=464   # GRAIN after the glide (as l4-esc.sh)
done
[[ -n $RP ]] && wait $RP 2>/dev/null; [[ -n $XP ]] && wait $XP 2>/dev/null
grep "\[MorphLog\]" $OUT/app.log > $OUT/morph.txt; wc -l < $OUT/morph.txt
