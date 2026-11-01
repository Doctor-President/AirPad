#!/bin/zsh
# 1.1 store — the preview clips on <sim> into <out>/clips/ (raw, with handles). Usage: clips.sh <sim> <out>
set -u
SIM=$1; OUT=$2; HERE=${0:A:h}; source $HERE/lib.sh; source $HERE/pairs.sh; mkdir -p $OUT/clips
xcrun simctl keychain $SIM reset   # no server endpoint left from shot 8: the Librarian answers with Apple Intelligence
# run <name> <appearance> <test> <out-dir placeholder handled by run> [ENV=…]
r() { local name=$1 ap=$2 t=$3; shift 3; xcrun simctl ui $SIM appearance $ap
  $HERE/run_ui.sh $SIM $t $OUT/run-$name "$@" >/dev/null 2>&1
  local f=$(ls -t $OUT/run-$name/clips/*.mov 2>/dev/null | head -1)
  [[ -n $f ]] && mv $f $OUT/clips/clip-$name.mov && echo "clip-$name" || echo "MISSING clip-$name"; }
pair_args "${pairs[1]}"; AD=$args     # Aura dark, navy-violet
pair_args "${pairs[3]}"; WL=$args     # Wash light, sand
r map-glide-slow-dark dark testClipGlide "STORE_ARGS=$AD" STORE_NAME=g STORE_VELOCITY=120
r map-glide-normal-dark dark testClipGlide "STORE_ARGS=$AD" STORE_NAME=g STORE_VELOCITY=600
r map-glide-slow-light light testClipGlide "STORE_ARGS=$WL" STORE_NAME=g STORE_VELOCITY=120
r map-glide-normal-light light testClipGlide "STORE_ARGS=$WL" STORE_NAME=g STORE_VELOCITY=600
for ap in light dark; do
  r open-entry-$ap $ap testClipOpenEntry
  r librarian-stream-$ap $ap testClipLibrarian
  xcrun simctl terminate $SIM com.apple.mobilesafari 2>/dev/null; xcrun simctl openurl $SIM http://brewing-notes.local:8765/slow-coffee.html; sleep 6
  r share-from-safari-$ap $ap testClipShare
done
for p in $pairs; do pair_args "$p"; r look-$nm-$ap-$bg $ap testClipLook "STORE_ARGS=$args" STORE_NAME=l; done
for ap in dark light; do for look in flat glass aura riso gradient outline; do
  nm=$look; [[ $look == aura && $ap == light ]] && nm=wash
  r look-$nm-$ap-default $ap testClipLook "STORE_ARGS=-mapLook.v1 $look" STORE_NAME=l; done; done
xcrun simctl ui $SIM appearance light
ls $OUT/clips | wc -l
