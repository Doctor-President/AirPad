#!/bin/zsh
# 1.1-A (6) — build the two dev-signed Release-iphoneos apps map_ground_trace.sh installs (≈ 8 min each). Mac-only, no device.
#   A = this tree as-is (Info.plist WITHOUT CADisableMinimumFrameDurationOnPhone → the phone caps at 60 Hz, today's state)
#   B = the same + CADisableMinimumFrameDurationOnPhone = YES (ProMotion 120 Hz unlocked), added for the build, then reverted
# Both: Release (-O, real CPU numbers) with the DEBUG harness compiled in (AIRPAD_TF_FLAG=DEBUG; App Store shader text).
#   scripts/perf/map_ground_build.sh [a|b|both]
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
WT=${0:A:h:h:h}; OUTD=$WT/build
cd $WT
b() {  # b <dd>
  xcodebuild -project AirPad.xcodeproj -scheme AirPad -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath $1 -allowProvisioningUpdates DEVELOPMENT_TEAM=8XM4B5F42Y CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    "AIRPAD_TF_FLAG=DEBUG" build 2>&1 | grep -E " error:|BUILD" ; }
restore() { git -C $WT checkout -- AirPad/Info.plist AirPad.xcodeproj/xcshareddata/xcschemes/AirPad.xcscheme 2>/dev/null || true; }
trap restore EXIT
[[ ${1:-both} != b ]] && b $OUTD/mg-a-dd
if [[ ${1:-both} != a ]]; then
  plutil -insert CADisableMinimumFrameDurationOnPhone -bool YES AirPad/Info.plist
  b $OUTD/mg-b-dd
  restore
  /usr/libexec/PlistBuddy -c "Print :CADisableMinimumFrameDurationOnPhone" $OUTD/mg-b-dd/Build/Products/Release-iphoneos/AirPad.app/Info.plist
fi
