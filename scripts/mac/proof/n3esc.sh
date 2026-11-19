#!/bin/zsh
# sweep-1 proof 3 · N3 Esc side cases (Library, view <V>):
#  search: View › Select Entries → click the toolbar Search, type "zq" → Esc → the field is empty AND selection mode is still on
#          (then a second Esc, focus gone, ends selection mode).
#  plain:  no selection mode, nothing focused → Esc → same view, no entry opened, no "Select items", app alive.
#   n3esc.sh <pid> <out> <view: List|Cards|Map>
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; V=$3; mkdir -p $O
log() { print -r -- "$*" | tee -a $O/results.txt; }
sel() { $R has $P 'Select items' | cut -c1-3; }
val() { $R get $P toolbar.search AXValue; }
$PF $P >/dev/null; sleep 0.4; $R menu $P View "$V" >/dev/null; sleep 1.5
$R menu $P View "Select Entries" >/dev/null; sleep 1.5; s1=$(sel)
$R click $P toolbar.search >/dev/null; sleep 0.8; $R type $P zq >/dev/null; sleep 1.2; v1=$(val); cap $P $O/${V:l}-typed.png
$R key $P 53 >/dev/null; sleep 1.2; v2=$(val); s2=$(sel); cap $P $O/${V:l}-esc1.png
$R key $P 53 >/dev/null; sleep 1.2; s3=$(sel)
ok=$([[ $s1 == yes && $v1 == *zq* && $v2 != *zq* && $s2 == yes ]] && echo PASS || echo FAIL)
log "$V search: select=[$s1] typed val=[$v1] · Esc → val=[$v2] select=[$s2] → $ok · 2nd Esc → select=[$s3]"
$R has $P Done | grep -q yes && { $R click $P Done >/dev/null; sleep 1; }
pids0=$P; b=$(sel); bt=$($R has $P titleField | cut -c1-3)
$R key $P 53 >/dev/null; sleep 1.2; a=$(sel); at=$($R has $P titleField | cut -c1-3); alive=$(kill -0 $P 2>/dev/null && echo yes || echo no); cap $P $O/${V:l}-plain.png
ok2=$([[ $a == no && $at == $bt && $alive == yes ]] && echo PASS || echo FAIL)
log "$V plain Esc: before select=[$b] entry-open=[$bt] → after select=[$a] entry-open=[$at] alive=$alive → $ok2"
