#!/bin/zsh
# E fix-up 3 · H3 — the view switch is always whole: a collection with a long name, the window at 900…1,728 pt
# (this display's width), sidebar shown / hidden, Librarian open (docked or floating) / closed. Reads the three
# segments' and the search field's frames through Accessibility; a still per config.
#   h3.sh <isolated .app> <out dir>      (the scratch's last collection should have a long name)
#   LIBS="Settings" → the Settings panel in the slot instead of the Librarian open / closed
set -u
D=${0:A:h:h:h:h}/build/mac-e/fixup3; mkdir -p $D
[[ $D/rclick -nt ${0:A:h}/rclick.swift ]] || swiftc -O -o $D/rclick ${0:A:h}/rclick.swift 2>/dev/null
APP=${1:?app}; OUT=${2:?out}; mkdir -p $OUT/stills
R=$D/rclick
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 12; $R winmove $P 0 60 >/dev/null
$R press $P sidebar.collection last >/dev/null; sleep 2
print -r -- "title: $($R get $P toolbar.title AXDescription)" | tee $OUT/matrix.txt
fr() { $R find $P $1 | tr -d '()' | awk -F'[, ×]' '{print $1, $2, $3, $4}' }
PASS=0; FAIL=0
for sb in on off; do
  for lib in ${=LIBS:-Open Closed}; do
    for w in ${=WIDTHS:-900 950 1000 1100 1200 1350 1500 1728}; do
      $R winsize $P $w 840 >/dev/null
      cur=$($R has $P sidebar.today); { [[ $sb == on && $cur == no ]] || [[ $sb == off && $cur == yes* ]] } && { $R click $P toolbar.sidebar >/dev/null; sleep 0.8 }
      if [[ $lib == Settings ]]; then
        [[ $($R get $P sidebar.settings AXValue) == Open ]] || { $R click $P sidebar.settings >/dev/null; sleep 1 }
      else
        [[ $($R get $P toolbar.librarian AXValue) != $lib ]] && { $R click $P toolbar.librarian >/dev/null; sleep 0.8 }
      fi
      $R hover $P toolbar.title >/dev/null; sleep 0.8
      win=($(fr toolbar.title >/dev/null; $R winpos $P | tr -d '()' | awk -F'[, ×]' '{print $1, $2, $3, $4}'))
      m=($(fr toolbar.view.Map)); l=($(fr toolbar.view.List)); c=($(fr toolbar.view.Cards)); s=($(fr toolbar.search)); t=($(fr toolbar.title))
      floats=$([[ $lib == Open && $($R has $P macLibrarianColumn) == yes* ]] && print "" || print "")
      ok=1; why=""
      (( ${#m} == 4 && ${#l} == 4 && ${#c} == 4 )) || { ok=0; why="segment missing" }
      if (( ok )); then
        (( m[3] >= 48 && l[3] >= 43 && c[3] >= 56 )) || { ok=0; why="segment narrowed (truncated)" }
        (( c[1] + c[3] + 30 <= s[1] )) || { ok=0; why="Cards ends $(( c[1]+c[3] )), search starts $(( s[1] ))" }
        (( c[1] + c[3] <= win[1] + win[3] )) || { ok=0; why="off the window" }
      fi
      (( ok )) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
      print -r -- "$([[ $ok == 1 ]] && print PASS || print FAIL) w $w · sidebar $sb · Librarian ${(L)lib} · title w ${t[3]:-?} · switch ${m[1]:-?}–$(( ${c[1]:-0} + ${c[3]:-0} )) (Map ${m[3]:-?} List ${l[3]:-?} Cards ${c[3]:-?}) · search at ${s[1]:-?} ${why:+· $why}" | tee -a $OUT/matrix.txt
      screencapture -x -R${win[1]},${win[2]},${win[3]},90 $OUT/stills/bar-$w-sb$sb-lib${(L)lib}.png
    done
  done
done
print -r -- "SUMMARY $PASS pass · $FAIL fail" | tee -a $OUT/matrix.txt
