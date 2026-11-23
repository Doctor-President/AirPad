#!/bin/zsh
# Sweep 2b · 2.3 — process CPU with the Map at rest, recorder OFF (its own 120 Hz link would count):
#   trial_restcpu.sh <app> <label> [settle_s=30] [window_s=30]   (env EXTRA = launch args, WIN as run.sh)
# Launches the isolated copy, opens Library › Map, waits `settle` (past the 14 s -MapZoom), then CPU% = Δ(cpu time) / Δ(wall)
# over `window` with no input. Isolated copy only; screen must be unlocked (the Map renders only on a lit display).
ROOT=${0:A:h:h:h:h}; B=$ROOT/build/mac-perf; R=$B/rclick
APP=${1:?app}; LBL=${2:?label}; SET=${3:-30}; WIN_S=${4:-30}
pkill -f "AirPadMacA.app/Contents/MacOS/AirPad"; sleep 1
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES ${=EXTRA:-} > /dev/null 2>&1 & P=$!
sleep 8; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 ${WINY:-0} >/dev/null; $R winsize $P ${=WIN:-1728 1029} >/dev/null; sleep 1
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $P) to true" >/dev/null 2>&1; sleep 1
$R click $P sidebar.library >/dev/null; sleep 2; $R click $P toolbar.view.Map >/dev/null
sleep $SET
t() { ps -p $P -o time= | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
c0=$(t); w0=$(python3 -c 'import time;print(time.time())')
sleep $WIN_S
c1=$(t); w1=$(python3 -c 'import time;print(time.time())')
kill $P; wait $P 2>/dev/null
python3 -c "print(f'$LBL: process CPU {100*($c1-$c0)/($w1-$w0):.2f}% over {$w1-$w0:.0f} s at rest (settle ${SET} s, recorder off)')"
