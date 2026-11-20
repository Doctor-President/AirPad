#!/bin/zsh
# proof 6 · 4 (b87eebd5) — fresh launch, Library › Cards, NO scroll: two window captures 1.0 s apart; the mean abs
# diff over the cards area must be > 0 (gradients animate) while the sidebar stays ~0.   p6grad.sh <app> <out> <trial>
D=${0:A:h}; source $D/lib.sh; APP=$1; O=$2; T=$3; mkdir -p $O
P=$(WIN_W=1350 zsh $ROOT/scripts/mac/kit/launch.sh $APP $O/launch | tail -1)
$R clickat $P 69 305 >/dev/null; sleep 1; $R menu $P View Cards >/dev/null; sleep 4
cap $P $O/t$T-a.png; sleep 1.0; cap $P $O/t$T-b.png
r=$(python3 $D/p6grad.py $O/t$T-a.png $O/t$T-b.png 250 120 960 820 250 115 465 265 10 380 220 700 | tr '\n' ' ')
print -r -- "launch $T (pid $P): cards area [250,120,960,820] · one card gradient [250,115,465,265] · sidebar [10,380,220,700] → $r" | tee -a $O/results.txt
