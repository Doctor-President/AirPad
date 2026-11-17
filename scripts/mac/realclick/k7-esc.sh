#!/bin/zsh
# E fix-up 4 · K7 — Esc closes the Map's preview card (View › Close Preview), with REAL events: a real click on an orb
# (the Sample Map's baked layout: "GRAIN" near the middle) opens the card, a real Esc key closes it. N rounds.
#   k7-esc.sh <isolated .app> <out> [rounds=5]
set -u
B=${0:A:h:h:h}/../build/mac-e; B=${B:A}; R=$B/fixup3/rclick
APP=${1:?app}; OUT=${2:?out}; N=${3:-5}; mkdir -p $OUT
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 13; $R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null
[[ $($R has $P sidebar.today) == no ]] && $R click $P toolbar.sidebar >/dev/null
$R click $P sidebar.sample >/dev/null; sleep 1.5; $R click $P toolbar.view.Map >/dev/null; sleep 4
# Judged by PIXELS over the card's area (the card's view stays in the Accessibility tree after it closes, so "has
# mapCard" kept reading yes: fix-up 3's "Esc FAIL" read it). Card shown = the area differs from the no-card frame by
# > 12/255 on average; closed = back within 4/255.
RG=400,230,410,585
d() { python3 -c "
from PIL import Image, ImageChops, ImageStat; import sys
a=Image.open(sys.argv[1]).convert('RGB'); b=Image.open(sys.argv[2]).convert('RGB')
print(round(sum(ImageStat.Stat(ImageChops.difference(a,b)).mean)/3,1))" $1 $2 }
ok=0
for i in $(seq 1 $N); do
  $R hover $P toolbar.title >/dev/null; sleep 0.8; screencapture -x -R$RG $OUT/r$i-0.png
  $R clickat $P 616 362 >/dev/null; sleep 1.5; screencapture -x -R$RG $OUT/r$i-1.png
  $R hover $P toolbar.title >/dev/null; sleep 0.3
  $R key $P 53 >/dev/null; sleep 1.2; screencapture -x -R$RG $OUT/r$i-2.png
  o=$(d $OUT/r$i-0.png $OUT/r$i-1.png); c=$(d $OUT/r$i-0.png $OUT/r$i-2.png)
  print -r -- "round $i: card shown Δ$o · after Esc Δ$c" | tee -a $OUT/matrix.txt
  (( o > 12 && c < 4 )) && ok=$((ok+1))
done
print -r -- "K7 Esc: $ok/$N cards closed by a real Esc" | tee -a $OUT/matrix.txt
