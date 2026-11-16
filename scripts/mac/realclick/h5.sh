#!/bin/zsh
# E fix-up 3 · H5 — the Map card by real scroll events (rscroll) and keys/clicks (rclick). Per row: open GRAIN's card with a
# real click on its orb, then the path; read whether the card is still up (AX "mapCard.close") and keep a still.
D=${0:A:h:h:h:h}/build/mac-e/fixup3; cd $D; source ${0:A:h}/h5-open.sh  # run from the build dir (rclick, rscroll, h5-debug there)
OUT=${1:?out}; mkdir -p $OUT; : > $OUT/matrix.txt
start; $R click $P toolbar.view.Map >/dev/null; sleep 4
PASS=0; FAIL=0
up() { [[ $($R has $P mapCard) == yes* ]] && print up || print gone }
# the card sits centred on its orb; opening glides the Map, so the orb stays where the card was: reopen there
OX=618; OY=361
cardc() { $R find $P mapCard | tr -d '()' | awk -F'[, ×]' '{print int($1+$3/2) - 184, int($2+$4/2) + 269}' }   # AX frame = the X corner
open_card() { [[ $(up) == up ]] && { $R click $P mapCard >/dev/null; sleep 1 }
  for try in 1 2 3; do $R clickat $P $OX $OY >/dev/null; sleep 2; [[ $(up) == up ]] && break; sleep 2; done
  [[ $(up) == up ]] && { c=($(cardc)); OX=$c[1]; OY=$c[2] } }
for row in ${=ROWS:-"trackpad-down-300:gone" "trackpad-down-60:up" "trackpad-up-300:up" "wheel-down-8:up" "wheel-up-8:up" "esc:gone" "click-map:gone" "trackpad-down-fast-150:gone" "menu-close:gone"}; do
  name=${row%%:*}; want=${row##*:}
  open_card; b=$(up)
  case $name in
    trackpad-down-300) ./rscroll $OX $OY trackpad 300 20 ;;
    trackpad-down-60)  ./rscroll $OX $OY trackpad 60 8 ;;
    trackpad-up-300)   ./rscroll $OX $OY trackpad -300 20 ;;
    wheel-down-8)      ./rscroll $OX $OY wheel 8 ;;
    wheel-up-8)        ./rscroll $OX $OY wheel -8 ;;
    esc)               $R key $P 53 ;;
    click-map)         screencapture -x -R0,60,1350,840 $OUT/pre-click.png; $R clickat $P $(python3 ${0:A:h}/emptyspot.py $OUT/pre-click.png $OX $OY) ;;
    menu-close)        $R menu $P View "Close Preview" ;;
    trackpad-down-fast-150) ./rscroll $OX $OY trackpad 150 5 8 ;;
  esac > /dev/null
  sleep 1.2; a=$(up)
  ok=$([[ $b == up && $a == $want ]] && print PASS || print FAIL); [[ $ok == PASS ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  print -r -- "$ok $name — card before: $b · after: $a (want $want)" | tee -a $OUT/matrix.txt
  screencapture -x -R0,60,1350,840 $OUT/$name.png
done
kill $P
print -r -- "SUMMARY $PASS pass · $FAIL fail" | tee -a $OUT/matrix.txt
