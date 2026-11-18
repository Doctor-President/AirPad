#!/bin/zsh
# E fix-up 6 · M6 — drop into an existing item, REAL drags out of Finder onto an open entry (a one-video gallery at
# the top; AirPad at 0,60 1100×840, Librarian closed). Each path: a still mid-drag (the highlight / line / outline),
# a still after, the app's [EntryDrop] line.   m6-drop.sh <pid> <out>   (Finder m1src holds droptest.png + .pdf)
set -u
B=${0:A:h:h:h:h}/build/mac-e/fixup6; R=$B/rfinder; RC=${0:A:h:h:h:h}/build/mac-e/fixup4/rclick; X=$B/rraw
P=${1:?pid}; OUT=${2:?out}; mkdir -p $OUT; LOG=${LOG:-$B/m6/app.log}
ITEM=${ITEM:?ITEM=<gallery item id>}
pos() {   # the gallery's frame now (DEBUG marker) → GAL (its middle), GAP (just below it), ELSE (the header above it)
  local f=$($RC find $P entryDropItem-$ITEM); f=${f//[(),×]/ }; local a=(${=f})
  GAL=($((a[1]+a[3]/2)) $((a[2]+a[4]/2))); GAP=($((a[1]+a[3]/2)) $((a[2]+a[4]+${GAPOFF:-6}))); ELSE=($((a[1]+120)) $((a[2]-110)))
  local g=$($RC find $P entryDropGapZone-${GAPINDEX:-1}); g=${g//[(),×]/ }; local b=(${=g})
  [[ ${#b} == 4 ]] && GAP=($((b[1]+b[3]/2)) $((b[2]+b[4]/2)))
  echo "  gallery $a gap $b → GAL $GAL GAP $GAP ELSE $ELSE" >> $OUT/steps.txt
}
n=0
shot() { n=$((n+1)); screencapture -x -R0,60,1100,840 $OUT/$(printf %02d $n)-$1.png; }
lastlog() { grep "\[EntryDrop\]" $LOG | tail -1 | sed 's/.*\[EntryDrop\]/[EntryDrop]/'; }
trial() {   # trial <label> <file> <x> <y> [still]
  local lab=$1 f=$2 x=$3 y=$4; local before=$(grep -c "\[EntryDrop\]" $LOG)
  local ic=($($R icon m1src $f)); [[ -z ${MULTI:-} ]] && { $X 1700 430 > /dev/null; sleep 0.4; $X 1700 430 > /dev/null; sleep 0.4; $X $ic[1] $ic[2] > /dev/null; sleep 0.5; }   # select just this file
  ($R drag $ic[1] $ic[2] $x $y $x $((y+2)) 600 ${5:-} > /dev/null &); sleep 1.9; shot $lab-mid; sleep 3.5; shot $lab-after
  local now=$(grep -c "\[EntryDrop\]" $LOG); echo "$lab · $([[ $now -gt $before ]] && lastlog || echo 'no EntryDrop line (window drop: new item at the end)')" | tee -a $OUT/steps.txt
}
pos; trial into-gallery droptest.png $GAL
$RC cmdkey $P 6 > /dev/null; sleep 2.5; shot undo; echo "undo · ⌘Z" | tee -a $OUT/steps.txt
pos; trial gap-below droptest.png $GAP still
pos; trial elsewhere droptest.png $ELSE
# mixed: select the PNG and the PDF in Finder (click, ⌘-click), drag them together onto the gallery
pi=($($R icon m1src droptest.png)); di=($($R icon m1src droptest.pdf))
$X $pi[1] $pi[2] > /dev/null; sleep 0.4
swift -e "import CoreGraphics; let s = CGEventSource(stateID: .hidSystemState); func k(_ d: Bool) { let e = CGEvent(keyboardEventSource: s, virtualKey: 55, keyDown: d); e?.flags = d ? .maskCommand : []; e?.post(tap: .cghidEventTap) }; k(true); usleep(80000); for t in [CGEventType.leftMouseDown, .leftMouseUp] { let e = CGEvent(mouseEventSource: s, mouseType: t, mouseCursorPosition: CGPoint(x: $di[1], y: $di[2]), mouseButton: .left); e?.flags = .maskCommand; e?.post(tap: .cghidEventTap); usleep(60000) }; k(false)"
sleep 0.5; pos; MULTI=1 trial mixed-onto-gallery droptest.pdf $GAL
swift ${0:A:h}/mods.swift 2>/dev/null | tail -1 >> $OUT/steps.txt
