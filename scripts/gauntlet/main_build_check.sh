#!/bin/zsh
# Follow-up freeze on a MAIN build (no Gauntlet hooks) on T's phone — rules out the CH-0 instrumentation.
# Uses the throwaway MainBuildFreezeRepro test built from a `main` worktree (never committed). Isolated
# -UITestLibrary; turn 1 is a REAL answer through the phone's normal Host pairing. A hang = the test stalls
# after SENT_FOLLOWUP with no RESPONSIVE line for 60 s → this watchdog terminates the app on the device.
#   scripts/gauntlet/main_build_check.sh <run_dir> <udid> <worktree> <products_dd>
set -uo pipefail
RUN_DIR=${1:?}; UDID=${2:?}; WT=${3:?}; DD=${4:?}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"; RUN_DIR=$(cd "$RUN_DIR" && pwd); L="$RUN_DIR/xcuitest.log"
( cd "$WT" && xcodebuild -project AirPad.xcodeproj -scheme AirPad -destination "platform=iOS,id=$UDID" -derivedDataPath "$DD" \
    -only-testing:AirPadUITests/MainBuildFreezeRepro/testFollowUpAfterRealAnswers test-without-building > "$L" 2>&1 ) &
XPID=$!
while kill -0 $XPID 2>/dev/null; do
  sleep 5
  last=$(grep -E "MAINREPRO ATTEMPT [0-9]+ (SENT_FOLLOWUP|RESPONSIVE)" "$L" | tail -1)
  if [[ $last == *SENT_FOLLOWUP* ]]; then
    sent=$(echo $last | awk '{print $NF}' | cut -d. -f1)
    if (( $(date +%s) - sent > 60 )); then
      PID=$(xcrun devicectl device info processes --device $UDID 2>/dev/null | grep "AirPad.app/AirPad" | awk '{print $1}' | head -1)
      echo "WATCHDOG $(date +%T): no RESPONSIVE 60s after follow-up → app HUNG (pid $PID) — terminating" | tee -a "$RUN_DIR/run.log"
      echo "$last" >> "$RUN_DIR/hangs.log"
      [[ -n $PID ]] && xcrun devicectl device process terminate --device $UDID --pid $PID --kill >/dev/null 2>&1
      sleep 20
    fi
  fi
done
grep -E "MAINREPRO|WATCHDOG" "$L" "$RUN_DIR/run.log" 2>/dev/null | sed 's/^[^:]*://' | grep -E "SENT_FOLLOWUP|DONE|not running|WATCHDOG"
