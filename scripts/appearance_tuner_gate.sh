#!/bin/zsh
# live-22 (2) — the appearance tuner is compiled OUT of App Store builds. Builds Release for device twice — TestFlight
# mode (AIRPAD_TF_FLAG=TESTFLIGHT, as scripts/testflight_upload.sh does) and App Store mode (no flag, as
# AIRPAD_APP_STORE_BUILD=1 archives) — and counts the tuner's strings in each AirPad binary. PASS = every probe present
# in TestFlight mode (the positive control: "0 hits" alone proves nothing) and absent in App Store mode.
#   scripts/appearance_tuner_gate.sh [out_dir]
set -uo pipefail
A=${0:A:h:h}; OUT=${1:-$A/build/tuner-gate}; mkdir -p $OUT
# live-23: "saturationBlendMode" left the probes — the frost backdrop ships now (T's tuned Librarian, `LibrarianSurfaceSpec`).
PROBES=("Appearance tuner" "appearanceTuning.v1" "AppearanceTunerWindow" "Frost 50% + glass" "Before = thin material" "Fade length (of the hero zone)" "tunerCaptureControls" "tunerCardContent")
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fail=0
for mode in testflight appstore; do
  args=(); [[ $mode == testflight ]] && args=(AIRPAD_TF_FLAG=TESTFLIGHT)
  xcodebuild -project $A/AirPad.xcodeproj -scheme AirPad -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath $OUT/dd-$mode CODE_SIGNING_ALLOWED=NO "${args[@]}" build > $OUT/build-$mode.log 2>&1 \
    || { echo "BUILD FAILED ($mode) — $OUT/build-$mode.log"; exit 2; }
  bin=$OUT/dd-$mode/Build/Products/Release-iphoneos/AirPad.app/AirPad
  for p in "${PROBES[@]}"; do
    n=$(strings -a $bin | grep -c -F -- "$p")
    want=$([[ $mode == testflight ]] && echo ">0" || echo "0")
    ok=1; [[ $mode == testflight && $n -eq 0 ]] && ok=0; [[ $mode == appstore && $n -ne 0 ]] && ok=0
    (( ok )) || fail=1
    printf "%-4s %-10s %-24s hits=%s (want %s)\n" $([[ $ok == 1 ]] && echo PASS || echo FAIL) $mode "$p" $n $want
  done
done
(( fail )) && { echo "[AppearanceTunerGate] FAIL"; exit 1; } || echo "[AppearanceTunerGate] PASS"
