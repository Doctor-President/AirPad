#!/bin/zsh
# 1.1-A (1)(2) stills — the ≡ menu and the Appearance panel over the real Map and Dashboard, light + dark, Sample Library.
#   SIM=<udid> scripts/renders/shoot_1_1a_menu.sh <app> <out_dir>
set -uo pipefail
APP=${1:?app}; OUT=${2:?out}; SIM=${SIM:?sim}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl boot $SIM >/dev/null 2>&1; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM $APP
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -NoMapDebugHUD)
for mode in light dark; do
  xcrun simctl ui $SIM appearance $mode
  for where in OpenMap OpenDashboard; do
    for what in none OpenMenu OpenAppearancePanel; do
      args=($BASE -$where); [[ $what != none ]] && args+=(-$what)
      xcrun simctl launch --terminate-running-process $SIM $APPID $args >/dev/null
      sleep 10
      xcrun simctl io $SIM screenshot --type=png $OUT/${mode}-${where#Open}-${what#Open}.png >/dev/null 2>&1
    done
  done
done
xcrun simctl terminate $SIM $APPID >/dev/null 2>&1; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
