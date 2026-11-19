# sourced by the proof scripts: R=rclick, cap <pid> <out.png> (window capture, then a 1x copy *-s.png for viewing)
ROOT=${0:A:h:h:h:h}; [[ -d $ROOT/build/kit ]] || ROOT=~/Developer/AirPad/.claude/worktrees/ws-mac
R=$ROOT/build/kit/rclick; PF=$ROOT/build/runs/s1-proof/pfront; SK=$ROOT/build/runs/s1-proof/skey
cap() { local w=$($PF $1); screencapture -x -o -l $w $2; sips -Z 1350 $2 --out ${2:r}-s.png >/dev/null 2>&1; }
