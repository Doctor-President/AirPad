#!/bin/zsh
# proof 4 (b) — Search used then cleared, then View › Select Entries → Esc ends selection mode. escsel.sh <pid> <out> <view> <trial>
R=${RC:-$(cd $(dirname $0)/../../.. && pwd)/build/kit/rclick}; P=$1; O=$2; V=$3; T=$4; mkdir -p $O
sel() { $R has $P 'Select items' | cut -c1-3; }
val() { $R get $P toolbar.search AXValue; }
$R menu $P View "$V" >/dev/null; sleep 1.5
$R click $P toolbar.search >/dev/null; sleep 0.8; $R type $P zq >/dev/null; sleep 1.2; v1=$(val)
$R key $P 53 >/dev/null; sleep 1.2; v2=$(val); foc=$($R get $P toolbar.search AXFocused)
$R menu $P View "Select Entries" >/dev/null; sleep 1.5; s1=$(sel)
screencapture -x -R0,60,1350,840 $O/$T-${V:l}-selecting.png
$R key $P 53 >/dev/null; sleep 1.2; s2=$(sel)
screencapture -x -R0,60,1350,840 $O/$T-${V:l}-after-esc.png
ok=$([[ $v1 == *zq* && $v2 != *zq* && $s1 == yes && $s2 == no ]] && echo PASS || echo FAIL)
print -r -- "$T $V: typed=[$v1] Esc→ field=[$v2] focused=[$foc] · Select Entries → selecting=[$s1] · Esc → selecting=[$s2] → $ok" | tee -a $O/results.txt
[[ $s2 == yes ]] && { $R click $P Done >/dev/null; sleep 1; }
