#!/bin/zsh
# sweep-1 diag · lost drop on a documents item's lower area. For each named point: a REAL Finder drag of
# "Sweep Test Two.pdf" hovering at (x,y), then released there. Records: the app.log [DropDiag]/[EntryDrop] lines that
# appeared, the entry-drop note, the stored items (nodeitems.py), the AX element under the point MID-DRAG (axat, +2.0 s)
# and a mid-drag still (+1.9 s). If the PDF was added, the note's Undo (real click) takes it back.
#   dropdiag.sh <pid> <out> <app.log> <node id> <tag:x:y> [<tag:x:y> …]
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; LOG=$3; NODE=$4; shift 4; mkdir -p $O; AXAT=$ROOT/build/runs/s1-diag-run/axat
items() { python3 $D/nodeitems.py $NODE | tr '\n' ';'; }
for spec in "$@"; do
  T=${spec%%:*}; r=${spec#*:}; X=${r%%:*}; Y=${r#*:}
  n0=$(wc -l < $LOG); b=$(items)
  osascript -e "tell application \"Finder\" to select {(POSIX file \"$ROOT/build/runs/s1-proof2/dropfiles/Sweep Test Two.pdf\" as alias)}" >/dev/null; sleep 0.6
  xy=($($ROOT/build/kit/rfinder icon dropfiles "Sweep Test Two.pdf"))
  (sleep 1.9; screencapture -x -R0,60,1350,840 $O/$T-mid.png; $AXAT $P $X $Y 7 > $O/$T-ax.txt 2>&1) &
  $ROOT/build/kit/rfinder drag $xy[1] $xy[2] $X $Y $X $((Y + 1)) 600 still > $O/$T-drag.txt
  sleep 1.5; dlg=""; if [[ $($R has $P action-button--996) == yes* ]]; then dlg="dialog:[$($R get $P action-button--999 AXTitle)|$($R get $P action-button--998 AXTitle)|…] picked first; "; cap $P $O/$T-dialog.png; $R click $P action-button--999 >/dev/null; sleep 1.5; fi
  note=$($R has $P entryDropNote); a=$(items); wait
  sed -n "$((n0 + 1)),\$p" $LOG | grep -E "DropDiag|EntryDrop" | sed -E 's/^.*\] //' > $O/$T-diag.txt
  added=$([[ $a != $b ]] && echo yes || echo no)
  if [[ $added == yes ]]; then $R click $P entryDropNoteUndo >/dev/null; sleep 1.5; fi
  print -r -- "== $T ($X,$Y) · added=$added · ${dlg}note=[$note]" | tee -a $O/results.txt
  print -r -- "   diag: $(tr '\n' '|' < $O/$T-diag.txt)" | tee -a $O/results.txt
  print -r -- "   ax:   $(head -3 $O/$T-ax.txt | tr '\n' '|')" | tee -a $O/results.txt
  print -r -- "   after=[$a] restored=[$(items)]" >> $O/results.txt
  sleep 1
done
