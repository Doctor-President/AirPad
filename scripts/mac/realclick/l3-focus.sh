#!/bin/zsh
# E fix-up 5 · L3 — where does a blue focus ring around the window come from? REAL keys and clicks on the isolated Debug
# copy with -MacFocusLog (every UIKit focus move: what took focus, its frame), a still of the window after each step.
#   l3-focus.sh <isolated Debug .app> <out>
set -u
B=${0:A:h:h:h}/../build/mac-e; B=${B:A}; R=$B/fixup4/rclick
APP=${1:?app}; OUT=${2:?out}; mkdir -p $OUT; OUT=${OUT:A}
caffeinate -u -t 2; [[ $($B/fixup5/locked) == "locked 1"* ]] && { echo LOCKED; exit 3 }
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -MacFocusLog YES ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 10; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null; sleep 1
n=0
step() {   # step <label> <rclick args…>
  n=$((n+1)); local lab=$1; shift
  echo "STEP $n $lab $(python3 -c 'import time;print(int(time.time()*1000))')" >> $OUT/steps.txt
  $R "$@" >/dev/null 2>&1; sleep 0.9
  screencapture -x -R0,60,1350,840 $OUT/$(printf %02d $n)-$lab.png
}
step library   click $P sidebar.library
step list      click $P toolbar.view.List
step tab1      key $P 48
step tab2      key $P 48
step tab3      key $P 48
step tab4      key $P 48
step down      key $P 125
step up        key $P 126
step esc       key $P 53
step emptylist clickat $P 700 860
step emptybar  clickat $P 900 85
step map       click $P toolbar.view.Map
step emptymap  clickat $P 300 800
step tab5      key $P 48
step gear      click $P sidebar.settings
step tab6      key $P 48
step gear2     click $P sidebar.settings
step cmdL      cmdkey $P 37
step cmdL2     cmdkey $P 37
step cmdF      cmdkey $P 3
step esc2      key $P 53
step today     click $P sidebar.today
step tab7      key $P 48
step emptytoday clickat $P 700 860
step cards     click $P sidebar.library
step cardsv    click $P toolbar.view.Cards
step tab8      key $P 48
step arrows    key $P 124
step finder    clickat $P 1370 500
step back      clickat $P 700 75
step tab9      key $P 48
grep "\[FOCUS\]" $OUT/app.log > $OUT/focus.txt; wc -l < $OUT/focus.txt
