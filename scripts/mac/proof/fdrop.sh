#!/bin/zsh
# fdrop.sh <pid> <out dir> <tag> <x> <y> <file> [file2 …] — a REAL Finder drag of one or more files from the "dropfiles"
# window (list view) to (x,y) in the app, hovering there before the release. The files are selected in Finder first
# (AppleScript `select`, so an earlier multi-selection doesn't ride along), then the press lands on the first one's row —
# Finder drags the whole selection.
# Prints the entry-drop note's frame, captures mid-drag (+1.9 s) and after.
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; T=$3; X=$4; Y=$5; shift 5; mkdir -p $O
DIR=$ROOT/build/runs/s1-proof2/dropfiles
{
  list=""; for f in "$@"; do list+="${list:+, }(POSIX file \"$DIR/$f\" as alias)"; done
  osascript -e "tell application \"Finder\" to select {$list}" >/dev/null
  sleep 0.6
}
xy=($($ROOT/build/kit/rfinder icon dropfiles "$1"))
(sleep 1.9; screencapture -x -R0,60,1350,840 $O/$T-mid.png) &
$ROOT/build/kit/rfinder drag $xy[1] $xy[2] $X $Y $X $((Y + 1)) 600 still
sleep 1.5; echo "note: $($R has $P entryDropNote)"; cap $P $O/$T-after.png
