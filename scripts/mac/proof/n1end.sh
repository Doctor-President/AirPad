#!/bin/zsh
# sweep-1 proof 2 · N1 end gap — a real Finder drag of "Sweep Test Two.pdf" dropped 10 / 20 / 30 pt BELOW the open
# entry's last item (Round trip, scrolled to its end). Expect: the PDF is added (sorted into the Documents item), the note
# (entryDropNote) says so, and the note's Undo (real click) takes it back.   n1end.sh <pid> <out> <node id> <item bottom y DURING the drag (gaps above open)>; OFFS="10 20 30"
D=${0:A:h}; source $D/lib.sh; P=${1:?pid}; O=${2:?out}; NODE=${3:?node}; BOT=${4:?bottom}; mkdir -p $O; : > $O/results.txt
items() { python3 $D/nodeitems.py $NODE | tr '\n' ';'; }
i=0
for off in ${=OFFS:-10 20 30}; do
  i=$((i + 1)); b=$(items); xy=($($ROOT/build/kit/rfinder icon dropfiles "Sweep Test Two.pdf"))
  (sleep 1.9; screencapture -x -R0,60,1350,840 $O/t$i-mid.png) &
  $ROOT/build/kit/rfinder drag $xy[1] $xy[2] 600 $((BOT + off)) 600 $((BOT + off + 1)) 600 still >> $O/drag.txt
  sleep 1.2; a=$(items); note=$($R has $P entryDropNote); cap $P $O/t$i-after.png
  added=$([[ $a == *"Sweep Test Two.pdf"* && $b != *"Sweep Test Two.pdf"* ]] && echo yes || echo no)
  $R click $P entryDropNoteUndo >/dev/null; sleep 1.5; u=$(items)
  gone=$([[ $u != *"Sweep Test Two.pdf"* ]] && echo yes || echo no)
  ok=$([[ $added == yes && $note == yes* && $gone == yes ]] && echo PASS || echo FAIL)
  print -r -- "t$i drop ${off}pt below (y $((BOT + off))): added=$added note=[$note] after=[$a] · Undo → gone=$gone after-undo=[$u] → $ok" | tee -a $O/results.txt
  sleep 1
done
echo "PASS $(grep -c "PASS$" $O/results.txt)/$i" | tee -a $O/results.txt
