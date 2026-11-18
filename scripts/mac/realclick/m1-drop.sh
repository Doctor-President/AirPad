#!/bin/zsh
# E fix-up 6 · M1 — the drop highlight left on after a drag that ends elsewhere. REAL drags out of Finder
# (rfinder): over AirPad, then dropped on another app (Finder folder, a TextEdit document), dragged back to the
# source, Esc mid-drag, a fast exit. A still mid-drag (positive control: the outline must show) and 2 s after the
# release (must be gone). The outline = the accent stroke 4 pt in from the window's left edge.
#   m1-drop.sh <pid> <out> [rounds=3]       (AirPad at 0,60 1100×840; Finder m1src/m1dst + TextEdit m1target.rtf placed)
set -u
B=${0:A:h:h:h:h}/build/mac-e/fixup6; R=$B/rfinder; P=${1:?pid}; OUT=${2:?out}; N=${3:-3}; mkdir -p $OUT
SRC=/private/tmp/claude-501/-Users-thomasjurgensen-Developer/640217fa-a318-402a-bde6-411d88513a1a/scratchpad
edge() { python3 -c "
from PIL import Image; im=Image.open('$1').convert('RGB'); p=[im.getpixel((x,800)) for x in (9,10,11)]
print('ON' if any(b-r>90 for r,g,b in p) else 'off')"; }
reset() { mv $SRC/m1dst/droptest.png $SRC/m1src/ 2>/dev/null; true; }
trial() {   # trial <label> <rfinder drag args after the source point…>
  local lab=$1; shift; reset; sleep 0.6
  local ic=($($R icon m1src droptest.png)); [[ ${#ic} != 2 ]] && { echo "$lab no icon"; return }
  ($R drag $ic[1] $ic[2] "$@" > /dev/null &); sleep 1.75
  screencapture -x -R0,60,1100,840 $OUT/$lab-mid.png; sleep 3.2
  screencapture -x -R0,60,1100,840 $OUT/$lab-after.png
  local after=$(edge $OUT/$lab-after.png) held=""
  if [[ $after == ON ]]; then sleep 10; screencapture -x -R0,60,1100,840 $OUT/$lab-10s.png; held=" 10s-later $(edge $OUT/$lab-10s.png)"; fi
  echo "$lab mid $(edge $OUT/$lab-mid.png) after $after$held" | tee -a $OUT/results.txt
}
if [[ ${OVERLAP:-} == 1 ]]; then   # TextEdit's window sits ON TOP of AirPad's right side (T's Claude window over AirPad)
  RF_BID=com.apple.TextEdit $R place m1target.rtf 800 600 500 300 > /dev/null
  for i in $(seq 1 $N); do
    trial o$i-over     450 500  1000 800 600          # out of AirPad straight into the window on top of it
    trial o$i-overfast 450 500  1000 800 600 fast
  done
  RF_BID=com.apple.TextEdit $R place m1target.rtf 1120 760 600 300 > /dev/null; reset; grep -c "after ON" $OUT/results.txt; exit
fi
for i in $(seq 1 $N); do
  trial r$i-finder   550 500  1620 600 600            # dropped into another Finder folder
  trial r$i-textedit 550 500  1500 900 600            # dropped into a TextEdit document
  trial r$i-back     550 500  1513 168 600            # dragged over and back to the source
  trial r$i-reject   550 500  1500 830 600            # dropped where nothing takes it (TextEdit's ruler): slides back
  trial r$i-esc      550 500  1620 600 600 esc        # Esc held over AirPad, then out
  trial r$i-fast     550 500  1500 900 600 fast       # a fast exit straight into TextEdit
  trial r$i-edge     1050 500 1500 900 600 fast       # entered at the right edge, fast out
done
reset; grep -c "after ON" $OUT/results.txt
