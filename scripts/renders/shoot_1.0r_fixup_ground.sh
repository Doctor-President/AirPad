#!/bin/zsh
# 1.0r fix-up F1 — the Pro custom background on the Dashboard, List and Card views, light + dark, without and with a
# custom gradient (Sample Library, Pro on via DEBUG `-ProUnlocked`, lava frozen by `-GlassFreezeTime` so two Dashboard
# shots can be diffed). Installs <AirPad.app> (a Debug Simulator build) on $SIM first.
#   SIM=<udid> scripts/renders/shoot_1.0r_fixup_ground.sh <AirPad.app> <out_dir> <tag>
set -uo pipefail
APP=${1:?app}; OUT=${2:?out}; TAG=${3:?tag}; SIM=${SIM:?SIM udid}; APPID=com.doctorpresident.airpad; S=${S:-16}
mkdir -p $OUT
xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM $APP
# dark 1B2A4A → 5A2346, light F6D9B8 → BFD8F0, both at 45° (a two-stop gradient, the case T set)
GROUND=$(printf '%s' '{"dark":{"custom":true,"color":"1B2A4A","gradient":true,"color2":"5A2346","angle":45,"dot":"FFFFFF","dotOpacity":0.8},"light":{"custom":true,"color":"F6D9B8","gradient":true,"color2":"BFD8F0","angle":45,"dot":"3B362F","dotOpacity":0.8}}' | base64)
CALLOUTS=(); for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do CALLOUTS+=(-com.airpad.callouts.$k YES); done
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -ProUnlocked YES -GlassFreezeTime 5 $CALLOUTS)
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
for G in light dark; do
  xcrun simctl ui $SIM appearance $G
  for V in dashboard list cards; do
    case $V in dashboard) VA=(-OpenDashboard);; list) VA=(-OpenListView);; cards) VA=(-OpenCardView);; esac
    for B in plain custom; do
      GA=(); [[ $B == custom ]] && GA=(-MapGroundDebug $GROUND)
      xcrun simctl launch --terminate-running-process $SIM $APPID $BASE $VA $GA >/dev/null
      python3 -c "import time; time.sleep($S)"
      xcrun simctl io $SIM screenshot --type=png $OUT/$TAG-$V-$G-$B.png >/dev/null 2>&1
    done
  done
done
xcrun simctl terminate $SIM $APPID >/dev/null 2>&1; xcrun simctl status_bar $SIM clear
ls $OUT/$TAG-*.png | wc -l
