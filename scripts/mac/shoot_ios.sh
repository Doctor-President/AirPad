#!/bin/zsh
# Mac batch A — iPhone stills of 6 screens (Sample Library scratch, light, lava frozen) for the "iOS unchanged" diff.
#   SIM=<udid> shoot_ios.sh <out_dir> <tag>     (the app must already be installed)
set -uo pipefail
OUT=${1:?out}; TAG=${2:?tag}; SIM=${SIM:?}; APPID=com.doctorpresident.airpad; S=${S:-16}; mkdir -p $OUT
CALLOUTS=(); for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do CALLOUTS+=(-com.airpad.callouts.$k YES); done
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 5 $CALLOUTS)
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl ui $SIM appearance light
for V in dashboard map list cards entry chats; do
  case $V in dashboard) VA=(-OpenDashboard);; map) VA=(-OpenMap);; list) VA=(-OpenListView);; cards) VA=(-OpenCardView);;
    entry) VA=(-OpenFirstGradientEntry);; chats) VA=(-OpenChatsList);; esac
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE $VA >/dev/null
  python3 -c "import time; time.sleep($S)"
  xcrun simctl io $SIM screenshot --type=png $OUT/$TAG-$V.png >/dev/null 2>&1
done
xcrun simctl terminate $SIM $APPID >/dev/null 2>&1
