#!/bin/zsh
# live-39 — dark Map stills, Sample Library (scratch), iOS 27 Simulator: flat vs Fresnel (subtle / medium / strong) in ONE
# launch (-MapOrbCycle steps the look every 4 s → same layout + framing), then one zoomed-in Fresnel (medium) still for
# label legibility. The tuner is live (-AppearanceTuner YES) from its defaults.
#   scripts/renders/shoot_live39_map.sh <out_dir> [start-seconds]
set -uo pipefail
OUT=${1:?out}; S=${2:-22}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -OpenMap -NoMapDebugHUD -AppearanceTuner YES -AppearanceTunerReset YES)
xcrun simctl ui $SIM appearance dark
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
snap() { xcrun simctl io $SIM screenshot --type=png $OUT/$1.png >/dev/null 2>&1; }
xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -MapOrbCycle $S >/dev/null
python3 -c "import time; time.sleep($S + 2)"; snap 1-flat
python3 -c "import time; time.sleep(4)"; snap 2-fresnel-subtle
python3 -c "import time; time.sleep(4)"; snap 3-fresnel-medium
python3 -c "import time; time.sleep(4)"; snap 4-fresnel-strong
xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -MapOrbRender medium -MapZoom 0.45 >/dev/null
python3 -c "import time; time.sleep($S)"; snap 5-fresnel-medium-zoomed
xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
