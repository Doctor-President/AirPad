#!/bin/zsh
# sweep-1 proof 2 · N3 — View › Select Entries from the REAL menu bar in List, Cards and Map (Library, no entry open):
# selection mode starts ("Select items" + Done), two real clicks on entries → "2 selected", then Esc (or Done) ends it.
# Click points are passed per view (global points).   n3.sh <pid> <out> <view: List|Cards|Map> <x1 y1> <x2 y2> [end: esc|done]
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; V=$3; X1=$4; Y1=$5; X2=$6; Y2=$7; END=${8:-esc}; mkdir -p $O
log() { print -r -- "$*" | tee -a $O/results.txt; }
st() { local s="sel-items=$($R has $P 'Select items' | cut -c1-3) done=$($R has $P Done | cut -c1-3)"; for n in 1 2 3; do [[ $($R has $P "$n selected") == yes* ]] && s+=" count=$n"; done; echo $s; }
$PF $P >/dev/null; sleep 0.5
$R menu $P View "$V" >/dev/null; sleep 2; s0=$(st)
$R menu $P View "Select Entries" >/dev/null; sleep 1.5; s1=$(st); cap $P $O/${V:l}-select.png
$R clickat $P $X1 $Y1 >/dev/null; sleep 1; $R clickat $P $X2 $Y2 >/dev/null; sleep 1.2; s2=$(st); cap $P $O/${V:l}-two.png
if [[ $END == esc ]]; then $R key $P 53 >/dev/null; else $R click $P Done >/dev/null; fi; sleep 1.5; s3=$(st); cap $P $O/${V:l}-end.png
ok=$([[ $s1 == *"sel-items=yes"*"done=yes"* && $s2 == *"count=2"* && $s3 == *"sel-items=no done=no"* ]] && echo PASS || echo FAIL)
log "$V: before [$s0] · Select Entries → [$s1] · click ($X1,$Y1) ($X2,$Y2) → [$s2] · $END → [$s3] → $ok"
