#!/bin/zsh
# Sweep 2b · 2.3 renderer trial, scene 2 — the background-to-card offset while scrolling, from stepped screen captures of
# a fast swipe (the screen as composited, i.e. what reaches the glass):
#   trial_cards_offset.sh <app> <out dir> <arm> [EXTRA]   (env WIN="1703 924" WINY=40, N=14 captures, DY=-2400 over 80 × 8 ms)
# Launches the isolated copy on Cards (arm B host + the arm), waits, starts N back-to-back `screencapture -x` of a region in
# the grid, posts one fast swipe with rperf, and keeps the stills (synthetic library only). Read them by eye at 200 %:
# the card's rim / text (cell) against its field and shadow (the pass). Not a speed run (captures load the machine).
ROOT=${0:A:h:h:h:h}; B=$ROOT/build/mac-perf; R=$B/rclick
C=~/Library/Containers/com.doctorpresident.airpad.macA/Data
APP=${1:?app}; OUT=${2:?out}; ARM=${3:?arm}; mkdir -p $OUT; OUT=${OUT:A}; touch $OUT/.keep
[[ $(cat $C/Documents/AirPad/.k3-library 2>/dev/null) == realistic ]] || { echo "realistic library not installed"; exit 1 }
[[ $($B/locked) == "locked 1"* ]] && { echo "LOCKED: not running"; exit 3 }
pkill -f "AirPadMacA.app/Contents/MacOS/AirPad"; sleep 1
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -MacCardsCollection B -MacCardsResize scale -MacCardsClick open -LivingTrial cards -LivingTrialArm $ARM ${=4:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 8; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 ${WINY:-40} >/dev/null; $R winsize $P ${=WIN:-1703 924} >/dev/null; sleep 1
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $P) to true" >/dev/null 2>&1; sleep 1
[[ $($R has $P sidebar.today) == no ]] && { $R click $P toolbar.sidebar >/dev/null; sleep 1 }
$R click $P sidebar.library >/dev/null; sleep 2; $R click $P toolbar.view.Cards >/dev/null; sleep 5
echo "arm $ARM · window $($R winpos $P) · $(git -C $ROOT rev-parse --short HEAD) · EXTRA ${4:-}" > $OUT/setup.txt
print -- "fast      scroll 640,600 ${DY:--2400} 80 8" > $OUT/swipe.steps
$R hover $P toolbar.title >/dev/null 2>&1; sleep 1
screencapture -x -R 300,200,700,560 $OUT/rest.png
( sleep 0.25; for i in $(seq -w 1 ${N:-14}); do screencapture -x -R 300,200,700,560 $OUT/swipe-$i.png; done ) & CAP=$!
$B/rperf $P $OUT/swipe.steps > $OUT/rperf.txt 2>&1
wait $CAP
kill $P 2>/dev/null; trap - EXIT
ls $OUT/*.png | wc -l
