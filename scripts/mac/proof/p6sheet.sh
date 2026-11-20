#!/bin/zsh
# proof 6 · 1a/1b (3cc531b6) — text in the Librarian's Ask, then File › New Collection (a sheet), then Return or Esc.
# Ask text + bubbles are read once the sheet is gone (AX hides the main window under a sheet).
# Expect: the Ask is NOT sent (no "zq sheet" bubble right of x=980), Ask text unchanged; Esc closes the sheet.
#   p6sheet.sh <pid> <out> <return|esc> <trial>
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; K=$3; T=$4; mkdir -p $O
AXT=$ROOT/build/runs/s1-proof/axtext; AXC=$ROOT/build/runs/s1-proof/axcount
CJ=~/Library/Containers/com.doctorpresident.airpad.macA/Data/Documents/AirPad/collections.json
ask() { $AXT $P | grep ' · macLibrarianColumn · ' | sed -E 's/.*val=\[([^]]*)\].*/\1/'; }
sheet() { $AXT $P | grep -q 'ph=\[Collection name\]' && echo up || echo gone; }
ncol() { python3 -c "import json;print(len(json.load(open('$CJ'))))"; }
$PF $P >/dev/null; sleep 0.4
f=($($AXT $P | grep ' · macLibrarianColumn · ' | sed -E 's/.*\(([0-9]+),([0-9]+) ([0-9]+)×([0-9]+)\).*/\1 \2 \3 \4/'))
v0=$(ask); [[ ${v0:l} != "zq sheet" ]] && { [[ -n $v0 ]] && { $R clickat $P $((f[1] + f[3] / 2)) $((f[2] + f[4] / 2)) >/dev/null; sleep 0.5; $R cmdkey $P 0 >/dev/null; $R key $P 51 >/dev/null; sleep 0.5; }; $R clickat $P $((f[1] + f[3] / 2)) $((f[2] + f[4] / 2)) >/dev/null; sleep 0.8; $R type $P "zq sheet" >/dev/null; sleep 1; }
a0=$(ask); b0=$($AXC $P "zq sheet" 980); c0=$(ncol)
$R menu $P File "New Collection" >/dev/null; sleep 2; s1=$(sheet)
[[ $T == 1 ]] && cap $P $O/sheet-$K.png
if [[ $K == return ]]; then $R key $P 36 >/dev/null; else $R key $P 53 >/dev/null; fi; sleep 2
s2=$(sheet); [[ $T == 1 ]] && cap $P $O/after-$K.png
[[ $s2 == up ]] && { $R key $P 53 >/dev/null; sleep 1.5; }   # the main window's fields aren't in AX while a sheet is up: read after
a1=$(ask); b1=$($AXC $P "zq sheet" 980); c1=$(ncol); [[ $T == 1 ]] && cap $P $O/closed-$K.png
if [[ $K == return ]]; then ok=$([[ $s1 == up && ${a1:l} == "zq sheet" && ${b1%% *} == 0 ]] && echo PASS || echo FAIL)
else ok=$([[ $s1 == up && $s2 == gone && ${a1:l} == "zq sheet" && ${b1%% *} == 0 && $c1 == $c0 ]] && echo PASS || echo FAIL); fi
print -r -- "$K t$T: ask=[$a0] bubbles(tree onscreen)=[$b0] collections=$c0 · New Collection → sheet=$s1 · $K → sheet=$s2 ask=[$a1] bubbles=[$b1] collections=$c1 → $ok" | tee -a $O/results.txt
