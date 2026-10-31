#!/bin/zsh
# 1.1-D — ServerModelsUI against a FAKE Ollama on a scratch port (never T's servers).
#   ui_test.sh <sim-udid> <derived-data> [result-bundle]
set -u
SIM=$1; DD=$2; RB=${3:-$DD/ServerModelsUI.xcresult}
HERE=${0:A:h}; FAKE=$HERE/../gauntlet/restore_fake.py; D=$(mktemp -d)
P=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
FAKE_OLLAMA_VERSION=0.13.2 python3 $FAKE ollama $P $D & F=$!
trap 'kill $F 2>/dev/null' EXIT
sleep 1
rm -rf $RB
TEST_RUNNER_FAKE_OLLAMA=http://127.0.0.1:$P DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ${HERE:h:h}/AirPad.xcodeproj -scheme AirPad -configuration Debug -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath $DD -resultBundlePath $RB test-without-building -only-testing:AirPadUITests/ServerModelsUI 2>&1 | grep -E "Test Case|error:|TEST |Executed" | tail -12
