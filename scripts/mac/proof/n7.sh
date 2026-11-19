#!/bin/zsh
# sweep-1 N7 — Librarian float switch: at 1350 docked → float → column; at 1000 the panel is forced to float, and the
# switch widens the window and docks; then edge cases (screen-wide window; a 1000 window against the screen's right edge).
# Real clicks; the window resized through AX (winsize).   n7.sh <pid> <out> [n=3]
source ${0:A:h}/lib.sh; P=${1:?pid}; O=${2:?out}; N=${3:-3}; mkdir -p $O; : > $O/results.txt
sw() { $R get $P macPanelFloatSwitch AXDescription; }   # "Float over content" = docked · "Show as column" = floating
mode() { [[ $(sw) == "Float over content" ]] && echo column || echo float; }
for i in $(seq 1 $N); do
  $R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null; sleep 1.2
  [[ $(mode) == float ]] && { $R click $P macPanelFloatSwitch >/dev/null; sleep 1.5; }
  m0=$(mode); $R click $P macPanelFloatSwitch >/dev/null; sleep 1.5; m1=$(mode); $R click $P macPanelFloatSwitch >/dev/null; sleep 1.5; m2=$(mode)
  ok=$([[ $m0 == column && $m1 == float && $m2 == column ]] && echo PASS || echo FAIL)
  echo "1350 $i: $m0 → click → $m1 → click → $m2 → $ok" | tee -a $O/results.txt
  $R winsize $P 1000 840 >/dev/null; sleep 1.5; m3=$(mode); w0=$($R winpos $P)
  [[ $i == 1 ]] && cap $P $O/w1000-forced.png
  $R click $P macPanelFloatSwitch >/dev/null; sleep 2; m4=$(mode); w1=$($R winpos $P)
  [[ $i == 1 ]] && cap $P $O/w1000-docked.png
  W1=$(echo $w1 | sed -E 's/.* ([0-9]+)×.*/\1/')
  ok=$([[ $m3 == float && $m4 == column && $W1 -gt 1000 ]] && echo PASS || echo FAIL)
  echo "1000 $i: at 1000 $m3 win $w0 → click → $m4 win $w1 → $ok" | tee -a $O/results.txt
done
# edge 1: as wide as the screen (AX clamps) — docked, float, back
$R winmove $P 0 30 >/dev/null; wmax=$($R winsize $P 4000 840); sleep 1.5
e0=$(mode); $R click $P macPanelFloatSwitch >/dev/null; sleep 1.5; e1=$(mode); $R click $P macPanelFloatSwitch >/dev/null; sleep 1.5; e2=$(mode)
echo "edge screen-wide: win $wmax · $e0 → $e1 → $e2 · after $($R winpos $P)" | tee -a $O/results.txt
# edge 2: a 1000-wide window flush against the screen's right edge, forced float, then the switch
SW=$(echo $wmax | sed -E 's/.* ([0-9]+)×.*/\1/')   # the screen's width = the clamped screen-wide window
$R winsize $P 1000 840 >/dev/null; $R winmove $P $((SW - 1000)) 60 >/dev/null; sleep 1.5; f0=$(mode); g0=$($R winpos $P)
$R click $P macPanelFloatSwitch >/dev/null; sleep 2; f1=$(mode); g1=$($R winpos $P)
echo "edge right-flush (screen $SW wide): $f0 win $g0 → click → $f1 win $g1" | tee -a $O/results.txt
cap $P $O/edge-right.png
# edge 3: the screen-wide window minus a little, then narrowed to 900 (below what fits a column + content?)
$R winmove $P 0 60 >/dev/null; $R winsize $P 900 840 >/dev/null; sleep 1.5; h0=$(mode); k0=$($R winpos $P)
$R click $P macPanelFloatSwitch >/dev/null; sleep 2; h1=$(mode); k1=$($R winpos $P)
echo "edge 900 at x=0: $h0 win $k0 → click → $h1 win $k1" | tee -a $O/results.txt
$R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null; sleep 1
echo "1350 PASS $(grep -c '^1350.*PASS' $O/results.txt)/$N · 1000 PASS $(grep -c '^1000.*PASS' $O/results.txt)/$N" | tee -a $O/results.txt
