#!/bin/zsh
# live-40 — dark Map Glass stills, Sample Library (scratch), iOS 27 Simulator. ONE launch (-MapOrbCycle steps every 4 s →
# same layout + framing): flat · Fresnel medium · Glass subtle / medium / strong · Glass medium at two simulated tilts ·
# Glass medium with the dot shrink off. Then one zoomed Glass-medium still for refraction + label legibility.
# The tuner is live (-AppearanceTuner YES) from its defaults.
#   scripts/renders/shoot_live40_glass.sh <out_dir> [start-seconds]
set -uo pipefail
OUT=${1:?out}; S=${2:-22}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -OpenMap -NoMapDebugHUD -AppearanceTuner YES -AppearanceTunerReset YES)
xcrun simctl ui $SIM appearance dark
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
snap() { xcrun simctl io $SIM screenshot --type=png $OUT/$1.png >/dev/null 2>&1; }
xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -MapOrbCycle $S >/dev/null
python3 -c "import time; time.sleep($S + 2)"; snap 1-flat
python3 -c "import time; time.sleep(4)"; snap 2-fresnel-medium
python3 -c "import time; time.sleep(4)"; snap 3-glass-subtle
python3 -c "import time; time.sleep(4)"; snap 4-glass-medium
python3 -c "import time; time.sleep(4)"; snap 5-glass-strong
python3 -c "import time; time.sleep(4)"; snap 6-glass-medium-tilt-left-up
python3 -c "import time; time.sleep(4)"; snap 7-glass-medium-tilt-right-down
python3 -c "import time; time.sleep(4)"; snap 8-glass-medium-shrink-off
xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -MapOrbRender glass-medium -MapZoom 0.45 >/dev/null
python3 -c "import time; time.sleep($S)"; snap 9-glass-medium-zoomed
xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
