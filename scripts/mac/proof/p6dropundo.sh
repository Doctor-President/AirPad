#!/bin/zsh
# proof 6 · 3 (4daf9147) — the drop note's Undo takes back exactly that drop. Entry "Round trip" scrolled to its top:
# a REAL Finder drag of "Sweep Test Two.pdf" onto the note (→ "Add the files to…" → Documents), then within the note's
# 6 s ONE other undoable action (click at the end of the note's last line, type " zq"), then a real click on the note's
# Undo. Expect: the PDF gone from Documents, " zq" still in the note. Cleanup: three Backspaces at the line end.
#   p6dropundo.sh <pid> <out> <trial> <node id> <drop x y> <text-end x y>
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; T=$3; NODE=$4; DX=$5; DY=$6; TX=$7; TY=$8; mkdir -p $O
log() { print -r -- "$*" | tee -a $O/results.txt; }
docs() { python3 $D/nodeitems.py $NODE | grep "'Documents' docs" | sed -E 's/.*docs=\[([^]]*)\].*/\1/'; }
note() { $ROOT/build/runs/s1-proof/axtext $P | grep AXTextArea | head -1 | sed -E 's/.*val=\[(.*)\] · focused.*/\1/' | sed -E 's/.*\\n//'; }
DIR=$ROOT/build/runs/s1-proof2/dropfiles
d0=$(docs); n0=$(note)
osascript -e "tell application \"Finder\" to select {(POSIX file \"$DIR/Sweep Test Two.pdf\" as alias)}" >/dev/null; sleep 0.6
xy=($($ROOT/build/kit/rfinder icon dropfiles "Sweep Test Two.pdf"))
$ROOT/build/kit/rfinder drag $xy[1] $xy[2] $DX $DY $DX $((DY + 1)) 600 still >/dev/null
sleep 1.2; dlg=$($R get $P action-button--999 AXTitle 2>/dev/null)
$R click $P action-button--999 >/dev/null; t0=$EPOCHREALTIME; sleep 0.6
nt=$($R has $P entryDropNote | cut -c1-3)
$R clickat $P $TX $TY >/dev/null; sleep 0.3; $R type $P " zq" >/dev/null; sleep 0.4
d1=$(docs); n1=$(note); nt2=$($R has $P entryDropNote | cut -c1-3)
[[ $T == 1 ]] && cap $P $O/t1-before-undo.png
uc=$($R click $P entryDropNoteUndo 2>&1 | cut -c1-60); t1=$EPOCHREALTIME; sleep 2; [[ $(docs) != "$d0" ]] && sleep 3
d2=$(docs); n2=$(note); [[ $T == 1 ]] && cap $P $O/t1-after-undo.png
ok=$([[ $dlg == Documents && $d1 != "$d0" && $n1 == *zq && $d2 == "$d0" && $n2 == *zq ]] && echo PASS || echo FAIL)
log "t$T: docs=[$d0] last line=[$n0] · drop → dialog first=[$dlg] → Documents · note=$nt · typed → docs=[$d1] line=[$n1] note still=$nt2 · Undo [$uc] (+$(( (t1 - t0) )) s) → docs=[$d2] line=[$n2] → $ok"
# cleanup: the typing
$R clickat $P $TX $TY >/dev/null; sleep 0.3; for k in 1 2 3; do $R key $P 51 >/dev/null; done; sleep 0.8
log "   cleanup: line=[$(note)] docs=[$(docs)]"
