#!/bin/zsh
# dragprobe.sh <pid> <out> <x> <y> <id> [id …] — a REAL Finder drag of "Sweep Test Two.pdf" that hovers at (x,y) and is
# CANCELLED with Esc (nothing dropped); mid-hover (+1.9 s) prints every listed AX identifier's frame(s) (layout during a drag).
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; X=$3; Y=$4; shift 4; mkdir -p $O
osascript -e "tell application \"Finder\" to select {(POSIX file \"$ROOT/build/runs/s1-proof2/dropfiles/Sweep Test Two.pdf\" as alias)}" >/dev/null; sleep 0.6
xy=($($ROOT/build/kit/rfinder icon dropfiles "Sweep Test Two.pdf"))
(sleep 1.9; screencapture -x -R0,60,1350,840 $O/probe-mid.png; for id in "$@"; do echo "$id: $($ROOT/build/runs/s1-proof/axall $P $id | tr '\n' ';')"; done > $O/probe-frames.txt) &
$ROOT/build/kit/rfinder drag $xy[1] $xy[2] $X $Y $X $Y 600 still esc; wait; cat $O/probe-frames.txt
