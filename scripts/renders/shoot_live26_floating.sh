#!/bin/zsh
# live-26 (3d) — the floating "+" and view switcher, Today vs Glass (-FloatingButtons), on the Card grid and the busy Map
# (Sample Library), light + dark.   scripts/renders/shoot_live26_floating.sh <out_dir>
set -uo pipefail
OUT=${1:?out}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1)
for m in light dark; do xcrun simctl ui $SIM appearance $m
  for f in today glass; do
    xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -OpenCardView -gridColumnCount 2 -FloatingButtons $f >/dev/null
    python3 -c "import time; time.sleep(9)"; xcrun simctl io $SIM screenshot --type=png $OUT/$m-cards-$f.png >/dev/null 2>&1
    xcrun simctl launch --terminate-running-process $SIM $APPID $BASE -OpenMap -FloatingButtons $f >/dev/null
    python3 -c "import time; time.sleep(11)"; xcrun simctl io $SIM screenshot --type=png $OUT/$m-map-$f.png >/dev/null 2>&1
  done
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
