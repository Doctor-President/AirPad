#!/bin/zsh
# 1.0r S0a/S0c — forward-format probe on one Simulator (one folder = what two devices share over iCloud).
# Seeds the Sample library into the persistent -UITestLibrary scratch, futurizes it (versions → 99 + unknown
# fields), then runs this build against it twice: A = open only, B = open an entry + type into its note
# (XCUITest ForwardFormatProbe). Diffs each against the futurized snapshot.
# Usage: probe.sh <udid> <derived-data> <out-dir>
set -u
UDID=$1; DD=$2; OUT=$3; BID=com.doctorpresident.airpad
HERE=${0:A:h}; DEV=/Applications/Xcode.app/Contents/Developer
mkdir -p $OUT; rm -rf $OUT/after-control $OUT/seeded $OUT/before $OUT/after-open $OUT/after-edit
APP=$(ls -d $DD/Build/Products/Debug-iphonesimulator/AirPad.app)
xcrun simctl boot $UDID 2>/dev/null; xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl install $UDID $APP
run() { # $1 label, rest = args
  local label=$1; shift
  xcrun simctl launch --terminate-running-process --console-pty $UDID $BID "$@" > $OUT/console-$label.log 2>&1 &
  local pid=$!; sleep 30; xcrun simctl terminate $UDID $BID 2>/dev/null; sleep 2; kill $pid 2>/dev/null
}
scratch() { echo "$(xcrun simctl get_app_container $UDID $BID data)/Library/Caches/AirPadUITestScratch"; }
run seed -UITestLibrary -UITestLibraryFresh -UITestSampleLibrary
S=$(scratch); cp -R "$S" $OUT/seeded
python3 $HERE/futurize.py "$S" > $OUT/futurize.txt
cp -R "$S" $OUT/before
# A — open only
run open -UITestLibrary -UITestSampleLibrary
cp -R "$S" $OUT/after-open
python3 $HERE/diff.py $OUT/before $OUT/after-open > $OUT/diff-open.md
# C (control) — the same edit on the UN-futurized library must land on disk, or B proves nothing
if [[ ${CONTROL:-1} == 1 ]]; then
  S=$(scratch); rm -rf "$S"; cp -R $OUT/seeded "$S"
  DEVELOPER_DIR=$DEV xcodebuild test-without-building -project ${HERE:h:h}/AirPad.xcodeproj -scheme AirPad \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath $DD \
    -only-testing:AirPadUITests/ForwardFormatProbe > $OUT/xcuitest-control.log 2>&1
  S=$(scratch); rm -rf $OUT/after-control; cp -R "$S" $OUT/after-control
  python3 $HERE/diff.py $OUT/seeded $OUT/after-control > $OUT/diff-control.md
  echo "control: $(grep -rl FWDPROBE $OUT/after-control | wc -l | tr -d ' ') file(s) carry the edit"
fi
# B — restore the futurized library, then open an entry + type into its note
S=$(scratch); rm -rf "$S"; cp -R $OUT/before "$S"
DEVELOPER_DIR=$DEV xcodebuild test-without-building -project ${HERE:h:h}/AirPad.xcodeproj -scheme AirPad \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath $DD \
  -only-testing:AirPadUITests/ForwardFormatProbe > $OUT/xcuitest-edit.log 2>&1
S=$(scratch); cp -R "$S" $OUT/after-edit   # the test reinstalls → the data container path can move
python3 $HERE/diff.py $OUT/before $OUT/after-edit > $OUT/diff-edit.md
grep -E "\*\* TEST|FWDPROBE" $OUT/xcuitest-edit.log | head -5
tail -1 $OUT/diff-open.md; tail -1 $OUT/diff-edit.md
