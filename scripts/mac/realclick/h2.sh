#!/bin/zsh
# E fix-up 3 · H2 — the inline format bar shows only while a note is being edited. Real clicks / keys (rclick) on the
# isolated copy (Debug: the note editor's AX id), Sample Library, List. Per path: open the first row, click into the
# note (the bar must show), take the path, then read whether the bar is still there.
#   h2.sh <isolated Debug .app> <out dir> [path …]   paths: title librarian-col esc back sidebar librarian toolbar-search
#   (the bar goes) · bar-bold note-again (the bar stays)
set -u
D=${0:A:h:h:h:h}/build/mac-e/fixup3; mkdir -p $D
for t in rclick; do [[ $D/$t -nt ${0:A:h}/$t.swift ]] || swiftc -O -o $D/$t ${0:A:h}/$t.swift 2>/dev/null; done
APP=${1:?app}; OUT=${2:?out}; shift 2; mkdir -p $OUT
R=$D/rclick
# First-run callouts take the next click (any tap dismisses them) and hide the rest from Accessibility: marked shown,
# as on any library that has been used.
PREF=~/Library/Containers/com.doctorpresident.airpad.macA/Data/Library/Preferences/com.doctorpresident.airpad.macA
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do
  defaults write $PREF com.airpad.callouts.$k -bool true
done
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -MacLibrarian open -MacSidebar on ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 12; $R winmove $P 0 160 >/dev/null; $R click $P sidebar.sample >/dev/null; sleep 2
bar() { [[ $($R has $P inlineBar.style) == yes* ]] && print up || print gone }
: > $OUT/matrix.txt
DEF="title librarian-col esc back sidebar librarian toolbar-search bar-bold note-again"; for pth in ${@:-${=DEF}}; do
  [[ $($R has $P toolbar.view.List) == yes* ]] || { $R click $P sidebar.sample >/dev/null; sleep 2 }
  $R click $P toolbar.view.List >/dev/null; sleep 1.5
  $R click $P 'listRow-*' >/dev/null; sleep 2.5
  $R click $P toolbar.title >/dev/null; sleep 0.8          # a first-run callout over the entry takes this click
  ce=$($R click $P noteEditor); sleep 1
  b0=$(bar)
  [[ $b0 == up ]] || { print -r -- "  setup: $ce · title $($R get $P toolbar.title AXDescription) · back $($R get $P toolbar.back AXEnabled)"; screencapture -x -R$($R winpos $P | tr -d '()' | awk -F'[, ×]' '{print $1","$2","$3","$4}') $OUT/setup-$pth.png }
  case $pth in
    title)          $R click $P toolbar.title ;;
    librarian-col)  $R click $P macLibrarianColumn ;;
    esc)            $R key $P 53 ;;
    back)           $R click $P toolbar.back ;;
    sidebar)        $R click $P sidebar.today ;;
    librarian)      $R click $P toolbar.librarian ;;
    toolbar-search) $R click $P toolbar.search ;;
    bar-bold)       $R click $P bold ;;          # stays: a press on the bar is part of the editing
    note-again)     $R click $P noteEditor ;;    # stays
  esac > /dev/null
  sleep 1.2
  b1=$(bar)
  want=gone; [[ $pth == bar-bold || $pth == note-again ]] && want=up
  ok=$([[ $b0 == up && $b1 == $want ]] && print PASS || print FAIL)
  print -r -- "$ok $pth — bar after the click into the note: $b0 · after the path: $b1" | tee -a $OUT/matrix.txt
  # reset: leave the entry, Librarian open again
  $R key $P 53 >/dev/null; [[ $($R get $P toolbar.back AXEnabled) == 1 ]] && $R click $P toolbar.back >/dev/null
  [[ $($R get $P toolbar.librarian AXValue) == Closed ]] && $R click $P toolbar.librarian >/dev/null
  sleep 1
done
print -r -- "SUMMARY $(grep -c ^PASS $OUT/matrix.txt) pass · $(grep -c ^FAIL $OUT/matrix.txt) fail" | tee -a $OUT/matrix.txt
