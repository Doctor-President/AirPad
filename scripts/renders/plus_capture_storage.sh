#!/bin/zsh
# live-26 (3) — run the REAL "+" tap test (PlusCaptureOverlap: a synthetic two-line note typed into "+" Capture, Done),
# then read what the scratch library STORED for it (the -UITestLibrary scratch survives until the next launch) and
# export the test's stills. Fails if any stored note content carries `**`.
#   [PLUS_FONT=sourceSerif4|lato|sfPro|newYork] scripts/renders/plus_capture_storage.sh <out_dir>
set -uo pipefail
OUT=${1:?out}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT; rm -rf $OUT/run.xcresult
TEST_RUNNER_PLUS_FONT=${PLUS_FONT:-lato} DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project AirPad.xcodeproj -scheme AirPad \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build/gauntlet-dd -resultBundlePath $OUT/run.xcresult \
  -only-testing:AirPadUITests/PlusCaptureOverlap 2>&1 | grep -E "Test Case.*(passed|failed)|error:" | head
DATA=$(xcrun simctl get_app_container $SIM $APPID data)
python3 - "$DATA/Library/Caches/AirPadUITestScratch/nodes" <<'PY'
import sys, os, json, glob
hits = 0
for f in glob.glob(os.path.join(sys.argv[1], "**", "*.json"), recursive=True):
    try: d = json.load(open(f))
    except Exception: continue
    for it in d.get("items", []):
        c = it.get("content") or ""
        if "harbour office" in c:
            hits += 1
            print("stored:", json.dumps(c)); print("  `**` present:", "**" in c)
print("notes found:", hits)
PY
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcresulttool export attachments --path $OUT/run.xcresult --output-path $OUT/attachments >/dev/null 2>&1; ls $OUT/attachments | head
