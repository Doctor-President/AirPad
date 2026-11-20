#!/bin/zsh
# proof 6 · 1c select variant — preview open FIRST (real click on an orb), then View › Select Entries; Esc #1 → the preview
# closes and selection mode stays (MacSelectionEscape.blocked), Esc #2 → selection mode ends.  p6mapesc2.sh <pid> <out> <trial> <x> <y>
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; T=$3; X=$4; Y=$5; mkdir -p $O
card() { $R has $P mapCard | cut -c1-3; }
sel() { [[ $($R has $P Done) == yes* ]] && echo yes || echo no; }
$PF $P >/dev/null; sleep 0.4
$R clickat $P $X $Y >/dev/null; sleep 1.8; c1=$(card)
$R menu $P View "Select Entries" >/dev/null; sleep 1.5; c2=$(card); s2=$(sel); [[ $T == 1 ]] && cap $P $O/sel-card.png
$R key $P 53 >/dev/null; sleep 1.5; c3=$(card); s3=$(sel); [[ $T == 1 ]] && cap $P $O/sel-esc1.png
$R key $P 53 >/dev/null; sleep 1.5; c4=$(card); s4=$(sel)
[[ $s4 == yes ]] && { $R click $P Done >/dev/null; sleep 1; }; [[ $c4 == yes ]] && { $R click $P mapCard.close >/dev/null; sleep 1; }
ok=$([[ $c1 == yes && $c2 == yes && $s2 == yes && $c3 == no && $s3 == yes && $s4 == no ]] && echo PASS || echo FAIL)
print -r -- "select t$T: click orb ($X,$Y) → card=$c1 · Select Entries → card=$c2 selecting=$s2 · Esc → card=$c3 selecting=$s3 · Esc #2 → card=$c4 selecting=$s4 → $ok" | tee -a $O/results.txt
