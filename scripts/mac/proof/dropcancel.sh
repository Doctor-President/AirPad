#!/bin/zsh
# proof 6 bug fix — Cancel in the drop dialog ("Add the files to…") adds nothing. A REAL Finder drag of "Sweep Test Two.pdf"
# onto the open entry's note (two documents items → the dialog), then a real click on Cancel. Expect: the entry's items
# unchanged, no "Added …" note.   dropcancel.sh <pid> <out> <trial> <node id> <drop x y>
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; T=$3; NODE=$4; DX=$5; DY=$6; mkdir -p $O
DIR=$ROOT/build/runs/s1-proof2/dropfiles
items() { python3 $D/nodeitems.py $NODE | sed -E 's/ id=.*//' | tr '\n' '|'; }
i0=$(items)
osascript -e "tell application \"Finder\" to select {(POSIX file \"$DIR/Sweep Test Two.pdf\" as alias)}" >/dev/null; sleep 0.6
xy=($($ROOT/build/kit/rfinder icon dropfiles "Sweep Test Two.pdf"))
$ROOT/build/kit/rfinder drag $xy[1] $xy[2] $DX $DY $DX $((DY + 1)) 600 still >/dev/null
sleep 1.2; dlg=$($R has $P Cancel | cut -c1-3); [[ $T == 1 ]] && cap $P $O/t1-dialog.png
$R click $P Cancel >/dev/null; sleep 2.5
i1=$(items); nt=$($R has $P entryDropNote | cut -c1-3); [[ $T == 1 ]] && cap $P $O/t1-after.png
ok=$([[ $dlg == yes && $i1 == "$i0" && $nt == no ]] && echo PASS || echo FAIL)
print -r -- "t$T: dialog Cancel shown=[$dlg] · items before=[$i0] after=[$i1] · note=[$nt] → $ok" | tee -a $O/results.txt
