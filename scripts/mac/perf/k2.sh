#!/bin/zsh
# E fix-up 4 · K2 — Settings › Appearance checkboxes on the Mac by REAL clicks: Fluted glass and Gravity, each clicked
# off then on again; does the checkbox flip, is it saved, do the cards lose the ribs? Stills of Cards with glass on / off.
#   k2.sh <isolated .app> <out dir>
set -u
B=${0:A:h:h:h:h}/build/mac-e; R=$B/fixup3/rclick; AX=$B/fixup4/axrole; SC=$B/fixup4/rscroll
APP=${1:?app}; OUT=${2:?out}; mkdir -p $OUT
C=~/Library/Containers/com.doctorpresident.airpad.macA/Data; PREF=$C/Library/Preferences/com.doctorpresident.airpad.macA
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
defaults delete $PREF appearance.flutedGlass 2>/dev/null
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 12; $R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null
[[ $($R has $P sidebar.today) == no ]] && $R click $P toolbar.sidebar >/dev/null
$R click $P sidebar.sample >/dev/null; sleep 1.5; $R click $P toolbar.view.Cards >/dev/null; sleep 2
shot() { screencapture -x -R0,60,1350,840 $OUT/$1.png }
$R click $P sidebar.settings >/dev/null; sleep 1.2; $R click $P settingsRow.Appearance >/dev/null; sleep 1.5
$SC 1150 500 trackpad -900 30 >/dev/null; sleep 1.2
val() { $AX $P AXCheckBox | grep "\[$1" | grep -o 'value [0-9]' | cut -c7 }
clk() { local L=$($AX $P AXCheckBox | grep "\[$1" | sed 's/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/'); set -- ${=L}; $R clickat $P $(( $1 + 9 )) $(( $2 + 9 )) >/dev/null; sleep 1.2 }
shot 1-glass-on
pass=0; tot=0
for name in "Fluted glass" Gravity; do
  for want in 0 1; do
    b=$(val $name); clk $name; a=$(val $name); tot=$((tot+1)); [[ $a == $want && $b != $a ]] && pass=$((pass+1))
    print -r -- "$name click: $b → $a (want $want) · saved glass $(defaults read $PREF appearance.flutedGlass 2>/dev/null || echo unset)" | tee -a $OUT/matrix.txt
    [[ $name == "Fluted glass" && $want == 0 ]] && shot 2-glass-off
  done
done
print -r -- "K2 $pass/$tot clicks flipped the checkbox" | tee -a $OUT/matrix.txt
