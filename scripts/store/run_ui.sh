#!/bin/zsh
# 1.1 store — run one StoreShots test on <sim> and export its screenshots to <out>/.
#   run_ui.sh <sim> <testName> <out> [ENV=VAL ...]   (ENV vars are passed to the runner as TEST_RUNNER_<ENV>)
set -u
SIM=$1; T=$2; OUT=$3; shift 3
WT=~/Developer/AirPad/.claude/worktrees/ws-1.1d; DD=${DD:-$WT/build/DD-store-rel}; CONF=${CONF:-Release}
[[ $T == *Share* ]] || { xcrun simctl terminate $SIM com.apple.mobilesafari 2>/dev/null; xcrun simctl terminate $SIM com.apple.DocumentsApp 2>/dev/null; }
[[ $T == testServer ]] && xcrun simctl keychain $SIM reset   # the endpoint is kept in the (Simulator's) Keychain
MARK=$(mktemp -d); RB=$OUT/$T.xcresult; rm -rf $RB; mkdir -p $OUT
envs=(TEST_RUNNER_STORE_MARK=$MARK); for kv in "$@"; do envs+=(TEST_RUNNER_$kv); done
# Face ID: the test touches $MARK/faceid-match when the prompt is up; answer with a match.
( while true; do for f in $MARK/*(N); do [[ $f == *.done ]] && continue; [[ -e $f.done ]] && continue
    case ${f:t} in
      snap-*) xcrun simctl io $SIM screenshot --type=png $OUT/${${f:t}#snap-}.png >/dev/null 2>&1;;
      faceid-match) sleep 1; xcrun simctl spawn $SIM notifyutil -p com.apple.BiometricKit_Sim.pearl.match;;
      rec-start-*) n=${${f:t}#rec-start-}; mkdir -p $OUT/clips; pkill -INT -f "simctl io $SIM recordVideo"; sleep 1
        xcrun simctl io $SIM recordVideo --codec h264 --mask ignored --force $OUT/clips/$n.mov >/dev/null 2>&1 & echo $! > $MARK/pid-$n; sleep 1.5;;
      rec-stop-*) n=${${f:t}#rec-stop-}; kill -INT $(cat $MARK/pid-$n) 2>/dev/null
        for i in {1..50}; do kill -0 $(cat $MARK/pid-$n) 2>/dev/null || break; sleep 0.2; done
        kill -9 $(cat $MARK/pid-$n) 2>/dev/null;;
    esac
    touch $f.done; done; sleep 0.3; done ) & W=$!
env $envs DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project $WT/AirPad.xcodeproj -scheme AirPad \
  -configuration $CONF -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD -resultBundlePath $RB \
  test-without-building -collect-test-diagnostics never -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 -only-testing:AirPadUITests/StoreShots/$T > $OUT/$T.log 2>&1; grep -E "Test Case|error:|failed|StoreShots\]|Executed" $OUT/$T.log | tail -15
kill $W 2>/dev/null
python3 ${0:A:h}/export.py $RB $OUT
