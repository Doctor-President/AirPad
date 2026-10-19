#!/bin/zsh
# live-23 — stills over the synthetic card showcase (`-UITestSeedCardShowcase`, a fresh scratch library) and/or the
# Sample Library: Card coverflow / vertical / grid 2-col / grid 3-col, light + dark. iOS 27.0 Simulator.
#   scripts/renders/shoot_live23.sh <out_dir> <showcase|sample> [modes: "light dark"] [extra launch args…]
set -uo pipefail
OUT=${1:?out}; LIB=${2:?showcase|sample}; MODES=${3:-"light dark"}; shift 3 2>/dev/null || shift $#; EXTRA=("$@")
SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
if [[ $LIB == showcase ]]; then BASE=(-UITestLibrary -UITestLibraryFresh -UITestSeedCardShowcase -EmbedCPUOnly -GlassFreezeTime 1)
else BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1); fi   # fresh: a scratch left with other seeds never seeds the sample
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
shot() {   # shot <file> <wait-seconds> <args...>
  local f=$1 w=$2; shift 2
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" "${EXTRA[@]}" >/dev/null
  python3 -c "import time; time.sleep($w)"
  xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1
}
for m in ${=MODES}; do xcrun simctl ui $SIM appearance $m
  shot $m-coverflow 10 -OpenCardView -gridColumnCount 1
  shot $m-vertical 10 -OpenCardView -gridColumnCount 4
  shot $m-grid2 10 -OpenCardView -gridColumnCount 2
  shot $m-grid3 10 -OpenCardView -gridColumnCount 3
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
