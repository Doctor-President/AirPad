#!/bin/zsh
# 1.1 store — shots 1 and 5 pinched out (several territories in frame) via testMapZoomed. Usage: zoomed.sh <sim> <out>
set -u
SIM=$1; OUT=$2; HERE=${0:A:h}; source $HERE/lib.sh; source $HERE/pairs.sh; mkdir -p $OUT
for p in $pairs; do pair_args "$p"; xcrun simctl ui $SIM appearance $ap
  $HERE/run_ui.sh $SIM testMapZoomed $OUT/z-$nm-$ap-$bg "STORE_ARGS=$args" STORE_NAME=01-map-$nm-$ap-$bg >/dev/null 2>&1; done
for ap in dark light; do xcrun simctl ui $SIM appearance $ap; for look in flat glass aura riso gradient outline; do
  nm=$look; [[ $look == aura && $ap == light ]] && nm=wash
  $HERE/run_ui.sh $SIM testMapZoomed $OUT/z-$nm-$ap "STORE_ARGS=-mapLook.v1 $look" STORE_NAME=05-look-$nm-$ap >/dev/null 2>&1; done; done
xcrun simctl ui $SIM appearance light
mv $OUT/z-*/*-zoomed.png $OUT/ 2>/dev/null; ls $OUT/*-zoomed.png | wc -l
