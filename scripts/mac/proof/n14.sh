#!/bin/zsh
# sweep-1 N14 — a Map card stays centred in the visible Map while the Librarian floats/docks and closes/opens.
# Real clicks (an orb, the float switch, the toolbar Librarian button). Card edges measured from window stills (cardx.py,
# dark mode); visible Map = the card's AX container, minus a floating panel on its right.   n14.sh <pid> <out> [n=3]
D=${0:A:h}; source $D/lib.sh; P=${1:?pid}; O=${2:?out}; N=${3:-3}; mkdir -p $O; : > $O/results.txt
AU=$ROOT/build/runs/s1-proof/axup; WY=$($R winpos $P | sed -E 's/\([0-9-]+,([0-9-]+) .*/\1/')
num() { sed -E 's/.*\(([0-9-]+),([0-9-]+) ([0-9]+)×([0-9]+)\).*/\1 \2 \3 \4/'; }
measure() {   # measure <label> <shot>
  local lab=$1 png=$O/$2.png; cap $P $png
  local b=($($R find $P mapCard | num)); [[ ${#b} != 4 ]] && { echo "$lab: card GONE" | tee -a $O/results.txt; return }
  local g=($($AU $P mapCard | sed -n 2p | num)); local sw=$($R get $P macPanelFloatSwitch AXDescription 2>/dev/null)
  local right=$((g[1] + g[3])) mode=closed
  if [[ $($R has $P macPanelFloatSwitch) == yes* ]]; then
    if [[ $sw == "Show as column" ]]; then mode=float; local c=($($R find $P macLibrarianColumn | num)); right=$((c[1] < right ? c[1] : right)); else mode=column; fi
  fi
  local vc=$(( (g[1] + right) / 2.0 )); local cx=($(python3 $D/cardx.py $png $((b[2] - WY + 420))))
  local d=$(( cx[3] - vc )); local ok=$([[ ${cx[1]} != none ]] && (( d <= 20 && d >= -20 )) && echo PASS || echo FAIL)
  printf "%s: librarian=%s mapgroup=%d..%d visible=%d..%d centre=%.1f card=%s..%s centre=%s Δ=%.1f → %s\n" $lab $mode $g[1] $((g[1]+g[3])) $g[1] $right $vc "${cx[1]}" "${cx[2]}" "${cx[3]}" $d $ok | tee -a $O/results.txt
}
for i in $(seq 1 $N); do
  [[ $($R get $P macPanelFloatSwitch AXDescription 2>/dev/null) == "Show as column" ]] && { $R click $P macPanelFloatSwitch >/dev/null; sleep 1.5; }
  $R has $P mapCard | grep -q yes && { $R click $P mapCard >/dev/null; sleep 1.5; }
  $R cmdkey $P 29 >/dev/null; sleep 2; cap $P $O/t$i-fit.png    # ⌘0 fit, then click the orb nearest the Map's centre
  for xy in "${(@f)$(python3 $D/orbs.py $O/t$i-fit.png 231 979 605 450)}"; do
    o=(${=xy}); $R clickat $P $o[1] $((o[2] + WY)) >/dev/null; sleep 2.5
    $R has $P mapCard | grep -q yes && { echo "t$i orb at window ($o[1],$o[2])" >> $O/results.txt; break; }
  done
  measure "t$i open(docked)" t$i-a
  $R click $P macPanelFloatSwitch >/dev/null; sleep 2; measure "t$i floated" t$i-b
  $R click $P macPanelFloatSwitch >/dev/null; sleep 2; measure "t$i docked" t$i-c
  $R click $P toolbar.librarian >/dev/null; sleep 2; measure "t$i lib-closed" t$i-d
  $R click $P toolbar.librarian >/dev/null; sleep 2; measure "t$i lib-open" t$i-e
done
echo "PASS $(grep -c 'PASS$' $O/results.txt)/$(grep -c '^t.*: ' $O/results.txt)" | tee -a $O/results.txt
