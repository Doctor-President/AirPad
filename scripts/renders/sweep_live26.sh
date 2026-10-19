#!/bin/zsh
# live-26 (2) — opacity sweep for the pill placeholders / × / peek magnifier (DEBUG -Pill*Opacity{Light,Dark}), peek +
# search postures, shown + hidden, T's baked values. sweep_live26.sh <out> <light|dark> <label> <args...>
set -uo pipefail
OUT=${1:?}; M=${2:?}; L=${3:?}; shift 3; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView -gridColumnCount 2
      -AppearanceTuner YES -AppearanceTunerReset YES)
SEARCH=(-LibrarianDetent half -SearchPrefill "harbour")
xcrun simctl ui $SIM appearance $M
shot() { local f=$1; shift; xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep(9)"; xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1; }
shot $L-$M-peek "$@"; shot $L-$M-peek-hidden "$@" -RenderHideText YES
shot $L-$M-search $SEARCH "$@"; shot $L-$M-search-hidden $SEARCH "$@" -RenderHideText YES
