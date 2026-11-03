#!/bin/zsh
# 1.0r S2b — UPGRADE TEST: TestFlight testers have the 1.0 build (4262602). Install it on an erased Simulator, let it
# seed the Sample Library, add a user entry the way the share sheet does (App Group inbox), then install the new build
# OVER it and launch twice. Compares the library before/after: nothing lost, nothing migrated wrongly, no read-only
# banner (the forward-format guard must not fire on an older library).
# Usage: upgrade_test.sh <udid> <old AirPad.app> <new AirPad.app> <out-dir>
set -u
UDID=$1; OLD=$2; NEW=$3; OUT=$4; BID=com.doctorpresident.airpad; GRP=group.com.doctorpresident.airpad
HERE=${0:A:h}
rm -rf $OUT; mkdir -p $OUT
xcrun simctl shutdown $UDID 2>/dev/null; xcrun simctl erase $UDID
xcrun simctl boot $UDID; xcrun simctl bootstatus $UDID -b >/dev/null
run() { local label=$1
  xcrun simctl launch --terminate-running-process --console-pty $UDID $BID > $OUT/console-$label.log 2>&1 &
  local pid=$!; sleep 40; xcrun simctl io $UDID screenshot $OUT/$label.png >/dev/null 2>&1
  xcrun simctl terminate $UDID $BID 2>/dev/null; sleep 2; kill $pid 2>/dev/null; }
libroot() { local c=$(xcrun simctl get_app_container $UDID $BID data)
  dirname "$(find "$c" -name corpus_index.json -not -path '*Caches*' | head -1)"; }
xcrun simctl install $UDID $OLD
run old-1                                    # first launch: seeds the Sample Library
G=$(xcrun simctl get_app_container $UDID $BID $GRP)
python3 $HERE/stage_share_entry.py "$(libroot)" "$G/AirPad/inbox" > $OUT/staged.txt
run old-2                                    # imports the staged share as a user entry
L=$(libroot); echo "library root: $L" > $OUT/root.txt
cp -R "$L" $OUT/lib-old
xcrun simctl install $UDID $NEW              # the update, over the old install
run new-1
cp -R "$(libroot)" $OUT/lib-new1
run new-2
cp -R "$(libroot)" $OUT/lib-new2
python3 $HERE/upgrade_compare.py $OUT/lib-old $OUT/lib-new2 "$(cat $OUT/staged.txt)" > $OUT/compare.md
grep -h "FormatGuard" $OUT/console-new-*.log | head -3
tail -6 $OUT/compare.md
