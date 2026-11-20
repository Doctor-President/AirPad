#!/bin/zsh
# proof 6 · C1 — List view: a real scroll at (x,y), the pointer left still there, then a real right-click at the same
# point → the entry's context menu (items read through AX), Esc closes it.   p6c1.sh <pid> <out> <trial> <x> <y> <dy>
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; T=$3; X=$4; Y=$5; DY=$6; mkdir -p $O; RR=$ROOT/build/runs/s1-proof/rright
mi() { local s=""; for m in Open "Make Private" "Export…" "Delete…"; do [[ $($R has $P "$m") == yes* ]] && s+="[$m]"; done; echo $s; }
$PF $P >/dev/null; sleep 0.4; m0=$(mi)
$ROOT/build/kit/rscroll $X $Y trackpad $DY 12 16 >/dev/null; sleep 1.2
$RR $X $Y >/dev/null; sleep 1.2; m1=$(mi); [[ $T == 1 ]] && screencapture -x -R$((X - 30)),$((Y - 30)),480,360 $O/c1-menu.png
$R key $P 53 >/dev/null; sleep 1; m2=$(mi)
print -r -- "C1 t$T: before [$m0] · scroll $DY at ($X,$Y), pointer still · right-click → [$m1] · Esc → [$m2] → $([[ -z $m0 && $m1 == *"[Delete…]"* && -z $m2 ]] && echo PASS || echo FAIL)" | tee -a $O/results.txt
