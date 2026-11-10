#!/bin/zsh
# Mac batch C step 3 — CHECKS at ws-mac HEAD. Status lines in build/mac-c/step3/status; logs beside.
cd ${0:A:h:h:h}
DD=build/mac-c; O=$DD/step3; mkdir -p $O; ST=$O/status; : > $ST
S2=C4B92815-18BB-4871-80A8-BCCFDB2373EA; S3=94908949-765A-4397-9755-00C2A1EFE89E; SST=D8D41476-3F36-4C43-87A3-97749B7C8C6A
I13=3552FEB6-488F-4507-9D40-D83ECE51A432; MA=096E2D93-EE7A-4856-9F52-67857AFCC981; MB=DE4884A1-685E-4931-AB50-FDF2B23562E3
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
step() { echo "$(date +%H:%M:%S) $*" >> $ST; }
scheme() { git checkout -- AirPad.xcodeproj/xcshareddata/xcschemes/AirPad.xcscheme 2>/dev/null; }
step "HEAD $(git rev-parse --short HEAD)"
# --- iOS builds (HEAD + baseline f502435f)
for C in Debug Release; do
  xcodebuild -project AirPad.xcodeproj -scheme AirPad -configuration $C -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath $DD/dd-ios-${C:l} build > $O/build-$C.log 2>&1; step "ios build $C exit $?"
done
B=.claude/worktrees/macc-base-f502
(cd $B && xcodebuild -project AirPad.xcodeproj -scheme AirPad -configuration Debug -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath build/dd-base build > ../../../$O/build-base.log 2>&1); step "baseline f502435f build exit $?"
(cd $B && git checkout -- AirPad.xcodeproj/xcshareddata/xcschemes/AirPad.xcscheme 2>/dev/null)
scheme
DBG=$DD/dd-ios-debug/Build/Products/Debug-iphonesimulator/AirPad.app
REL=$DD/dd-ios-release/Build/Products/Release-iphonesimulator/AirPad.app
BASE=$B/build/dd-base/Build/Products/Debug-iphonesimulator/AirPad.app
# --- iPhone stills: f502435f vs HEAD (+ launch-to-launch + ribs control)
SO=$O/stills; rm -rf $SO; mkdir -p $SO; export SIM=$SST; xcrun simctl boot $SST 2>/dev/null; xcrun simctl bootstatus $SST -b >/dev/null
export VIEWS="dashboard recents list cards entry chats quik"
for LOOK in light dark; do
  export LOOK
  xcrun simctl install $SST $BASE; zsh scripts/mac/shoot_ios.sh $SO base-$LOOK
  xcrun simctl install $SST $DBG;  zsh scripts/mac/shoot_ios.sh $SO new-$LOOK
  xcrun simctl install $SST $DBG;  zsh scripts/mac/shoot_ios.sh $SO new2-$LOOK
done
LOOK=light VIEWS="dashboard entry" EXTRA="-glass.ribPitchScale 0.9" zsh scripts/mac/shoot_ios.sh $SO ctl-light
{ for LOOK in light dark; do
  echo "== $LOOK base(f502435f) vs new"; MASK_TOP=200 python3 scripts/mac/imgdiff.py $SO base-$LOOK new-$LOOK $=VIEWS
  echo "== $LOOK new vs new2 (launch-to-launch)"; MASK_TOP=200 python3 scripts/mac/imgdiff.py $SO new-$LOOK new2-$LOOK $=VIEWS
done; echo "== CONTROL new vs ribs ×0.9 (must differ)"; MASK_TOP=200 python3 scripts/mac/imgdiff.py $SO new-light ctl-light dashboard entry; } > $SO/diff.txt 2>&1
xcrun simctl shutdown $SST; step "iphone stills done (diff.txt)"
# --- self-tests (inventory) + unit
xcrun simctl erase $S2
python3 scripts/inventory/selftests.py --sim $S2 --app $DBG --out $O/selftests > $O/selftests.log 2>&1; step "selftests exit $? · $(tail -1 $O/selftests.log)"
xcodebuild test -project AirPad.xcodeproj -scheme AirPad -destination id=$S2 -derivedDataPath $DD/dd-ios-debug -only-testing:AirPadTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 -collect-test-diagnostics never > $O/unit.log 2>&1; step "unit exit $? · $(grep -E 'Executed [0-9]+ tests' $O/unit.log | tail -1)"
scheme
# --- C-batch self-tests on iPhone (unchanged-behaviour rows)
for T in MacEnrichServerSelfTest DropImportSelfTest; do
  xcrun simctl terminate $S2 com.doctorpresident.airpad 2>/dev/null
  xcrun simctl launch --console-pty --terminate-running-process $S2 com.doctorpresident.airpad -UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -StubAuthorModel -$T -MacEnrichEndpoint http://127.0.0.1:11434 > $O/iphone-$T.log 2>&1 &
  LP=$!; for i in {1..150}; do grep -q "$T\] [PF]A" $O/iphone-$T.log && break; sleep 1; done; sleep 2; kill $LP 2>/dev/null
  step "iphone $T: $(grep -m1 "$T\] [PF]A" $O/iphone-$T.log | sed 's/^.*\] //')"
done
xcrun simctl terminate $S2 com.doctorpresident.airpad 2>/dev/null
# --- iPhone: the entry menus stay off (+ iPad UI tests)
xcodebuild test -project AirPad.xcodeproj -scheme AirPad -destination id=$S2 -derivedDataPath $DD/dd-ios-debug -only-testing:AirPadUITests/EntryMenusUI -collect-test-diagnostics never > $O/ui-iphone.log 2>&1; step "iPhone EntryMenusUI exit $?"
xcrun simctl shutdown $S2
xcrun simctl boot $I13 2>/dev/null
xcodebuild test -project AirPad.xcodeproj -scheme AirPad -destination id=$I13 -derivedDataPath $DD/dd-ios-debug -only-testing:AirPadUITests/IPadKeyCommands -only-testing:AirPadUITests/IPadEditorKeys -only-testing:AirPadUITests/EntryMenusUI -only-testing:AirPadUITests/IPadRotation -collect-test-diagnostics never > $O/ui-ipad.log 2>&1; step "iPad UI tests exit $? · $(grep -E 'Executed [0-9]+ tests' $O/ui-ipad.log | tail -1)"
xcrun simctl shutdown $I13; scheme
# --- F3, gate, hooks, clean install
scripts/check_project_yml.sh > $O/f3.log 2>&1; step "F3 $(tail -1 $O/f3.log)"
zsh scripts/appearance_tuner_gate.sh $O/gate > $O/gate.log 2>&1; step "gate exit $? · $(tail -1 $O/gate.log)"
zsh scripts/replacement/hook_scan.sh $O/gate/dd-appstore/Build/Products/Release-iphoneos/AirPad.app $DBG $O/hooks > $O/hooks.log 2>&1; step "hooks exit $? · $(head -1 $O/hooks.log)"
xcrun simctl erase $S3; xcrun simctl boot $S3; xcrun simctl bootstatus $S3 -b >/dev/null
xcrun simctl install $S3 $REL
C=$(xcrun simctl get_app_container $S3 com.doctorpresident.airpad app)
for p in "" PlugIns/AirPadShare.appex/ PlugIns/AirPadWidgets.appex/; do echo "$p: $(plutil -extract CFBundleShortVersionString raw $C/${p}Info.plist) ($(plutil -extract CFBundleVersion raw $C/${p}Info.plist))"; done > $O/clean-versions.txt
xcrun simctl launch $S3 com.doctorpresident.airpad > /dev/null; sleep 15; xcrun simctl io $S3 screenshot $O/clean-1.png >/dev/null 2>&1
step "clean install · running=$(xcrun simctl spawn $S3 launchctl list | grep -c airpad) · $(tr '\n' ' ' < $O/clean-versions.txt)"
xcrun simctl terminate $S3 com.doctorpresident.airpad; xcrun simctl shutdown $S3
# --- iPhone Map rest (0 frames)
SIM=$I13 APP=$DBG OUT=$O/rest-ipad TAG=after CASES="dark:glass light:flat" WAIT=30 zsh ~/Developer/Ops/design-refs/map-rest/scripts/rest.sh > $O/rest-ipad.log 2>&1
xcrun simctl boot $S2 2>/dev/null; SIM=$S2 APP=$DBG OUT=$O/rest-iphone TAG=after CASES="dark:glass light:flat" WAIT=30 zsh ~/Developer/Ops/design-refs/map-rest/scripts/rest.sh > $O/rest-iphone.log 2>&1
for d in rest-iphone rest-ipad; do for f in $O/$d/*.console; do step "$d ${f:t:r}: MAPREST last5=$(grep -o 'MAPREST\] frames=[0-9]*' $f | tail -5 | sed 's/.*=//' | tr '\n' ',') $(grep cpu5s $O/$d/cpu.txt | grep ${f:t:r} | sed 's/.*cpu5s=/cpu=/')"; done; done
xcrun simctl shutdown $S2; xcrun simctl shutdown $I13
# --- Mac builds
for C in Debug Release; do
  xcodebuild -project AirPad.xcodeproj -scheme AirPad -configuration $C -destination "generic/platform=macOS,variant=Mac Catalyst" -derivedDataPath $DD/dd-mac-${C:l} build > $O/mac-$C.log 2>&1; step "mac $C exit $?"
done
scheme
MREL=$DD/dd-mac-release/Build/Products/Release-maccatalyst/AirPad.app
codesign --verify --deep --strict $MREL > $O/mac-verify.log 2>&1 && step "mac Release codesign verify OK · $(lipo -archs $MREL/Contents/MacOS/AirPad) · MLX symbols $(nm $MREL/Contents/MacOS/AirPad 2>/dev/null | grep -ci mlx) · hardened=$(codesign -dv $MREL 2>&1 | grep -c 'runtime')" || step "mac Release codesign verify FAILED"
# --- two-device matrix
python3 scripts/twodevice/matrix.py $DBG $MA $MB $O/twodev > $O/twodev.log 2>&1; step "matrix exit $? · $(tail -1 $O/twodev.log)"
xcrun simctl shutdown $MA; xcrun simctl shutdown $MB
git status --short >> $ST
step DONE
