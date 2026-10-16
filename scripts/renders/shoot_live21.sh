#!/bin/zsh
# live-21 (1) — RENDER ONLY: the Librarian panel variants A–E, light palettes L1–L3, card shadows S1–S4 × field F1–F4,
# and the layered export, on the iOS 27.0 Simulator over the Sample Library (scratch library; DEBUG -Render* hooks).
#   scripts/renders/shoot_live21.sh <out_dir> [panels|palettes|shadows|layers|clips|all]
set -uo pipefail
OUT=${1:?out}; WHAT=${2:-all}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly)
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
rt() { xcrun simctl spawn $SIM defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool $1; }
mode() { xcrun simctl ui $SIM appearance $1; }
shot() {   # shot <file> <wait-seconds> <args...>
  local f=$1 w=$2; shift 2
  xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep($w)"
  xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1
}
typeset -A BACK; BACK=(grid "-OpenCardView -gridColumnCount 2" map "-OpenMap" vertical "-OpenCardView -gridColumnCount 4")
rt false
if [[ $WHAT == panels || $WHAT == all ]]; then
  mkdir -p $OUT/1-panels
  for m in light dark; do mode $m
    for v in A B C D E; do for b in grid map vertical; do
      w=9; [[ $b == map ]] && w=14
      shot 1-panels/$v-$m-$b-home $w ${=BACK[$b]} -RenderPanel $v -LibrarianDetent full
      shot 1-panels/$v-$m-$b-long $w ${=BACK[$b]} -RenderPanel $v -RenderLongAnswer YES
    done; done
  done
  rt true   # Reduce Transparency ON: B and C over the Card grid
  for m in light dark; do mode $m; for v in B C; do
    shot 1-panels/RT-$v-$m-grid-home 9 ${=BACK[grid]} -RenderPanel $v -LibrarianDetent full
    shot 1-panels/RT-$v-$m-grid-long 9 ${=BACK[grid]} -RenderPanel $v -RenderLongAnswer YES
  done; done
  rt false
fi
if [[ $WHAT == backdrops || $WHAT == all ]]; then   # the long-answer stills again with the transcript text hidden (contrast)
  mkdir -p $OUT/1-backdrops
  for m in light dark; do mode $m; for v in A B C D E; do for b in grid map vertical; do
    w=9; [[ $b == map ]] && w=14
    shot 1-backdrops/$v-$m-$b-long $w ${=BACK[$b]} -RenderPanel $v -RenderLongAnswer YES -RenderHideText YES
  done; done; done
  rt true
  for m in light dark; do mode $m; for v in B C; do
    shot 1-backdrops/RT-$v-$m-grid-long 9 ${=BACK[grid]} -RenderPanel $v -RenderLongAnswer YES -RenderHideText YES
  done; done
  rt false
fi
if [[ $WHAT == palettes || $WHAT == all ]]; then
  mkdir -p $OUT/2-palettes; mode light
  for p in L1 L2 L3; do
    shot 2-palettes/$p-card 9 ${=BACK[grid]} -RenderPalette $p
    shot 2-palettes/$p-map 14 -OpenMap -RenderPalette $p
    shot 2-palettes/$p-entry 12 -OpenCardView -OpenFirstGradientEntry -RenderPalette $p
    shot 2-palettes/$p-librarian 9 ${=BACK[grid]} -RenderPalette $p -RenderLongAnswer YES
  done
fi
if [[ $WHAT == shadows || $WHAT == all ]]; then
  mkdir -p $OUT/3-shadows; mode light
  for p in L1 L2; do for s in S1 S2 S3 S4; do for f in F1 F2 F3 F4; do
    shot 3-shadows/$p-$s-$f-vertical 8 -OpenCardView -gridColumnCount 4 -RenderPalette $p -RenderShadow $s -RenderField $f
    shot 3-shadows/$p-$s-$f-coverflow 8 -OpenCardView -gridColumnCount 1 -RenderPalette $p -RenderShadow $s -RenderField $f
  done; done; done
  mode dark
  for s in S1 S2 S3; do
    shot 3-shadows/dark-$s-vertical 8 -OpenCardView -gridColumnCount 4 -RenderShadow $s
    shot 3-shadows/dark-$s-coverflow 8 -OpenCardView -gridColumnCount 1 -RenderShadow $s
  done
fi
if [[ $WHAT == layers || $WHAT == all ]]; then
  mkdir -p $OUT/3-layers-raw; mode light
  for l in field cards shadow hairline; do for bg in white black; do
    shot 3-layers-raw/L2-vertical-$l-on-$bg 8 -OpenCardView -gridColumnCount 4 -RenderPalette L2 -RenderShadow S1 -RenderLayer $l -RenderLayerBG $bg
  done; done
fi
if [[ $WHAT == clips || $WHAT == all ]]; then
  mkdir -p $OUT/1-clips
  for m in light dark; do mode $m; for v in A B C D E; do
    xcrun simctl launch --terminate-running-process $SIM $APPID $BASE ${=BACK[grid]} -RenderPanel $v -RenderLongAnswer YES -RenderAnimateOpen YES >/dev/null
    xcrun simctl io $SIM recordVideo --codec=h264 --force $OUT/1-clips/$v-$m-open.mp4 >/dev/null 2>&1 &
    rec=$!; python3 -c "import time; time.sleep(7)"; kill -INT $rec; wait $rec 2>/dev/null
  done; done
fi
mode light; xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
find $OUT -name "*.png" -o -name "*.mp4" | wc -l
