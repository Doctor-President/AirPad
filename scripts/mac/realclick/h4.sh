#!/bin/zsh
# E fix-up 3 · H4 — Settings as the right slide-out, by real clicks / keys (rclick) on the isolated copy.
#   h4.sh <isolated .app> <out dir>
set -u
D=${0:A:h:h:h:h}/build/mac-e/fixup3; mkdir -p $D
[[ $D/rclick -nt ${0:A:h}/rclick.swift ]] || swiftc -O -o $D/rclick ${0:A:h}/rclick.swift 2>/dev/null
APP=${1:?app}; OUT=${2:?out}; mkdir -p $OUT
R=$D/rclick
PREF=~/Library/Containers/com.doctorpresident.airpad.macA/Data/Library/Preferences/com.doctorpresident.airpad.macA
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
defaults delete $PREF mac.layout.settingsWidth.v1 2>/dev/null
caffeinate -d -u -w $$ &
launch() { $APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES ${=EXTRA:-} >> $OUT/app.log 2>&1 & P=$!; sleep 12; $R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null; [[ $($R has $P sidebar.today) == no ]] && $R click $P toolbar.sidebar >/dev/null; $R click $P sidebar.sample >/dev/null; sleep 1.5 }
trap 'kill $P 2>/dev/null' EXIT
PASS=0; FAIL=0; : > $OUT/matrix.txt
row() { if [[ $1 == 1 ]]; then PASS=$((PASS+1)); s=PASS; else FAIL=$((FAIL+1)); s=FAIL; fi; print -r -- "$s $2 — $3" | tee -a $OUT/matrix.txt }
gear() { $R get $P sidebar.settings AXValue }
lib()  { $R get $P toolbar.librarian AXValue }
col()  { [[ $($R has $P macLibrarianColumn) == yes* ]] && print shown || print gone }
panelx() { $R find $P resize.settings | tr -d '()' | awk -F'[, ×]' '{print $1 + $3/2}' }
launch
[[ $(lib) == Closed ]] && { $R click $P toolbar.librarian >/dev/null; sleep 1 }
$R click $P toolbar.view.Map >/dev/null; sleep 2
# Open: ⌘, (real key events)
g0=$(gear); $R cmdkey $P 43 >/dev/null; sleep 1.2
row $([[ $g0 == Closed && $(gear) == Open && $(col) == gone && $(lib) == Closed ]] && echo 1 || echo 0) "⌘, opens Settings in the Librarian's slot" "gear $g0 → $(gear) · Librarian column $(col) · toolbar Librarian $(lib)"
screencapture -x -R0,60,1350,840 $OUT/home.png
# Every section pushes and comes back with ‹
for sec in Library Tags Models "Web search" Librarian Appearance Privacy "Support AirPad" About; do
  sentinel=settingsRow.Privacy; [[ $sec == Privacy ]] && sentinel=settingsRow.Tags
  h0=$($R has $P $sentinel); $R click $P "settingsRow.$sec" >/dev/null; sleep 1.3; h1=$($R has $P $sentinel)
  $R click $P BackButton >/dev/null; sleep 1.2; h2=$($R has $P $sentinel)   # the nav bar ‹ (AX id BackButton)
  row $([[ $h0 == yes* && $h1 == no && $h2 == yes* ]] && echo 1 || echo 0) "section $sec opens in the panel, ‹ back to its home" "home rows ${h0%% *} → ${h1%% *} → ${h2%% *}"
done
# Done closes, the Librarian (open before) comes back
$R click $P Done >/dev/null; sleep 1.2
row $([[ $(gear) == Closed && $(col) == shown && $(lib) == Open ]] && echo 1 || echo 0) "Done closes it; the Librarian (open before) is back" "gear $(gear) · column $(col) · toolbar $(lib)"
# The gear opens it; the gear again closes it
$R click $P sidebar.settings >/dev/null; sleep 1.2; a=$(gear); $R click $P sidebar.settings >/dev/null; sleep 1.2; b=$(gear)
row $([[ $a == Open && $b == Closed && $(col) == shown ]] && echo 1 || echo 0) "the sidebar gear opens it, again closes it" "gear → $a → $b · column $(col)"
# With the Librarian closed: Settings, then Done → the Librarian stays closed
$R click $P toolbar.librarian >/dev/null; sleep 1; $R click $P sidebar.settings >/dev/null; sleep 1.2; $R click $P Done >/dev/null; sleep 1.2
row $([[ $(gear) == Closed && $(col) == gone && $(lib) == Closed ]] && echo 1 || echo 0) "Librarian closed before → stays closed after Settings" "gear $(gear) · column $(col) · toolbar $(lib)"
# The Librarian button while Settings is open: Settings goes, the Librarian shows
# (the pointer rests 0.5 s on the button first: a press within ~0.1 s of arriving, right after Settings opened, is H1's
# lost click — the mouse-down never becomes a touch — and that row is H1's, not this one's)
$R click $P sidebar.settings >/dev/null; sleep 1.2; $R hover $P toolbar.librarian >/dev/null; sleep 0.5; $R click $P toolbar.librarian >/dev/null; sleep 1.2
row $([[ $(gear) == Closed && $(col) == shown && $(lib) == Open ]] && echo 1 || echo 0) "the toolbar's Librarian button with Settings open shows the Librarian" "gear $(gear) · column $(col) · toolbar $(lib)"
# AirPad › Settings… (the menu; pressed through Accessibility)
$R menu $P AirPad "Settings" >/dev/null; sleep 1.2
row $([[ $(gear) == Open ]] && echo 1 || echo 0) "AirPad › Settings… opens it" "gear $(gear)"
# Resize: the slot's edge, real drags to the limits (300 … 520), remembered after a relaunch
wr=$($R winpos $P | tr -d '()' | awk -F'[, ×]' '{print $1 + $3}')
x0=$(panelx); w0=$(( wr - x0 )); $R drag $P $x0 300 -260 0 >/dev/null; sleep 1; x1=$(panelx); w1=$(( wr - x1 ))
screencapture -x -R0,60,1350,840 $OUT/width-max.png
$R drag $P $x1 300 400 0 >/dev/null; sleep 1; x2=$(panelx); w2=$(( wr - x2 ))
screencapture -x -R0,60,1350,840 $OUT/width-min.png
row $([[ $w0 -ge 415 && $w0 -le 425 && $w1 -ge 516 && $w1 -le 528 && $w2 -ge 296 && $w2 -le 306 ]] && echo 1 || echo 0) "drag the edge: wider to 520, narrower to 300 (default 420)" "width $w0 → $w1 → $w2"
$R drag $P $x2 300 -80 0 >/dev/null; sleep 1; x3=$(panelx); w3=$(( wr - x3 ))
kill $P; sleep 2; launch
$R click $P sidebar.settings >/dev/null; sleep 1.2; x4=$(panelx); w4=$(( wr - x4 ))
row $([[ $w4 == $w3 ]] && echo 1 || echo 0) "its width is remembered after a relaunch (the Librarian's isn't touched)" "set $w3 → after relaunch $w4"
print -r -- "SUMMARY $PASS pass · $FAIL fail" | tee -a $OUT/matrix.txt
