#!/bin/zsh
# H1 — run a step sequence, then test-click a view button; report whether that click landed. Repeats per case.
#   h1-seq.sh <app> <out> <reps> "<case>" …   case = steps separated by spaces:
#     c:<id> click · h:<id> hover · w:<s> wait · T:<View> test-click toolbar.view.<View> (needs a change)
#     S:<id>:<watch>:<attr> test-click <id>, watch <watch>.<attr> change
D=${0:A:h:h:h:h}/build/mac-e/fixup3; mkdir -p $D; for t in rclick rlat rframe; do [[ $D/$t -nt ${0:A:h}/$t.swift ]] || swiftc -O -o $D/$t ${0:A:h}/$t.swift 2>/dev/null; done; APP=${1:?app}; OUT=${2:?out}; N=${3:-3}; shift 3; mkdir -p $OUT
R=$D/rclick
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 12; $R winmove $P 0 160 >/dev/null; { [[ $($R has $P sidebar.today) == no ]] && { $R click $P toolbar.sidebar >/dev/null; sleep 1 } }; $R click $P sidebar.sample >/dev/null; sleep 2
for C in "$@"; do
  lost=0; tot=0
  for i in $(seq 1 $N); do
    for st in ${=C}; do
      k=${st%%:*}; v=${st#*:}
      case $k in
        c) $R click $P $v >/dev/null; sleep 0.6 ;;
        h) $R hover $P $v >/dev/null ;;
        w) sleep $v ;;
        R) $D/rlat $P $v wait 300 0 toolbar.librarian:toolbar.librarian:AXValue > /dev/null ;;
        B) cur=$($R has $P sidebar.today); { [[ $v == on && $cur == no ]] || [[ $v == off && $cur == yes* ]] } && { $R click $P toolbar.sidebar >/dev/null; sleep 0.8 }; $R hover $P toolbar.title >/dev/null; sleep 1 ;;
        L) cur=$($R get $P toolbar.librarian AXValue); [[ ${(L)cur} != $v ]] && { $R click $P toolbar.librarian >/dev/null; sleep 0.8 }; $R hover $P toolbar.title >/dev/null; sleep 1 ;;
        T) s0=$($R get $P toolbar.view.$v AXSelected); o=$($R click $P toolbar.view.$v); [[ $o == *NOT-FRONT* ]] && print -r -- "  $o"; sleep 1.2; s=$($R get $P toolbar.view.$v AXSelected)
           tot=$((tot+1)); [[ $s0 == 0 && $s != 1 ]] && lost=$((lost+1)); [[ $s0 == 1 ]] && print -r -- "  (no change possible: $v already on)" ;;
        S) a=(${(s/:/)v}); s0=$($R get $P $a[2] $a[3]); $R click $P $a[1] >/dev/null; sleep 1.2; s=$($R get $P $a[2] $a[3])
           tot=$((tot+1)); [[ $s0 == $s ]] && lost=$((lost+1)) ;;
      esac
    done
  done
  print -r -- "LOST $lost/$tot · $C" | tee -a $OUT/summary.txt
done
