#!/bin/zsh
# live-26 (4) — the App Store configuration vs the TestFlight one (T's 10-18 values at the tuner's defaults), same
# views (AppStoreLookStills: Card · List · Map · Librarian half), synthetic content (a fresh install's Sample Library),
# light + dark. Release builds from build/dd-appstore and build/dd-tf (build-for-testing). Stills → <out>/<cfg>-<mode>-<view>.png
set -uo pipefail
OUT=${1:?out}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
for cfg in ${=CFGS:-appstore tf}; do
  for m in light dark; do
    xcrun simctl terminate $SIM $APPID 2>/dev/null; xcrun simctl uninstall $SIM $APPID
    xcrun simctl install $SIM build/dd-$cfg/Build/Products/Release-iphonesimulator/AirPad.app
    for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do
      xcrun simctl spawn $SIM defaults write $APPID com.airpad.callouts.$k -bool YES
    done
    xcrun simctl ui $SIM appearance $m
    R=$OUT/$cfg-$m.xcresult; rm -rf $R
    xcodebuild test-without-building -xctestrun $(ls build/dd-$cfg/Build/Products/*.xctestrun | head -1) \
      -destination "platform=iOS Simulator,id=$SIM" -resultBundlePath $R -only-testing:AirPadUITests/AppStoreLookStills 2>&1 \
      | grep -E "Test Case.*(passed|failed)|error:" | head -3
    python3 - "$R" "$OUT" "$cfg-$m" <<'PY'
import sys, json, subprocess, shutil, os
r, out, tag = sys.argv[1:4]
att = r + ".att"; subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", r, "--output-path", att], capture_output=True)
for t in json.load(open(os.path.join(att, "manifest.json"))):
    for a in t["attachments"]:
        n = a["suggestedHumanReadableName"].split("_")[0]
        if n.endswith(".txt"): continue
        shutil.copy(os.path.join(att, a["exportedFileName"]), os.path.join(out, f"{tag}-{n}.png"))
PY
  done
done
xcrun simctl ui $SIM appearance light; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
