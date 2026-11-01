#!/bin/zsh
# 1.1-D — stills of the server UI against the FAKES (never T's servers): Settings → Your own models, its Models screen,
# and the pill's quick switcher, for an Ollama fake and an LM Studio fake.
#   shoot_server_ui.sh <sim-udid> <AirPad.app (Debug)> <out-dir>
set -u
SIM=$1; APP=$2; OUT=$3
HERE=${0:A:h}; FAKE=$HERE/../gauntlet/restore_fake.py; BID=com.doctorpresident.airpad
mkdir -p $OUT/o $OUT/l
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
OP=$(free_port); LP=$(free_port)
FAKE_OLLAMA_VERSION=0.13.2 python3 $FAKE ollama $OP $OUT/o & P1=$!
python3 $FAKE lmstudio $LP $OUT/l & P2=$!
trap 'kill $P1 $P2 2>/dev/null' EXIT
sleep 1
# a loaded model on each (as the user's server would have)
curl -s -X POST http://127.0.0.1:$OP/api/generate -d '{"model":"qwen3:8b-q4_K_M","options":{"num_ctx":20480}}' >/dev/null
curl -s -X POST http://127.0.0.1:$LP/api/v1/models/load -d '{"model":"qwen/qwen3-8b","context_length":8192}' >/dev/null
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM $APP || exit 1
shot() {  # name, appearance, endpoint, screen
  xcrun simctl ui $SIM appearance $2
  xcrun simctl terminate $SIM $BID 2>/dev/null
  xcrun simctl launch $SIM $BID -Screen $4 -DebugEndpointURL $3 -airpadLibrarianRoute endpoint -UITestLibrary -UITestLibraryFresh >/dev/null
  sleep 6
  xcrun simctl io $SIM screenshot $OUT/$1.png >/dev/null 2>&1 && echo "$OUT/$1.png"
}
for ap in light dark; do
  shot ollama-advanced-$ap $ap http://127.0.0.1:$OP settings-advanced
  shot ollama-models-$ap $ap http://127.0.0.1:$OP settings-servermodels
  shot ollama-picker-$ap $ap http://127.0.0.1:$OP modelpicker
done
shot lms-models-light light http://127.0.0.1:$LP settings-servermodels
shot lms-picker-light light http://127.0.0.1:$LP modelpicker
shot closed-advanced-light light http://127.0.0.1:9 settings-advanced
shot closed-advanced-dark dark http://127.0.0.1:9 settings-advanced   # 1.1-D fix-up: the network hint
xcrun simctl ui $SIM content_size accessibility-large
shot closed-advanced-light-ax light http://127.0.0.1:9 settings-advanced
xcrun simctl ui $SIM content_size large
xcrun simctl terminate $SIM $BID 2>/dev/null
