#!/bin/zsh
# E fix-up 3 · H4 stills — Settings beside the live Map, by real clicks: Appearance (dark), a Map look changed with the
# panel open (before / after, one frame each), Theme → Light from the panel, the home in light, min / max widths.
#   h4-stills.sh <isolated Debug .app> <out dir>      (Debug: -ProUnlocked YES so a Pro look can be picked)
set -u
D=${0:A:h:h:h:h}/build/mac-e/fixup3; R=$D/rclick
APP=${1:?app}; OUT=${2:?out}; mkdir -p $OUT
PREF=~/Library/Containers/com.doctorpresident.airpad.macA/Data/Library/Preferences/com.doctorpresident.airpad.macA
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
defaults write $PREF appearance.override -string ${THEME:-dark} 2>/dev/null
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -ProUnlocked YES -appearance.override ${THEME:-dark} ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 12; $R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null
[[ $($R has $P sidebar.today) == no ]] && $R click $P toolbar.sidebar >/dev/null
$R click $P sidebar.sample >/dev/null; sleep 1.5; $R click $P toolbar.view.Map >/dev/null; sleep 3
shot() { $R hover $P toolbar.title >/dev/null; sleep 1.2; screencapture -x -R0,60,1350,840 $OUT/$1.png; print -r -- "still $1" }
$R click $P sidebar.settings >/dev/null; sleep 1.2; shot 1-home-dark
$R click $P settingsRow.Appearance >/dev/null; sleep 1.5; shot 2-appearance-dark-before
for look in Glass Flat; do $R click $P $look >/dev/null; sleep 2.5; shot 3-appearance-dark-look-$look; done
shot 4-appearance-${THEME:-dark}-after-looks
$R click $P BackButton >/dev/null; sleep 1.2; shot 5-home-light
x=$($R find $P resize.settings | tr -d '()' | awk -F'[, ×]' '{print $1 + $3/2}')
$R drag $P $x 300 -260 0 >/dev/null; sleep 1; shot 6-width-max-light
x=$($R find $P resize.settings | tr -d '()' | awk -F'[, ×]' '{print $1 + $3/2}')
$R drag $P $x 300 400 0 >/dev/null; sleep 1; shot 7-width-min-light
$R click $P settingsRow.Appearance >/dev/null; sleep 1.2; $R click $P Dark >/dev/null; sleep 2; shot 8-width-min-dark-appearance
x=$($R find $P resize.settings | tr -d '()' | awk -F'[, ×]' '{print $1 + $3/2}'); $R drag $P $x 300 -120 0 >/dev/null; sleep 1
