#!/bin/zsh
# live-32 (1)/(3) — LIVE web turns (real search providers, a real model) through the real Librarian (General).
#   scripts/live/run.sh <out_dir> <xctestrun> <set.json> <tavily|brave|none> [app launch args …]
# The route comes from the app args: T's server (`-DebugEndpointURL <url> -DebugEndpointModel <id> -ClearHostPairing YES`)
# or a scratch Host (`-DebugHostURL … -DebugHostSecret … -DebugHostPubKey … -DebugHostModel …`).
# The provider key is read from this Mac's Keychain (`airpad-live-<provider>`, put there by T) straight into the test
# runner's environment: never printed, never written. Afterwards every file the run wrote is checked for it.
set -uo pipefail
OUT=${1:?out_dir}; XCTR=${2:?xctestrun}; SET=${3:?set.json}; PROV=${4:?provider}; shift 4
SIM=${LIVE_SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}
BUNDLE=com.doctorpresident.airpad
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
log() { print -r -- "[live $(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }
CHATS=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); ids=[x for x in sys.argv[2].split(",") if x]; print(json.dumps([c["turns"] for c in d["chats"] if not ids or c["id"] in ids]))' "$SET" "${LIVE_ONLY:-}")
KEY=""; KEYARG=""
case $PROV in
  tavily) KEYARG=-TavilyTestKey; KEY=$(security find-generic-password -s airpad-live-tavily -w 2>/dev/null);;
  brave)  KEYARG=-BraveTestKey;  KEY=$(security find-generic-password -s airpad-live-brave -w 2>/dev/null);;
  none) ;;
  *) echo "provider: tavily|brave|none"; exit 2;;
esac
[[ $PROV != none && -z $KEY ]] && { log "could not read the Keychain item airpad-live-$PROV (missing, or the read was denied)"; exit 1; }
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null 2>&1
DATA=$(xcrun simctl get_app_container $SIM $BUNDLE data 2>/dev/null); [[ -n $DATA ]] && rm -f "$DATA/tmp/webtrace.jsonl"
log "provider=$PROV args=[$*] chats=$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$CHATS")"
rm -rf "$OUT/result.xcresult"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TEST_RUNNER_LIVE_CHATS="$CHATS" TEST_RUNNER_LIVE_ARGS="-webSearchProvider ${PROV/none/tavily} $*" \
TEST_RUNNER_LIVE_KEY="$KEY" TEST_RUNNER_LIVE_KEY_ARG="$KEYARG" TEST_RUNNER_LIVE_TURN_TIMEOUT=${LIVE_TURN_TIMEOUT:-300} \
  xcodebuild test-without-building -xctestrun "$XCTR" -destination "id=$SIM" -only-testing:AirPadUITests/LiveWebUI \
  -resultBundlePath "$OUT/result.xcresult" -collect-test-diagnostics never > "$OUT/xcuitest.log" 2>&1
log "xcodebuild exit $?"
/usr/bin/grep -E "\[LiveWeb\]|Test Case .*(passed|failed)" "$OUT/xcuitest.log" | /usr/bin/grep -v "^\s*t = " | tee -a "$OUT/run.log"
# Screenshots out, then the bundle goes: its compressed records can't be checked for the key (the app's launch arguments).
mkdir -p "$OUT/shots"; xcrun xcresulttool export attachments --path "$OUT/result.xcresult" --output-path "$OUT/shots" >/dev/null 2>&1
rm -rf "$OUT/result.xcresult"
DATA=$(xcrun simctl get_app_container $SIM $BUNDLE data 2>/dev/null)
cp "$DATA/tmp/webtrace.jsonl" "$OUT/webtrace.jsonl" 2>/dev/null || log "no trace"
if [[ -n $KEY ]]; then
  LEAKS=$(/usr/bin/grep -rlF -- "$KEY" "$OUT" 2>/dev/null)
  if [[ -n $LEAKS ]]; then
    log "KEY FOUND in $(print -r -- "$LEAKS" | wc -l | tr -d ' ') file(s) — removed:"; print -r -- "$LEAKS" | sed "s|$OUT/||" | tee -a "$OUT/run.log"
    print -r -- "$LEAKS" | while read -r f; do rm -f "$f"; done
  else log "key check: not in any file the run wrote"; fi
fi
KEY=""; unset KEY
python3 ${0:A:h}/grade.py "$SET" "$OUT/webtrace.jsonl" "$OUT" | tee -a "$OUT/run.log"
