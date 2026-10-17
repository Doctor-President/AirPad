#!/bin/zsh
# live-23 — the card showcase (`-CardShowcase`, synthetic entries) as stills: <out> <tag> [modes] [extra launch args…]
# Shoots coverflow (3 pages) · vertical (3 pages) · grid2 (2 pages) · grid3 (1 page) per mode.
set -uo pipefail
OUT=${1:?out}; TAG=${2:?tag}; MODES=${3:-"light dark"}; shift 3 2>/dev/null || shift $#; EXTRA=("$@")
SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSeedCardShowcase -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView)
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
shot() { local f=$1; shift
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" "${EXTRA[@]}" >/dev/null
  python3 -c "import time; time.sleep(${WAIT:-8})"
  xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1; }
for m in ${=MODES}; do xcrun simctl ui $SIM appearance $m
  for k p in coverflow 0 coverflow 1 coverflow 2 vertical 0 vertical 1 vertical 2 grid2 0 grid2 1 grid3 0; do
    [[ -n ${ONLY:-} && $k != ${~ONLY} ]] && continue
    shot $TAG-$m-$k-p$p -CardShowcase $k -CardShowcasePage $p
  done
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/$TAG-*.png | wc -l
