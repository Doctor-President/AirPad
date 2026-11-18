#!/bin/zsh
# E fix-up 6 · M8 — the Librarian panel in Ask vs Search (toolbar Search, real typing), light + dark, docked + floating;
# Esc leaves search. Stills + whether the "Search · query" header is up.   m8-search.sh <build dir under fixup6> <out>
set -u
B=${0:A:h:h:h:h}/build/mac-e/fixup6; RC=${0:A:h:h:h:h}/build/mac-e/fixup4/rclick; OUT=${2:?out}; mkdir -p $OUT
for look in light dark; do
  export EXTRA=$([[ $look == dark ]] && echo "-appearance.override dark" || echo "-appearance.override light"); P=$($B/launch.sh $1 $OUT)
  $RC winsize $P 1350 840 > /dev/null; sleep 1; $RC click $P sidebar.library > /dev/null; sleep 1.5
  [[ $($RC get $P toolbar.librarian AXValue) != Open ]] && { $RC click $P toolbar.librarian > /dev/null; sleep 1.5; }
  for place in a b; do
    tag=$look-$([[ $place == a ]] && echo first || echo switched)   # the float switch flips docked ↔ floating
    screencapture -x -R0,60,1350,840 $OUT/$tag-1-ask.png
    $RC click $P toolbar.search > /dev/null; sleep 0.5; $RC type $P video > /dev/null; sleep 2
    screencapture -x -R0,60,1350,840 $OUT/$tag-2-search.png
    echo "$tag search header: $($RC has $P macLibrarianSearchTitle)" | tee -a $OUT/steps.txt
    $RC key $P 53 > /dev/null; sleep 1.5
    screencapture -x -R0,60,1350,840 $OUT/$tag-3-esc.png
    echo "$tag after Esc header: $($RC has $P macLibrarianSearchTitle)" | tee -a $OUT/steps.txt
    $RC click $P macPanelFloatSwitch > /dev/null; sleep 1.5
  done
done
