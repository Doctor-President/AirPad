#!/bin/zsh
# Sweep 2b · 4.6 — compile (Mac Catalyst, -D PERFLOG -D DEVSWITCHES) + run the keeper's headless check. build/4x/ only.
ROOT=${0:A:h:h:h:h:h}; O=$ROOT/build/4x/keeper-test; mkdir -p $O
cp ${0:A:h}/keeper_test.swift $O/main.swift
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; SDK=$(xcrun --sdk macosx --show-sdk-path); IOS=$SDK/System/iOSSupport
xcrun swiftc -target arm64-apple-ios26.0-macabi -sdk $SDK -Fsystem $IOS/System/Library/Frameworks -I $IOS/usr/lib/swift \
  -L $IOS/usr/lib/swift -D PERFLOG -D DEVSWITCHES \
  -o $O/keeper_test $ROOT/AirPad/Services/MacLibraryKeeper.swift $ROOT/AirPad/Services/MacProofLog.swift $O/main.swift || exit 2
$O/keeper_test -Sweep4Log YES; e=$?
defaults delete keeper_test >/dev/null 2>&1; rm -f ~/Library/Preferences/keeper_test.plist; exit $e
