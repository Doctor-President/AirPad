#!/bin/zsh
# C7 — iPad stills in all four orientations (Sample Library scratch, light, lava frozen). The app launches portrait and
# turns after FA s (DEBUG `-ForceOrientation`), so each still is a real mid-session rotation.
#   SIM=<udid> shoot_ipad_rot.sh <out_dir> <tag>      (app installed; VIEWS / ORIENTS / LOOK / S / FA override)
set -uo pipefail
OUT=${1:?out}; TAG=${2:?tag}; SIM=${SIM:?}; APPID=com.doctorpresident.airpad; S=${S:-16}; FA=${FA:-6}; mkdir -p $OUT
CALLOUTS=(); for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do CALLOUTS+=(-com.airpad.callouts.$k YES); done
LOOK=${LOOK:-light}
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 5 -appearance.override $LOOK $CALLOUTS -ForceOrientationAfter $FA)
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3
xcrun simctl ui $SIM appearance $LOOK
for O in ${=ORIENTS:-portrait landscapeLeft upsideDown landscapeRight}; do
  for V in ${=VIEWS:-dashboard map list cards entry librarian}; do
    case $V in dashboard) VA=(-OpenDashboard);; map) VA=(-OpenMap);; list) VA=(-OpenListView);; cards) VA=(-OpenCardView);;
      entry) VA=(-OpenFirstGradientEntry);; librarian) VA=(-OpenMap -OpenLibrarian);; esac
    xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -ForceOrientation $O $VA >/dev/null
    python3 -c "import time; time.sleep($S)"
    xcrun simctl io $SIM screenshot --type=png $OUT/$TAG-$O-$V.png >/dev/null 2>&1
    echo "$O $V done"
  done
done
xcrun simctl terminate $SIM $APPID >/dev/null 2>&1
