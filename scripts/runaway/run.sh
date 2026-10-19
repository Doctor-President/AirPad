#!/bin/zsh
# live-28 (1) — the runaway rows on the REAL Host path with a FAKE Ollama. Never touches T's Host (:8787) or T's Ollama
# (:11434): the fake runs on :11600, a Host built from airpad-host's branch on :8798 with a scratch identity/secret.
#   scripts/runaway/run.sh <out_dir> <xctestrun> [test ids, comma-separated, default all of RunawayAnswerUI]
set -uo pipefail
OUT=${1:?out_dir}; XCTR=${2:?xctestrun}; ONLY=${3:-}
AIRPAD=~/Developer/AirPad; HOSTREPO=~/Developer/airpad-host
SIM=${RUNAWAY_SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}
FP=11600; HP=8798
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); SCR=$(mktemp -d "${TMPDIR:-/tmp}/runaway-host.XXXX")
log() { print -r -- "[runaway $(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }
python3 $AIRPAD/scripts/runaway/fake_ollama.py $FP "$OUT" 60 >> "$OUT/fake.log" 2>&1 &
FAKE_PID=$!
cleanup() { kill $HOST_PID $FAKE_PID 2>/dev/null; rm -rf "$SCR"; }
trap cleanup EXIT
(cd $HOSTREPO && go build -o "$SCR/airpad-host" ./cmd/airpad-host) || { log "Host build FAILED"; exit 1; }
SECRET=$(openssl rand -hex 32)
for i in {1..20}; do curl -s -m 1 127.0.0.1:$FP/api/version >/dev/null && break; sleep 0.5; done
HOST_SECRET=$SECRET "$SCR/airpad-host" --headless --observe --listen 127.0.0.1:$HP --ollama 127.0.0.1:$FP \
  --ollama-bin /usr/bin/false --manifest $HOSTREPO/manifest.json \
  --identity "$SCR/identity.key" --secret-file "$SCR/secret" >> "$OUT/host.log" 2>&1 &
HOST_PID=$!
TOKEN=$(HOST_SECRET=$SECRET "$SCR/airpad-host" --print-token)
for i in {1..60}; do HPK=$(curl -s -m 3 127.0.0.1:$HP/health -H "Authorization: Bearer $TOKEN" | python3 -c "import json,sys;print(json.load(sys.stdin).get('hostPublicKey',''))" 2>/dev/null); [[ -n $HPK ]] && break; sleep 1; done
[[ -z ${HPK:-} ]] && { log "scratch Host never became healthy"; exit 1; }
log "scratch Host $(git -C $HOSTREPO branch --show-current)@$(git -C $HOSTREPO rev-parse --short HEAD) pid=$HOST_PID :$HP → fake Ollama pid=$FAKE_PID :$FP"
TESTS=()
if [[ -n $ONLY ]]; then for t in ${(s:,:)ONLY}; do [[ $t == */* || $t == *UI ]] && TESTS+=(-only-testing:AirPadUITests/$t) || TESTS+=(-only-testing:AirPadUITests/RunawayAnswerUI/$t); done
else TESTS=(-only-testing:AirPadUITests/RunawayAnswerUI); fi
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null 2>&1
rm -rf "$OUT/result.xcresult"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TEST_RUNNER_WEBSWITCH_RED=${WEBSWITCH_RED:-0} TEST_RUNNER_RUNAWAY_FAKE_URL=http://127.0.0.1:$FP \
TEST_RUNNER_RUNAWAY_HOST_ARGS="-DebugHostURL http://127.0.0.1:$HP -DebugHostSecret $SECRET -DebugHostPubKey $HPK" \
  xcodebuild test-without-building -xctestrun "$XCTR" -destination "id=$SIM" "${TESTS[@]}" \
  -resultBundlePath "$OUT/result.xcresult" > "$OUT/xcuitest.log" 2>&1
log "xcodebuild exit $?"
/usr/bin/grep -E "\[Runaway\]|Test Case .*(passed|failed)" "$OUT/xcuitest.log" | /usr/bin/grep -v "^\s*t = " | tee -a "$OUT/run.log"
sleep ${RUNAWAY_AFTER_SEC:-20}
log "still generating ${RUNAWAY_AFTER_SEC:-20} s after the last row (the Mac's view): $(curl -s -m 3 127.0.0.1:$FP/status)"
log "fake Ollama streams:"; cat "$OUT/streams.jsonl" 2>/dev/null | tee -a "$OUT/run.log"
log "web-search requests (live-28 A2):"; cat "$OUT/web.jsonl" 2>/dev/null | tee -a "$OUT/run.log" || true
/usr/bin/grep -E "chat→ollama|chat done|chat/e2e" "$OUT/host.log" | cut -c1-220 > "$OUT/host-obs.log"
