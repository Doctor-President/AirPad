#!/bin/zsh
# live-26 (2) — the Librarian's glyphs + "Search" placeholder on T's baked 2026-10-18 values (= Reset = what ships), over a
# busy Card grid (Sample Library, 2-col), light + dark, iOS 27.0 Simulator. Postures: peek (the resting search pill:
# magnifier + "Search"), search (the open search pill at half with typed text: magnifier, ×, mic hidden) and long (a
# synthetic four-paragraph answer + typed Ask text: feather, ×, send). Each shot again with the text AND glyphs hidden
# (-RenderHideText) for the contrast numbers.
#   scripts/renders/shoot_live26_glyphs.sh <out_dir> <label>
set -uo pipefail
OUT=${1:?out}; L=${2:?label}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView -gridColumnCount 2
      -AppearanceTuner YES -AppearanceTunerReset YES)
LONG=(-RenderLongAnswer YES -AskPrefill "Which note should I read first")
SEARCH=(-LibrarianDetent half -SearchPrefill "harbour")
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
shot() {   # shot <file> <args...>
  local f=$1; shift
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep(10)"
  xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1
}
for m in light dark; do xcrun simctl ui $SIM appearance $m
  shot $L-$m-peek
  shot $L-$m-peek-hidden -RenderHideText YES
  shot $L-$m-search $SEARCH
  shot $L-$m-search-hidden $SEARCH -RenderHideText YES
  shot $L-$m-long $LONG
  shot $L-$m-long-hidden $LONG -RenderHideText YES
done
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
