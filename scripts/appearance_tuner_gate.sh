#!/bin/zsh
# live-22 (2) — the appearance tuner is compiled OUT of App Store builds. Builds Release for device twice — TestFlight
# mode (AIRPAD_TF_FLAG=TESTFLIGHT, as scripts/testflight_upload.sh does) and App Store mode (no flag, as
# AIRPAD_APP_STORE_BUILD=1 archives) — and counts the tuner's strings in each AirPad binary. PASS = every probe present
# in TestFlight mode (the positive control: "0 hits" alone proves nothing) and absent in App Store mode.
#   scripts/appearance_tuner_gate.sh [out_dir]
set -uo pipefail
A=${0:A:h:h}; OUT=${1:-$A/build/tuner-gate}; mkdir -p $OUT
# live-23: "saturationBlendMode" left the probes — the frost backdrop ships now (T's tuned Librarian, `LibrarianSurfaceSpec`).
# live-26: the floating-buttons switch (3d) and "Fade into body" / "Match fluted" (3c) are tuner-only too.
# 2026-10-17 brief: the per-pill sections + the accordion (live-24's "Graded tint on the pills" / "Ask pill + search pill" left the sheet).
# live-24: + the graded-tint section and the reading veil (LibrarianGlass types ship; their tuner does not). Probes must be > 15 bytes: Swift keeps shorter strings inline in code, invisible to `strings`.
PROBES=("Appearance tuner" "appearanceTuning.v1" "AppearanceTunerWindow" "Frost 50% + glass" "Before = thin material" "Fade length (of the hero zone)" "tunerCaptureControls" "tunerCardContent" "Graded presets (all three pills + the panel)" "The Ask bar mirrors the search pill" "Reading veil (behind the transcript)" "Rim while answering" "AppearanceTunerOpenSection" "tunerFloatingButtons" "tunerFadeMatchFluted" "Fade into body carries it down" "dateline; above it, your fade alone" "chat scroll trace (live-29 C1)")
# live-32: + the live-31 web baseline, the web trace, the evidence self-test, the server model pin, the Wikipedia stub
# switches (DEBUG-only) and the evidence rules, the Wikipedia row, the server reasoning switch (shipped).
# live-31: + the transcript's live-30 baseline / motion recorder, the Host web self-test, the table perf seed (DEBUG-only)
# and the provider-failed line (shipped).
# live-28 — DEBUG-only hooks must be in NEITHER Release build; the shipped caps line must be in BOTH (the positive control).
# live-30 — + the (A1) RED switch and the transcript open trace (DEBUG-only); the (A1) framing line ships in both.
DEBUG_PROBES=("AnswerWallClockSec" "WebSearchSwitchIgnored" "WebSearchBaseURL" "[AnswerCapSelfTest]" "[TitleCaseSelfTest]" "AppleWebFollowUpOff" "TranscriptOpenTrace" "TranscriptLive30" "TranscriptMotionLog" "[HostWebSelfTest]" "GauntletSeedTable" "Live31Web" "WebTrace" "[WebEvidenceSelfTest]" "DebugEndpointModel" "WikipediaBaseURL" "WikipediaLive")
SHIPPED_PROBES=("Stopped: the answer ran too long" "Tavily (free, no card)" "Web search is off. [Turn it on" "they come from the app's search, not from the user" "The web search didn't go through" "THE RESULTS ARE RIGHT" "Searched the web and Wikipedia" "reasoning_effort")
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
  for p in "${DEBUG_PROBES[@]}"; do
    n=$(strings -a $bin | grep -c -F -- "$p"); ok=$(( n == 0 )); (( ok )) || fail=1
    printf "%-4s %-10s %-24s hits=%s (want 0, DEBUG only)\n" $([[ $ok == 1 ]] && echo PASS || echo FAIL) $mode "$p" $n
  done
  for p in "${SHIPPED_PROBES[@]}"; do
    n=$(strings -a $bin | grep -c -F -- "$p"); ok=$(( n > 0 )); (( ok )) || fail=1
    printf "%-4s %-10s %-24s hits=%s (want >0, shipped)\n" $([[ $ok == 1 ]] && echo PASS || echo FAIL) $mode "$p" $n
  done
done
(( fail )) && { echo "[AppearanceTunerGate] FAIL"; exit 1; } || echo "[AppearanceTunerGate] PASS"
