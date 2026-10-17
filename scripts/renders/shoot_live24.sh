#!/bin/zsh
# live-24 (5) — the Librarian glass presets over a busy Card grid (Sample Library, 2-col), light + dark, iOS 27.0
# Simulator: shipped (live-23's frost) · glass (the Liquid Glass mode at its defaults) · siriPill · gradedPanel · both.
# Postures: peek (the search pill over the grid) and long (a synthetic four-paragraph answer + typed Ask text), each
# also shot with the text hidden (-RenderHideText) for the contrast numbers; plus Reduce Transparency ON (every
# preset, long) and Increase Contrast ON ("both", long).
#   scripts/renders/shoot_live24.sh <out_dir>
set -uo pipefail
OUT=${1:?out}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView -gridColumnCount 2
      -AppearanceTuner YES -AppearanceTunerReset YES)
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
acc() { xcrun simctl spawn $SIM defaults write com.apple.Accessibility $1 -bool $2; }
shot() {   # shot <file> <preset> <args...>
  local f=$1 p=$2; shift 2
  local P=(); [[ $p != shipped ]] && P=(-GlassPresetRender $p)
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE $P "$@" >/dev/null
  python3 -c "import time; time.sleep(10)"
  xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1
}
LONG=(-RenderLongAnswer YES -AskPrefill "Which note should I read first")
acc EnhancedBackgroundContrastEnabled false; acc DarkenSystemColors false
for m in light dark; do xcrun simctl ui $SIM appearance $m
  for p in shipped glass siriPill gradedPanel both; do
    shot $p-$m-peek $p
    shot $p-$m-peek-hidden $p -RenderHideText YES
    shot $p-$m-long $p $LONG
    shot $p-$m-long-hidden $p $LONG -RenderHideText YES
  done
done
acc EnhancedBackgroundContrastEnabled true
for m in light dark; do xcrun simctl ui $SIM appearance $m
  for p in shipped glass siriPill gradedPanel both; do shot RT-$p-$m-long $p $LONG; done
done
acc EnhancedBackgroundContrastEnabled false; acc DarkenSystemColors true
for m in light dark; do xcrun simctl ui $SIM appearance $m
  shot IC-both-$m-long both $LONG
  shot IC-both-$m-long-hidden both $LONG -RenderHideText YES
done
acc DarkenSystemColors false
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
