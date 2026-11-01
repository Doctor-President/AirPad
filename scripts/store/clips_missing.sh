#!/bin/zsh
set -u
SIM=$1; OUT=$2; HERE=${0:A:h}; source $HERE/lib.sh; source $HERE/pairs.sh
r() { local name=$1 ap=$2 t=$3; shift 3; xcrun simctl ui $SIM appearance $ap; rm -rf $OUT/run-$name
  $HERE/run_ui.sh $SIM $t $OUT/run-$name "$@" >/dev/null 2>&1
  local f=$(ls -t $OUT/run-$name/clips/*.mov 2>/dev/null | head -1)
  [[ -n $f ]] && mv $f $OUT/clips/clip-$name.mov && echo "clip-$name" || echo "MISSING clip-$name"; }
for ap in dark light; do for look in flat glass aura riso gradient outline; do
  nm=$look; [[ $look == aura && $ap == light ]] && nm=wash
  [[ -e $OUT/clips/clip-look-$nm-$ap-default.mov ]] && continue
  r look-$nm-$ap-default $ap testClipLook "STORE_ARGS=-mapLook.v1 $look" STORE_NAME=l; done; done
xcrun simctl ui $SIM appearance light
