#!/bin/zsh
# Good Flow spike · process CPU at rest over 30 s (design §1: Map / nothing hovered ≤ 1 %; live ≤ 3 points above the still).
#   tools/mac_restcpu.sh <case> <label> [settle_s=12] [window_s=30]   env ARGS (e.g. "-Live off", "-Flat on"), WIN, HOVER=x,y
# Launched through LaunchServices, window at (0,0) sized WIN, no input during the window (HOVER puts the pointer on a card
# first: the hovered-card live row). Recorder samples stay on (1 Hz, a background timer); no display link of its own.
set -u
SPIKE=${0:A:h:h}; ROOT=${SPIKE:h:h}; RC=$ROOT/scripts/mac/realclick; T=$SPIKE/build/tools
APP=${APP:-$SPIKE/build/dd/Build/Products/Release-maccatalyst/GoodFlow.app}
CASE=${1:?case}; LBL=${2:?label}; SET=${3:-12}; WS=${4:-30}
mkdir -p $T; for t in rclick locked; do [[ $T/$t -nt $RC/$t.swift ]] || swiftc -O -o $T/$t $RC/$t.swift 2>/dev/null; done
[[ $($T/locked) == "locked 0"* || -n ${DRYRUN:-} ]] || { echo "LOCKED: not running (the Map and live surfaces render only on a lit display)"; exit 3 }
for p in $(pgrep -x GoodFlow); do kill $p; done; sleep 1
open -n -a $APP --args -Case $CASE -ApplePersistenceIgnoreState YES ${=ARGS:-}
P=; for i in $(seq 1 20); do P=$(pgrep -nx GoodFlow); [[ -n $P ]] && break; sleep 0.5; done
sleep 4; $T/rclick winmove $P 0 0 > /dev/null; $T/rclick winsize $P ${=WIN:-1728 1028} > /dev/null
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $P) to true" > /dev/null 2>&1
[[ -n ${HOVER:-} ]] && swift -e "import CoreGraphics; let p = CGPoint(x: ${HOVER%,*}, y: ${HOVER#*,}); CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)" 2>/dev/null
sleep $SET
t() { ps -p $P -o time= | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
c0=$(t); w0=$(python3 -c 'import time;print(time.time())')
sleep $WS
c1=$(t); w1=$(python3 -c 'import time;print(time.time())')
kill $P
python3 -c "print(f'$LBL ($CASE, ARGS=${ARGS:-}): process CPU {100*($c1-$c0)/($w1-$w0):.2f}% over {$w1-$w0:.0f} s at rest (settle ${SET} s)')"
