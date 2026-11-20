#!/bin/zsh
# proof 6 · 1c (3cc531b6) — Map: real click on an orb → its card preview (AX id mapCard); Esc → the preview closes.
# select mode: View › Select Entries first; Esc #1 must close only the preview (selection mode stays), Esc #2 ends selection.
#   p6mapesc.sh <pid> <out> <plain|select> <trial> <x> <y>   (orb centre, global points)
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; M=$3; T=$4; X=$5; Y=$6; mkdir -p $O
card() { $R has $P mapCard | cut -c1-3; }
sel() { $R has $P 'Select items' | cut -c1-3; }
$PF $P >/dev/null; sleep 0.4
[[ $M == select ]] && { $R menu $P View "Select Entries" >/dev/null; sleep 1.5; }
s0=$(sel); $R clickat $P $X $Y >/dev/null; sleep 1.8; c1=$(card); s1=$(sel); [[ $T == 1 ]] && cap $P $O/$M-card.png
$R key $P 53 >/dev/null; sleep 1.5; c2=$(card); s2=$(sel); [[ $T == 1 ]] && cap $P $O/$M-esc.png
extra=""
if [[ $M == select ]]; then $R key $P 53 >/dev/null; sleep 1.5; s3=$(sel); extra=" · Esc #2 → selecting=$s3"
  [[ $s3 == yes ]] && { $R click $P Done >/dev/null; sleep 1; }
  ok=$([[ $s0 == yes && $c1 == yes && $c2 == no && $s2 == yes && $s3 == no ]] && echo PASS || echo FAIL)
else ok=$([[ $c1 == yes && $c2 == no && $s2 == no ]] && echo PASS || echo FAIL); fi
[[ $c2 == yes ]] && { $R click $P mapCard.close >/dev/null; sleep 1; }
print -r -- "$M t$T: selecting=$s0 · click orb ($X,$Y) → card=$c1 selecting=$s1 · Esc → card=$c2 selecting=$s2$extra → $ok" | tee -a $O/results.txt
