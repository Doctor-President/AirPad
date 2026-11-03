#!/bin/zsh
# 1.1-D — the custom-server adapter against FAKE servers (scripts/gauntlet/restore_fake.py), in the Simulator.
# Never touches T's servers: scratch ports on 127.0.0.1 only.
#   fake_selftest.sh <sim-udid> <AirPad.app (Debug)> [out-dir]
# Runs -CustomServerSelfTest (pure) then -CustomServerFakeSelfTest (Ollama fake, LM Studio fake, a token-locked LM Studio
# fake, a closed port) and prints both verdicts; exit 0 only when both PASS.
set -u
SIM=$1; APP=$2; OUT=${3:-$(mktemp -d)}
HERE=${0:A:h}; FAKE=$HERE/../gauntlet/restore_fake.py; BID=com.doctorpresident.airpad
mkdir -p $OUT/ollama $OUT/lms $OUT/locked
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
OP=$(free_port); LP=$(free_port); KP=$(free_port); CP=$(free_port)
FAKE_OLLAMA_VERSION=0.13.2-fake python3 $FAKE ollama $OP $OUT/ollama & P1=$!
python3 $FAKE lmstudio $LP $OUT/lms & P2=$!
FAKE_LMS_TOKEN=fake-lms-token python3 $FAKE lmstudio $KP $OUT/locked & P3=$!
trap 'kill $P1 $P2 $P3 2>/dev/null' EXIT
sleep 1
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM $APP || exit 1
run() {  # name, done-regex, args…
  local name=$1 re=$2; shift 2
  xcrun simctl terminate $SIM $BID 2>/dev/null
  xcrun simctl launch --console-pty --terminate-running-process $SIM $BID "$@" -UITestLibrary -UITestLibraryFresh -EmbedCPUOnly > $OUT/$name.log 2>&1 &
  local L=$! t=0
  while (( t < 150 )); do sleep 1; ((t++)); grep -qE "$re" $OUT/$name.log && break; done
  sleep 1; kill $L 2>/dev/null; xcrun simctl terminate $SIM $BID 2>/dev/null
  grep -E "$re" $OUT/$name.log | head -1 || echo "$name: no verdict in ${t}s"
  grep -E "^FAIL |FAIL-ROW" $OUT/$name.log | head -20
}
run pure "\[CustomServerSelfTest\] (PASS|FAIL)" -CustomServerSelfTest
run fake "\[CustomServerFakeSelfTest\] (PASS|FAIL)" -CustomServerFakeSelfTest \
  -FakeOllamaURL http://127.0.0.1:$OP -FakeLMStudioURL http://127.0.0.1:$LP -FakeLMLockedURL http://127.0.0.1:$KP -FakeClosedURL http://127.0.0.1:$CP
grep -q "\[CustomServerSelfTest\] PASS" $OUT/pure.log && grep -q "\[CustomServerFakeSelfTest\] PASS" $OUT/fake.log
