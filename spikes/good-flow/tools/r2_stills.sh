#!/bin/zsh
# Good Flow spike · round 2: render the 120 reference-named stills with the Mac build into build/r2/<name>.
#   tools/r2_stills.sh <name> [app args…]       e.g. tools/r2_stills.sh pools-bench -Pools bench
# Offscreen (valid with the screen locked). One app at a time (an earlier spike instance is quit by PID).
set -u
SPIKE=${0:A:h:h}
APP=$SPIKE/build/dd/Build/Products/Release-maccatalyst/GoodFlow.app
C=~/Library/Containers/com.doctorpresident.spike.SpikeHarness/Data/Documents
N=${1:?name}; shift
for p in $(pgrep -x GoodFlow); do kill $p; done; sleep 1
rm -rf $C/r2-$N
open -n -a $APP --args -ApplePersistenceIgnoreState YES -RenderStills r2-$N -StillsRepeat 1 "$@"
for i in $(seq 1 240); do [[ -f $C/r2-$N/DONE ]] && break; sleep 1; done
[[ -f $C/r2-$N/DONE ]] || { echo "no DONE after 240 s"; exit 1 }
mkdir -p $SPIKE/build/r2; rm -rf $SPIKE/build/r2/$N; cp -R $C/r2-$N $SPIKE/build/r2/$N
echo "$N: $(cat $SPIKE/build/r2/$N/DONE)"
