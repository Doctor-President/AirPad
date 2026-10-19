#!/bin/zsh
# live-27 (4d) — the Librarian's pills under Reduce Transparency (and Increase Contrast) through the real screen: peek,
# the open search pill (a typed query), the Ask bar (a synthetic answer), light + dark, at T's baked values (tuner Reset)
# and at each glass preset. RT = the Simulator's com.apple.Accessibility EnhancedBackgroundContrastEnabled; IC =
# `simctl ui increase_contrast`. Shown + text-hidden (-RenderHideText) for the contrast backdrops.
#   A11Y=rt|ic|none MODES="light dark" scripts/renders/shoot_live27_rt.sh <out_dir> <label> [extra args...]
set -uo pipefail
OUT=${1:?out}; L=${2:?label}; shift 2; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
RT=0; IC=disabled
case ${A11Y:-rt} in rt) RT=1;; ic) IC=enabled;; both) RT=1; IC=enabled;; esac
xcrun simctl spawn $SIM defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool $([[ $RT == 1 ]] && echo true || echo false)
xcrun simctl ui $SIM increase_contrast $IC
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
BASE=(-UITestLibrary -UITestLibraryFresh -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView -gridColumnCount 2
      -AppearanceTuner YES -AppearanceTunerReset YES)
shot() { local f=$1; shift; xcrun simctl launch --terminate-running-process $SIM $APPID $BASE "$@" >/dev/null
  python3 -c "import time; time.sleep(9)"; xcrun simctl io $SIM screenshot --type=png $OUT/$f.png >/dev/null 2>&1; }
for m in ${=MODES:-light dark}; do xcrun simctl ui $SIM appearance $m
  for p in ${=PRESETS:-baked}; do
    pa=(); [[ $p != baked ]] && pa=(-GlassPresetRender $p)
    shot $p-$m-peek $pa "$@"; shot $p-$m-peek-hidden $pa -RenderHideText YES "$@"
    shot $p-$m-search $pa -LibrarianDetent half -SearchPrefill harbour "$@"
    shot $p-$m-search-hidden $pa -LibrarianDetent half -SearchPrefill harbour -RenderHideText YES "$@"
    shot $p-$m-long $pa -RenderLongAnswer YES "$@"; shot $p-$m-long-hidden $pa -RenderLongAnswer YES -RenderHideText YES "$@"
  done
done
xcrun simctl spawn $SIM defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool false
xcrun simctl ui $SIM increase_contrast disabled; xcrun simctl ui $SIM appearance light
xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
