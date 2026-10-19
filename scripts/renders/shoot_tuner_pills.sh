#!/bin/zsh
# 2026-10-17 brief (per-pill looks, split rim, collapsible tuner) — stills over a busy Card grid (Sample Library,
# 2-col), light + dark, iOS 27.0 Simulator:
#   sheet-closed      the tuner as it opens: section headers only, Copy / Reset pinned
#   defaults-*        the TestFlight defaults (light: a white rim at rest on all three pills; dark: none)
#   thinking-idle-*   Siri-style pills with the rim OFF at rest + shimmer while answering, nothing generating → no rim
#   thinking-gen-*    the same while an answer generates (-RenderGenerating) → the shimmer, on Search + Ask only
# Postures: peek (the peek pill) and long (panel open: search pill + Ask bar).
#   scripts/renders/shoot_tuner_pills.sh <out_dir>
set -uo pipefail
OUT=${1:?out}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView -gridColumnCount 2
      -AppearanceTuner YES -AppearanceTunerReset YES)
LONG=(-RenderLongAnswer YES -AskPrefill "Which note should I read first")
THINK=(-GlassPresetRender siriPill -RimRestRender off -RimAnimationRender shimmer)
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
shot() {   # shot <file> <args...>
  local f=$1; shift
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep(10)"
  xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1
}
for m in light dark; do xcrun simctl ui $SIM appearance $m
  shot sheet-closed-$m -AppearanceTunerOpen YES
  shot defaults-$m-peek
  shot defaults-$m-long $LONG
  shot thinking-idle-$m-peek $THINK
  shot thinking-idle-$m-long $THINK $LONG
  shot thinking-gen-$m-long $THINK $LONG -RenderGenerating YES
done
# A clip of the shimmer while generating (dark, long).
xcrun simctl ui $SIM appearance dark
xcrun simctl launch --terminate-running-process $SIM $APPID $BASE $THINK $LONG -RenderGenerating YES >/dev/null
python3 -c "import time; time.sleep(10)"
xcrun simctl io $SIM recordVideo --codec=h264 --force $OUT/thinking-gen-dark-shimmer.mp4 >/dev/null 2>&1 &
REC=$!; python3 -c "import time; time.sleep(6)"; kill -INT $REC; wait $REC 2>/dev/null
xcrun simctl ui $SIM appearance light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT | wc -l
