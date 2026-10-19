#!/bin/zsh
# Brief CJ — the inventory's host-free UI rows in ONE xcodebuild, spread over N clones of the Simulator by
# Xcode's own parallel testing. `--erase` starts from a freshly erased Simulator (what Xcode Cloud starts from).
#   scripts/inventory/ui_hostfree.sh <out_dir> [--workers N] [--sim UDID] [--erase] [--no-build]
set -uo pipefail
OUT=${1:?out_dir}; shift; W=3; SIM=1E797E28-B816-4CA3-B6B5-5E640671067D; ERASE=0; BUILD=1
while (( $# )); do case $1 in --workers) W=$2; shift 2;; --sim) SIM=$2; shift 2;; --erase) ERASE=1; shift;; --no-build) BUILD=0; shift;; *) echo "unknown $1"; exit 2;; esac; done
A=${0:A:h:h:h}; DD=${INVENTORY_DD:-$A/build/gauntlet-dd}; export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p $OUT; OUT=$(cd $OUT && pwd)
ONLY=(${(f)"$(grep -v '^#' $A/scripts/inventory/ui_hostfree.txt | grep . | sed 's|^|-only-testing:AirPadUITests/|')"})
if (( BUILD )); then
  xcodebuild -project $A/AirPad.xcodeproj -scheme AirPad -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD build-for-testing > $OUT/build.log 2>&1 || { echo "build failed"; exit 1; }
fi
if (( ERASE )); then xcrun simctl shutdown $SIM 2>/dev/null; xcrun simctl erase $SIM; fi
T0=$(date +%s)
xcodebuild -project $A/AirPad.xcodeproj -scheme AirPad -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD \
  -parallel-testing-enabled YES -parallel-testing-worker-count $W -collect-test-diagnostics never \
  -resultBundlePath $OUT/result.xcresult "${ONLY[@]}" test-without-building > $OUT/xcuitest.log 2>&1
RC=$?
grep -E "^Test case '.*' (passed|failed|skipped)" $OUT/xcuitest.log | sed -E "s/Test case '-?\[?AirPadUITests\.?//; s/\]?' / /" > $OUT/results.txt
print -r -- "host-free UI rows: $(grep -c ' passed' $OUT/results.txt) passed · $(grep -c ' failed' $OUT/results.txt) failed · $(grep -c ' skipped' $OUT/results.txt) skipped of ${#ONLY} · workers $W · wall $(( $(date +%s) - T0 ))s (exit $RC)"
grep ' failed' $OUT/results.txt
exit $RC
