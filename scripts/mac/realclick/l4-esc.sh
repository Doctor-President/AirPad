#!/bin/zsh
# E fix-up 5 · L4 — Esc on the Map's preview card with REAL events, judged against a control. Fix-up 4's K7 harness
# judged "closed" by pixels against the frame before the click, but opening a card glides the camera, so the frame
# never returns; and it moved the pointer across the Map before Esc (a hover wakes the Map). Here, per round: click an
# orb, leave the pointer still ON the card for 2.5 s (the morph settles, the Map rests — as when T presses Esc), A =
# still; real Esc; 1.5 s; B = still; then move the pointer over the Map (its hover wakes the Map); 1.2 s; C = still.
# Esc closed the card  ⇔  A→B changed (> 5/255) and B→C didn't (< 3/255). The bug: B ≈ A minus the ×, and C differs.
#   l4-esc.sh <isolated .app> <out> [rounds=5]
set -u
B=${0:A:h:h:h}/../build/mac-e; B=${B:A}; R=$B/fixup4/rclick
APP=${1:?app}; OUT=${2:?out}; N=${3:-5}; mkdir -p $OUT; OUT=${OUT:A}
caffeinate -u -t 2; [[ $($B/fixup5/locked) == "locked 1"* ]] && { echo LOCKED; exit 3 }
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 10; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null
[[ $($R has $P sidebar.today) == no ]] && $R click $P toolbar.sidebar >/dev/null
$R click $P sidebar.sample >/dev/null; sleep 1.5; $R click $P toolbar.view.Map >/dev/null; sleep 5
d() { python3 -c "
from PIL import Image, ImageChops, ImageStat; import sys
a=Image.open(sys.argv[1]).convert('RGB'); b=Image.open(sys.argv[2]).convert('RGB')
print(round(sum(ImageStat.Stat(ImageChops.difference(a,b)).mean)/3,1))" $1 $2 }
X=616; Y=362; ok=0; opened=0
for i in $(seq 1 $N); do
  $R clickat $P $X $Y >/dev/null; sleep 2.5
  screencapture -x -R0,60,1350,840 $OUT/r$i-A.png
  $R key $P 53 >/dev/null; sleep 1.5; screencapture -x -R0,60,1350,840 $OUT/r$i-B.png
  $R hover $P toolbar.title >/dev/null; sleep 1.2; screencapture -x -R0,60,1350,840 $OUT/r$i-C.png
  ab=$(d $OUT/r$i-A.png $OUT/r$i-B.png); bc=$(d $OUT/r$i-B.png $OUT/r$i-C.png)
  print -r -- "round $i: click ($X,$Y) · A→B Δ$ab · B→C Δ$bc" | tee -a $OUT/matrix.txt
  (( ab > 5 )) && opened=$((opened+1)); (( ab > 5 && bc < 3 )) && ok=$((ok+1))
  # the card glided its orb to the middle of the visible Map (sidebar 233 + the content's middle; under the 52 pt bar):
  # tap it there next round
  X=611; Y=464   # measured: GRAIN after the glide (window at 0,60, 1,350 × 840, sidebar + Librarian docked)
done
print -r -- "L4 Esc: $ok/$N cards closed by a real Esc with the pointer still ($opened rounds showed a card change on Esc)" | tee -a $OUT/matrix.txt
