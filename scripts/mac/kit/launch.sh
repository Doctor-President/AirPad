#!/bin/zsh
# launch.sh <isolated .app> <out dir> [open-entry] — relaunch the isolated copy at (0,60) 1100×840; prints the pid.
# EXTRA="-Key v …" adds launch arguments (export it).
source ${0:A:h}/env.sh; APP=${1:A}; O=${2:?out}; mkdir -p $O
pkill -f "AirPadMacA.app/Contents/MacOS/AirPad"; sleep 2
($APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES ${=EXTRA:-} >> $O/app.log 2>&1 &)
for i in $(seq 1 30); do P=$(pgrep -f "$APP/Contents/MacOS/AirPad" | head -1); [[ -n $P ]] && $RC winpos $P >/dev/null 2>&1 && break; sleep 1; done
sleep 2; echo $P > $O/pid
$RC winmove $P 0 60 >/dev/null; $RC winsize $P ${WIN_W:-1100} ${WIN_H:-840} >/dev/null; sleep 1
[[ ${3:-} == open-entry ]] && { $RC clickat $P 412 236 >/dev/null; sleep 3; }
echo $P
