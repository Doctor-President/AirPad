#!/bin/zsh
# Mac E fix-up 2 — the toolbar by REAL clicks (window-server CGEvents from rclick), effects read through Accessibility.
#   [EXTRA="-Arg value"] matrix.sh <isolated .app> <out_dir>   (Release or Debug; needs Accessibility for Terminal; Mac unlocked)
# Holds caffeinate only while it runs. Prints one PASS/FAIL row per control + a summary line.
set -u
APP=${1:?app}; OUT=${2:?out}; mkdir -p $OUT
R=${0:A:h:h:h:h}/build/mac-e/fixup2/rclick
X=${R:h}/axids
[[ -x $R ]] || swiftc -O -o $R ${0:A:h}/rclick.swift || exit 2
[[ -x $X ]] || swiftc -O -o $X ${0:A:h}/axids.swift || exit 2
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 12
PASS=0; FAIL=0; : > $OUT/matrix.txt
row() { # row <ok 0/1> <name> <detail>
  if [[ $1 == 1 ]]; then PASS=$((PASS+1)); s=PASS; else FAIL=$((FAIL+1)); s=FAIL; fi
  print -r -- "$s $2 — $3" | tee -a $OUT/matrix.txt
}
title() { $R get $P toolbar.title AXDescription }
sel()   { $R get $P toolbar.view.$1 AXSelected }
click() { $R click $P "$@" >> $OUT/clicks.log }
print -r -- "INFO method: CGEvent mouse moved/down/up posted at .cghidEventTap (window server) at the AX frame's centre; effects read via AXUIElement · app $APP · pid $P · window $($R winpos $P)" | tee -a $OUT/matrix.txt

# Positive control (content, not toolbar): two sidebar rows build history.
click sidebar.recents; sleep 1; click sidebar.sample; sleep 1.5
t=$(title); row $([[ $t == "Sample Library" ]] && echo 1 || echo 0) "CONTROL sidebar row (content) → Sample Library" "title '$t'"

# Every row needs a CHANGE: the state before must differ from the wanted state (else a dead control "passes").
# The view switch: a view already on (the place remembers its view) is skipped, not counted.
for v in Map Cards List Map List; do
  s0=$(sel $v); if [[ $s0 == 1 ]]; then print -r -- "INFO view switch $v already on: skipped" | tee -a $OUT/matrix.txt; continue; fi
  click toolbar.view.$v; sleep 1.2; s=$(sel $v)
  row $([[ $s == 1 ]] && echo 1 || echo 0) "view switch $v" "AXSelected $s0 → $s"
done

h0=$($R has $P sidebar.today); click toolbar.sidebar; sleep 1; h=$($R has $P sidebar.today)
row $([[ $h0 == yes* && $h == no ]] && echo 1 || echo 0) "sidebar button (hide)" "sidebar shown ${h0%% *} → ${h%% *}"
h0=$h; click toolbar.sidebar; sleep 1; h=$($R has $P sidebar.today)
row $([[ $h0 == no && $h == yes* ]] && echo 1 || echo 0) "sidebar button (show)" "sidebar shown ${h0%% *} → ${h%% *}"

l0=$($R get $P toolbar.librarian AXValue); click toolbar.librarian; sleep 1.2; l1=$($R get $P toolbar.librarian AXValue)
row $([[ $l0 != $l1 ]] && echo 1 || echo 0) "Librarian button (toggle 1)" "value $l0 → $l1"
click toolbar.librarian; sleep 1.2; l2=$($R get $P toolbar.librarian AXValue)
row $([[ $l2 != $l1 ]] && echo 1 || echo 0) "Librarian button (toggle 2)" "value $l1 → $l2"

f0=$($R get $P toolbar.search AXFocused); click toolbar.search; sleep 0.8; f=$($R get $P toolbar.search AXFocused)
row $([[ $f0 == 0 && $f == 1 ]] && echo 1 || echo 0) "search field (click focuses)" "AXFocused $f0 → $f"
$R type $P film >> $OUT/clicks.log; sleep 0.8; v=$($R get $P toolbar.search AXValue)
row $([[ $v == film ]] && echo 1 || echo 0) "search field (typing lands)" "value '$v'"
$R key $P 53 >> $OUT/clicks.log; sleep 0.5

# Window drag from the empty bar (between the view switch and the search field).
w0=$($R winpos $P); sx=$($R find $P toolbar.search | tr -d '()' | cut -d, -f1); vy=$($R find $P toolbar.title | tr -d '()' | awk -F'[, ]' '{print $2}')
cx=$($R find $P toolbar.view.Cards | tr -d '()' | awk -F'[, ×]' '{print $1+$3}')
gx=$(( (cx + sx) / 2 )); gy=$(( vy + 9 ))
$R drag $P $gx $gy 60 40 >> $OUT/clicks.log; sleep 0.8; w1=$($R winpos $P)
row $([[ $w0 != $w1 ]] && echo 1 || echo 0) "window drag on the empty bar at ($gx,$gy) by (60,40)" "$w0 → $w1"
$R drag $P $((gx+60)) $((gy+40)) -60 -40 >> $OUT/clicks.log; sleep 0.8

# A press on a control that wanders 3 pt before release is still the control's, never a window drag.
w0=$($R winpos $P); m=$($R find $P toolbar.view.Map | tr -d '()' | awk -F'[, ×]' '{printf "%d %d", $1+$3/2, $2+$4/2}')
$R drag $P ${=m} 3 2 >> $OUT/clicks.log; sleep 0.8; w1=$($R winpos $P)
row $([[ $w0 == $w1 ]] && echo 1 || echo 0) "press on Map, 3 pt wander, release: the window stays" "$w0 → $w1"

# + New Entry: a new entry opens (Recents counts it; it goes on the place's NavigationStack, so ‹ lights up).
n0=$($R get $P sidebar.recents AXDescription); click toolbar.newEntry; sleep 2.5; n1=$($R get $P sidebar.recents AXDescription)
b1=$($R get $P toolbar.back AXEnabled)
row $([[ -n $n0 && $n0 != nil && $n0 != $n1 ]] && echo 1 || echo 0) "+ New Entry" "'$n0' → '$n1' · back enabled $b1"
# ‹ › follow that stack: back closes the entry (forward lights up), forward re-opens it.
click toolbar.back; sleep 2; b2=$($R get $P toolbar.back AXEnabled); f2=$($R get $P toolbar.forward AXEnabled)
row $([[ $b1 == 1 && $b2 == 0 && $f2 == 1 ]] && echo 1 || echo 0) "‹ back (closes the new entry)" "back $b1 → $b2 · forward → $f2"
click toolbar.forward; sleep 2; b3=$($R get $P toolbar.back AXEnabled); f3=$($R get $P toolbar.forward AXEnabled)
row $([[ $f2 == 1 && $b3 == 1 && $f3 == 0 ]] && echo 1 || echo 0) "› forward (re-opens it)" "forward $f2 → $f3 · back → $b3"
click toolbar.back; sleep 1.5

print -r -- "SUMMARY $PASS pass · $FAIL fail" | tee -a $OUT/matrix.txt
