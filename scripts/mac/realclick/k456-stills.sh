#!/bin/zsh
# E fix-up 4 · K4 / K5 / K6 stills by real clicks on the isolated copy (Sample Library; -MacTodaySample on Today):
#   K4 the Librarian and Settings panels, docked (1,350 pt) and floating (1,100 pt with the sidebar), light + dark;
#   K5 the Map's Analyze button at rest, running and done; K6 Today at 1,100 / 1,350 with the panel floating / docked.
#   k456-stills.sh <isolated Debug .app> <out dir>      THEME=dark|light
set -u
D=${0:A:h:h:h:h}/build/mac-e/fixup3; R=$D/rclick
APP=${1:?app}; OUT=${2:?out}; TH=${THEME:-dark}; mkdir -p $OUT
PREF=~/Library/Containers/com.doctorpresident.airpad.macA/Data/Library/Preferences/com.doctorpresident.airpad.macA
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
defaults write $PREF appearance.override -string $TH 2>/dev/null
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -MacTodaySample YES -appearance.override $TH ${=EXTRA:-} > $OUT/app-$TH.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 12; $R winmove $P 0 60 >/dev/null
size() { $R winsize $P $1 840 >/dev/null; sleep 1.2; W=$1 }
shot() { $R hover $P toolbar.title >/dev/null; sleep 1.2; screencapture -x -R0,60,$W,840 $OUT/$1-$TH.png; print -r -- "still $1-$TH ($(${=2:-true}))" }
size 1350
[[ $($R has $P sidebar.today) == no ]] && $R click $P toolbar.sidebar >/dev/null
[[ $($R get $P toolbar.librarian AXValue) != Open ]] && $R click $P toolbar.librarian >/dev/null
$R click $P sidebar.sample >/dev/null; sleep 1.5; $R click $P toolbar.view.Map >/dev/null; sleep 3
shot k4-librarian-docked-1350
size 1100; shot k4-librarian-floating-1100
$R click $P sidebar.settings >/dev/null; sleep 1.2; shot k4-settings-floating-1100
size 1350; shot k4-settings-docked-1350
$R click $P sidebar.settings >/dev/null; sleep 1
# K5 — Analyze at rest / running / done (the Map is showing)
shot k5-analyze-rest
$R click $P map.analyze >/dev/null; sleep 0.25; shot k5-analyze-running "$R get $P map.analyze AXValue"
sleep 1.6; shot k5-analyze-later "$R get $P map.analyze AXValue"
# K6 — Today beside the panel
$R click $P sidebar.today >/dev/null; sleep 2
shot k6-today-docked-1350
size 1100; shot k6-today-floating-1100
$R click $P sidebar.settings >/dev/null; sleep 1.2; shot k6-today-settings-floating-1100
$R click $P sidebar.settings >/dev/null; sleep 1
$R click $P toolbar.librarian >/dev/null; sleep 1; shot k6-today-closed-1100
$R click $P toolbar.librarian >/dev/null; sleep 1
size 1350
